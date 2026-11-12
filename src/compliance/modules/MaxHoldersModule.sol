// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AbstractModule} from "./AbstractModule.sol";
import {IFundShareToken} from "../../interfaces/IFundShareToken.sol";

/// @title MaxHoldersModule
/// @notice Caps the number of investors holding shares (for example a private-placement limit).
/// @dev    Counts wallets with a non-zero share balance. System addresses (vault, gateway) hold shares in
///         transit and are not investors, so they are not counted. The hooks run after balances changed,
///         so "was this wallet empty before" is rebuilt from the current balance and the moved amount.
contract MaxHoldersModule is AbstractModule {
    uint256 public maxHolders;
    uint256 public holderCount;

    event MaxHoldersSet(uint256 maxHolders);

    error BelowCurrentHolderCount();

    constructor(address compliance_, IFundShareToken token_, address owner_, uint256 maxHolders_)
        AbstractModule(compliance_, token_, owner_)
    {
        maxHolders = maxHolders_;
        emit MaxHoldersSet(maxHolders_);
    }

    function setMaxHolders(uint256 maxHolders_) external onlyOwner {
        if (maxHolders_ < holderCount) revert BelowCurrentHolderCount();
        maxHolders = maxHolders_;
        emit MaxHoldersSet(maxHolders_);
    }

    function moduleCheck(address from, address to, uint256 shares) external view returns (bool) {
        if (shares == 0 || from == to || to == address(0) || token.isSystem(to)) return true;
        if (token.sharesOf(to) != 0) return true; // already a holder
        uint256 count = holderCount;
        // A sender who moves their whole balance stops being a holder and frees a slot.
        if (from != address(0) && !token.isSystem(from) && token.sharesOf(from) == shares) count -= 1;
        return count + 1 <= maxHolders;
    }

    function moduleTransferAction(address from, address to, uint256 shares) external onlyCompliance {
        if (shares == 0 || from == to) return;
        _left(from);
        _joined(to, shares);
    }

    function moduleMintAction(address to, uint256 shares) external onlyCompliance {
        if (shares == 0) return;
        _joined(to, shares);
    }

    function moduleBurnAction(address from, uint256 shares) external onlyCompliance {
        if (shares == 0) return;
        _left(from);
    }

    function _joined(address to, uint256 shares) private {
        if (!token.isSystem(to) && token.sharesOf(to) == shares) holderCount += 1;
    }

    function _left(address from) private {
        if (!token.isSystem(from) && token.sharesOf(from) == 0) holderCount -= 1;
    }

    function name() external pure returns (string memory) {
        return "MaxHoldersModule";
    }
}
