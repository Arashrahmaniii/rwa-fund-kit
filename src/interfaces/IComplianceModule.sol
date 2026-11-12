// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @notice One transfer rule. `moduleCheck` runs before a move; the action hooks run after it.
///         For a mint `from` is address(0); for a burn `to` is address(0).
interface IComplianceModule {
    function moduleCheck(address from, address to, uint256 shares) external view returns (bool);
    function moduleTransferAction(address from, address to, uint256 shares) external;
    function moduleMintAction(address to, uint256 shares) external;
    function moduleBurnAction(address from, uint256 shares) external;
    function name() external pure returns (string memory);
}
