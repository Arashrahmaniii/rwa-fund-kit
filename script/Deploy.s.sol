// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
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

/// @notice Deploys and wires the kit, hands every role to the configured addresses, and leaves the
///         deployer with nothing.
///
/// Configuration comes from environment variables. Every address defaults to the deployer, which is
/// only acceptable on a test network:
///   ISSUER_ADMIN, TRANSFER_AGENT, FUND_MANAGER, NAV_POSTER, NAV_GUARDIAN, CUSTODIAN
///   PAY_TOKEN          payment token; a MockUSDC is deployed if unset
///   FUND_NAME, FUND_SYMBOL
///   MAX_HOLDERS (default 500), GATE_BPS (2500), MIN_DEPOSIT (100e6)
///   NAV_BAND_BPS (1000), NAV_MAX_AGE (172800 seconds)
contract Deploy is Script {
    struct Config {
        address admin;
        address agent;
        address manager;
        address navPoster;
        address navGuardian;
        address custodian;
    }

    struct Deployment {
        IERC20 payToken;
        IdentityRegistry registry;
        ModularCompliance compliance;
        CountryRestrictModule countryModule;
        MaxHoldersModule holdersModule;
        DistributionModule distributions;
        FundShareToken token;
        NavOracle oracle;
        FundVault vault;
        CorporateActions actions;
    }

    function run() external returns (Deployment memory d) {
        address deployer = msg.sender;
        Config memory c = Config({
            admin: vm.envOr("ISSUER_ADMIN", deployer),
            agent: vm.envOr("TRANSFER_AGENT", deployer),
            manager: vm.envOr("FUND_MANAGER", deployer),
            navPoster: vm.envOr("NAV_POSTER", deployer),
            navGuardian: vm.envOr("NAV_GUARDIAN", deployer),
            custodian: vm.envOr("CUSTODIAN", deployer)
        });

        vm.startBroadcast();
        d = deploy(deployer, c);
        vm.stopBroadcast();

        console2.log("payToken        ", address(d.payToken));
        console2.log("IdentityRegistry", address(d.registry));
        console2.log("Compliance      ", address(d.compliance));
        console2.log("FundShareToken  ", address(d.token));
        console2.log("NavOracle       ", address(d.oracle));
        console2.log("FundVault       ", address(d.vault));
        console2.log("Distributions   ", address(d.distributions));
        console2.log("CorporateActions", address(d.actions));
    }

    /// @dev Separated from `run` so tests can call it without broadcasting.
    function deploy(address deployer, Config memory c) public returns (Deployment memory d) {
        address payToken = vm.envOr("PAY_TOKEN", address(0));
        d.payToken = payToken == address(0) ? IERC20(address(new MockUSDC())) : IERC20(payToken);

        // The deployer is admin only for the length of this function.
        d.registry = new IdentityRegistry(deployer);
        d.compliance = new ModularCompliance(deployer);
        d.token = new FundShareToken(
            vm.envOr("FUND_NAME", string("Example Treasury Fund")),
            vm.envOr("FUND_SYMBOL", string("xTF")),
            deployer,
            d.registry,
            d.compliance
        );
        d.compliance.bindToken(address(d.token));

        // Modules go in before any share exists; they cannot be added afterwards.
        d.countryModule = new CountryRestrictModule(address(d.compliance), d.token, c.admin);
        d.holdersModule =
            new MaxHoldersModule(address(d.compliance), d.token, c.admin, vm.envOr("MAX_HOLDERS", uint256(500)));
        d.distributions = new DistributionModule(address(d.compliance), d.token, deployer, d.payToken);
        d.compliance.addModule(d.countryModule);
        d.compliance.addModule(d.holdersModule);
        d.compliance.addModule(d.distributions);

        d.oracle = new NavOracle(
            deployer, 1e18, vm.envOr("NAV_BAND_BPS", uint256(1_000)), uint64(vm.envOr("NAV_MAX_AGE", uint256(2 days)))
        );
        d.vault = new FundVault(
            deployer,
            d.payToken,
            d.token,
            d.oracle,
            c.custodian,
            vm.envOr("GATE_BPS", uint256(2_500)),
            vm.envOr("MIN_DEPOSIT", uint256(100e6))
        );
        d.actions = new CorporateActions(deployer, d.token, d.oracle);

        // Operating roles
        d.registry.grantRole(d.registry.AGENT_ROLE(), c.agent);
        d.token.grantRole(d.token.AGENT_ROLE(), c.agent);
        d.token.grantRole(d.token.MINTER_ROLE(), address(d.vault));
        d.token.grantRole(d.token.CORPORATE_ACTIONS_ROLE(), address(d.actions));
        d.token.setSystemAddress(address(d.vault), true);
        d.oracle.grantRole(d.oracle.ORACLE_ROLE(), c.navPoster);
        d.oracle.grantRole(d.oracle.GUARDIAN_ROLE(), c.navGuardian);
        d.oracle.grantRole(d.oracle.CORPORATE_ACTIONS_ROLE(), address(d.actions));
        d.vault.grantRole(d.vault.MANAGER_ROLE(), c.manager);
        d.actions.grantRole(d.actions.ISSUER_ROLE(), c.admin);
        d.distributions.setEpochGuard(IEpochGuard(address(d.vault)));

        // Hand over admin and drop the deployer's rights.
        if (c.admin != deployer) {
            _handOver(d, deployer, c.admin);
        }
    }

    function _handOver(Deployment memory d, address deployer, address admin) private {
        bytes32 adminRole = 0x00;
        d.registry.grantRole(adminRole, admin);
        d.registry.renounceRole(adminRole, deployer);
        d.token.grantRole(adminRole, admin);
        d.token.renounceRole(adminRole, deployer);
        d.oracle.grantRole(adminRole, admin);
        d.oracle.renounceRole(adminRole, deployer);
        d.vault.grantRole(adminRole, admin);
        d.vault.renounceRole(adminRole, deployer);
        d.actions.grantRole(adminRole, admin);
        d.actions.renounceRole(adminRole, deployer);
        d.compliance.transferOwnership(admin);
        d.distributions.transferOwnership(admin);
    }
}
