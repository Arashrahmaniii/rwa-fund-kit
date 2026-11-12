// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IdentityRegistry} from "../src/identity/IdentityRegistry.sol";
import {ModularCompliance} from "../src/compliance/ModularCompliance.sol";
import {CountryRestrictModule} from "../src/compliance/modules/CountryRestrictModule.sol";
import {MaxHoldersModule} from "../src/compliance/modules/MaxHoldersModule.sol";
import {FundShareToken} from "../src/token/FundShareToken.sol";
import {NavOracle} from "../src/oracle/NavOracle.sol";
import {FundVault} from "../src/vault/FundVault.sol";
import {DistributionModule, IEpochGuard} from "../src/actions/DistributionModule.sol";
import {CorporateActions} from "../src/actions/CorporateActions.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";

/// @notice Deploys and wires the whole kit the way `script/Deploy.s.sol` does, with named actors.
abstract contract Base is Test {
    uint16 internal constant DE = 276;
    uint16 internal constant FR = 250;
    uint16 internal constant CH = 756;
    uint16 internal constant KP = 408;

    address internal admin = makeAddr("admin");
    address internal agent = makeAddr("agent");
    address internal manager = makeAddr("manager");
    address internal navPoster = makeAddr("navPoster");
    address internal guardian = makeAddr("guardian");
    address internal issuer = makeAddr("issuer");
    address internal custodian = makeAddr("custodian");

    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");
    address internal carol = makeAddr("carol");
    address internal mallory = makeAddr("mallory"); // never verified

    MockUSDC internal usdc;
    IdentityRegistry internal registry;
    ModularCompliance internal compliance;
    CountryRestrictModule internal countryModule;
    MaxHoldersModule internal holdersModule;
    DistributionModule internal distributions;
    FundShareToken internal token;
    NavOracle internal oracle;
    FundVault internal vault;
    CorporateActions internal actions;

    uint256 internal constant NAV_ONE = 1e18;
    uint256 internal constant USDC_UNIT = 1e6;

    function setUp() public virtual {
        vm.warp(1_800_000_000);

        usdc = new MockUSDC();
        vm.startPrank(admin);
        registry = new IdentityRegistry(admin);
        compliance = new ModularCompliance(admin);
        token = new FundShareToken("Example Treasury Fund", "xTF", admin, registry, compliance);
        compliance.bindToken(address(token));

        countryModule = new CountryRestrictModule(address(compliance), token, admin);
        holdersModule = new MaxHoldersModule(address(compliance), token, admin, 100);
        distributions = new DistributionModule(address(compliance), token, admin, IERC20(address(usdc)));
        compliance.addModule(countryModule);
        compliance.addModule(holdersModule);
        compliance.addModule(distributions);

        oracle = new NavOracle(admin, NAV_ONE, 1_000, 2 days);
        vault = new FundVault(admin, IERC20(address(usdc)), token, oracle, custodian, 2_500, 100 * USDC_UNIT);
        actions = new CorporateActions(admin, token, oracle);

        registry.grantRole(registry.AGENT_ROLE(), agent);
        token.grantRole(token.AGENT_ROLE(), agent);
        token.grantRole(token.MINTER_ROLE(), address(vault));
        token.grantRole(token.CORPORATE_ACTIONS_ROLE(), address(actions));
        token.setSystemAddress(address(vault), true);
        oracle.grantRole(oracle.ORACLE_ROLE(), navPoster);
        oracle.grantRole(oracle.GUARDIAN_ROLE(), guardian);
        oracle.grantRole(oracle.CORPORATE_ACTIONS_ROLE(), address(actions));
        vault.grantRole(vault.MANAGER_ROLE(), manager);
        actions.grantRole(actions.ISSUER_ROLE(), issuer);
        distributions.setEpochGuard(IEpochGuard(address(vault)));
        countryModule.setCountryBlocked(KP, true);
        vm.stopPrank();

        _verify(alice, DE);
        _verify(bob, FR);
        _verify(carol, CH);

        address[4] memory users = [alice, bob, carol, mallory];
        for (uint256 i; i < users.length; ++i) {
            usdc.mint(users[i], 10_000_000 * USDC_UNIT);
            vm.startPrank(users[i]);
            usdc.approve(address(vault), type(uint256).max);
            token.approve(address(vault), type(uint256).max);
            vm.stopPrank();
        }
        usdc.mint(custodian, 100_000_000 * USDC_UNIT);
        vm.prank(custodian);
        usdc.approve(address(vault), type(uint256).max);
        usdc.mint(admin, 10_000_000 * USDC_UNIT);
        vm.prank(admin);
        usdc.approve(address(distributions), type(uint256).max);
    }

    // ------------------------------------------------------------------ helpers

    function _verify(address who, uint16 country) internal {
        vm.prank(agent);
        registry.registerIdentity(who, country, 1, uint64(block.timestamp + 365 days));
    }

    function _requestDeposit(address who, uint256 assets) internal {
        vm.prank(who);
        vault.requestDeposit(assets, who, who);
    }

    function _requestRedeem(address who, uint256 tokens) internal {
        vm.prank(who);
        vault.requestRedeem(tokens, who, who);
    }

    function _postNav(uint256 nav) internal {
        vm.prank(navPoster);
        oracle.postNav(nav, uint64(block.timestamp));
    }

    /// @dev Cut-off, one hour for the administrator to value the fund, NAV, settlement.
    function _runEpoch(uint256 nav, uint256 fillBps) internal {
        vm.prank(manager);
        vault.closeEpoch();
        skip(1 hours);
        _postNav(nav);
        vm.prank(manager);
        vault.settleEpoch(fillBps);
    }

    /// @dev Subscribe at `nav` and deliver the shares.
    function _fund(address who, uint256 assets, uint256 nav) internal {
        _requestDeposit(who, assets);
        _runEpoch(nav, 10_000);
        vm.prank(who);
        vault.claimDeposit(who, who);
    }
}
