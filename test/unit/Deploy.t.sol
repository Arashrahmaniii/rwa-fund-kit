// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {MockUSDC} from "../../src/mocks/MockUSDC.sol";

/// @notice The deployment script is part of the product: a wrong role at launch is an incident.
contract DeployTest is Test {
    address internal admin = makeAddr("admin");
    address internal agent = makeAddr("agent");
    address internal manager = makeAddr("manager");
    address internal navPoster = makeAddr("navPoster");
    address internal guardian = makeAddr("guardian");
    address internal custodian = makeAddr("custodian");
    address internal investor = makeAddr("investor");

    Deploy internal script;
    Deploy.Deployment internal d;

    function setUp() public {
        vm.warp(1_800_000_000);
        script = new Deploy();
        d = script.deploy(address(script), Deploy.Config(admin, agent, manager, navPoster, guardian, custodian));
    }

    function test_deployerKeepsNoRights() public view {
        address deployer = address(script);
        bytes32 adminRole = 0x00;
        assertFalse(d.registry.hasRole(adminRole, deployer));
        assertFalse(d.token.hasRole(adminRole, deployer));
        assertFalse(d.oracle.hasRole(adminRole, deployer));
        assertFalse(d.vault.hasRole(adminRole, deployer));
        assertFalse(d.actions.hasRole(adminRole, deployer));
        assertTrue(d.compliance.owner() != deployer);
        assertTrue(d.distributions.owner() != deployer);
        assertTrue(d.countryModule.owner() != deployer);
        assertTrue(d.holdersModule.owner() != deployer);
    }

    function test_adminHoldsEveryAdminRole() public view {
        bytes32 adminRole = 0x00;
        assertTrue(d.registry.hasRole(adminRole, admin));
        assertTrue(d.token.hasRole(adminRole, admin));
        assertTrue(d.oracle.hasRole(adminRole, admin));
        assertTrue(d.vault.hasRole(adminRole, admin));
        assertTrue(d.actions.hasRole(adminRole, admin));
        assertEq(d.compliance.owner(), admin);
        assertEq(d.distributions.owner(), admin);
        assertEq(d.countryModule.owner(), admin);
        assertEq(d.holdersModule.owner(), admin);
    }

    function test_sensitiveRolesAreHeldOnlyByContracts() public view {
        assertTrue(d.token.hasRole(d.token.MINTER_ROLE(), address(d.vault)));
        assertFalse(d.token.hasRole(d.token.MINTER_ROLE(), admin));
        assertFalse(d.token.hasRole(d.token.MINTER_ROLE(), agent));

        assertTrue(d.token.hasRole(d.token.CORPORATE_ACTIONS_ROLE(), address(d.actions)));
        assertFalse(d.token.hasRole(d.token.CORPORATE_ACTIONS_ROLE(), admin));
        assertTrue(d.oracle.hasRole(d.oracle.CORPORATE_ACTIONS_ROLE(), address(d.actions)));
        assertFalse(d.oracle.hasRole(d.oracle.CORPORATE_ACTIONS_ROLE(), admin));

        assertTrue(d.token.isSystem(address(d.vault)));
        assertEq(address(d.distributions.epochGuard()), address(d.vault));
        assertEq(d.compliance.token(), address(d.token));
        assertEq(d.compliance.modules().length, 3);
        assertEq(d.vault.custodian(), custodian);
    }

    function test_operatingRoles() public view {
        assertTrue(d.registry.hasRole(d.registry.AGENT_ROLE(), agent));
        assertTrue(d.token.hasRole(d.token.AGENT_ROLE(), agent));
        assertTrue(d.oracle.hasRole(d.oracle.ORACLE_ROLE(), navPoster));
        assertTrue(d.oracle.hasRole(d.oracle.GUARDIAN_ROLE(), guardian));
        assertFalse(d.oracle.hasRole(d.oracle.GUARDIAN_ROLE(), navPoster), "poster must not be its own guardian");
        assertTrue(d.vault.hasRole(d.vault.MANAGER_ROLE(), manager));
        assertTrue(d.actions.hasRole(d.actions.ISSUER_ROLE(), admin));
    }

    /// One full dealing day on the freshly deployed system.
    function test_firstEpochEndToEnd() public {
        MockUSDC usdc = MockUSDC(address(d.payToken));
        usdc.mint(investor, 10_000e6);
        vm.prank(agent);
        d.registry.registerIdentity(investor, 276, 1, uint64(block.timestamp + 365 days));

        vm.startPrank(investor);
        usdc.approve(address(d.vault), type(uint256).max);
        d.vault.requestDeposit(10_000e6, investor, investor);
        vm.stopPrank();

        vm.prank(manager);
        d.vault.closeEpoch();
        skip(2 hours);
        vm.prank(navPoster);
        d.oracle.postNav(1.0025e18, uint64(block.timestamp));
        vm.prank(manager);
        d.vault.settleEpoch(10_000);

        vm.prank(investor);
        d.vault.claimDeposit(investor, investor);
        assertApproxEqAbs(d.token.balanceOf(investor), 9_975.062344e18, 1e15);
        assertEq(usdc.balanceOf(custodian), 10_000e6);
    }
}
