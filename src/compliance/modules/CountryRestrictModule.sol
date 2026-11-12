// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AbstractModule} from "./AbstractModule.sol";
import {IFundShareToken} from "../../interfaces/IFundShareToken.sol";

/// @title CountryRestrictModule
/// @notice Blocks any movement of shares to an investor whose registered country is on the blocked list.
contract CountryRestrictModule is AbstractModule {
    mapping(uint16 => bool) public isCountryBlocked;

    event CountryBlocked(uint16 indexed country, bool blocked);

    constructor(address compliance_, IFundShareToken token_, address owner_)
        AbstractModule(compliance_, token_, owner_)
    {}

    function setCountryBlocked(uint16 country, bool blocked) external onlyOwner {
        isCountryBlocked[country] = blocked;
        emit CountryBlocked(country, blocked);
    }

    function moduleCheck(address, address to, uint256) external view returns (bool) {
        if (to == address(0) || token.isSystem(to)) return true;
        return !isCountryBlocked[token.identityRegistry().investorCountry(to)];
    }

    function moduleTransferAction(address, address, uint256) external onlyCompliance {}

    function moduleMintAction(address, uint256) external onlyCompliance {}

    function moduleBurnAction(address, uint256) external onlyCompliance {}

    function name() external pure returns (string memory) {
        return "CountryRestrictModule";
    }
}
