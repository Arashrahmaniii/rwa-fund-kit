// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {IComplianceModule} from "../../interfaces/IComplianceModule.sol";
import {IFundShareToken} from "../../interfaces/IFundShareToken.sol";

/// @notice Shared plumbing for rule modules: who may call the hooks, and which token they describe.
abstract contract AbstractModule is IComplianceModule, Ownable {
    address public immutable compliance;
    IFundShareToken public immutable token;

    error OnlyCompliance();

    modifier onlyCompliance() {
        if (msg.sender != compliance) revert OnlyCompliance();
        _;
    }

    constructor(address compliance_, IFundShareToken token_, address owner_) Ownable(owner_) {
        compliance = compliance_;
        token = token_;
    }
}
