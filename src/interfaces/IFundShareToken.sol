// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IIdentityRegistry} from "./IIdentityRegistry.sol";

interface IFundShareToken is IERC20 {
    function sharesOf(address account) external view returns (uint256);
    function totalShares() external view returns (uint256);
    function multiplier() external view returns (uint256);
    function tokensToShares(uint256 tokens) external view returns (uint256);
    function sharesToTokens(uint256 shares) external view returns (uint256);
    function transferShares(address to, uint256 shares) external returns (uint256 tokens);
    function transferSharesFrom(address from, address to, uint256 shares) external returns (uint256 tokens);
    function mintShares(address to, uint256 shares) external;
    function burnShares(uint256 shares) external;
    function setMultiplier(uint256 newMultiplier) external;
    function isSystem(address account) external view returns (bool);
    function frozen(address account) external view returns (bool);
    function identityRegistry() external view returns (IIdentityRegistry);
}
