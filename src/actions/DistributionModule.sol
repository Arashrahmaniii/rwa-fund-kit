// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AbstractModule} from "../compliance/modules/AbstractModule.sol";
import {IFundShareToken} from "../interfaces/IFundShareToken.sol";

interface IEpochGuard {
    function hasUnsettledEpoch() external view returns (bool);
}

/// @title DistributionModule
/// @notice Dividends and coupons, paid pro rata to investors in a payment token.
///
/// It is bound to the token as a compliance module, not because it restricts anything (its check always
/// passes) but because the module hooks tell it about every share movement. That lets it keep a
/// cumulative "paid per share" figure and settle each wallet's entitlement at the moment its balance
/// changes, so a distribution costs one storage write however many investors there are, and shares
/// bought after a distribution earn nothing from it.
///
/// Payout is pull-based: a holder (or anyone on their behalf) calls `claim` and the money goes to the
/// holder. One wallet that cannot receive the payment token (for example a USDC-blocklisted address)
/// only blocks itself.
///
/// Shares held by system addresses (the vault's escrow, the bridge) earn nothing. The record date of
/// a distribution is the block it is funded in.
contract DistributionModule is AbstractModule {
    using SafeERC20 for IERC20;

    uint256 internal constant PRECISION = 1e27;

    IERC20 public immutable payToken;
    IEpochGuard public epochGuard;

    /// @notice Base shares held by investors (total minus system addresses).
    uint256 public eligibleShares;
    uint256 public accPerShare; // payToken per base share, scaled by PRECISION
    uint256 public totalDistributed;
    uint256 public totalClaimed;

    mapping(address => uint256) private _debt; // entitlement already accounted for
    mapping(address => uint256) private _owed; // settled, not yet paid

    event Distributed(address indexed from, uint256 amount, uint256 eligibleShares);
    event Claimed(address indexed holder, uint256 amount);
    event EntitlementReassigned(address indexed from, address indexed to, uint256 amount);
    event EpochGuardSet(address indexed guard);

    error ZeroAmount();
    error NoEligibleShares();
    error EpochAwaitingSettlement();
    error HolderNotVerified(address holder);
    error HolderFrozen(address holder);

    constructor(address compliance_, IFundShareToken token_, address owner_, IERC20 payToken_)
        AbstractModule(compliance_, token_, owner_)
    {
        payToken = payToken_;
    }

    /// @notice Point at the vault so distributions wait while a closed epoch is being priced.
    function setEpochGuard(IEpochGuard guard) external onlyOwner {
        epochGuard = guard;
        emit EpochGuardSet(address(guard));
    }

    /// @notice Fund a distribution for the investors on the register right now.
    /// @dev    Blocked between an epoch's cut-off and its settlement: redeemers in that epoch no longer
    ///         hold their shares, and paying cash out of the fund before their NAV is struck would take
    ///         value from them.
    function distribute(uint256 amount) external onlyOwner {
        if (amount == 0) revert ZeroAmount();
        if (eligibleShares == 0) revert NoEligibleShares();
        if (address(epochGuard) != address(0) && epochGuard.hasUnsettledEpoch()) revert EpochAwaitingSettlement();

        payToken.safeTransferFrom(msg.sender, address(this), amount);
        accPerShare += Math.mulDiv(amount, PRECISION, eligibleShares);
        totalDistributed += amount;
        emit Distributed(msg.sender, amount, eligibleShares);
    }

    /// @notice Pay `holder` everything it has earned. Callable by anyone; the money goes to the holder.
    function claim(address holder) external returns (uint256 amount) {
        if (!token.identityRegistry().isVerified(holder)) revert HolderNotVerified(holder);
        if (token.frozen(holder)) revert HolderFrozen(holder);
        _settle(holder, _balance(holder));
        amount = _owed[holder];
        if (amount == 0) revert ZeroAmount();
        _owed[holder] = 0;
        totalClaimed += amount;
        payToken.safeTransfer(holder, amount);
        emit Claimed(holder, amount);
    }

    /// @notice After a wallet recovery, move the lost wallet's unpaid entitlement to the new wallet.
    function reassignEntitlement(address from, address to) external onlyOwner {
        _settle(from, _balance(from));
        _settle(to, _balance(to));
        uint256 amount = _owed[from];
        _owed[from] = 0;
        _owed[to] += amount;
        emit EntitlementReassigned(from, to, amount);
    }

    function claimable(address holder) external view returns (uint256) {
        uint256 accrued = Math.mulDiv(_balance(holder), accPerShare, PRECISION);
        uint256 debt = _debt[holder];
        return _owed[holder] + (accrued > debt ? accrued - debt : 0);
    }

    // ------------------------------------------------------------------ module hooks

    function moduleCheck(address, address, uint256) external pure returns (bool) {
        return true;
    }

    function moduleTransferAction(address from, address to, uint256 shares) external onlyCompliance {
        if (shares == 0 || from == to) return;
        _afterDecrease(from, shares);
        _afterIncrease(to, shares);
    }

    function moduleMintAction(address to, uint256 shares) external onlyCompliance {
        if (shares == 0) return;
        _afterIncrease(to, shares);
    }

    function moduleBurnAction(address from, uint256 shares) external onlyCompliance {
        if (shares == 0) return;
        _afterDecrease(from, shares);
    }

    function name() external pure returns (string memory) {
        return "DistributionModule";
    }

    // ------------------------------------------------------------------ internals

    /// @dev Hooks run after the token updated balances, so the balance before the move is rebuilt here.
    function _afterIncrease(address account, uint256 shares) private {
        if (token.isSystem(account)) return;
        uint256 balanceNow = token.sharesOf(account);
        _settle(account, balanceNow - shares);
        _debt[account] = _debtFor(balanceNow);
        eligibleShares += shares;
    }

    function _afterDecrease(address account, uint256 shares) private {
        if (token.isSystem(account)) return;
        uint256 balanceNow = token.sharesOf(account);
        _settle(account, balanceNow + shares);
        _debt[account] = _debtFor(balanceNow);
        eligibleShares -= shares;
    }

    /// @dev Books what `account` earned on `balance` since its last settlement.
    function _settle(address account, uint256 balance) private {
        uint256 accrued = Math.mulDiv(balance, accPerShare, PRECISION);
        uint256 debt = _debt[account];
        if (accrued > debt) {
            _owed[account] += accrued - debt;
            _debt[account] = accrued;
        }
    }

    /// @dev The starting point for a balance that just changed, rounded UP. Entitlements are rounded
    ///      down, so `floor(now) - ceil(start)` can never exceed the exact amount earned. With both
    ///      rounded down, each balance change could over-credit by a fraction of a unit, and across
    ///      many changes the sum owed could exceed what was funded (found by
    ///      `invariant_distributionsAreFullyFunded`).
    function _debtFor(uint256 balance) private view returns (uint256) {
        return Math.mulDiv(balance, accPerShare, PRECISION, Math.Rounding.Ceil);
    }

    function _balance(address account) private view returns (uint256) {
        return token.isSystem(account) ? 0 : token.sharesOf(account);
    }
}
