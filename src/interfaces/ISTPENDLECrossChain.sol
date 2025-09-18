//SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/**
 * @title ISTPENDLECrossChain
 * @notice Receiver for cross-chain transfers of stPENDLE.
 * this contract will mint stPENDLE on the destination chain and burn tokens being sent to another chain
 */
interface ISTPENDLECrossChain {
    struct BridgeStPendleData {
        address sender;
        address receiver;
        uint256 amount;
    }

    event MessageSent(bytes32 messageId);
    event MessageReceived(bytes32 messageId);
    event CrossChainMint(uint64 chainId, address sender, address receiver, uint256 amount);
    event FeeTokenSet(address feeToken);
    event CCIPRouterSet(address ccipRouter);

    error InvalidChainIdsAndReceivers();
    error InvalidChain(uint64 chainSelector);
    error InvalidChainId(uint64 chainId);
    error InvalidCCIPRouter();
    error InvalidCrossChainGateway();
    error InvalidDestChainId();

    function bridgeStPendle(uint64 destChainId, address receiver, uint256 amount) external returns (bytes32);
}
