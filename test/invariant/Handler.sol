// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {CommonBase} from "forge-std/Base.sol";
import {StdCheats} from "forge-std/StdCheats.sol";
import {StdUtils} from "forge-std/StdUtils.sol";
import {IdentityRegistry} from "../../src/identity/IdentityRegistry.sol";
import {FundShareToken} from "../../src/token/FundShareToken.sol";
import {NavOracle} from "../../src/oracle/NavOracle.sol";
import {FundVault} from "../../src/vault/FundVault.sol";
import {DistributionModule} from "../../src/actions/DistributionModule.sol";
import {CorporateActions} from "../../src/actions/CorporateActions.sol";
import {MaxHoldersModule} from "../../src/compliance/modules/MaxHoldersModule.sol";
import {MockUSDC} from "../../src/mocks/MockUSDC.sol";

/// @notice Drives the whole kit with random investor, agent, manager and attacker actions.
///
/// It keeps its own copy of the share register (`ledger`), written from what each action is supposed
/// to do, the way a transfer agent's off-chain system would. The invariants compare the chain to it.
/// Anything that must never happen is recorded as a violation string and checked by the test.
contract Handler is CommonBase, StdCheats, StdUtils {
    struct Actors {
        address admin;
        address agent;
        address manager;
        address navPoster;
        address issuer;
        address mallory;
    }

    MockUSDC public usdc;
    IdentityRegistry public registry;
    FundShareToken public token;
    NavOracle public oracle;
    FundVault public vault;
    DistributionModule public distributions;
    CorporateActions public actions;
    Actors public roles;

    address[] public investors;
    mapping(address => uint256) public ledger; // base shares each investor should hold

    string[] public violations;
    uint256 public settlements;
    uint256 public splits;
    uint256 public distributionsFunded;
    uint256 public attackerAttempts;

    constructor(
        MockUSDC usdc_,
        IdentityRegistry registry_,
        FundShareToken token_,
        NavOracle oracle_,
        FundVault vault_,
        DistributionModule distributions_,
        CorporateActions actions_,
        Actors memory roles_,
        address[] memory investors_
    ) {
        usdc = usdc_;
        registry = registry_;
        token = token_;
        oracle = oracle_;
        vault = vault_;
        distributions = distributions_;
        actions = actions_;
        roles = roles_;
        investors = investors_;
        // The transfer agent's ledger starts from the register as it stands at hand-over.
        for (uint256 i; i < investors_.length; ++i) {
            ledger[investors_[i]] = token_.sharesOf(investors_[i]);
        }
    }

    function investorCount() external view returns (uint256) {
        return investors.length;
    }

    function violationCount() external view returns (uint256) {
        return violations.length;
    }

    function _investor(uint256 seed) private view returns (address) {
        return investors[seed % investors.length];
    }

    function _eligible(address who) private view returns (bool) {
        return registry.isVerified(who) && !token.frozen(who);
    }

    // ------------------------------------------------------------------ investors

    function requestDeposit(uint256 seed, uint256 assets) external {
        address who = _investor(seed);
        assets = bound(assets, 100e6, 1_000_000e6);
        vm.prank(who);
        try vault.requestDeposit(assets, who, who) {} catch {}
    }

    function requestRedeem(uint256 seed, uint256 tokens) external {
        address who = _investor(seed);
        uint256 bal = token.balanceOf(who);
        if (bal == 0) return;
        tokens = bound(tokens, 1, bal);
        uint256 shares = token.tokensToShares(tokens);
        vm.prank(who);
        try vault.requestRedeem(tokens, who, who) {
            ledger[who] -= shares;
        } catch {}
    }

    function cancelDeposit(uint256 seed) external {
        address who = _investor(seed);
        vm.prank(who);
        try vault.cancelDepositRequest(who) {} catch {}
    }

    function cancelRedeem(uint256 seed) external {
        address who = _investor(seed);
        uint256 pending = vault.accountOf(who).pendingRedeemShares;
        bool ok = _eligible(who);
        vm.prank(who);
        try vault.cancelRedeemRequest(who) {
            ledger[who] += pending;
            if (!ok && pending != 0) violations.push("cancelRedeem delivered shares to an ineligible wallet");
        } catch {}
    }

    function claimDeposit(uint256 seed) external {
        address who = _investor(seed);
        uint256 owed = vault.accountOf(who).claimableDepositShares;
        bool ok = _eligible(who);
        vm.prank(who);
        try vault.claimDeposit(who, who) {
            ledger[who] += owed;
            if (!ok && owed != 0) violations.push("claimDeposit delivered shares to an ineligible wallet");
        } catch {}
    }

    function claimRedeem(uint256 seed) external {
        address who = _investor(seed);
        FundVault.Account memory a = vault.accountOf(who);
        bool isFrozen = token.frozen(who);
        uint256 before = usdc.balanceOf(who);
        vm.prank(who);
        try vault.claimRedeem(who, who) {
            if (isFrozen) violations.push("a frozen investor withdrew cash");
            if (usdc.balanceOf(who) - before != a.claimableRedeemAssets) {
                violations.push("claimRedeem paid something other than what was owed");
            }
        } catch {}
    }

    function claimReturned(uint256 seed) external {
        address who = _investor(seed);
        uint256 owed = vault.accountOf(who).claimableReturnedShares;
        bool ok = _eligible(who);
        vm.prank(who);
        try vault.claimReturnedShares(who) {
            ledger[who] += owed;
            if (!ok && owed != 0) violations.push("claimReturnedShares delivered to an ineligible wallet");
        } catch {}
    }

    function transfer(uint256 fromSeed, uint256 toSeed, uint256 tokens) external {
        address from = _investor(fromSeed);
        address to = _investor(toSeed);
        uint256 bal = token.balanceOf(from);
        if (bal == 0) return;
        tokens = bound(tokens, 1, bal);
        uint256 shares = token.tokensToShares(tokens);
        bool ok = _eligible(to);
        vm.prank(from);
        try token.transfer(to, tokens) {
            ledger[from] -= shares;
            ledger[to] += shares;
            if (!ok && shares != 0) violations.push("transfer reached an ineligible wallet");
        } catch {}
    }

    function claimDistribution(uint256 seed) external {
        address who = _investor(seed);
        uint256 owed = distributions.claimable(who);
        uint256 before = usdc.balanceOf(who);
        try distributions.claim(who) {
            if (usdc.balanceOf(who) - before != owed) violations.push("distribution paid a wrong amount");
        } catch {}
    }

    // ------------------------------------------------------------------ manager, oracle, issuer

    function closeEpoch() external {
        vm.prank(roles.manager);
        try vault.closeEpoch() {} catch {}
    }

    /// @dev With `postFirst` the administrator values the fund after the cut-off, which is the correct
    ///      procedure: that settlement must go through. Without it the last NAV predates the cut-off,
    ///      and the settlement must be refused.
    function settle(uint256 navSeed, uint256 fillBps, bool postFirst) external {
        if (!vault.hasUnsettledEpoch()) {
            vm.prank(roles.manager);
            vault.closeEpoch();
        }
        uint64 id = vault.currentEpoch() - 1;
        (uint64 closedAt,,,,,,,,) = vault.epochs(id);
        fillBps = bound(fillBps, 0, 10_000);

        if (postFirst) {
            skip(1 hours);
            uint256 nav = oracle.nav();
            nav = nav * bound(navSeed, 9_100, 10_900) / 10_000; // inside the 10% band
            if (nav == 0) nav = 1;
            vm.prank(roles.navPoster);
            oracle.postNav(nav, uint64(block.timestamp));
        }
        bool navIsAfterCutoff = oracle.asOf() > closedAt;

        uint256 supplyBefore = token.totalShares();
        vm.prank(roles.manager);
        try vault.settleEpoch(fillBps) {
            settlements++;
            if (!navIsAfterCutoff) violations.push("epoch settled at a NAV valued before its cut-off");
            _checkSettlement(id, supplyBefore);
        } catch {
            if (postFirst) violations.push("a correctly valued epoch could not be settled (queue bricked)");
        }
    }

    function _checkSettlement(uint64 id, uint256 supplyBefore) private {
        (
            ,
            ,
            uint256 depositAssets,
            uint256 redeemShares,
            uint256 minted,
            uint256 filled,
            uint256 paid,
            uint256 nav,
            uint256 mult
        ) = vault.epochs(id);
        uint256 scale = vault.assetScale();
        // 18-decimal value of the shares created and destroyed, at the settlement NAV
        uint256 mintedValue = (minted * mult / 1e18) * nav / 1e18;
        uint256 filledValue = (filled * mult / 1e18) * nav / 1e18;
        if (mintedValue > depositAssets * scale) violations.push("subscribers got more shares than they paid for");
        if (paid * scale > filledValue) violations.push("redeemers were paid more than their shares were worth");
        if (filled > redeemShares) violations.push("more shares redeemed than requested");
        if (filled > supplyBefore * vault.maxRedeemBpsPerEpoch() / 10_000) {
            violations.push("redemption gate exceeded");
        }
    }

    function split(uint256 num, uint256 den) external {
        num = bound(num, 1, 20);
        den = bound(den, 1, 20);
        if (num == den) return;
        uint256 newMult = token.multiplier() * num / den;
        if (newMult < 1e12 || newMult > 1e24) return; // keep the fuzz inside a realistic range

        uint256 valueBefore = oracle.nav() * token.multiplier();
        uint256 supplyBefore = token.totalShares();
        vm.prank(roles.issuer);
        try actions.split(num, den) {
            splits++;
            uint256 valueAfter = oracle.nav() * token.multiplier();
            if (valueAfter > valueBefore) violations.push("split raised the value of a share");
            if (valueBefore - valueAfter > valueBefore / 1e9) violations.push("split moved share value");
            if (token.totalShares() != supplyBefore) violations.push("split changed the share supply");
        } catch {}
    }

    function distribute(uint256 amount) external {
        amount = bound(amount, 1e6, 500_000e6);
        vm.prank(roles.admin);
        try distributions.distribute(amount) {
            distributionsFunded++;
        } catch {}
    }

    function pushDepositShares(uint256 seed) external {
        address who = _investor(seed);
        uint256 owed = vault.accountOf(who).claimableDepositShares;
        vm.prank(roles.manager);
        try vault.pushDepositShares(who) {
            ledger[who] += owed;
        } catch {}
    }

    function setVaultLimits(uint256 gateBps, uint256 minDeposit) external {
        gateBps = bound(gateBps, 1, 10_000);
        minDeposit = bound(minDeposit, 0, 10_000e6);
        vm.prank(roles.admin);
        vault.setLimits(gateBps, minDeposit);
    }

    // ------------------------------------------------------------------ agent

    function setFrozen(uint256 seed, bool isFrozen) external {
        vm.prank(roles.agent);
        token.setAddressFrozen(_investor(seed), isFrozen);
    }

    function setKyc(uint256 seed, bool verified) external {
        address who = _investor(seed);
        vm.startPrank(roles.agent);
        if (verified) {
            registry.registerIdentity(who, 276, 1, uint64(block.timestamp + 365 days));
        } else if (registry.isVerified(who)) {
            registry.removeIdentity(who);
        }
        vm.stopPrank();
    }

    function freezePartial(uint256 seed, uint256 shares) external {
        address who = _investor(seed);
        uint256 free = token.sharesOf(who) - token.frozenShares(who);
        if (free == 0) return;
        vm.prank(roles.agent);
        token.freezePartialShares(who, bound(shares, 1, free));
    }

    function unfreezePartial(uint256 seed) external {
        address who = _investor(seed);
        uint256 f = token.frozenShares(who);
        if (f == 0) return;
        vm.prank(roles.agent);
        token.unfreezePartialShares(who, f);
    }

    function forcedTransfer(uint256 fromSeed, uint256 toSeed, uint256 shares) external {
        address from = _investor(fromSeed);
        address to = _investor(toSeed);
        uint256 bal = token.sharesOf(from);
        if (bal == 0) return;
        shares = bound(shares, 1, bal);
        bool verified = registry.isVerified(to);
        vm.prank(roles.agent);
        try token.forcedTransfer(from, to, shares) {
            ledger[from] -= shares;
            ledger[to] += shares;
            if (!verified) violations.push("forcedTransfer reached an unverified wallet");
        } catch {}
    }

    function setTokenPaused(bool paused) external {
        vm.startPrank(roles.agent);
        if (paused && !token.paused()) token.pause();
        if (!paused && token.paused()) token.unpause();
        vm.stopPrank();
    }

    function warp(uint256 secs) external {
        skip(bound(secs, 1, 6 hours));
    }

    // ------------------------------------------------------------------ attacker (never verified)

    function attackerSubscribe(uint256 assets) external {
        attackerAttempts++;
        assets = bound(assets, 100e6, 1_000_000e6);
        vm.prank(roles.mallory);
        try vault.requestDeposit(assets, roles.mallory, roles.mallory) {
            violations.push("an unverified wallet placed a subscription");
        } catch {}
    }

    function attackerReceive(uint256 fromSeed, uint256 tokens) external {
        attackerAttempts++;
        address from = _investor(fromSeed);
        uint256 bal = token.balanceOf(from);
        if (bal == 0) return;
        vm.prank(from);
        try token.transfer(roles.mallory, bound(tokens, 1, bal)) {
            violations.push("an unverified wallet received shares by transfer");
        } catch {}
    }

    function attackerClaimsForInvestor(uint256 seed) external {
        attackerAttempts++;
        address who = _investor(seed);
        vm.startPrank(roles.mallory);
        try vault.claimDeposit(roles.mallory, who) {
            violations.push("a stranger claimed an investor's shares");
        } catch {}
        try vault.claimRedeem(roles.mallory, who) {
            violations.push("a stranger claimed an investor's cash");
        } catch {}
        try vault.cancelDepositRequest(who) {
            violations.push("a stranger cancelled an investor's request");
        } catch {}
        vm.stopPrank();
    }

    function attackerPrivilegedCalls(uint256 x) external {
        attackerAttempts++;
        vm.startPrank(roles.mallory);
        try token.mintShares(roles.mallory, 1e18) {
            violations.push("attacker minted shares");
        } catch {}
        try token.setMultiplier(bound(x, 1e9, 1e27)) {
            violations.push("attacker changed the multiplier");
        } catch {}
        try oracle.postNav(bound(x, 1, 1e30), uint64(block.timestamp)) {
            violations.push("attacker posted a NAV");
        } catch {}
        try vault.settleEpoch(10_000) {
            violations.push("attacker settled an epoch");
        } catch {}
        try token.forcedTransfer(investors[0], roles.mallory, 1) {
            violations.push("attacker forced a transfer");
        } catch {}
        vm.stopPrank();
    }
}
