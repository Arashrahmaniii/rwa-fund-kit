// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

/// @title NavOracle
/// @notice Net asset value per share token, pushed by the fund administrator.
///
/// `nav` is the price of one whole share token in whole units of the vault's asset, with 18 decimals,
/// whatever the asset's own decimals are. For a fund at 1.05 USDC per share, nav = 1.05e18.
///
/// Three protections:
///  - `asOf` is the valuation time. The vault only settles an epoch with a NAV valued after that epoch's
///    cut-off, so nobody can subscribe or redeem against a price they already know (forward pricing).
///  - a NAV that moves more than `maxDeviationBps` from the last one is parked until a second role, the
///    GUARDIAN, confirms it. One compromised or fat-fingered poster cannot reprice the fund alone.
///  - `freshNav` reverts when the NAV is older than `maxStaleness`.
contract NavOracle is AccessControl {
    bytes32 public constant ORACLE_ROLE = keccak256("ORACLE_ROLE");
    bytes32 public constant GUARDIAN_ROLE = keccak256("GUARDIAN_ROLE");
    bytes32 public constant CORPORATE_ACTIONS_ROLE = keccak256("CORPORATE_ACTIONS_ROLE");

    uint256 internal constant BPS = 10_000;

    uint256 public nav;
    uint64 public asOf;
    uint64 public postedAt;

    uint256 public pendingNav;
    uint64 public pendingAsOf;

    uint256 public maxDeviationBps;
    uint64 public maxStaleness;

    event NavPosted(uint256 nav, uint64 asOf);
    event NavPendingConfirmation(uint256 nav, uint64 asOf, uint256 deviationBps);
    event PendingNavRejected(uint256 nav, uint64 asOf);
    event NavRescaled(uint256 oldNav, uint256 newNav, uint256 numerator, uint256 denominator);
    event LimitsSet(uint256 maxDeviationBps, uint64 maxStaleness);

    error ZeroNav();
    error AsOfInFuture();
    error AsOfNotAfterPrevious();
    error NoPendingNav();
    error StaleNav(uint64 postedAt, uint64 maxStaleness);
    error NavNotSet();
    error BadLimits();
    error BadRatio();

    constructor(address admin, uint256 initialNav, uint256 maxDeviationBps_, uint64 maxStaleness_) {
        if (initialNav == 0) revert ZeroNav();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        _setLimits(maxDeviationBps_, maxStaleness_);
        nav = initialNav;
        asOf = uint64(block.timestamp);
        postedAt = uint64(block.timestamp);
        emit NavPosted(initialNav, uint64(block.timestamp));
    }

    /// @notice Post a new NAV valued at `asOf_`. Large moves wait for the guardian.
    function postNav(uint256 newNav, uint64 asOf_) external onlyRole(ORACLE_ROLE) {
        if (newNav == 0) revert ZeroNav();
        if (asOf_ > block.timestamp) revert AsOfInFuture();
        if (asOf_ <= asOf) revert AsOfNotAfterPrevious();

        uint256 diff = newNav > nav ? newNav - nav : nav - newNav;
        uint256 deviationBps = Math.mulDiv(diff, BPS, nav);
        if (deviationBps > maxDeviationBps) {
            pendingNav = newNav;
            pendingAsOf = asOf_;
            emit NavPendingConfirmation(newNav, asOf_, deviationBps);
            return;
        }
        _accept(newNav, asOf_);
    }

    /// @notice Second signature for a NAV outside the deviation band.
    function confirmPendingNav() external onlyRole(GUARDIAN_ROLE) {
        if (pendingNav == 0) revert NoPendingNav();
        _accept(pendingNav, pendingAsOf);
    }

    function rejectPendingNav() external onlyRole(GUARDIAN_ROLE) {
        if (pendingNav == 0) revert NoPendingNav();
        emit PendingNavRejected(pendingNav, pendingAsOf);
        pendingNav = 0;
        pendingAsOf = 0;
    }

    /// @notice Keep the price of a base share constant across a split: when the token multiplier is
    ///         multiplied by numerator/denominator, the NAV per token is divided by the same ratio.
    /// @dev    Valuation time is left alone. A split is not a new valuation.
    function rescaleForSplit(uint256 numerator, uint256 denominator) external onlyRole(CORPORATE_ACTIONS_ROLE) {
        if (numerator == 0 || denominator == 0) revert BadRatio();
        uint256 newNav = Math.mulDiv(nav, denominator, numerator);
        if (newNav == 0) revert ZeroNav();
        emit NavRescaled(nav, newNav, numerator, denominator);
        nav = newNav;
        if (pendingNav != 0) {
            pendingNav = Math.mulDiv(pendingNav, denominator, numerator);
        }
    }

    function setLimits(uint256 maxDeviationBps_, uint64 maxStaleness_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        _setLimits(maxDeviationBps_, maxStaleness_);
    }

    /// @notice Latest NAV and its valuation time. Reverts if it is too old to transact on.
    function freshNav() external view returns (uint256, uint64) {
        if (nav == 0) revert NavNotSet();
        if (block.timestamp - postedAt > maxStaleness) revert StaleNav(postedAt, maxStaleness);
        return (nav, asOf);
    }

    /// @dev Accepting any NAV drops a parked one: a parked NAV is always older than the one that
    ///      replaced it, and confirming it later would move the valuation time backwards.
    function _accept(uint256 newNav, uint64 asOf_) private {
        nav = newNav;
        asOf = asOf_;
        postedAt = uint64(block.timestamp);
        pendingNav = 0;
        pendingAsOf = 0;
        emit NavPosted(newNav, asOf_);
    }

    function _setLimits(uint256 maxDeviationBps_, uint64 maxStaleness_) private {
        if (maxDeviationBps_ == 0 || maxDeviationBps_ > BPS || maxStaleness_ == 0) revert BadLimits();
        maxDeviationBps = maxDeviationBps_;
        maxStaleness = maxStaleness_;
        emit LimitsSet(maxDeviationBps_, maxStaleness_);
    }
}
