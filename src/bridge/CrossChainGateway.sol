// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {AccessControl} from "@openzeppelin/contracts/access/AccessControl.sol";
import {Pausable} from "@openzeppelin/contracts/utils/Pausable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IFundShareToken} from "../interfaces/IFundShareToken.sol";

/// @notice The cross-chain transport this gateway sits on (LayerZero, CCIP, a bank's own relayer).
///         An adapter implements this and calls `receiveMessage` on the destination gateway.
interface IMessenger {
    function sendMessage(uint32 dstChain, bytes32 dstGateway, bytes calldata payload) external payable;
}

/// @title CrossChainGateway
/// @notice Moves fund shares between chains by burning on the source and minting on the destination,
///         without ever putting shares in a wallet that is not eligible on the destination.
///
/// Three rules make it safe for a permissioned token:
///  1. Eligibility is checked where the shares land. The destination token runs its own identity and
///     compliance checks at mint. If they fail, the shares are parked for that recipient, not minted,
///     and can be claimed once the recipient is eligible or sent back by the agent. An inbound message
///     therefore never reverts and never strands value in transit.
///  2. Amounts travel as base shares, the unit that does not change in a split, so a transfer is worth
///     the same on both sides even if one chain has not applied a split yet.
///  3. Minting is rate-limited per time window and can be paused. A compromised messenger can mint at
///     most one window's allowance before the admin stops it; anything above the limit is parked.
contract CrossChainGateway is AccessControl, Pausable, ReentrancyGuard {
    bytes32 public constant AGENT_ROLE = keccak256("AGENT_ROLE");

    IFundShareToken public immutable token;
    IMessenger public messenger;

    /// @notice The gateway trusted on each remote chain. Messages from anything else are rejected.
    mapping(uint32 => bytes32) public peers;

    uint256 public windowLength = 1 days;
    uint256 public outboundLimit; // base shares per window
    uint256 public inboundLimit; // base shares per window
    uint64 public windowStart;
    uint256 public outboundUsed;
    uint256 public inboundUsed;

    mapping(address => uint256) public parked; // base shares waiting for an eligible recipient
    uint256 public totalParked;
    mapping(uint32 => uint256) public sentTo; // base shares, lifetime, per remote chain
    mapping(uint32 => uint256) public receivedFrom;

    event Bridged(address indexed from, uint32 indexed dstChain, address indexed recipient, uint256 shares);
    event Delivered(uint32 indexed srcChain, address indexed recipient, uint256 shares);
    event Parked(uint32 indexed srcChain, address indexed recipient, uint256 shares, string reason);
    event ParkedClaimed(address indexed recipient, uint256 shares);
    event ParkedReturned(address indexed recipient, uint32 indexed dstChain, address indexed to, uint256 shares);
    event PeerSet(uint32 indexed chain, bytes32 gateway);
    event MessengerSet(address indexed messenger);
    event LimitsSet(uint256 outboundLimit, uint256 inboundLimit, uint256 windowLength);

    error ZeroAddress();
    error ZeroAmount();
    error UnknownPeer(uint32 chain);
    error OnlyMessenger();
    error UntrustedSender(uint32 srcChain, bytes32 sender);
    error OutboundLimitExceeded(uint256 available, uint256 requested);
    error NothingParked();

    constructor(
        address admin,
        IFundShareToken token_,
        IMessenger messenger_,
        uint256 outboundLimit_,
        uint256 inboundLimit_
    ) {
        if (admin == address(0) || address(messenger_) == address(0)) revert ZeroAddress();
        token = token_;
        messenger = messenger_;
        outboundLimit = outboundLimit_;
        inboundLimit = inboundLimit_;
        windowStart = uint64(block.timestamp);
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    // ------------------------------------------------------------------ outbound

    /// @notice Send `tokens` to `recipient` on `dstChain`. The caller must have approved this gateway.
    function bridge(uint32 dstChain, address recipient, uint256 tokens)
        external
        payable
        nonReentrant
        whenNotPaused
        returns (uint256 shares)
    {
        bytes32 peer = peers[dstChain];
        if (peer == bytes32(0)) revert UnknownPeer(dstChain);
        if (recipient == address(0)) revert ZeroAddress();
        shares = token.tokensToShares(tokens);
        if (shares == 0) revert ZeroAmount();

        _rollWindow();
        uint256 available = _room(outboundLimit, outboundUsed);
        if (shares > available) revert OutboundLimitExceeded(available, shares);
        outboundUsed += shares;
        sentTo[dstChain] += shares;

        // The token's own rules apply to this leg: a frozen or paused holder cannot bridge out.
        token.transferSharesFrom(msg.sender, address(this), shares);
        token.burnShares(shares);

        messenger.sendMessage{value: msg.value}(dstChain, peer, abi.encode(recipient, shares));
        emit Bridged(msg.sender, dstChain, recipient, shares);
    }

    // ------------------------------------------------------------------ inbound

    /// @notice Called by the messenger adapter with a message from `srcGateway` on `srcChain`.
    /// @dev    Never reverts for a recipient-side reason: shares that cannot be minted are parked.
    function receiveMessage(uint32 srcChain, bytes32 srcGateway, bytes calldata payload) external nonReentrant {
        if (msg.sender != address(messenger)) revert OnlyMessenger();
        if (peers[srcChain] == bytes32(0) || peers[srcChain] != srcGateway) {
            revert UntrustedSender(srcChain, srcGateway);
        }
        (address recipient, uint256 shares) = abi.decode(payload, (address, uint256));
        receivedFrom[srcChain] += shares;

        _rollWindow();
        if (paused()) {
            _park(srcChain, recipient, shares, "gateway paused");
        } else if (shares > _room(inboundLimit, inboundUsed)) {
            _park(srcChain, recipient, shares, "inbound limit reached");
        } else if (_tryMint(recipient, shares)) {
            inboundUsed += shares;
            emit Delivered(srcChain, recipient, shares);
        } else {
            _park(srcChain, recipient, shares, "recipient not eligible on this chain");
        }
    }

    /// @notice Deliver parked shares once the recipient is eligible. Anyone may call; the shares go to
    ///         the recipient. Subject to the same inbound limit as a fresh message.
    function claimParked(address recipient) external nonReentrant whenNotPaused returns (uint256 shares) {
        shares = parked[recipient];
        if (shares == 0) revert NothingParked();
        _rollWindow();
        uint256 available = _room(inboundLimit, inboundUsed);
        if (shares > available) shares = available;
        if (shares == 0) revert NothingParked();

        parked[recipient] -= shares;
        totalParked -= shares;
        inboundUsed += shares;
        token.mintShares(recipient, shares); // reverts if still not eligible, leaving the shares parked
        emit ParkedClaimed(recipient, shares);
    }

    /// @notice Send parked shares back across the bridge, for a recipient who will not become eligible here.
    function returnParked(address recipient, uint32 dstChain, address to)
        external
        payable
        nonReentrant
        onlyRole(AGENT_ROLE)
    {
        bytes32 peer = peers[dstChain];
        if (peer == bytes32(0)) revert UnknownPeer(dstChain);
        if (to == address(0)) revert ZeroAddress();
        uint256 shares = parked[recipient];
        if (shares == 0) revert NothingParked();
        parked[recipient] = 0;
        totalParked -= shares;
        sentTo[dstChain] += shares;
        messenger.sendMessage{value: msg.value}(dstChain, peer, abi.encode(to, shares));
        emit ParkedReturned(recipient, dstChain, to, shares);
    }

    // ------------------------------------------------------------------ admin

    function setPeer(uint32 chain, bytes32 gateway) external onlyRole(DEFAULT_ADMIN_ROLE) {
        peers[chain] = gateway;
        emit PeerSet(chain, gateway);
    }

    function setMessenger(IMessenger messenger_) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (address(messenger_) == address(0)) revert ZeroAddress();
        messenger = messenger_;
        emit MessengerSet(address(messenger_));
    }

    function setLimits(uint256 outboundLimit_, uint256 inboundLimit_, uint256 windowLength_)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (windowLength_ == 0) revert ZeroAmount();
        outboundLimit = outboundLimit_;
        inboundLimit = inboundLimit_;
        windowLength = windowLength_;
        emit LimitsSet(outboundLimit_, inboundLimit_, windowLength_);
    }

    function pause() external onlyRole(AGENT_ROLE) {
        _pause();
    }

    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) {
        _unpause();
    }

    // ------------------------------------------------------------------ internals

    function _tryMint(address recipient, uint256 shares) private returns (bool) {
        try token.mintShares(recipient, shares) {
            return true;
        } catch {
            return false;
        }
    }

    function _park(uint32 srcChain, address recipient, uint256 shares, string memory reason) private {
        parked[recipient] += shares;
        totalParked += shares;
        emit Parked(srcChain, recipient, shares, reason);
    }

    /// @dev Saturating, so lowering a limit below what is already used can never make an inbound
    ///      message revert.
    function _room(uint256 limit, uint256 used) private pure returns (uint256) {
        return limit > used ? limit - used : 0;
    }

    function _rollWindow() private {
        if (block.timestamp >= windowStart + windowLength) {
            windowStart = uint64(block.timestamp);
            outboundUsed = 0;
            inboundUsed = 0;
        }
    }
}
