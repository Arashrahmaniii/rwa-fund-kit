// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {Deploy} from "./Deploy.s.sol";
import {DemoOperator} from "../src/mocks/DemoOperator.sol";
import {MockUSDC} from "../src/mocks/MockUSDC.sol";

/// @notice TESTNET ONLY. Deploys the kit with a `DemoOperator` as custodian, agent, manager and NAV
///         poster so the public console is self-service, and writes the addresses the console reads.
///         The deployer stays admin. Do not use this script for a real fund; use `Deploy.s.sol`.
contract DeployDemo is Deploy {
    function runDemo() external returns (Deployment memory d, DemoOperator demo) {
        address deployer = msg.sender;
        vm.startBroadcast();
        (d, demo) = deployDemo(deployer);
        vm.stopBroadcast();
        _writeAddresses(d, address(demo));
    }

    /// @dev Separated so tests can run it without broadcasting.
    function deployDemo(address deployer) public returns (Deployment memory d, DemoOperator demo) {
        demo = new DemoOperator();
        d = deploy(
            deployer,
            Config({
                admin: deployer,
                agent: deployer,
                manager: deployer,
                navPoster: deployer,
                navGuardian: deployer,
                custodian: address(demo)
            })
        );
        demo.init(d.registry, d.vault, d.oracle, MockUSDC(address(d.payToken)));
        d.registry.grantRole(d.registry.AGENT_ROLE(), address(demo));
        d.vault.grantRole(d.vault.MANAGER_ROLE(), address(demo));
        d.oracle.grantRole(d.oracle.ORACLE_ROLE(), address(demo));
    }

    function _writeAddresses(Deployment memory d, address demo) internal {
        string memory k = "deployment";
        vm.serializeUint(k, "chainId", block.chainid);
        vm.serializeAddress(k, "payToken", address(d.payToken));
        vm.serializeAddress(k, "registry", address(d.registry));
        vm.serializeAddress(k, "compliance", address(d.compliance));
        vm.serializeAddress(k, "countryModule", address(d.countryModule));
        vm.serializeAddress(k, "holdersModule", address(d.holdersModule));
        vm.serializeAddress(k, "distributions", address(d.distributions));
        vm.serializeAddress(k, "token", address(d.token));
        vm.serializeAddress(k, "oracle", address(d.oracle));
        vm.serializeAddress(k, "vault", address(d.vault));
        vm.serializeAddress(k, "actions", address(d.actions));
        string memory json = vm.serializeAddress(k, "demoOperator", demo);
        string memory path = string.concat("docs/console/deployments/", vm.toString(block.chainid), ".json");
        vm.writeJson(json, path);
        console2.log("wrote", path);
    }
}
