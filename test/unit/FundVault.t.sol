// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Base} from "../Base.t.sol";
import {FundVault} from "../../src/vault/FundVault.sol";
import {FundShareToken} from "../../src/token/FundShareToken.sol";
import {NavOracle} from "../../src/oracle/NavOracle.sol";

contract FundVaultTest is Base {
    // ------------------------------------------------------------------ subscriptions

    function test_subscribe_fullFlow() public {
        _requestDeposit(alice, 1_050 * USDC_UNIT);
        assertEq(vault.pendingDepositRequest(0, alice), 1_050 * USDC_UNIT);
        assertEq(usdc.balanceOf(address(vault)), 1_050 * USDC_UNIT);

        uint256 custodianBefore = usdc.balanceOf(custodian);
        _runEpoch(1.05e18, 10_000);

        assertEq(vault.pendingDepositRequest(0, alice), 0);
        assertEq(vault.claimableDepositRequest(0, alice), 1_050 * USDC_UNIT);
        assertEq(usdc.balanceOf(custodian) - custodianBefore, 1_050 * USDC_UNIT, "cash not sent to custodian");

        vm.prank(alice);
        uint256 got = vault.claimDeposit(alice, alice);
        assertEq(got, 1_000e18, "1,050 USDC at NAV 1.05 is 1,000 shares");
        assertEq(token.balanceOf(alice), 1_000e18);
        assertEq(vault.reservedShares(), 0);
        assertEq(vault.reservedAssets(), 0);
    }

    function test_subscribe_partialClaimIsProRata() public {
        _requestDeposit(alice, 1_000 * USDC_UNIT);
        _runEpoch(NAV_ONE, 10_000);

        vm.startPrank(alice);
        vault.deposit(250 * USDC_UNIT, alice, alice);
        assertEq(token.balanceOf(alice), 250e18);
        vault.deposit(750 * USDC_UNIT, alice, alice);
        assertEq(token.balanceOf(alice), 1_000e18);
        vm.expectRevert(FundVault.ZeroAmount.selector);
        vault.claimDeposit(alice, alice);
        vm.stopPrank();
    }

    function test_subscribe_unverifiedController_reverts() public {
        vm.prank(mallory);
        vm.expectRevert(abi.encodeWithSelector(FundVault.ControllerNotEligible.selector, mallory));
        vault.requestDeposit(1_000 * USDC_UNIT, mallory, mallory);
    }

    function test_subscribe_verifiedOwnerCannotRouteSharesToUnverifiedReceiver() public {
        _requestDeposit(alice, 1_000 * USDC_UNIT);
        _runEpoch(NAV_ONE, 10_000);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FundShareToken.ReceiverNotVerified.selector, mallory));
        vault.claimDeposit(mallory, alice);
    }

    function test_subscribe_belowMinimum_reverts() public {
        vm.prank(alice);
        vm.expectRevert(FundVault.BelowMinDeposit.selector);
        vault.requestDeposit(99 * USDC_UNIT, alice, alice);
    }

    function test_subscribe_managerCanPushSharesToController() public {
        _requestDeposit(alice, 1_000 * USDC_UNIT);
        _runEpoch(NAV_ONE, 10_000);
        vm.prank(manager);
        vault.pushDepositShares(alice);
        assertEq(token.balanceOf(alice), 1_000e18);
    }

    // ------------------------------------------------------------------ forward pricing

    /// The NAV free look: an epoch must not settle at a NAV that was known before its cut-off.
    function test_settle_withNavFromBeforeCutoff_reverts() public {
        _requestDeposit(alice, 1_000 * USDC_UNIT);
        skip(1 hours);
        _postNav(1.02e18); // public before the cut-off
        skip(10 minutes);

        vm.prank(manager);
        vault.closeEpoch();
        uint64 closedAt = uint64(block.timestamp);
        uint64 navAsOf = oracle.asOf();

        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(FundVault.NavNotAfterCutoff.selector, navAsOf, closedAt));
        vault.settleEpoch(10_000);

        // A NAV posted later but valued at (or before) the cut-off cannot be used either: what counts
        // is the valuation time, not the posting time.
        skip(1 hours);
        vm.prank(navPoster);
        oracle.postNav(1.03e18, closedAt);
        vm.prank(manager);
        vm.expectRevert(abi.encodeWithSelector(FundVault.NavNotAfterCutoff.selector, closedAt, closedAt));
        vault.settleEpoch(10_000);
    }

    function test_cancel_onlyBeforeCutoff() public {
        _requestDeposit(alice, 1_000 * USDC_UNIT);
        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        vault.cancelDepositRequest(alice);
        assertEq(usdc.balanceOf(alice), before + 1_000 * USDC_UNIT);
        assertEq(vault.reservedAssets(), 0);

        _requestDeposit(alice, 1_000 * USDC_UNIT);
        vm.prank(manager);
        vault.closeEpoch();
        vm.prank(alice);
        vm.expectRevert(FundVault.NothingToCancel.selector);
        vault.cancelDepositRequest(alice);
    }

    function test_request_whileEarlierOneIsLocked_reverts() public {
        _requestDeposit(alice, 1_000 * USDC_UNIT);
        vm.prank(manager);
        vault.closeEpoch();
        vm.prank(alice);
        vm.expectRevert(FundVault.RequestLockedInClosedEpoch.selector);
        vault.requestDeposit(500 * USDC_UNIT, alice, alice);
    }

    function test_closeEpoch_requiresPreviousSettled() public {
        vm.startPrank(manager);
        vault.closeEpoch();
        vm.expectRevert(FundVault.PreviousEpochNotSettled.selector);
        vault.closeEpoch();
        vm.stopPrank();
    }

    function test_settle_withStaleNav_reverts() public {
        _requestDeposit(alice, 1_000 * USDC_UNIT);
        vm.prank(manager);
        vault.closeEpoch();
        skip(1 hours);
        _postNav(NAV_ONE);
        skip(3 days); // older than maxStaleness
        vm.prank(manager);
        vm.expectRevert();
        vault.settleEpoch(10_000);
    }

    // ------------------------------------------------------------------ redemptions

    function test_redeem_fullFlow() public {
        _fund(alice, 1_000 * USDC_UNIT, NAV_ONE);
        _fund(bob, 1_000 * USDC_UNIT, NAV_ONE); // supply 2,000, so 400 is inside the 25% gate

        _requestRedeem(alice, 400e18);
        assertEq(token.balanceOf(alice), 600e18);
        assertEq(vault.pendingRedeemRequest(0, alice), 400e18);

        _runEpoch(NAV_ONE, 10_000);
        assertEq(vault.claimableRedeemRequest(0, alice), 400e18);

        uint256 before = usdc.balanceOf(alice);
        vm.prank(alice);
        uint256 assets = vault.claimRedeem(alice, alice);
        assertEq(assets, 400 * USDC_UNIT);
        assertEq(usdc.balanceOf(alice) - before, 400 * USDC_UNIT);
        assertEq(token.totalSupply(), 1_600e18);
    }

    function test_redeem_pricedAtNavAfterCutoff() public {
        _fund(alice, 1_000 * USDC_UNIT, NAV_ONE);
        _fund(bob, 3_000 * USDC_UNIT, NAV_ONE);

        _requestRedeem(alice, 500e18);
        _runEpoch(1.08e18, 10_000);

        vm.prank(alice);
        assertEq(vault.claimRedeem(alice, alice), 540 * USDC_UNIT);
    }

    function test_redeem_nettingOnlyMovesTheDifference() public {
        _fund(alice, 4_000 * USDC_UNIT, NAV_ONE);

        _requestRedeem(alice, 600e18);
        _requestDeposit(bob, 1_000 * USDC_UNIT);
        uint256 custodianBefore = usdc.balanceOf(custodian);
        _runEpoch(NAV_ONE, 10_000);

        assertEq(usdc.balanceOf(custodian) - custodianBefore, 400 * USDC_UNIT, "only the net goes out");
        assertEq(usdc.balanceOf(address(vault)), 600 * USDC_UNIT, "redemption cash stays for the claim");
    }

    function test_redeem_netOutflowIsPulledFromCustodian() public {
        _fund(alice, 4_000 * USDC_UNIT, NAV_ONE);
        _requestRedeem(alice, 1_000e18);
        uint256 custodianBefore = usdc.balanceOf(custodian);
        _runEpoch(NAV_ONE, 10_000);
        assertEq(custodianBefore - usdc.balanceOf(custodian), 1_000 * USDC_UNIT);
    }

    function test_redeem_partialFill_returnsTheRest() public {
        _fund(alice, 4_000 * USDC_UNIT, NAV_ONE);
        _requestRedeem(alice, 1_000e18);
        _runEpoch(NAV_ONE, 4_000); // the fund can only meet 40% this period

        vm.startPrank(alice);
        assertEq(vault.claimRedeem(alice, alice), 400 * USDC_UNIT);
        vault.claimReturnedShares(alice);
        vm.stopPrank();

        assertEq(token.balanceOf(alice), 3_600e18);
        assertEq(token.totalSupply(), 3_600e18);
        assertEq(vault.reservedShares(), 0);
        assertEq(vault.reservedAssets(), 0);
    }

    function test_redeem_gateCapsTheFill() public {
        _fund(alice, 1_000 * USDC_UNIT, NAV_ONE);
        _requestRedeem(alice, 1_000e18); // everything, but the gate is 25% of supply
        _runEpoch(NAV_ONE, 10_000);

        vm.startPrank(alice);
        assertEq(vault.claimRedeem(alice, alice), 250 * USDC_UNIT);
        vault.claimReturnedShares(alice);
        vm.stopPrank();
        assertEq(token.balanceOf(alice), 750e18);
    }

    function test_redeem_frozenControllerCannotTakeCash() public {
        _fund(alice, 4_000 * USDC_UNIT, NAV_ONE);
        _requestRedeem(alice, 500e18);
        _runEpoch(NAV_ONE, 10_000);

        vm.prank(agent);
        token.setAddressFrozen(alice, true);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FundVault.ControllerFrozen.selector, alice));
        vault.claimRedeem(alice, alice);
    }

    function test_redeem_expiredKycCanStillLeave() public {
        _fund(alice, 4_000 * USDC_UNIT, NAV_ONE);
        skip(366 days); // alice's KYC lapses; she holds shares but can no longer receive any
        assertFalse(registry.isVerified(alice));

        _requestRedeem(alice, 500e18);
        _runEpoch(NAV_ONE, 10_000);
        vm.prank(alice);
        assertEq(vault.claimRedeem(alice, alice), 500 * USDC_UNIT);
    }

    function test_redeem_cancelReturnsShares() public {
        _fund(alice, 1_000 * USDC_UNIT, NAV_ONE);
        _requestRedeem(alice, 300e18);
        vm.prank(alice);
        vault.cancelRedeemRequest(alice);
        assertEq(token.balanceOf(alice), 1_000e18);
        assertEq(vault.reservedShares(), 0);
    }

    // ------------------------------------------------------------------ operators

    function test_operator_canRequestAndClaimForController() public {
        address ops = makeAddr("ops");
        vm.prank(alice);
        vault.setOperator(ops, true);

        vm.prank(ops);
        vault.requestDeposit(1_000 * USDC_UNIT, alice, alice);
        _runEpoch(NAV_ONE, 10_000);
        vm.prank(ops);
        vault.claimDeposit(alice, alice);
        assertEq(token.balanceOf(alice), 1_000e18);
    }

    function test_stranger_cannotActForController() public {
        vm.prank(bob);
        vm.expectRevert(FundVault.NotAuthorized.selector);
        vault.requestDeposit(1_000 * USDC_UNIT, alice, alice);

        _requestDeposit(alice, 1_000 * USDC_UNIT);
        vm.prank(bob);
        vm.expectRevert(FundVault.NotAuthorized.selector);
        vault.cancelDepositRequest(alice);

        _runEpoch(NAV_ONE, 10_000);
        vm.prank(bob);
        vm.expectRevert(FundVault.NotAuthorized.selector);
        vault.claimDeposit(bob, alice);
    }

    // ------------------------------------------------------------------ splits

    function test_split_betweenSettlementAndClaim_changesNothing() public {
        _requestDeposit(alice, 1_000 * USDC_UNIT);
        _runEpoch(NAV_ONE, 10_000);

        vm.prank(issuer);
        actions.split(2, 1);

        vm.prank(alice);
        vault.claimDeposit(alice, alice);
        assertEq(token.balanceOf(alice), 2_000e18, "twice the tokens...");
        assertEq(oracle.nav(), 0.5e18, "...at half the price");
    }

    function test_split_betweenRedeemRequestAndSettlement_paysTheSameCash() public {
        _fund(alice, 4_000 * USDC_UNIT, NAV_ONE);
        _requestRedeem(alice, 1_000e18);

        vm.prank(issuer);
        actions.split(2, 1);
        assertEq(vault.pendingRedeemRequest(0, alice), 2_000e18);

        _runEpoch(0.5e18, 10_000);
        vm.prank(alice);
        assertEq(vault.claimRedeem(alice, alice), 1_000 * USDC_UNIT);
    }

    function test_split_thenSubscribe_pricesCorrectly() public {
        _fund(alice, 1_000 * USDC_UNIT, NAV_ONE);
        vm.prank(issuer);
        actions.split(1, 4); // reverse split: NAV per token becomes 4.00

        _requestDeposit(bob, 1_000 * USDC_UNIT);
        _runEpoch(4e18, 10_000);
        vm.prank(bob);
        vault.claimDeposit(bob, bob);

        assertEq(token.balanceOf(bob), 250e18);
        assertEq(token.sharesOf(bob), token.sharesOf(alice), "same cash at the same NAV buys the same stake");
    }

    // ------------------------------------------------------------------ interface details

    function test_previews_revert_and_interfaces() public {
        vm.expectRevert(FundVault.AsyncVault.selector);
        vault.previewDeposit(1);
        vm.expectRevert(FundVault.AsyncVault.selector);
        vault.previewRedeem(1);
        assertTrue(vault.supportsInterface(0xce3bbe50));
        assertTrue(vault.supportsInterface(0x620ee8e4));
        assertTrue(vault.supportsInterface(0xe3bc4e65));
    }

    function test_pause_stopsRequests_notExits() public {
        _fund(alice, 4_000 * USDC_UNIT, NAV_ONE);
        _requestRedeem(alice, 500e18);
        _requestDeposit(bob, 1_000 * USDC_UNIT);

        vm.prank(admin);
        vault.pause();

        vm.prank(carol);
        vm.expectRevert();
        vault.requestDeposit(1_000 * USDC_UNIT, carol, carol);

        vm.prank(bob);
        vault.cancelDepositRequest(bob); // still possible

        _runEpoch(NAV_ONE, 10_000);
        vm.prank(alice);
        assertEq(vault.claimRedeem(alice, alice), 500 * USDC_UNIT); // still possible
    }

    // ------------------------------------------------------------------ fuzz

    /// Subscribe and redeem at an unchanged NAV: nobody leaves with more cash than they brought.
    function testFuzz_roundTrip_atConstantNav_neverProfits(uint256 assets, uint256 nav, uint256 redeemPart)
        public
    {
        assets = bound(assets, 100 * USDC_UNIT, 5_000_000 * USDC_UNIT);
        nav = bound(nav, 0.91e18, 1.09e18);
        redeemPart = bound(redeemPart, 1, 10_000);

        _fund(carol, 5_000_000 * USDC_UNIT, nav); // background holder so the gate does not bind
        uint256 before = usdc.balanceOf(alice);
        _fund(alice, assets, nav);

        uint256 tokens = token.balanceOf(alice) * redeemPart / 10_000;
        vm.assume(token.tokensToShares(tokens) > 0);
        _requestRedeem(alice, tokens);
        _runEpoch(nav, 10_000);
        vm.prank(alice);
        try vault.claimRedeem(alice, alice) {} catch {}

        uint256 cashOut = usdc.balanceOf(alice) + assets - before;
        uint256 stillHeld = vault.convertToAssets(token.balanceOf(alice));
        assertLe(cashOut + stillHeld, assets, "round trip created value");
    }

    /// Whatever mix of subscriptions and redemptions settles, the vault holds exactly what it owes.
    function testFuzz_settlement_balancesMatchReserves(
        uint256 depA,
        uint256 depB,
        uint256 redeemTokens,
        uint256 nav,
        uint256 fillBps
    ) public {
        depA = bound(depA, 100 * USDC_UNIT, 1_000_000 * USDC_UNIT);
        depB = bound(depB, 100 * USDC_UNIT, 1_000_000 * USDC_UNIT);
        nav = bound(nav, 0.91e18, 1.09e18);
        fillBps = bound(fillBps, 0, 10_000);

        _fund(carol, 2_000_000 * USDC_UNIT, NAV_ONE);
        redeemTokens = bound(redeemTokens, 1e12, token.balanceOf(carol));

        _requestDeposit(alice, depA);
        _requestDeposit(bob, depB);
        _requestRedeem(carol, redeemTokens);
        _runEpoch(nav, fillBps);

        assertEq(usdc.balanceOf(address(vault)), vault.reservedAssets(), "assets held != assets owed");
        assertEq(token.sharesOf(address(vault)), vault.reservedShares(), "shares held != shares owed");

        vm.prank(alice);
        vault.claimDeposit(alice, alice);
        vm.prank(bob);
        vault.claimDeposit(bob, bob);
        FundVault.Account memory c = vault.accountOf(carol);
        vm.startPrank(carol);
        if (c.claimableRedeemShares != 0) vault.claimRedeem(carol, carol);
        if (c.claimableReturnedShares != 0) vault.claimReturnedShares(carol);
        vm.stopPrank();

        // After everyone claimed, only rounding dust may remain reserved.
        assertLe(vault.reservedShares(), 3, "share dust too large");
        assertLe(vault.reservedAssets(), 3, "asset dust too large");
        assertEq(usdc.balanceOf(address(vault)), vault.reservedAssets());
        assertEq(token.sharesOf(address(vault)), vault.reservedShares());
    }
}
