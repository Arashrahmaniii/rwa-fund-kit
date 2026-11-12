// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {IIdentityRegistry} from "../interfaces/IIdentityRegistry.sol";
import {ICompliance} from "../interfaces/ICompliance.sol";
import {IFundShareToken} from "../interfaces/IFundShareToken.sol";

/// @title FundShareToken
/// @notice Permissioned fund share in the ERC-3643 model, with a share multiplier for splits.
///
/// Two units are used throughout:
///  - base shares: what the contract stores. They only change on mint, burn and transfer.
///  - tokens: what wallets display. tokens = base shares * multiplier / 1e18.
/// A split changes `multiplier` and nothing else, so it cannot move value between holders. Every
/// other contract in the kit (vault, compliance modules, distributions, gateway) accounts in base
/// shares for the same reason.
///
/// Transfer rules (as in T-REX): the receiver must be a verified investor or a system address, neither
/// side may be frozen, the sender may only move unfrozen shares, and the compliance modules must agree.
contract FundShareToken is IFundShareToken, IERC20Metadata, AccessControl, Pausable {
    bytes32 public constant AGENT_ROLE = keccak256("AGENT_ROLE");
    bytes32 public constant MINTER_ROLE = keccak256("MINTER_ROLE");
    bytes32 public constant CORPORATE_ACTIONS_ROLE = keccak256("CORPORATE_ACTIONS_ROLE");

    uint256 internal constant ONE = 1e18;
    /// @dev Keeps `sharesToTokens` far from overflow and from rounding every balance to zero.
    uint256 public constant MIN_MULTIPLIER = 1e9;
    uint256 public constant MAX_MULTIPLIER = 1e27;

    string private _name;
    string private _symbol;

    IIdentityRegistry public identityRegistry;
    ICompliance public compliance;

    uint256 public multiplier = ONE;
    uint256 private _totalShares;
    mapping(address => uint256) private _shares;
    mapping(address => mapping(address => uint256)) private _allowances; // in tokens

    mapping(address => bool) public frozen;
    mapping(address => uint256) public frozenShares;
    /// @notice Protocol contracts (vault, gateway) that hold shares in transit. They skip the identity
    ///         check and are ignored by investor-level rules.
    mapping(address => bool) public isSystem;

    event TransferShares(address indexed from, address indexed to, uint256 shares);
    event MultiplierUpdated(uint256 oldMultiplier, uint256 newMultiplier);
    event AddressFrozen(address indexed account, bool isFrozen, address indexed agent);
    event SharesFrozen(address indexed account, uint256 shares);
    event SharesUnfrozen(address indexed account, uint256 shares);
    event RecoverySuccess(address indexed lostWallet, address indexed newWallet);
    event SystemAddressSet(address indexed account, bool isSystem);
    event IdentityRegistrySet(address indexed registry);
    event ComplianceSet(address indexed compliance);

    error ZeroAddress();
    error ReceiverNotVerified(address to);
    error WalletFrozen(address account);
    error InsufficientUnfrozenShares(address from, uint256 available, uint256 needed);
    error ComplianceRejected(address from, address to, uint256 shares);
    error InsufficientAllowance(address spender, uint256 allowance, uint256 needed);
    error MultiplierOutOfRange(uint256 multiplier);
    error SystemAddressHoldsShares(address account);
    error FreezeExceedsBalance();
    error UnfreezeExceedsFrozen();

    constructor(
        string memory name_,
        string memory symbol_,
        address admin,
        IIdentityRegistry registry_,
        ICompliance compliance_
    ) {
        if (admin == address(0) || address(registry_) == address(0) || address(compliance_) == address(0)) {
            revert ZeroAddress();
        }
        _name = name_;
        _symbol = symbol_;
        identityRegistry = registry_;
        compliance = compliance_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    // ------------------------------------------------------------------ ERC-20 views

    function name() external view returns (string memory) {
        return _name;
    }

    function symbol() external view returns (string memory) {
        return _symbol;
    }

    function decimals() external pure returns (uint8) {
        return 18;
    }

    function totalSupply() external view returns (uint256) {
        return sharesToTokens(_totalShares);
    }

    function balanceOf(address account) external view returns (uint256) {
        return sharesToTokens(_shares[account]);
    }

    function allowance(address owner, address spender) external view returns (uint256) {
        return _allowances[owner][spender];
    }

    // ------------------------------------------------------------------ share views

    function totalShares() external view returns (uint256) {
        return _totalShares;
    }

    function sharesOf(address account) external view returns (uint256) {
        return _shares[account];
    }

    /// @notice Base shares for a token amount, rounded down.
    function tokensToShares(uint256 tokens) public view returns (uint256) {
        return Math.mulDiv(tokens, ONE, multiplier);
    }

    /// @notice Token amount for base shares, rounded down.
    function sharesToTokens(uint256 shares) public view returns (uint256) {
        return Math.mulDiv(shares, multiplier, ONE);
    }

    // ------------------------------------------------------------------ ERC-20 actions

    function approve(address spender, uint256 tokens) external returns (bool) {
        if (spender == address(0)) revert ZeroAddress();
        _allowances[msg.sender][spender] = tokens;
        emit Approval(msg.sender, spender, tokens);
        return true;
    }

    function transfer(address to, uint256 tokens) external returns (bool) {
        _transferChecked(msg.sender, to, tokensToShares(tokens));
        return true;
    }

    function transferFrom(address from, address to, uint256 tokens) external returns (bool) {
        _spendAllowance(from, msg.sender, tokens);
        _transferChecked(from, to, tokensToShares(tokens));
        return true;
    }

    /// @notice Move an exact number of base shares. Use this from contracts so rounding never drifts.
    function transferShares(address to, uint256 shares) external returns (uint256 tokens) {
        _transferChecked(msg.sender, to, shares);
        return sharesToTokens(shares);
    }

    /// @notice As `transferShares`, spending allowance. The allowance is charged in tokens, rounded up.
    function transferSharesFrom(address from, address to, uint256 shares) external returns (uint256 tokens) {
        _spendAllowance(from, msg.sender, Math.mulDiv(shares, multiplier, ONE, Math.Rounding.Ceil));
        _transferChecked(from, to, shares);
        return sharesToTokens(shares);
    }

    // ------------------------------------------------------------------ mint / burn

    /// @notice Create shares for a verified investor or a system address.
    function mintShares(address to, uint256 shares) external onlyRole(MINTER_ROLE) {
        _requireReceiver(to);
        if (!compliance.canTransfer(address(0), to, shares)) revert ComplianceRejected(address(0), to, shares);
        _totalShares += shares;
        _shares[to] += shares;
        compliance.created(to, shares);
        emit TransferShares(address(0), to, shares);
        emit Transfer(address(0), to, sharesToTokens(shares));
    }

    /// @notice Destroy shares the caller holds. Minters burn what they have taken into custody, so an
    ///         investor's balance can only be burned after the investor (or an agent) moved it there.
    function burnShares(uint256 shares) external onlyRole(MINTER_ROLE) {
        _shares[msg.sender] -= shares;
        _totalShares -= shares;
        compliance.destroyed(msg.sender, shares);
        emit TransferShares(msg.sender, address(0), shares);
        emit Transfer(msg.sender, address(0), sharesToTokens(shares));
    }

    // ------------------------------------------------------------------ agent controls

    function pause() external onlyRole(AGENT_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(AGENT_ROLE) {
        _unpause();
    }

    function setAddressFrozen(address account, bool isFrozen) external onlyRole(AGENT_ROLE) {
        frozen[account] = isFrozen;
        emit AddressFrozen(account, isFrozen, msg.sender);
    }

    function freezePartialShares(address account, uint256 shares) external onlyRole(AGENT_ROLE) {
        if (frozenShares[account] + shares > _shares[account]) revert FreezeExceedsBalance();
        frozenShares[account] += shares;
        emit SharesFrozen(account, shares);
    }

    function unfreezePartialShares(address account, uint256 shares) external onlyRole(AGENT_ROLE) {
        if (shares > frozenShares[account]) revert UnfreezeExceedsFrozen();
        frozenShares[account] -= shares;
        emit SharesUnfrozen(account, shares);
    }

    /// @notice Court order or error correction: move shares without the holder's signature.
    /// @dev    As in T-REX it works while paused and from a frozen wallet, releases partially frozen
    ///         shares when it has to, and skips the module checks. The receiver must still be eligible,
    ///         and modules are still notified so their counters stay right.
    function forcedTransfer(address from, address to, uint256 shares) external onlyRole(AGENT_ROLE) {
        _requireReceiverIdentity(to);
        uint256 free = _shares[from] - frozenShares[from];
        if (shares > free) {
            uint256 release = shares - free; // reverts below if `shares` exceeds the whole balance
            frozenShares[from] -= release;
            emit SharesUnfrozen(from, release);
        }
        _move(from, to, shares);
    }

    /// @notice Lost-key recovery: move everything from `lostWallet` to the investor's new verified wallet.
    function recoveryAddress(address lostWallet, address newWallet) external onlyRole(AGENT_ROLE) {
        _requireReceiverIdentity(newWallet);
        uint256 shares = _shares[lostWallet];
        uint256 frozenPart = frozenShares[lostWallet];
        frozenShares[lostWallet] = 0;
        _move(lostWallet, newWallet, shares);
        if (frozenPart != 0) {
            frozenShares[newWallet] += frozenPart;
            emit SharesFrozen(newWallet, frozenPart);
        }
        if (frozen[lostWallet]) {
            frozen[newWallet] = true;
            emit AddressFrozen(newWallet, true, msg.sender);
        }
        emit RecoverySuccess(lostWallet, newWallet);
    }

    // ------------------------------------------------------------------ corporate actions

    /// @notice Change how many tokens one base share displays as (stock split / reverse split).
    /// @dev    Call it through `CorporateActions`, which rescales the NAV oracle in the same transaction.
    function setMultiplier(uint256 newMultiplier) external onlyRole(CORPORATE_ACTIONS_ROLE) {
        if (newMultiplier < MIN_MULTIPLIER || newMultiplier > MAX_MULTIPLIER) {
            revert MultiplierOutOfRange(newMultiplier);
        }
        emit MultiplierUpdated(multiplier, newMultiplier);
        multiplier = newMultiplier;
    }

    // ------------------------------------------------------------------ admin wiring

    /// @notice Mark a protocol contract. Only while it holds no shares, so no module ever sees an
    ///         address change category with a balance.
    function setSystemAddress(address account, bool system) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_shares[account] != 0) revert SystemAddressHoldsShares(account);
        isSystem[account] = system;
        emit SystemAddressSet(account, system);
    }

    function setIdentityRegistry(IIdentityRegistry registry_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(registry_) == address(0)) revert ZeroAddress();
        identityRegistry = registry_;
        emit IdentityRegistrySet(address(registry_));
    }

    function setCompliance(ICompliance compliance_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(compliance_) == address(0)) revert ZeroAddress();
        compliance = compliance_;
        emit ComplianceSet(address(compliance_));
    }

    // ------------------------------------------------------------------ internals

    function _spendAllowance(address owner, address spender, uint256 tokens) private {
        uint256 current = _allowances[owner][spender];
        if (current != type(uint256).max) {
            if (current < tokens) revert InsufficientAllowance(spender, current, tokens);
            _allowances[owner][spender] = current - tokens;
        }
    }

    function _requireReceiverIdentity(address to) private view {
        if (to == address(0)) revert ZeroAddress();
        if (!isSystem[to] && !identityRegistry.isVerified(to)) revert ReceiverNotVerified(to);
    }

    function _requireReceiver(address to) private view {
        _requireReceiverIdentity(to);
        if (frozen[to]) revert WalletFrozen(to);
    }

    function _transferChecked(address from, address to, uint256 shares) private whenNotPaused {
        if (frozen[from]) revert WalletFrozen(from);
        _requireReceiver(to);
        uint256 available = _shares[from] - frozenShares[from];
        if (shares > available) revert InsufficientUnfrozenShares(from, available, shares);
        if (!compliance.canTransfer(from, to, shares)) revert ComplianceRejected(from, to, shares);
        _move(from, to, shares);
    }

    function _move(address from, address to, uint256 shares) private {
        _shares[from] -= shares;
        _shares[to] += shares;
        compliance.transferred(from, to, shares);
        emit TransferShares(from, to, shares);
        emit Transfer(from, to, sharesToTokens(shares));
    }
}
