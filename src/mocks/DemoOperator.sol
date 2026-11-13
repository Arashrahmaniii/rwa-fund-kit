// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IdentityRegistry} from "../identity/IdentityRegistry.sol";
import {FundVault} from "../vault/FundVault.sol";
import {NavOracle} from "../oracle/NavOracle.sol";
import {MockUSDC} from "./MockUSDC.sol";

/// @title DemoOperator
/// @notice TESTNET ONLY. Lets any visitor play every part of a dealing day on the public demo:
///         verify themselves, get test USDC, close the epoch, value the fund and settle.
/// @dev    It holds the transfer-agent, manager and NAV-poster roles and acts as custodian, which is
///         exactly the concentration of power the threat model tells a real issuer to avoid. Never
///         deploy it next to real money.
contract DemoOperator {
    IdentityRegistry public registry;
    FundVault public vault;
    NavOracle public oracle;
    MockUSDC public usdc;
    address public immutable deployer;

    int256 public constant MAX_DRIFT_BPS = 100; // each demo valuation may move the NAV by at most 1%

    error AlreadyInitialised();
    error OnlyDeployer();
    error DriftTooLarge();

    constructor() {
        deployer = msg.sender;
    }

    function init(IdentityRegistry registry_, FundVault vault_, NavOracle oracle_, MockUSDC usdc_) external {
        if (msg.sender != deployer) revert OnlyDeployer();
        if (address(vault) != address(0)) revert AlreadyInitialised();
        registry = registry_;
        vault = vault_;
        oracle = oracle_;
        usdc = usdc_;
        usdc_.approve(address(vault_), type(uint256).max); // custodian duty: fund net redemptions
    }

    /// @notice Become a verified demo investor (Germany, retail, 90 days) and receive 100,000 test USDC.
    function onboard() external {
        registry.registerIdentity(msg.sender, 276, 2, uint64(block.timestamp + 90 days));
        usdc.mint(msg.sender, 100_000e6);
    }

    /// @notice The cut-off.
    function closeEpoch() external {
        vault.closeEpoch();
    }

    /// @notice Value the fund and settle the closed epoch in full. Must be a later block than the cut-off.
    /// @param driftBps How far to move the NAV from its last value, in basis points (-100 to 100).
    function valueAndSettle(int256 driftBps) external {
        if (driftBps > MAX_DRIFT_BPS || driftBps < -MAX_DRIFT_BPS) revert DriftTooLarge();
        uint256 nav = oracle.nav() * uint256(10_000 + driftBps) / 10_000;
        oracle.postNav(nav, uint64(block.timestamp));
        // A real custodian holds the fund's cash. The demo one prints what it is short.
        if (usdc.balanceOf(address(this)) < 10_000_000e6) usdc.mint(address(this), 10_000_000e6);
        vault.settleEpoch(10_000);
    }
}
