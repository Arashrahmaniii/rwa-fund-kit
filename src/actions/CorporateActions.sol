// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IFundShareToken} from "../interfaces/IFundShareToken.sol";
import {NavOracle} from "../oracle/NavOracle.sol";

/// @title CorporateActions
/// @notice The only path to a share split. It changes the token multiplier and rescales the NAV per
///         token in the same transaction, so the value of a base share is the same before and after.
/// @dev    This contract, and nothing else, should hold CORPORATE_ACTIONS_ROLE on the token and the
///         oracle. If the two steps could be run separately, the window between them would let anyone
///         subscribe or redeem at a price that is wrong by the split ratio.
contract CorporateActions is AccessControl {
    bytes32 public constant ISSUER_ROLE = keccak256("ISSUER_ROLE");

    IFundShareToken public immutable token;
    NavOracle public immutable oracle;

    event Split(uint256 numerator, uint256 denominator, uint256 oldMultiplier, uint256 newMultiplier);

    error BadRatio();

    constructor(address admin, IFundShareToken token_, NavOracle oracle_) {
        token = token_;
        oracle = oracle_;
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @notice Split shares `numerator`-for-`denominator` (2,1 doubles every balance; 1,10 is a
    ///         1-for-10 reverse split).
    function split(uint256 numerator, uint256 denominator) external onlyRole(ISSUER_ROLE) {
        if (numerator == 0 || denominator == 0 || numerator == denominator) revert BadRatio();
        uint256 oldMultiplier = token.multiplier();
        uint256 newMultiplier = Math.mulDiv(oldMultiplier, numerator, denominator);
        token.setMultiplier(newMultiplier);
        oracle.rescaleForSplit(numerator, denominator);
        emit Split(numerator, denominator, oldMultiplier, newMultiplier);
    }
}
