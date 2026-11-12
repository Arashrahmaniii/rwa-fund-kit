// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Base} from "../Base.t.sol";
import {NavOracle} from "../../src/oracle/NavOracle.sol";
import {CorporateActions} from "../../src/actions/CorporateActions.sol";

contract NavOracleTest is Base {
    function test_post_withinBand_takesEffect() public {
        skip(1 days);
        _postNav(1.05e18);
        assertEq(oracle.nav(), 1.05e18);
        assertEq(oracle.asOf(), block.timestamp);
    }

    function test_post_onlyOracleRole() public {
        skip(1 days);
        vm.prank(alice);
        vm.expectRevert();
        oracle.postNav(1.01e18, uint64(block.timestamp));
    }

    function test_post_outsideBand_waitsForGuardian() public {
        skip(1 days);
        _postNav(1.5e18); // +50%, band is 10%
        assertEq(oracle.nav(), NAV_ONE, "large move must not take effect alone");
        assertEq(oracle.pendingNav(), 1.5e18);

        vm.prank(navPoster);
        vm.expectRevert();
        oracle.confirmPendingNav(); // the poster cannot confirm their own number

        vm.prank(guardian);
        oracle.confirmPendingNav();
        assertEq(oracle.nav(), 1.5e18);
        assertEq(oracle.pendingNav(), 0);
    }

    function test_guardian_canRejectPendingNav() public {
        skip(1 days);
        _postNav(0.2e18);
        vm.prank(guardian);
        oracle.rejectPendingNav();
        assertEq(oracle.nav(), NAV_ONE);
        assertEq(oracle.pendingNav(), 0);
        vm.prank(guardian);
        vm.expectRevert(NavOracle.NoPendingNav.selector);
        oracle.confirmPendingNav();
    }

    function test_pendingNav_isDroppedWhenANewerNavIsAccepted() public {
        skip(1 days);
        _postNav(1.5e18); // parked, valued now
        skip(1 hours);
        _postNav(1.01e18); // normal post with a later valuation time
        assertEq(oracle.pendingNav(), 0);
        vm.prank(guardian);
        vm.expectRevert(NavOracle.NoPendingNav.selector);
        oracle.confirmPendingNav(); // the older number can no longer be brought back
        assertEq(oracle.nav(), 1.01e18);
    }

    function test_post_valuationTimeRules() public {
        vm.startPrank(navPoster);
        vm.expectRevert(NavOracle.AsOfInFuture.selector);
        oracle.postNav(1.01e18, uint64(block.timestamp + 1));
        vm.expectRevert(NavOracle.AsOfNotAfterPrevious.selector);
        oracle.postNav(1.01e18, uint64(block.timestamp)); // same time as the initial NAV
        vm.expectRevert(NavOracle.ZeroNav.selector);
        oracle.postNav(0, uint64(block.timestamp));
        vm.stopPrank();
    }

    function test_freshNav_revertsWhenStale() public {
        (uint256 nav,) = oracle.freshNav();
        assertEq(nav, NAV_ONE);
        skip(2 days + 1);
        vm.expectRevert();
        oracle.freshNav();
    }

    function test_setLimits_validation() public {
        vm.startPrank(admin);
        vm.expectRevert(NavOracle.BadLimits.selector);
        oracle.setLimits(0, 1 days);
        vm.expectRevert(NavOracle.BadLimits.selector);
        oracle.setLimits(500, 0);
        oracle.setLimits(500, 1 days);
        vm.stopPrank();
        assertEq(oracle.maxDeviationBps(), 500);
    }

    function test_rescale_onlyThroughCorporateActions() public {
        vm.prank(admin);
        vm.expectRevert();
        oracle.rescaleForSplit(2, 1);
    }

    function test_split_onlyIssuer_andValidRatio() public {
        vm.prank(admin);
        vm.expectRevert();
        actions.split(2, 1);
        vm.startPrank(issuer);
        vm.expectRevert(CorporateActions.BadRatio.selector);
        actions.split(0, 1);
        vm.expectRevert(CorporateActions.BadRatio.selector);
        actions.split(3, 3);
        vm.stopPrank();
    }

    function test_split_rescalesPendingNavToo() public {
        skip(1 days);
        _postNav(1.5e18); // parked
        vm.prank(issuer);
        actions.split(2, 1);
        assertEq(oracle.pendingNav(), 0.75e18);
        assertEq(oracle.nav(), 0.5e18);
    }

    /// The value of one base share is the same before and after any split, to within rounding.
    function testFuzz_split_keepsValuePerBaseShare(uint256 nav, uint256 num, uint256 den) public {
        nav = bound(nav, 0.91e18, 1.09e18);
        num = bound(num, 1, 10_000);
        den = bound(den, 1, 10_000);
        vm.assume(num != den);
        skip(1 days);
        _postNav(nav);

        uint256 valueBefore = oracle.nav() * token.multiplier();
        vm.prank(issuer);
        actions.split(num, den);
        uint256 valueAfter = oracle.nav() * token.multiplier();

        assertLe(valueAfter, valueBefore, "a split must never raise the value of a share");
        // Both steps round down by less than one unit in 1e18, i.e. a relative error below 1e-13 here.
        assertApproxEqRel(valueAfter, valueBefore, 1e5);
    }
}
