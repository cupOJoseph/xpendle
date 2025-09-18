// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "lib/forge-std/src/Test.sol";

import {stPendleCrossChainGateway} from "src/crosschain/StPendleCrossChainGateway.sol";
import {ISTPENDLECrossChain} from "src/interfaces/ISTPENDLECrossChain.sol";
import {Client} from "lib/chainlink-ccip/chains/evm/contracts/libraries/Client.sol";
import {
    CCIPLocalSimulator,
    IRouterClient,
    LinkToken,
    BurnMintERC677Helper
} from "@chainlink/local/src/ccip/CCIPLocalSimulator.sol";

contract StPendleCrossChainGatewayHarness is stPendleCrossChainGateway {
    constructor(uint64[] memory chainIds, address[] memory gateways, address router, address admin, address feeToken)
        stPendleCrossChainGateway(chainIds, gateways, router, admin, feeToken)
    {}

    function mintTo(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function setExtraArgs(uint64 chainId, bytes calldata extra) external {
        _extraArgsByChainId[chainId] = extra;
    }
}

contract StPendleCrossChainGatewayTest is Test {
    CCIPLocalSimulator ccipLocalSimulator;
    IRouterClient router;
    StPendleCrossChainGatewayHarness gateway;

    address admin = address(0xA11CE);
    address user = address(0xBEEF);
    address gatewaySrc = address(0xCAFE);
    address other = address(0xD00D);
    uint64 chainSrc;
    uint64 chainDst;

    function setUp() public {
        ccipLocalSimulator = new CCIPLocalSimulator();
        address _unused1;
        address _unused2;
 
               
        (uint64 _chainSelector, IRouterClient _sourceRouter,,, LinkToken link, BurnMintERC677Helper ccipBnM,) =
            ccipLocalSimulator.configuration();


        chainSrc = _chainSelector;
        router = _sourceRouter;

        uint64[] memory chains = new uint64[](1);
        address[] memory gateways = new address[](1);
        chains[0] = chainSrc;
        gateways[0] = gatewaySrc;
        gateway = new StPendleCrossChainGatewayHarness(chains, gateways, address(router), admin, address(0));
        vm.deal(address(gateway), 1 ether);
    }

    function testReceiveMintsFromAuthorizedGateway() public {
        Client.Any2EVMMessage memory msgIn;
        msgIn.sourceChainSelector = chainSrc;
        msgIn.sender = abi.encode(gatewaySrc);
        msgIn.data =
            abi.encode(ISTPENDLECrossChain.BridgeStPendleData({sender: other, receiver: user, amount: 123 ether}));

        vm.prank(address(router));
        gateway.ccipReceive(msgIn);

        assertEq(gateway.balanceOf(user), 123 ether);
    }

    function testReceiveRevertsIfUnauthorizedGateway() public {
        Client.Any2EVMMessage memory msgIn;
        msgIn.sourceChainSelector = chainSrc;
        msgIn.sender = abi.encode(other); // not authorized
        msgIn.data =
            abi.encode(ISTPENDLECrossChain.BridgeStPendleData({sender: other, receiver: user, amount: 1 ether}));

        vm.expectRevert();
        vm.prank(address(router));
        gateway.ccipReceive(msgIn);
    }

    function testBridgeBurnsAndSendsMessage() public {
        // Mint to user, then bridge
        gateway.mintTo(user, 10 ether);

        vm.prank(user);
        bytes32 mid = gateway.bridgeStPendle(chainSrc, other, 5 ether);

        // Assert burn
        assertEq(gateway.balanceOf(user), 5 ether);
        // Message is sent via Chainlink router; not introspected here.
        assertTrue(mid != bytes32(0));
    }

    function testBridgeRevertsIfInsufficientBalance() public {
        vm.prank(user);
        vm.expectRevert();
        gateway.bridgeStPendle(chainSrc, other, 1 ether);
    }
}
