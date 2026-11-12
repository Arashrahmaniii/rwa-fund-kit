// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Base} from "../Base.t.sol";
import {FundShareToken} from "../../src/token/FundShareToken.sol";
import {ModularCompliance} from "../../src/compliance/ModularCompliance.sol";
import {CountryRestrictModule} from "../../src/compliance/modules/CountryRestrictModule.sol";
import {AbstractModule} from "../../src/compliance/modules/AbstractModule.sol";
import {MaxHoldersModule} from "../../src/compliance/modules/MaxHoldersModule.sol";
import {IdentityRegistry} from "../../src/identity/IdentityRegistry.sol";

contract ComplianceTest is Base {
    address internal dave = makeAddr("dave");

    function setUp() public override {
        super.setUp();
        _fund(alice, 1_000 * USDC_UNIT, NAV_ONE);
    }

    // ------------------------------------------------------------------ identity registry

    function test_registry_onlyAgentRegisters() public {
        vm.prank(alice);
        vm.expectRevert();
        registry.registerIdentity(dave, DE, 1, uint64(block.timestamp + 1 days));
    }

    function test_registry_expiryMustBeInFuture() public {
        vm.prank(agent);
        vm.expectRevert(IdentityRegistry.ExpiryInPast.selector);
        registry.registerIdentity(dave, DE, 1, uint64(block.timestamp));
    }

    function test_registry_removeIdentity_stopsInboundTransfers() public {
        vm.prank(agent);
        registry.removeIdentity(bob);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FundShareToken.ReceiverNotVerified.selector, bob));
        token.transfer(bob, 1e18);
    }

    // ------------------------------------------------------------------ country rule

    function test_country_blockedReceiver_reverts() public {
        _verify(dave, KP);
        vm.prank(alice);
        vm.expectRevert(abi.encodeWithSelector(FundShareToken.ComplianceRejected.selector, alice, dave, 10e18));
        token.transfer(dave, 10e18);
    }

    function test_country_blockAppliesToForcedPathsToo_viaIdentityOnly() public {
        // forcedTransfer skips module checks by design (court orders), but still needs a verified receiver.
        _verify(dave, KP);
        vm.prank(agent);
        token.forcedTransfer(alice, dave, 10e18);
        assertEq(token.balanceOf(dave), 10e18);
    }

    function test_country_unblock() public {
        _verify(dave, KP);
        vm.prank(admin);
        countryModule.setCountryBlocked(KP, false);
        vm.prank(alice);
        token.transfer(dave, 10e18);
        assertEq(token.balanceOf(dave), 10e18);
    }

    function test_country_subscriptionFromBlockedCountry_cannotBeDelivered() public {
        _verify(dave, KP);
        usdc.mint(dave, 1_000 * USDC_UNIT);
        vm.startPrank(dave);
        usdc.approve(address(vault), type(uint256).max);
        vault.requestDeposit(1_000 * USDC_UNIT, dave, dave);
        vm.stopPrank();
        _runEpoch(NAV_ONE, 10_000);

        vm.prank(dave);
        vm.expectRevert();
        vault.claimDeposit(dave, dave);
    }

    // ------------------------------------------------------------------ holder cap

    function test_maxHolders_countsInvestorsNotSystemAddresses() public {
        assertEq(holdersModule.holderCount(), 1);
        _requestRedeem(alice, 100e18); // shares move to the vault: still one investor
        assertEq(holdersModule.holderCount(), 1);
        vm.prank(alice);
        token.transfer(bob, 100e18);
        assertEq(holdersModule.holderCount(), 2);
    }

    function test_maxHolders_capBlocksNewHolder() public {
        vm.prank(admin);
        holdersModule.setMaxHolders(2);
        vm.startPrank(alice);
        token.transfer(bob, 100e18);
        vm.expectRevert(abi.encodeWithSelector(FundShareToken.ComplianceRejected.selector, alice, carol, 100e18));
        token.transfer(carol, 100e18);
        token.transfer(bob, 50e18); // existing holders are unaffected
        vm.stopPrank();
    }

    function test_maxHolders_leavingFreesASlot() public {
        vm.prank(admin);
        holdersModule.setMaxHolders(2);
        vm.prank(alice);
        token.transfer(bob, 100e18);

        // bob hands his whole position to carol: holder count stays at 2, so it is allowed at the cap
        vm.prank(bob);
        token.transfer(carol, 100e18);
        assertEq(holdersModule.holderCount(), 2);
        assertEq(token.balanceOf(bob), 0);
    }

    function test_maxHolders_cannotSetBelowCurrent() public {
        vm.prank(alice);
        token.transfer(bob, 100e18);
        vm.prank(admin);
        vm.expectRevert(MaxHoldersModule.BelowCurrentHolderCount.selector);
        holdersModule.setMaxHolders(1);
    }

    function test_maxHolders_selfTransferDoesNotDoubleCount() public {
        vm.prank(alice);
        token.transfer(alice, 1_000e18);
        assertEq(holdersModule.holderCount(), 1);
    }

    // ------------------------------------------------------------------ engine

    function test_engine_hooksOnlyFromToken() public {
        vm.prank(alice);
        vm.expectRevert(ModularCompliance.OnlyToken.selector);
        compliance.transferred(alice, bob, 1);
        vm.prank(alice);
        vm.expectRevert(ModularCompliance.OnlyToken.selector);
        compliance.created(alice, 1);
        vm.prank(alice);
        vm.expectRevert(ModularCompliance.OnlyToken.selector);
        compliance.destroyed(alice, 1);
    }

    function test_engine_moduleHooksOnlyFromCompliance() public {
        vm.prank(alice);
        vm.expectRevert(AbstractModule.OnlyCompliance.selector);
        holdersModule.moduleMintAction(alice, 1);
        vm.prank(alice);
        vm.expectRevert(AbstractModule.OnlyCompliance.selector);
        distributions.moduleTransferAction(alice, bob, 1);
    }

    function test_engine_cannotAddModuleOnceSharesExist() public {
        vm.startPrank(admin);
        CountryRestrictModule extra = new CountryRestrictModule(address(compliance), token, admin);
        vm.expectRevert(ModularCompliance.SupplyNotEmpty.selector);
        compliance.addModule(extra);
        vm.stopPrank();
    }

    function test_engine_removeModule_liftsTheRule() public {
        _verify(dave, KP);
        vm.prank(admin);
        compliance.removeModule(countryModule);
        vm.prank(alice);
        token.transfer(dave, 10e18);
        assertEq(compliance.modules().length, 2);
    }

    function test_engine_tokenCannotBeReboundElsewhere() public {
        vm.prank(admin);
        vm.expectRevert(ModularCompliance.TokenAlreadyBound.selector);
        compliance.bindToken(address(usdc));
    }
}
