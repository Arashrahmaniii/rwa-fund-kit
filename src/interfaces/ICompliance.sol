// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice Transfer-rule engine bound to one token (ERC-3643 `ICompliance` shape).
///         All amounts are base shares, so rules do not move when the share multiplier changes.
interface ICompliance {
    function canTransfer(address from, address to, uint256 shares) external view returns (bool);
    function transferred(address from, address to, uint256 shares) external;
    function created(address to, uint256 shares) external;
    function destroyed(address from, uint256 shares) external;
}
