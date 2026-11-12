// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IFundShareToken} from "../interfaces/IFundShareToken.sol";
import {NavOracle} from "../oracle/NavOracle.sol";

/// @title FundVault
/// @notice Subscriptions and redemptions for a NAV-priced fund, in the ERC-7540 request/claim style.
///
/// Life of an epoch:
///  1. Open. Investors call `requestDeposit` / `requestRedeem`. Assets and shares sit in the vault.
///     A request can be cancelled while the epoch is still open.
///  2. `closeEpoch` is the cut-off. Later requests go to the next epoch; closed requests are locked in.
///  3. The administrator values the fund and posts a NAV dated after the cut-off.
///  4. `settleEpoch` prices every request in the epoch at that NAV, mints and burns shares, and nets the
///     cash with the custodian. Redemptions can be filled in part (liquidity, or the per-epoch gate);
///     the unfilled part goes back to the investor as shares.
///  5. Investors claim with `deposit` / `redeem` (or the claim-all helpers) whenever they like.
///
/// Accounting is in base shares, so a split between request and claim changes nothing. Requests are
/// aggregated per controller (ERC-7540 requestId 0).
contract FundVault is AccessControl, ReentrancyGuard, Pausable {
    using SafeERC20 for IERC20;

    bytes32 public constant MANAGER_ROLE = keccak256("MANAGER_ROLE");

    uint256 internal constant ONE = 1e18;
    uint256 internal constant BPS = 10_000;

    struct Epoch {
        uint64 closedAt;
        uint64 settledAt;
        uint256 depositAssets; // assets requested in this epoch
        uint256 redeemShares; // base shares requested for redemption in this epoch
        uint256 sharesMinted; // base shares created for `depositAssets`
        uint256 redeemSharesFilled; // base shares burned
        uint256 assetsPaid; // assets set aside for `redeemSharesFilled`
        uint256 nav; // NAV per token used
        uint256 multiplier; // token multiplier at settlement
    }

    struct Account {
        uint256 pendingDepositAssets;
        uint64 depositEpoch;
        uint256 pendingRedeemShares; // base shares
        uint64 redeemEpoch;
        uint256 claimableDepositAssets;
        uint256 claimableDepositShares; // base shares
        uint256 claimableRedeemShares; // base shares
        uint256 claimableRedeemAssets;
        uint256 claimableReturnedShares; // base shares, the unfilled part of a redemption
    }

    IERC20 public immutable asset;
    IFundShareToken public immutable share;
    NavOracle public immutable oracle;
    /// @dev 10 ** (18 - asset decimals): turns asset units into the 18-decimal amounts NAV is quoted in.
    uint256 public immutable assetScale;

    /// @notice The fund's treasury. Net subscriptions are sent here; it must approve this vault so net
    ///         redemptions can be pulled back at settlement.
    address public custodian;
    uint256 public maxRedeemBpsPerEpoch;
    uint256 public minDeposit;

    uint64 public currentEpoch = 1;
    mapping(uint64 => Epoch) public epochs;
    mapping(address => Account) private _accounts;
    mapping(address => mapping(address => bool)) public isOperator;

    /// @notice Assets owed to investors: deposits not yet settled plus redemption proceeds not yet claimed.
    uint256 public reservedAssets;
    /// @notice Base shares owed to investors: redemptions not yet settled, plus settled subscriptions and
    ///         returned shares not yet claimed.
    uint256 public reservedShares;

    // ERC-7540 events
    event DepositRequest(
        address indexed controller, address indexed owner, uint256 indexed requestId, address sender, uint256 assets
    );
    event RedeemRequest(
        address indexed controller, address indexed owner, uint256 indexed requestId, address sender, uint256 shares
    );
    event OperatorSet(address indexed controller, address indexed operator, bool approved);
    // ERC-4626 events
    event Deposit(address indexed sender, address indexed owner, uint256 assets, uint256 shares);
    event Withdraw(
        address indexed sender, address indexed receiver, address indexed owner, uint256 assets, uint256 shares
    );

    event DepositRequestCancelled(address indexed controller, uint256 assets);
    event RedeemRequestCancelled(address indexed controller, uint256 shares);
    event ReturnedSharesClaimed(address indexed controller, uint256 shares);
    event EpochClosed(uint64 indexed epoch, uint64 closedAt);
    event EpochSettled(
        uint64 indexed epoch,
        uint256 nav,
        uint256 depositAssets,
        uint256 sharesMinted,
        uint256 redeemSharesFilled,
        uint256 assetsPaid
    );
    event CustodianSet(address indexed custodian);
    event LimitsSet(uint256 maxRedeemBpsPerEpoch, uint256 minDeposit);

    error ZeroAddress();
    error ZeroAmount();
    error NotAuthorized();
    error ControllerNotEligible(address controller);
    error BelowMinDeposit();
    error RequestLockedInClosedEpoch();
    error NothingToCancel();
    error PreviousEpochNotSettled();
    error NoEpochToSettle();
    error NavNotAfterCutoff(uint64 navAsOf, uint64 closedAt);
    error BadBps();
    error ExceedsClaimable();
    error ControllerFrozen(address controller);
    error AsyncVault();

    constructor(
        address admin,
        IERC20 asset_,
        IFundShareToken share_,
        NavOracle oracle_,
        address custodian_,
        uint256 maxRedeemBpsPerEpoch_,
        uint256 minDeposit_
    ) {
        if (admin == address(0) || custodian_ == address(0)) revert ZeroAddress();
        if (maxRedeemBpsPerEpoch_ == 0 || maxRedeemBpsPerEpoch_ > BPS) revert BadBps();
        asset = asset_;
        assetScale = 10 ** (18 - IERC20Metadata(address(asset_)).decimals());
        share = share_;
        oracle = oracle_;
        custodian = custodian_;
        maxRedeemBpsPerEpoch = maxRedeemBpsPerEpoch_;
        minDeposit = minDeposit_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    // ------------------------------------------------------------------ requests

    /// @notice Ask to subscribe `assets`. They are held here until the epoch settles.
    /// @return requestId Always 0: requests are aggregated per controller.
    function requestDeposit(uint256 assets, address controller, address owner)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 requestId)
    {
        if (owner != msg.sender && !isOperator[owner][msg.sender]) revert NotAuthorized();
        if (assets == 0) revert ZeroAmount();
        if (assets < minDeposit) revert BelowMinDeposit();
        // The controller will receive shares, so it must be able to hold them.
        if (!share.identityRegistry().isVerified(controller) || share.frozen(controller)) {
            revert ControllerNotEligible(controller);
        }

        Account storage a = _accounts[controller];
        _sync(a);
        if (a.pendingDepositAssets != 0 && a.depositEpoch != currentEpoch) revert RequestLockedInClosedEpoch();

        a.pendingDepositAssets += assets;
        a.depositEpoch = currentEpoch;
        epochs[currentEpoch].depositAssets += assets;
        reservedAssets += assets;

        asset.safeTransferFrom(owner, address(this), assets);
        emit DepositRequest(controller, owner, 0, msg.sender, assets);
        return 0;
    }

    /// @notice Ask to redeem `shares` (token units). The vault takes custody of them until settlement.
    ///         `owner` must have approved the vault on the share token.
    function requestRedeem(uint256 shares, address controller, address owner)
        external
        nonReentrant
        whenNotPaused
        returns (uint256 requestId)
    {
        if (owner != msg.sender && !isOperator[owner][msg.sender]) revert NotAuthorized();
        if (controller == address(0)) revert ZeroAddress();
        uint256 baseShares = share.tokensToShares(shares);
        if (baseShares == 0) revert ZeroAmount();

        Account storage a = _accounts[controller];
        _sync(a);
        if (a.pendingRedeemShares != 0 && a.redeemEpoch != currentEpoch) revert RequestLockedInClosedEpoch();

        a.pendingRedeemShares += baseShares;
        a.redeemEpoch = currentEpoch;
        epochs[currentEpoch].redeemShares += baseShares;
        reservedShares += baseShares;

        share.transferSharesFrom(owner, address(this), baseShares);
        emit RedeemRequest(controller, owner, 0, msg.sender, shares);
        return 0;
    }

    /// @notice Withdraw a subscription request. Only before the cut-off of its epoch.
    function cancelDepositRequest(address controller) external nonReentrant {
        _auth(controller);
        Account storage a = _accounts[controller];
        uint256 assets = a.pendingDepositAssets;
        if (assets == 0 || a.depositEpoch != currentEpoch) revert NothingToCancel();

        a.pendingDepositAssets = 0;
        epochs[currentEpoch].depositAssets -= assets;
        reservedAssets -= assets;

        asset.safeTransfer(controller, assets);
        emit DepositRequestCancelled(controller, assets);
    }

    /// @notice Withdraw a redemption request. Only before the cut-off of its epoch.
    function cancelRedeemRequest(address controller) external nonReentrant {
        _auth(controller);
        Account storage a = _accounts[controller];
        uint256 baseShares = a.pendingRedeemShares;
        if (baseShares == 0 || a.redeemEpoch != currentEpoch) revert NothingToCancel();

        a.pendingRedeemShares = 0;
        epochs[currentEpoch].redeemShares -= baseShares;
        reservedShares -= baseShares;

        share.transferShares(controller, baseShares);
        emit RedeemRequestCancelled(controller, baseShares);
    }

    // ------------------------------------------------------------------ epoch management

    /// @notice The cut-off. Everything requested so far will be priced at the next NAV.
    function closeEpoch() external onlyRole(MANAGER_ROLE) {
        uint64 id = currentEpoch;
        if (id > 1 && epochs[id - 1].settledAt == 0) revert PreviousEpochNotSettled();
        epochs[id].closedAt = uint64(block.timestamp);
        currentEpoch = id + 1;
        emit EpochClosed(id, uint64(block.timestamp));
    }

    /// @notice Price and execute the closed epoch.
    /// @param redeemFillBps Share of redemption requests to honour now (10_000 = all). The per-epoch gate
    ///        may reduce it further. Every redeemer in the epoch gets the same fill ratio.
    function settleEpoch(uint256 redeemFillBps) external nonReentrant onlyRole(MANAGER_ROLE) {
        if (redeemFillBps > BPS) revert BadBps();
        uint64 id = currentEpoch - 1;
        Epoch storage e = epochs[id];
        if (id == 0 || e.settledAt != 0) revert NoEpochToSettle();

        (uint256 nav, uint64 navAsOf) = oracle.freshNav();
        // Forward pricing: the valuation must postdate the cut-off, or requests would be priced at a
        // NAV that was public while they could still be placed or cancelled.
        if (navAsOf <= e.closedAt) revert NavNotAfterCutoff(navAsOf, e.closedAt);
        uint256 mult = share.multiplier();

        // Subscriptions: shares are rounded down, in favour of existing holders.
        uint256 minted = Math.mulDiv(Math.mulDiv(e.depositAssets * assetScale, ONE, nav), ONE, mult);

        // Redemptions: apply the manager's fill ratio, then the gate.
        uint256 filled = Math.mulDiv(e.redeemShares, redeemFillBps, BPS);
        uint256 gate = Math.mulDiv(share.totalShares(), maxRedeemBpsPerEpoch, BPS);
        if (filled > gate) filled = gate;
        uint256 paid = Math.mulDiv(Math.mulDiv(filled, mult, ONE), nav, ONE) / assetScale;

        e.settledAt = uint64(block.timestamp);
        e.sharesMinted = minted;
        e.redeemSharesFilled = filled;
        e.assetsPaid = paid;
        e.nav = nav;
        e.multiplier = mult;

        // Deposits stop being owed as assets and become owed as shares; filled redemptions the reverse.
        reservedAssets = reservedAssets - e.depositAssets + paid;
        reservedShares = reservedShares + minted - filled;

        if (e.depositAssets > paid) {
            asset.safeTransfer(custodian, e.depositAssets - paid);
        } else if (paid > e.depositAssets) {
            asset.safeTransferFrom(custodian, address(this), paid - e.depositAssets);
        }
        if (minted != 0) share.mintShares(address(this), minted);
        if (filled != 0) share.burnShares(filled);

        emit EpochSettled(id, nav, e.depositAssets, minted, filled, paid);
    }

    // ------------------------------------------------------------------ claims

    /// @notice Claim shares for `assets` of a settled subscription (ERC-7540 `deposit`).
    function deposit(uint256 assets, address receiver, address controller)
        external
        nonReentrant
        returns (uint256 shares)
    {
        _auth(controller);
        Account storage a = _accounts[controller];
        _sync(a);
        return _claimDeposit(a, controller, receiver, assets);
    }

    /// @notice Claim every share the controller is owed.
    function claimDeposit(address receiver, address controller) external nonReentrant returns (uint256 shares) {
        _auth(controller);
        Account storage a = _accounts[controller];
        _sync(a);
        return _claimDeposit(a, controller, receiver, a.claimableDepositAssets);
    }

    /// @notice Manager convenience: deliver a controller's settled shares to the controller itself, for
    ///         example before a distribution so the investor is on the register.
    function pushDepositShares(address controller)
        external
        nonReentrant
        onlyRole(MANAGER_ROLE)
        returns (uint256 shares)
    {
        Account storage a = _accounts[controller];
        _sync(a);
        return _claimDeposit(a, controller, controller, a.claimableDepositAssets);
    }

    /// @notice Claim assets for `shares` (token units) of a settled redemption (ERC-7540 `redeem`).
    function redeem(uint256 shares, address receiver, address controller)
        external
        nonReentrant
        returns (uint256 assets)
    {
        _auth(controller);
        Account storage a = _accounts[controller];
        _sync(a);
        return _claimRedeem(a, controller, receiver, share.tokensToShares(shares));
    }

    /// @notice Claim all redemption proceeds the controller is owed.
    function claimRedeem(address receiver, address controller) external nonReentrant returns (uint256 assets) {
        _auth(controller);
        Account storage a = _accounts[controller];
        _sync(a);
        return _claimRedeem(a, controller, receiver, a.claimableRedeemShares);
    }

    /// @notice Take back the shares of a redemption that was only partly filled.
    function claimReturnedShares(address controller) external nonReentrant returns (uint256 baseShares) {
        _auth(controller);
        Account storage a = _accounts[controller];
        _sync(a);
        baseShares = a.claimableReturnedShares;
        if (baseShares == 0) revert ZeroAmount();
        a.claimableReturnedShares = 0;
        reservedShares -= baseShares;
        share.transferShares(controller, baseShares);
        emit ReturnedSharesClaimed(controller, baseShares);
    }

    /// @notice Roll a controller's settled request into its claimable balance. Anyone may call it.
    function sync(address controller) external {
        _sync(_accounts[controller]);
    }

    // ------------------------------------------------------------------ operators

    function setOperator(address operator, bool approved) external returns (bool) {
        isOperator[msg.sender][operator] = approved;
        emit OperatorSet(msg.sender, operator, approved);
        return true;
    }

    // ------------------------------------------------------------------ admin

    function setCustodian(address custodian_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (custodian_ == address(0)) revert ZeroAddress();
        custodian = custodian_;
        emit CustodianSet(custodian_);
    }

    function setLimits(uint256 maxRedeemBpsPerEpoch_, uint256 minDeposit_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (maxRedeemBpsPerEpoch_ == 0 || maxRedeemBpsPerEpoch_ > BPS) revert BadBps();
        maxRedeemBpsPerEpoch = maxRedeemBpsPerEpoch_;
        minDeposit = minDeposit_;
        emit LimitsSet(maxRedeemBpsPerEpoch_, minDeposit_);
    }

    /// @notice Stop new requests. Cancels and claims keep working so investors are never trapped.
    function pause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // ------------------------------------------------------------------ views

    /// @notice True while a closed epoch is waiting for its NAV. Distributions and other value-moving
    ///         corporate actions must wait until it is settled.
    function hasUnsettledEpoch() public view returns (bool) {
        uint64 id = currentEpoch;
        return id > 1 && epochs[id - 1].settledAt == 0;
    }

    function accountOf(address controller) external view returns (Account memory a) {
        a = _accounts[controller];
        _applySync(a);
    }

    function pendingDepositRequest(uint256, address controller) external view returns (uint256) {
        Account memory a = _accounts[controller];
        _applySync(a);
        return a.pendingDepositAssets;
    }

    function claimableDepositRequest(uint256, address controller) public view returns (uint256) {
        Account memory a = _accounts[controller];
        _applySync(a);
        return a.claimableDepositAssets;
    }

    function pendingRedeemRequest(uint256, address controller) external view returns (uint256) {
        Account memory a = _accounts[controller];
        _applySync(a);
        return share.sharesToTokens(a.pendingRedeemShares);
    }

    function claimableRedeemRequest(uint256, address controller) public view returns (uint256) {
        Account memory a = _accounts[controller];
        _applySync(a);
        return share.sharesToTokens(a.claimableRedeemShares);
    }

    function maxDeposit(address controller) external view returns (uint256) {
        return claimableDepositRequest(0, controller);
    }

    function maxRedeem(address controller) external view returns (uint256) {
        return claimableRedeemRequest(0, controller);
    }

    /// @notice Fund value at the last posted NAV. Informational: it does not check freshness.
    function totalAssets() external view returns (uint256) {
        return Math.mulDiv(share.totalSupply(), oracle.nav(), ONE) / assetScale;
    }

    function convertToShares(uint256 assets) external view returns (uint256) {
        return Math.mulDiv(assets * assetScale, ONE, oracle.nav());
    }

    function convertToAssets(uint256 shares) external view returns (uint256) {
        return Math.mulDiv(shares, oracle.nav(), ONE) / assetScale;
    }

    /// @dev ERC-7540: previews must revert for asynchronous flows.
    function previewDeposit(uint256) external pure returns (uint256) {
        revert AsyncVault();
    }

    function previewRedeem(uint256) external pure returns (uint256) {
        revert AsyncVault();
    }

    function supportsInterface(bytes4 interfaceId) public view override returns (bool) {
        return interfaceId == 0xe3bc4e65 // ERC-7540 operator methods
            || interfaceId == 0xce3bbe50 // ERC-7540 asynchronous deposit
            || interfaceId == 0x620ee8e4 // ERC-7540 asynchronous redeem
            || interfaceId == 0x2f0a18c5 // ERC-7575
            || super.supportsInterface(interfaceId);
    }

    // ------------------------------------------------------------------ internals

    function _auth(address controller) private view {
        if (controller != msg.sender && !isOperator[controller][msg.sender]) revert NotAuthorized();
    }

    function _claimDeposit(Account storage a, address controller, address receiver, uint256 assets)
        private
        returns (uint256 tokens)
    {
        if (assets == 0) revert ZeroAmount();
        if (assets > a.claimableDepositAssets) revert ExceedsClaimable();
        uint256 baseShares = Math.mulDiv(a.claimableDepositShares, assets, a.claimableDepositAssets);
        a.claimableDepositAssets -= assets;
        a.claimableDepositShares -= baseShares;
        reservedShares -= baseShares;

        tokens = share.transferShares(receiver, baseShares); // reverts unless the receiver is eligible
        emit Deposit(controller, receiver, assets, tokens);
    }

    function _claimRedeem(Account storage a, address controller, address receiver, uint256 baseShares)
        private
        returns (uint256 assets)
    {
        if (baseShares == 0) revert ZeroAmount();
        if (baseShares > a.claimableRedeemShares) revert ExceedsClaimable();
        // A frozen investor (sanctions, court order) cannot pull cash out; an expired KYC does not
        // trap anyone, since leaving the fund needs no new eligibility.
        if (share.frozen(controller)) revert ControllerFrozen(controller);
        if (receiver == address(0)) revert ZeroAddress();

        assets = Math.mulDiv(a.claimableRedeemAssets, baseShares, a.claimableRedeemShares);
        a.claimableRedeemShares -= baseShares;
        a.claimableRedeemAssets -= assets;
        reservedAssets -= assets;

        asset.safeTransfer(receiver, assets);
        emit Withdraw(msg.sender, receiver, controller, assets, share.sharesToTokens(baseShares));
    }

    function _sync(Account storage a) private {
        Account memory m = a;
        if (_applySync(m)) {
            a.pendingDepositAssets = m.pendingDepositAssets;
            a.pendingRedeemShares = m.pendingRedeemShares;
            a.claimableDepositAssets = m.claimableDepositAssets;
            a.claimableDepositShares = m.claimableDepositShares;
            a.claimableRedeemShares = m.claimableRedeemShares;
            a.claimableRedeemAssets = m.claimableRedeemAssets;
            a.claimableReturnedShares = m.claimableReturnedShares;
        }
    }

    /// @dev Moves a settled request into the claimable buckets. Every share of an epoch's totals is
    ///      rounded down per account, so the accounts of an epoch can never be owed more than the epoch
    ///      produced; the few wei of dust stay in the vault.
    function _applySync(Account memory a) private view returns (bool changed) {
        if (a.pendingDepositAssets != 0) {
            Epoch storage e = epochs[a.depositEpoch];
            if (e.settledAt != 0) {
                a.claimableDepositShares += Math.mulDiv(a.pendingDepositAssets, e.sharesMinted, e.depositAssets);
                a.claimableDepositAssets += a.pendingDepositAssets;
                a.pendingDepositAssets = 0;
                changed = true;
            }
        }
        if (a.pendingRedeemShares != 0) {
            Epoch storage e = epochs[a.redeemEpoch];
            if (e.settledAt != 0) {
                uint256 req = a.pendingRedeemShares;
                a.claimableRedeemShares += Math.mulDiv(req, e.redeemSharesFilled, e.redeemShares);
                a.claimableRedeemAssets += Math.mulDiv(req, e.assetsPaid, e.redeemShares);
                a.claimableReturnedShares +=
                    Math.mulDiv(req, e.redeemShares - e.redeemSharesFilled, e.redeemShares);
                a.pendingRedeemShares = 0;
                changed = true;
            }
        }
    }
}
