//SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Client} from "lib/chainlink-ccip/chains/evm/contracts/libraries/Client.sol";
import {CCIPReceiver} from "lib/chainlink-ccip/chains/evm/contracts/applications/CCIPReceiver.sol";
import {IRouterClient} from "lib/chainlink-ccip/chains/evm/contracts/interfaces/IRouterClient.sol";

import {Ownable} from "lib/solady/src/auth/Ownable.sol";
import {SafeTransferLib} from "lib/solady/src/utils/SafeTransferLib.sol";
import {ERC20} from "lib/solady/src/tokens/ERC20.sol";
import {ISTPENDLECrossChain} from "src/interfaces/ISTPENDLECrossChain.sol";

/**
 * @title stPendleCrossChainGateway
 * @notice Receiver for cross-chain transfers of stPENDLE.
 * this contract will mint stPENDLE on the destination chain and burn tokens being sent to another chain
 */
contract stPendleCrossChainGateway is ERC20, CCIPReceiver, Ownable, ISTPENDLECrossChain {
    using SafeTransferLib for address;

    string public constant NAME = "stPENDLE";
    string public constant SYMBOL = "stPEN";

    mapping(uint64 => address) internal _authorizedGatewayByChainId;
    mapping(uint64 => bytes) internal _extraArgsByChainId;

    address public feeToken;

    constructor(uint64[] memory chainIds, address[] memory gateways, address router, address admin, address _feeToken)
        CCIPReceiver(router)
    {
        if (chainIds.length != gateways.length) {
            revert InvalidChainIdsAndReceivers();
        }
        for (uint256 i = 0; i < chainIds.length; i++) {
            _authorizedGatewayByChainId[chainIds[i]] = gateways[i];
        }
        feeToken = _feeToken;
        _initializeOwner(admin);
    }

    function setAuthorizedSenderByChainId(uint64 chainId, address sender) public onlyOwner {
        _authorizedGatewayByChainId[chainId] = sender;
    }

    function getAuthorizedSenderByChainId(uint64 chainId) public view returns (address) {
        return _authorizedGatewayByChainId[chainId];
    }

    function _ccipReceive(Client.Any2EVMMessage memory message) internal override {
        uint64 chainId = message.sourceChainSelector;
        address sender = abi.decode(message.sender, (address));

        BridgeStPendleData memory bridgeData = _decodeBridgeData(message.data);

        _requireAllowedGateway(chainId, sender);

        // mint stPendleToReceiver
        _mint(bridgeData.receiver, bridgeData.amount);
        emit CrossChainMint(chainId, sender, bridgeData.receiver, bridgeData.amount);
    }

    function bridgeStPendle(uint64 destChainId, address receiver, uint256 amount) external returns (bytes32) {
        _requireAllowedChain(destChainId, receiver);
        if (amount > balanceOf(msg.sender)) revert InsufficientBalance();

        Client.EVMTokenAmount[] memory tokenAmounts = new Client.EVMTokenAmount[](0);

        Client.EVM2AnyMessage memory message = Client.EVM2AnyMessage({
            receiver: abi.encode(_authorizedGatewayByChainId[destChainId]),
            extraArgs: _extraArgsByChainId[destChainId],
            feeToken: feeToken,
            tokenAmounts: tokenAmounts,
            data: abi.encode(BridgeStPendleData({receiver: receiver, sender: msg.sender, amount: amount}))
        });

        uint256 fee = IRouterClient(i_ccipRouter).getFee(destChainId, message);
        bytes32 messageId;

        // assert fee balance
        if (feeToken == address(0)) {
            if (address(this).balance < fee) revert InsufficientBalance();
            messageId = IRouterClient(i_ccipRouter).ccipSend{value: fee}(destChainId, message);
        } else {
            if (SafeTransferLib.balanceOf(feeToken, msg.sender) < fee) revert InsufficientBalance();
            messageId = IRouterClient(i_ccipRouter).ccipSend(destChainId, message);
        }

        emit MessageSent(messageId);
        // burn bridged tokens
        _burn(msg.sender, amount);
        return messageId;
    }

    function _decodeBridgeData(bytes memory data) internal pure returns (BridgeStPendleData memory) {
        return abi.decode(data, (BridgeStPendleData));
    }

    function _requireAllowedChain(uint64 chainId, address sender) internal view {
        if (_authorizedGatewayByChainId[chainId] == address(0)) revert InvalidDestChainId();
    }

    function _requireAllowedGateway(uint64 chainId, address sender) internal view {
        if (_authorizedGatewayByChainId[chainId] != sender) revert InvalidChainId(chainId);
    }

    function name() public pure override returns (string memory) {
        return NAME;
    }

    function symbol() public pure override returns (string memory) {
        return SYMBOL;
    }
}
