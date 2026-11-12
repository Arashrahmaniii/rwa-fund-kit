// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Minimal identity registry in the ERC-3643 (T-REX) model: the token asks it whether a wallet
///         belongs to a verified investor before that wallet may receive shares.
interface IIdentityRegistry {
    function isVerified(address wallet) external view returns (bool);
    function investorCountry(address wallet) external view returns (uint16);
}
