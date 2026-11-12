// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Ownable} from "@openzeppelin/contracts/access/Ownable.sol";
import {ICompliance} from "../interfaces/ICompliance.sol";
import {IComplianceModule} from "../interfaces/IComplianceModule.sol";

interface IShareSupply {
    function totalShares() external view returns (uint256);
}

/// @title ModularCompliance
/// @notice Runs every bound rule module before a share movement and notifies them after it.
/// @dev    Modules that count holders or accrue distributions keep running totals, so they must be added
///         before the first mint. `addModule` enforces that.
contract ModularCompliance is ICompliance, Ownable {
    uint256 public constant MAX_MODULES = 12;

    address public token;
    IComplianceModule[] private _modules;
    mapping(address => bool) public isModuleBound;

    event TokenBound(address indexed token);
    event ModuleAdded(address indexed module);
    event ModuleRemoved(address indexed module);

    error OnlyToken();
    error TokenAlreadyBound();
    error ModuleAlreadyBound();
    error ModuleNotBound();
    error TooManyModules();
    error SupplyNotEmpty();
    error ZeroAddress();

    modifier onlyToken() {
        if (msg.sender != token) revert OnlyToken();
        _;
    }

    constructor(address owner_) Ownable(owner_) {}

    function bindToken(address token_) external onlyOwner {
        if (token != address(0)) revert TokenAlreadyBound();
        if (token_ == address(0)) revert ZeroAddress();
        token = token_;
        emit TokenBound(token_);
    }

    /// @notice Add a rule. Only possible while no shares exist, so stateful modules start from a true zero.
    function addModule(IComplianceModule module) external onlyOwner {
        if (isModuleBound[address(module)]) revert ModuleAlreadyBound();
        if (_modules.length == MAX_MODULES) revert TooManyModules();
        if (token != address(0) && IShareSupply(token).totalShares() != 0) revert SupplyNotEmpty();
        isModuleBound[address(module)] = true;
        _modules.push(module);
        emit ModuleAdded(address(module));
    }

    /// @notice Remove a rule. Allowed at any time: dropping a restriction never corrupts the others.
    function removeModule(IComplianceModule module) external onlyOwner {
        if (!isModuleBound[address(module)]) revert ModuleNotBound();
        uint256 n = _modules.length;
        for (uint256 i; i < n; ++i) {
            if (_modules[i] == module) {
                _modules[i] = _modules[n - 1];
                _modules.pop();
                break;
            }
        }
        isModuleBound[address(module)] = false;
        emit ModuleRemoved(address(module));
    }

    function modules() external view returns (IComplianceModule[] memory) {
        return _modules;
    }

    function canTransfer(address from, address to, uint256 shares) external view returns (bool) {
        uint256 n = _modules.length;
        for (uint256 i; i < n; ++i) {
            if (!_modules[i].moduleCheck(from, to, shares)) return false;
        }
        return true;
    }

    function transferred(address from, address to, uint256 shares) external onlyToken {
        uint256 n = _modules.length;
        for (uint256 i; i < n; ++i) {
            _modules[i].moduleTransferAction(from, to, shares);
        }
    }

    function created(address to, uint256 shares) external onlyToken {
        uint256 n = _modules.length;
        for (uint256 i; i < n; ++i) {
            _modules[i].moduleMintAction(to, shares);
        }
    }

    function destroyed(address from, uint256 shares) external onlyToken {
        uint256 n = _modules.length;
        for (uint256 i; i < n; ++i) {
            _modules[i].moduleBurnAction(from, shares);
        }
    }
}
