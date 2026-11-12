// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IMessenger} from "../bridge/CrossChainGateway.sol";

interface IGatewayReceiver {
    function receiveMessage(uint32 srcChain, bytes32 srcGateway, bytes calldata payload) external;
}

/// @notice Test transport: two "chains" inside one EVM. A message is delivered in the same transaction,
///         to the gateway address named in the message, tagged with the chain id the sender registered.
contract MockMessenger is IMessenger {
    mapping(address => uint32) public chainOf;

    function register(address gateway, uint32 chain) external {
        chainOf[gateway] = chain;
    }

    function sendMessage(uint32, bytes32 dstGateway, bytes calldata payload) external payable {
        IGatewayReceiver(address(uint160(uint256(dstGateway)))).receiveMessage(
            chainOf[msg.sender], bytes32(uint256(uint160(msg.sender))), payload
        );
    }

    /// @dev Lets a test play a compromised transport: deliver an arbitrary message to a gateway.
    function forge(address dstGateway, uint32 srcChain, bytes32 srcGateway, bytes calldata payload) external {
        IGatewayReceiver(dstGateway).receiveMessage(srcChain, srcGateway, payload);
    }
}
