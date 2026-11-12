// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Base} from "../Base.t.sol";
import {DistributionModule} from "../../src/actions/DistributionModule.sol";
import {MockUSDC} from "../../src/mocks/MockUSDC.sol";

contract DistributionTest is Base {
    function setUp() public override {
        super.setUp();
        _fund(alice, 3_000 * USDC_UNIT, NAV_ONE);
        _fund(bob, 1_000 * USDC_UNIT, NAV_ONE);
    }

    function _distribute(uint256 amount) internal {
        vm.prank(admin);
        distributions.distribute(amount);
    }

    function test_distribute_isProRata() public {
        _distribute(400 * USDC_UNIT);
        assertEq(distributions.claimable(alice), 300 * USDC_UNIT);
        assertEq(distributions.claimable(bob), 100 * USDC_UNIT);

        uint256 before = usdc.balanceOf(alice);
        distributions.claim(alice); // anyone can trigger it; alice is paid
        assertEq(usdc.balanceOf(alice) - before, 300 * USDC_UNIT);
        assertEq(distributions.claimable(alice), 0);
    }

    function test_distribute_onlyOwner() public {
        vm.prank(alice);
        vm.expectRevert();
        distributions.distribute(1);
    }

    function test_laterBuyer_earnsNothingFromEarlierDistribution() public {
        _distribute(400 * USDC_UNIT);
        _fund(carol, 4_000 * USDC_UNIT, NAV_ONE);
        assertEq(distributions.claimable(carol), 0);

        _distribute(800 * USDC_UNIT); // now carol holds half
        assertEq(distributions.claimable(carol), 400 * USDC_UNIT);
        assertEq(distributions.claimable(alice), 300 * USDC_UNIT + 300 * USDC_UNIT);
    }

    function test_transfer_movesFutureIncome_notPast() public {
        _distribute(400 * USDC_UNIT);
        vm.prank(alice);
        token.transfer(carol, 3_000e18);

        assertEq(distributions.claimable(alice), 300 * USDC_UNIT, "seller keeps what was already declared");
        assertEq(distributions.claimable(carol), 0);

        _distribute(400 * USDC_UNIT);
        assertEq(distributions.claimable(alice), 300 * USDC_UNIT);
        assertEq(distributions.claimable(carol), 300 * USDC_UNIT);
    }

    /// The Gavel lesson: one wallet that cannot receive the payment token must not block the others.
    function test_blocklistedHolder_onlyBlocksItself() public {
        _distribute(400 * USDC_UNIT);
        usdc.setBlocked(alice, true);

        vm.expectRevert(abi.encodeWithSelector(MockUSDC.Blocked.selector, alice));
        distributions.claim(alice);

        distributions.claim(bob);
        assertEq(distributions.claimable(bob), 0);

        usdc.setBlocked(alice, false);
        distributions.claim(alice); // nothing was lost while she was blocked
        assertEq(distributions.claimable(alice), 0);
    }

    function test_claim_requiresVerifiedUnfrozenHolder() public {
        _distribute(400 * USDC_UNIT);
        vm.prank(agent);
        token.setAddressFrozen(alice, true);
        vm.expectRevert(abi.encodeWithSelector(DistributionModule.HolderFrozen.selector, alice));
        distributions.claim(alice);

        vm.prank(agent);
        registry.removeIdentity(bob);
        vm.expectRevert(abi.encodeWithSelector(DistributionModule.HolderNotVerified.selector, bob));
        distributions.claim(bob);
        assertEq(distributions.claimable(bob), 100 * USDC_UNIT, "held for him until he is verified again");
    }

    function test_vaultEscrow_earnsNothing() public {
        _requestRedeem(alice, 1_000e18); // alice now has 2,000 on the register, the vault holds 1,000
        assertEq(distributions.eligibleShares(), 3_000e18);
        _distribute(300 * USDC_UNIT);
        assertEq(distributions.claimable(alice), 200 * USDC_UNIT);
        assertEq(distributions.claimable(bob), 100 * USDC_UNIT);
        assertEq(distributions.claimable(address(vault)), 0);
    }

    function test_distribute_blockedWhileEpochAwaitsNav() public {
        _requestRedeem(alice, 500e18);
        vm.prank(manager);
        vault.closeEpoch();

        vm.prank(admin);
        vm.expectRevert(DistributionModule.EpochAwaitingSettlement.selector);
        distributions.distribute(100 * USDC_UNIT);

        skip(1 hours);
        _postNav(NAV_ONE);
        vm.prank(manager);
        vault.settleEpoch(10_000);
        _distribute(100 * USDC_UNIT);
    }

    function test_recovery_entitlementCanFollowTheInvestor() public {
        _distribute(400 * USDC_UNIT);
        address aliceNew = makeAddr("aliceNew");
        _verify(aliceNew, DE);
        vm.prank(agent);
        token.recoveryAddress(alice, aliceNew);
        assertEq(distributions.claimable(alice), 300 * USDC_UNIT);

        vm.prank(admin);
        distributions.reassignEntitlement(alice, aliceNew);
        assertEq(distributions.claimable(alice), 0);
        assertEq(distributions.claimable(aliceNew), 300 * USDC_UNIT);

        _distribute(400 * USDC_UNIT);
        assertEq(distributions.claimable(aliceNew), 600 * USDC_UNIT);
    }

    function test_split_doesNotChangeEntitlements() public {
        _distribute(400 * USDC_UNIT);
        vm.prank(issuer);
        actions.split(5, 1);
        assertEq(distributions.claimable(alice), 300 * USDC_UNIT);
        _distribute(400 * USDC_UNIT);
        assertEq(distributions.claimable(alice), 600 * USDC_UNIT);
        assertEq(distributions.claimable(bob), 200 * USDC_UNIT);
    }

    function test_distribute_withNoInvestors_reverts() public {
        vm.startPrank(alice);
        token.transfer(bob, 3_000e18);
        vm.stopPrank();
        _requestRedeem(bob, 4_000e18); // every share is now in the vault
        vm.prank(admin);
        vm.expectRevert(DistributionModule.NoEligibleShares.selector);
        distributions.distribute(100 * USDC_UNIT);
    }

    /// Regression for a bug the invariant suite found in the first version of the module: with the
    /// starting point of a changed balance rounded down, every balance change could over-credit by a
    /// fraction of a unit, and enough of them made the sum owed exceed the sum funded.
    function testFuzz_manyBalanceChanges_neverOverPromise(uint256[10] memory amounts, uint256[10] memory moves)
        public
    {
        address[3] memory users = [alice, bob, carol];
        uint256 funded;
        for (uint256 i; i < amounts.length; ++i) {
            uint256 amount = bound(amounts[i], 1, 1_000 * USDC_UNIT);
            _distribute(amount);
            funded += amount;

            address from = users[moves[i] % 3];
            address to = users[(moves[i] / 3) % 3];
            uint256 bal = token.balanceOf(from);
            if (bal != 0) {
                vm.prank(from);
                token.transfer(to, bound(moves[i], 1, bal));
            }

            uint256 owed = distributions.claimable(alice) + distributions.claimable(bob)
                + distributions.claimable(carol);
            assertLe(owed, funded, "owed more than was funded");
        }
        // And everyone can actually be paid.
        for (uint256 u; u < 3; ++u) {
            if (distributions.claimable(users[u]) != 0) distributions.claim(users[u]);
        }
        assertLe(distributions.totalClaimed(), funded);
    }

    function testFuzz_neverPaysMoreThanDistributed(uint256 amount, uint256 moved, uint256 amount2) public {
        amount = bound(amount, 1, 1_000_000 * USDC_UNIT);
        amount2 = bound(amount2, 1, 1_000_000 * USDC_UNIT);
        moved = bound(moved, 0, 3_000e18);

        _distribute(amount);
        vm.prank(alice);
        token.transfer(carol, moved);
        _distribute(amount2);

        uint256 owed =
            distributions.claimable(alice) + distributions.claimable(bob) + distributions.claimable(carol);
        assertLe(owed, amount + amount2, "owed more than was funded");
        // Rounding always favours the pool: at most one unit per holder per balance change.
        assertGe(owed + 8, amount + amount2, "lost more than dust");
        assertEq(usdc.balanceOf(address(distributions)), amount + amount2);
    }
}
