// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Base} from "../Base.t.sol";
import {FundShareToken} from "../../src/token/FundShareToken.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";

contract FundShareTokenTest is Base {
    function setUp() public override {
        super.setUp();
        _fund(alice, 1_000 * USDC_UNIT, NAV_ONE); // alice holds 1,000 tokens
    }

    function test_metadata() public view {
        assertEq(token.name(), "Example Treasury Fund");
        assertEq(token.symbol(), "xTF");
        assertEq(token.decimals(), 18);
        assertEq(token.balanceOf(alice), 1_000e18);
        assertEq(token.totalSupply(), 1_000e18);
    }

    function test_transfer_betweenVerifiedInvestors() public {
        vm.prank(alice);
        token.transfer(bob, 400e18);
        assertEq(token.balanceOf(alice), 600e18);
        assertEq(token.balanceOf(bob), 400e18);
    }

    function test_transfer_toUnverified_reverts() public {
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FundShareToken.ReceiverNotVerified.selector, mallory));
        token.transfer(mallory, 1e18);
    }

    function test_transfer_toExpiredKyc_reverts() public {
        skip(366 days);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FundShareToken.ReceiverNotVerified.selector, bob));
        token.transfer(bob, 1e18);
    }

    function test_transfer_fromFrozenWallet_reverts() public {
        vm.prank(agent);
        token.setAddressFrozen(alice, true);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FundShareToken.WalletFrozen.selector, alice));
        token.transfer(bob, 1e18);
    }

    function test_transfer_toFrozenWallet_reverts() public {
        vm.prank(agent);
        token.setAddressFrozen(bob, true);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FundShareToken.WalletFrozen.selector, bob));
        token.transfer(bob, 1e18);
    }

    function test_partialFreeze_limitsWhatCanMove() public {
        vm.prank(agent);
        token.freezePartialShares(alice, 700e18);

        vm.prank(alice);
        vm.expectRevert(
            abi.encodeWithSelector(FundShareToken.InsufficientUnfrozenShares.selector, alice, 300e18, 301e18)
        );
        token.transfer(bob, 301e18);

        vm.prank(alice);
        token.transfer(bob, 300e18);
        assertEq(token.balanceOf(bob), 300e18);

        vm.prank(agent);
        token.unfreezePartialShares(alice, 700e18);
        vm.prank(alice);
        token.transfer(bob, 700e18);
        assertEq(token.balanceOf(alice), 0);
    }

    function test_freezePartial_cannotExceedBalance() public {
        vm.prank(agent);
        vm.expectRevert(FundShareToken.FreezeExceedsBalance.selector);
        token.freezePartialShares(alice, 1_001e18);
    }

    function test_pause_blocksTransfers_butNotForcedTransfer() public {
        vm.prank(agent);
        token.pause();
        vm.prank(alice);
        vm.expectRevert(Pausable.EnforcedPause.selector);
        token.transfer(bob, 1e18);

        vm.prank(agent);
        token.forcedTransfer(alice, bob, 10e18);
        assertEq(token.balanceOf(bob), 10e18);
    }

    function test_forcedTransfer_fromFrozenWallet_releasesFrozenShares() public {
        vm.startPrank(agent);
        token.setAddressFrozen(alice, true);
        token.freezePartialShares(alice, 900e18);
        token.forcedTransfer(alice, bob, 950e18);
        vm.stopPrank();

        assertEq(token.balanceOf(bob), 950e18);
        assertEq(token.balanceOf(alice), 50e18);
        assertEq(token.frozenShares(alice), 50e18); // 850 of the 900 frozen had to be released
    }

    function test_forcedTransfer_toUnverified_reverts() public {
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(FundShareToken.ReceiverNotVerified.selector, mallory));
        token.forcedTransfer(alice, mallory, 1e18);
    }

    function test_forcedTransfer_onlyAgent() public {
        vm.prank(alice);
        vm.expectRevert();
        token.forcedTransfer(bob, alice, 1e18);
    }

    function test_recovery_movesEverythingAndKeepsRestrictions() public {
        address aliceNew = makeAddr("aliceNew");
        _verify(aliceNew, DE);
        vm.startPrank(agent);
        token.freezePartialShares(alice, 250e18);
        token.setAddressFrozen(alice, true);
        token.recoveryAddress(alice, aliceNew);
        vm.stopPrank();

        assertEq(token.balanceOf(alice), 0);
        assertEq(token.balanceOf(aliceNew), 1_000e18);
        assertEq(token.frozenShares(aliceNew), 250e18);
        assertEq(token.frozenShares(alice), 0);
        assertTrue(token.frozen(aliceNew));
    }

    function test_recovery_toUnverified_reverts() public {
        vm.prank(agent);
        vm.expectRevert(abi.encodeWithSelector(FundShareToken.ReceiverNotVerified.selector, mallory));
        token.recoveryAddress(alice, mallory);
    }

    function test_mint_onlyMinter() public {
        vm.prank(agent);
        vm.expectRevert();
        token.mintShares(alice, 1e18);
    }

    function test_mint_toUnverified_reverts() public {
        vm.prank(address(vault));
        vm.expectRevert(abi.encodeWithSelector(FundShareToken.ReceiverNotVerified.selector, mallory));
        token.mintShares(mallory, 1e18);
    }

    function test_burn_onlyFromOwnBalance() public {
        // The vault holds nothing right now, so it cannot burn alice's shares.
        vm.prank(address(vault));
        vm.expectRevert();
        token.burnShares(1e18);
    }

    function test_allowance_isInTokens() public {
        vm.prank(alice);
        token.approve(bob, 100e18);
        vm.prank(bob);
        token.transferFrom(alice, carol, 60e18);
        assertEq(token.allowance(alice, bob), 40e18);
        assertEq(token.balanceOf(carol), 60e18);

        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(FundShareToken.InsufficientAllowance.selector, bob, 40e18, 41e18));
        token.transferFrom(alice, carol, 41e18);
    }

    function test_systemAddress_cannotBeSetWhileHoldingShares() public {
        vm.prank(admin);
        vm.expectRevert(abi.encodeWithSelector(FundShareToken.SystemAddressHoldsShares.selector, alice));
        token.setSystemAddress(alice, true);
    }

    function test_setMultiplier_onlyThroughCorporateActions() public {
        vm.prank(admin);
        vm.expectRevert();
        token.setMultiplier(2e18);
        vm.prank(agent);
        vm.expectRevert();
        token.setMultiplier(2e18);
    }

    function test_split_changesDisplayNotOwnership() public {
        vm.prank(alice);
        token.transfer(bob, 250e18);
        uint256 aliceShares = token.sharesOf(alice);
        uint256 bobShares = token.sharesOf(bob);

        vm.prank(issuer);
        actions.split(3, 1);

        assertEq(token.sharesOf(alice), aliceShares);
        assertEq(token.sharesOf(bob), bobShares);
        assertEq(token.balanceOf(alice), 2_250e18);
        assertEq(token.balanceOf(bob), 750e18);
        assertEq(token.totalSupply(), 3_000e18);
    }

    function testFuzz_transfer_conservesShares(uint256 amount, uint256 num, uint256 den) public {
        num = bound(num, 1, 1_000);
        den = bound(den, 1, 1_000);
        if (num != den) {
            vm.prank(issuer);
            actions.split(num, den);
        }
        amount = bound(amount, 0, token.balanceOf(alice));

        uint256 total = token.totalShares();
        uint256 a0 = token.sharesOf(alice);
        vm.prank(alice);
        token.transfer(bob, amount);

        assertEq(token.totalShares(), total, "supply changed");
        assertEq(a0 - token.sharesOf(alice), token.sharesOf(bob), "shares created or lost in transit");
        assertLe(token.balanceOf(bob), amount, "receiver got more tokens than were sent");
    }

    function testFuzz_transferSharesFrom_neverUndercharges(uint256 shares, uint256 num, uint256 den) public {
        num = bound(num, 1, 1_000);
        den = bound(den, 1, 1_000);
        if (num != den) {
            vm.prank(issuer);
            actions.split(num, den);
        }
        shares = bound(shares, 1, token.sharesOf(alice));
        uint256 tokensMoved = token.sharesToTokens(shares);

        vm.prank(alice);
        token.approve(bob, type(uint128).max);
        vm.prank(bob);
        token.transferSharesFrom(alice, bob, shares);

        uint256 charged = type(uint128).max - token.allowance(alice, bob);
        assertGe(charged, tokensMoved, "allowance charged less than the tokens moved");
        assertLe(charged, tokensMoved + 1);
    }
}
