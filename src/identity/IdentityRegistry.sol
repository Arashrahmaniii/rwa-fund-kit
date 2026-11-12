// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {IIdentityRegistry} from "../interfaces/IIdentityRegistry.sol";

/// @title IdentityRegistry
/// @notice The on-chain copy of the transfer agent's investor list. A wallet is verified while it has a
///         record whose KYC expiry is in the future.
/// @dev    This is the ERC-3643 registry model with the claim logic left out: a full T-REX deployment
///         checks ONCHAINID claims signed by trusted issuers, here an AGENT attests directly. The token
///         only depends on `IIdentityRegistry`, so a claim-based registry can replace this one.
contract IdentityRegistry is IIdentityRegistry, AccessControl {
    bytes32 public constant AGENT_ROLE = keccak256("AGENT_ROLE");

    struct Identity {
        uint16 country; // ISO 3166-1 numeric
        uint8 investorClass; // issuer-defined, e.g. 1 = professional, 2 = retail
        uint64 kycExpiry;
    }

    mapping(address => Identity) private _identities;

    event IdentityRegistered(address indexed wallet, uint16 country, uint8 investorClass, uint64 kycExpiry);
    event IdentityRemoved(address indexed wallet);

    error ZeroAddress();
    error ExpiryInPast();
    error NotRegistered(address wallet);

    constructor(address admin) {
        if (admin == address(0)) revert ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    /// @notice Add a wallet or overwrite its record (country change, KYC renewal).
    function registerIdentity(address wallet, uint16 country, uint8 investorClass, uint64 kycExpiry)
        public
        onlyRole(AGENT_ROLE)
    {
        if (wallet == address(0)) revert ZeroAddress();
        if (kycExpiry <= block.timestamp) revert ExpiryInPast();
        _identities[wallet] = Identity(country, investorClass, kycExpiry);
        emit IdentityRegistered(wallet, country, investorClass, kycExpiry);
    }

    function batchRegisterIdentity(
        address[] calldata wallets,
        uint16[] calldata countries,
        uint8[] calldata classes,
        uint64[] calldata expiries
    ) external {
        for (uint256 i; i < wallets.length; ++i) {
            registerIdentity(wallets[i], countries[i], classes[i], expiries[i]);
        }
    }

    function removeIdentity(address wallet) external onlyRole(AGENT_ROLE) {
        if (_identities[wallet].kycExpiry == 0) revert NotRegistered(wallet);
        delete _identities[wallet];
        emit IdentityRemoved(wallet);
    }

    function isVerified(address wallet) external view returns (bool) {
        return _identities[wallet].kycExpiry > block.timestamp;
    }

    function investorCountry(address wallet) external view returns (uint16) {
        return _identities[wallet].country;
    }

    function identityOf(address wallet) external view returns (Identity memory) {
        return _identities[wallet];
    }
}
