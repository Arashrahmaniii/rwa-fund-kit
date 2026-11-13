// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {DeployDemo} from "../../script/DeployDemo.s.sol";
import {DemoOperator} from "../../src/mocks/DemoOperator.sol";
import {MockUSDC} from "../../src/mocks/MockUSDC.sol";

/// @notice The public testnet demo: a visitor with no role runs a whole dealing day.
contract DemoTest is Test {
    DeployDemo internal script;
    Deploy.Deployment internal d;
    DemoOperator internal demo;
    address internal visitor = makeAddr("visitor");
    address internal other = makeAddr("other");

    function setUp() public {
        vm.warp(1_800_000_000);
        script = new DeployDemo();
        (d, demo) = script.deployDemo(address(script));
    }

    function test_visitorRunsAFullDealingDay() public {
        MockUSDC usdc = MockUSDC(address(d.payToken));
        vm.startPrank(visitor);
        demo.onboard();
        assertTrue(d.registry.isVerified(visitor));
        assertEq(usdc.balanceOf(visitor), 100_000e6);

        usdc.approve(address(d.vault), type(uint256).max);
        d.vault.requestDeposit(50_000e6, visitor, visitor);
        demo.closeEpoch();
        skip(12); // next block
        demo.valueAndSettle(50); // NAV 1.005
        d.vault.claimDeposit(visitor, visitor);
        assertApproxEqAbs(d.token.balanceOf(visitor), 49_751.243781e18, 1e15);

        // and out again, at a higher NAV
        d.token.approve(address(d.vault), type(uint256).max);
        d.vault.requestRedeem(10_000e18, visitor, visitor);
        demo.closeEpoch();
        skip(12);
        demo.valueAndSettle(100);
        uint256 cash = d.vault.claimRedeem(visitor, visitor);
        vm.stopPrank();
        assertApproxEqAbs(cash, 10_150.5e6, 1e3); // 10,000 shares at 1.005 * 1.01
    }

    function test_settleInSameBlockAsCutoff_reverts() public {
        vm.startPrank(visitor);
        demo.onboard();
        MockUSDC(address(d.payToken)).approve(address(d.vault), type(uint256).max);
        d.vault.requestDeposit(1_000e6, visitor, visitor);
        demo.closeEpoch();
        vm.expectRevert(); // forward pricing still applies to the demo
        demo.valueAndSettle(0);
        vm.stopPrank();
    }

    function test_driftIsBounded_andInitIsOneShot() public {
        vm.expectRevert(DemoOperator.DriftTooLarge.selector);
        demo.valueAndSettle(101);
        vm.expectRevert(DemoOperator.DriftTooLarge.selector);
        demo.valueAndSettle(-101);

        vm.prank(other);
        vm.expectRevert(DemoOperator.OnlyDeployer.selector);
        demo.init(d.registry, d.vault, d.oracle, MockUSDC(address(d.payToken)));
        vm.prank(address(script));
        vm.expectRevert(DemoOperator.AlreadyInitialised.selector);
        demo.init(d.registry, d.vault, d.oracle, MockUSDC(address(d.payToken)));
    }
}
