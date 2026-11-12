// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Base} from "../Base.t.sol";
import {console2} from "forge-std/console2.sol";
import {Handler} from "./Handler.sol";
import {FundVault} from "../../src/vault/FundVault.sol";

/// @notice Properties that must hold after any sequence of investor, agent, manager and attacker
///         actions. Each one names the real-world failure it guards against.
contract FundInvariants is Base {
    Handler internal handler;
    address[] internal investors;

    function setUp() public override {
        super.setUp();
        address dave = makeAddr("dave");
        address erin = makeAddr("erin");
        _verify(dave, DE);
        _verify(erin, FR);
        investors = [alice, bob, carol, dave, erin];

        for (uint256 i; i < investors.length; ++i) {
            usdc.mint(investors[i], 1_000_000_000e6);
            vm.startPrank(investors[i]);
            usdc.approve(address(vault), type(uint256).max);
            token.approve(address(vault), type(uint256).max);
            vm.stopPrank();
        }
        // Start from a live fund: every investor already holds shares bought at NAV 1.00.
        for (uint256 i; i < investors.length; ++i) {
            _requestDeposit(investors[i], 1_000_000e6);
        }
        _runEpoch(NAV_ONE, 10_000);
        for (uint256 i; i < investors.length; ++i) {
            vm.prank(investors[i]);
            vault.claimDeposit(investors[i], investors[i]);
        }

        usdc.mint(custodian, 1_000_000_000_000e6);
        usdc.mint(admin, 1_000_000_000_000e6);

        handler = new Handler(
            usdc,
            registry,
            token,
            oracle,
            vault,
            distributions,
            actions,
            Handler.Actors(admin, agent, manager, navPoster, issuer, mallory),
            investors
        );
        targetContract(address(handler));
    }

    /// Catch-all: the handler records anything that must never happen (an ineligible wallet receiving
    /// shares, a frozen investor cashing out, an epoch settled at a pre-cut-off NAV, a correctly valued
    /// epoch that cannot settle, a split that moves value, an attacker call that succeeds).
    function invariant_noViolationsRecorded() public view {
        uint256 n = handler.violationCount();
        if (n != 0) revert(handler.violations(0));
    }

    /// The chain and the transfer agent's ledger never disagree, for any investor.
    /// (Incident class: issuer books and on-chain supply drifting apart.)
    function invariant_registerMatchesTransferAgentLedger() public view {
        uint256 sum;
        for (uint256 i; i < investors.length; ++i) {
            assertEq(token.sharesOf(investors[i]), handler.ledger(investors[i]), "register != ledger");
            sum += token.sharesOf(investors[i]);
        }
        assertEq(sum + token.sharesOf(address(vault)), token.totalShares(), "shares exist outside the register");
    }

    /// No wallet outside the verified set ever holds a share.
    /// (Incident class: a side entrance that skips the KYC check.)
    function invariant_unverifiedWalletHoldsNothing() public view {
        assertEq(token.sharesOf(mallory), 0);
        assertEq(token.balanceOf(mallory), 0);
    }

    /// The vault holds exactly the cash and shares it owes, no more and no less.
    /// (Incident class: withdrawal queues that pay out more than was escrowed.)
    function invariant_vaultHoldsExactlyWhatItOwes() public view {
        assertEq(usdc.balanceOf(address(vault)), vault.reservedAssets(), "cash held != cash owed");
        assertEq(token.sharesOf(address(vault)), vault.reservedShares(), "shares held != shares owed");
    }

    /// Adding up every investor's individual claims never exceeds what the vault has set aside.
    function invariant_individualClaimsAreCovered() public view {
        uint256 assetsOwed;
        uint256 sharesOwed;
        uint64 open = vault.currentEpoch();
        for (uint256 i; i < investors.length; ++i) {
            FundVault.Account memory a = vault.accountOf(investors[i]);
            assetsOwed += a.pendingDepositAssets + a.claimableRedeemAssets;
            sharesOwed += a.pendingRedeemShares + a.claimableDepositShares + a.claimableReturnedShares;
            // A pending request always belongs to the open epoch or the one awaiting its NAV.
            if (a.pendingDepositAssets != 0) assertGe(a.depositEpoch + 1, open);
            if (a.pendingRedeemShares != 0) assertGe(a.redeemEpoch + 1, open);
        }
        assertLe(assetsOwed, vault.reservedAssets(), "investors are owed more cash than is reserved");
        assertLe(sharesOwed, vault.reservedShares(), "investors are owed more shares than are reserved");
    }

    /// At most one epoch is ever waiting for its NAV, and settled epochs are in order.
    function invariant_epochsSettleInOrder() public view {
        uint64 open = vault.currentEpoch();
        for (uint64 id = 1; id + 1 < open; ++id) {
            (uint64 closedAt, uint64 settledAt,,,,,,,) = vault.epochs(id);
            assertGt(closedAt, 0);
            assertGt(settledAt, 0, "an older epoch was skipped");
            assertGe(settledAt, closedAt);
        }
    }

    /// Distributions never promise more than was funded, and the money is there.
    /// (Incident class: reward accounting that lets claims exceed deposits.)
    function invariant_distributionsAreFullyFunded() public view {
        uint256 owed;
        uint256 shares;
        for (uint256 i; i < investors.length; ++i) {
            owed += distributions.claimable(investors[i]);
            shares += token.sharesOf(investors[i]);
        }
        assertLe(owed + distributions.totalClaimed(), distributions.totalDistributed(), "over-promised");
        assertGe(usdc.balanceOf(address(distributions)), owed, "distribution cash missing");
        assertEq(distributions.eligibleShares(), shares, "eligible share count drifted");
        assertEq(distributions.claimable(address(vault)), 0, "escrowed shares earned a distribution");
    }

    /// The holder counter equals the number of investors who actually hold shares.
    function invariant_holderCountIsExact() public view {
        uint256 holders;
        for (uint256 i; i < investors.length; ++i) {
            if (token.sharesOf(investors[i]) != 0) holders++;
        }
        assertEq(holdersModule.holderCount(), holders);
        assertLe(holders, holdersModule.maxHolders());
    }

    /// Frozen shares are always a subset of the balance they belong to.
    function invariant_frozenSharesNeverExceedBalance() public view {
        for (uint256 i; i < investors.length; ++i) {
            assertLe(token.frozenShares(investors[i]), token.sharesOf(investors[i]));
        }
    }

    /// Displayed supply is base supply times the multiplier, and displayed balances never add up to
    /// more than the displayed supply.
    /// (Incident class: rebasing and multiplier tokens that create balance out of rounding.)
    function invariant_displayBalancesNeverExceedSupply() public view {
        uint256 sum = token.balanceOf(address(vault));
        for (uint256 i; i < investors.length; ++i) {
            sum += token.balanceOf(investors[i]);
        }
        assertLe(sum, token.totalSupply());
        assertEq(token.totalSupply(), token.sharesToTokens(token.totalShares()));
    }

    /// @dev Printed with -vv: shows that each run reached settlements, splits and distributions, so a
    ///      green result is not the product of a campaign that never left the starting state.
    function afterInvariant() public view {
        console2.log("settlements", handler.settlements());
        console2.log("splits", handler.splits());
        console2.log("distributions", handler.distributionsFunded());
        console2.log("attacker attempts", handler.attackerAttempts());
        console2.log("total shares", token.totalShares());
    }
}
