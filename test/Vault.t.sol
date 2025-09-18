// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test, console} from "lib/forge-std/src/Test.sol";
import {stPENDLE} from "../src/stPENDLE.sol";
import {ERC20} from "lib/solady/src/tokens/ERC20.sol";
import {TimelockController} from "lib/openzeppelin-contracts/contracts/governance/TimelockController.sol";
import {IPVotingEscrowMainchain} from "src/interfaces/pendle/IPVotingEscrowMainchain.sol";
import {IPVeToken} from "src/interfaces/pendle/IPVeToken.sol";
import {IPVotingController} from "src/interfaces/pendle/IPVotingController.sol";
import {ISTPENDLE} from "src/interfaces/ISTPENDLE.sol";
import {IERC20} from "lib/forge-std/src/interfaces/IERC20.sol";
import {ISTPENDLECrossChain} from "src/interfaces/ISTPENDLECrossChain.sol";
import {stPendleCrossChainGateway} from "src/crosschain/StPendleCrossChainGateway.sol";

// chainlink testing
import {
    CCIPLocalSimulator,
    IRouterClient,
    LinkToken,
    BurnMintERC677Helper
} from "@chainlink/local/src/ccip/CCIPLocalSimulator.sol";
import {Client} from "@chainlink/contracts-ccip/contracts/libraries/Client.sol";

/// forge-lint: disable-start(all)
// Mock contracts for testing
contract MockVotingEscrowMainchain {
    MockPENDLE public pendle;
    MockMerkleDistributor public merkleDistributor;

    mapping(address => uint128) public balances;
    mapping(address => uint128) public lockedBalances;
    mapping(address => uint128) public unlockTimes;
    uint128 public totalSupply;

    constructor(MockPENDLE _pendle, MockMerkleDistributor _merkleDistributor) {
        pendle = _pendle;
        merkleDistributor = _merkleDistributor;
    }

    function increaseLockPosition(uint128 additionalAmountToLock, uint128 expiry) external returns (uint128) {
        require(additionalAmountToLock > 0, "Additional amount to lock must be greater than 0");
        pendle.transferFrom(msg.sender, address(this), additionalAmountToLock);
        merkleDistributor.setClaimable(msg.sender, additionalAmountToLock / 10);
        balances[msg.sender] += additionalAmountToLock;
        lockedBalances[msg.sender] += additionalAmountToLock;
        unlockTimes[msg.sender] = expiry;
        return lockedBalances[msg.sender];
    }

    function withdraw() external returns (uint128) {
        uint128 balance = lockedBalances[msg.sender];
        pendle.transfer(msg.sender, balance);
        lockedBalances[msg.sender] = 0;
        balances[msg.sender] = 0;
        return balance;
    }

    function balanceOf(address user) public view returns (uint128) {
        return balances[user];
    }

    function positionData(address user) external view returns (uint128 amount, uint128 expiry) {
        return (balanceOf(user), unlockTimes[user]);
    }

    function totalSupplyStored() external view returns (uint128) {
        return totalSupply;
    }

    function totalSupplyCurrent() external view returns (uint128) {
        return totalSupply;
    }

    function totalSupplyAndBalanceCurrent(address user) external view returns (uint128, uint128) {
        return (totalSupply, balances[user]);
    }

    function mint(address to, uint128 amount) external {
        balances[to] += amount;
        totalSupply += amount;
    }
}

contract MockMerkleDistributor {
    mapping(address => uint256) public claimableAmounts;
    MockPENDLE public pendle;

    constructor(MockPENDLE _mockErc20) {
        pendle = _mockErc20;
        pendle.mint(address(this), 1000e18);
    }

    function setClaimable(address account, uint256 amount) external {
        claimableAmounts[account] = amount;
    }

    function claimable(address account) external view returns (uint256) {
        return claimableAmounts[account];
    }

    function claim(address account, uint256, /* amount */ bytes32[] calldata /* merkleProof */ )
        external
        returns (uint256)
    {
        uint256 claimableAmount = claimableAmounts[account];
        claimableAmounts[account] = 0;
        pendle.mint(account, claimableAmount);
        return claimableAmount;
    }
}

contract MockVotingController {
    function vote(uint256 poll, uint256 voteAmount) external {
        // Mock implementation
    }
}

contract MockUSDT is ERC20 {
    constructor() {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function name() public pure override returns (string memory) {
        return "USDTether";
    }

    function symbol() public pure override returns (string memory) {
        return "USDT";
    }
}

contract MockPENDLE is ERC20 {
    constructor() {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }

    function name() public pure override returns (string memory) {
        return "PENDLE";
    }

    function symbol() public pure override returns (string memory) {
        return "PEN";
    }
}

contract stPENDLETest is Test {
    stPENDLE public vault;
    MockVotingEscrowMainchain public votingEscrowMainchain;
    MockMerkleDistributor public merkleDistributor;
    MockVotingController public votingController;
    MockUSDT public usdt;
    MockPENDLE public pendle;
    TimelockController public timelockController;
    ISTPENDLECrossChain public crossChainGateway;

    // ccip
    CCIPLocalSimulator public ccipLocalSimulator;
    LinkToken linkToken;
    uint64 destinationChainSelector;
    IRouterClient router;

    address public alice = address(0x1);
    address public bob = address(0x2);
    address public charlie = address(0x3);
    address public david = address(0x4);
    address public eve = address(0x5);
    address public feeReceiver = address(0x6);
    address public lpFeeReceiver = address(0x7);

    uint256 public constant INITIAL_BALANCE = 1000e18;
    uint256 public constant DEPOSIT_AMOUNT = 100e18;

    event FeeSwitchSet(bool enabled);
    event UseUSDTForFeesSet(bool useUSDT);
    event WithdrawalRequested(address indexed user, uint256 amount, uint256 requestTime);
    event WithdrawalProcessed(address indexed user, uint256 amount);

    function setUp() public {
        // warp state ahead so first epoch == 1
        vm.warp(block.timestamp + 31 days);
        usdt = new MockUSDT();
        pendle = new MockPENDLE();

        ccipLocalSimulator = new CCIPLocalSimulator();

        (uint64 chainSelector, IRouterClient sourceRouter,,, LinkToken link, BurnMintERC677Helper ccipBnM,) =
            ccipLocalSimulator.configuration();

        router = sourceRouter;
        destinationChainSelector = chainSelector;
        linkToken = link;

        // Deploy mock contracts
        merkleDistributor = new MockMerkleDistributor(pendle);
        votingController = new MockVotingController();
        votingEscrowMainchain = new MockVotingEscrowMainchain(pendle, merkleDistributor);
        address[] memory proposers = new address[](1);
        address[] memory executors = new address[](1);
        proposers[0] = address(this);
        executors[0] = address(this);
        timelockController = new TimelockController(1 hours, proposers, executors, address(this));
        ISTPENDLE.VaultConfig memory config = ISTPENDLE.VaultConfig({
            pendleTokenAddress: address(pendle),
            merkleDistributorAddress: address(merkleDistributor),
            votingEscrowMainchain: address(votingEscrowMainchain),
            votingControllerAddress: address(votingController),
            timelockController: address(timelockController),
            admin: address(this),
            lpFeeReceiver: lpFeeReceiver,
            feeReceiver: feeReceiver,
            preLockRedemptionPeriod: 20 days,
            epochDuration: 30 days,
            ccipRouter: address(router),
            feeToken: address(0)
        });

        // Deploy vault
        vault = new stPENDLE(config);
        // deploy cross chain gateway
        uint64[] memory chainIds = new uint64[](1);
        address[] memory gateways = new address[](1);
        chainIds[0] = destinationChainSelector;
        gateways[0] = address(ccipLocalSimulator);
        crossChainGateway =
            new stPendleCrossChainGateway(chainIds, gateways, address(router), address(this), address(0));

        vm.deal(address(vault), 1000e18);
        vm.deal(address(crossChainGateway), 1000e18);

        // Setup initial balances
        pendle.mint(address(this), INITIAL_BALANCE);
        pendle.mint(alice, INITIAL_BALANCE);
        pendle.mint(bob, INITIAL_BALANCE);
        pendle.mint(charlie, INITIAL_BALANCE);
        pendle.mint(david, INITIAL_BALANCE);
        pendle.mint(eve, INITIAL_BALANCE);

        // Setup fee receiver
        vault.setFeeReceiver(feeReceiver);

        // Label addresses for better test output
        vm.label(address(vault), "Vault");
        vm.label(address(merkleDistributor), "MerkleDistributor");
        vm.label(address(usdt), "USDT");
        vm.label(address(pendle), "PENDLE");
        vm.label(address(votingEscrowMainchain), "VotingEscrowMainchain");
        vm.label(address(votingController), "VotingController");
        vm.label(address(timelockController), "TimelockController");
        vm.label(alice, "Alice");
        vm.label(bob, "Bob");
        vm.label(charlie, "Charlie");
        vm.label(david, "David");
        vm.label(eve, "Eve");
        vm.label(feeReceiver, "FeeReceiver");
    }

    function startFirstEpoch() public {
        // deposit initial pendleBalance
        pendle.approve(address(vault), DEPOSIT_AMOUNT);
        vault.depositBeforeFirstEpoch(DEPOSIT_AMOUNT, feeReceiver);

        vm.startPrank(address(this));
        vault.startFirstEpoch();
        vm.stopPrank();
    }

    function test_startFirstEpoch() public {
        startFirstEpoch();
        assertEq(vault.currentEpoch(), 1, "epoch should be 1");
        assertEq(vault.currentEpochStart(), block.timestamp, "epoch start should be current timestamp");
        assertEq(vault.epochDuration(), 30 days, "epoch duration should be 30 days");
        assertEq(vault.totalLockedPendle(), DEPOSIT_AMOUNT, "total locked pendle should be initial deposit");
        assertEq(vault.totalSupply(), DEPOSIT_AMOUNT, "total supply should be initial deposit");
        assertEq(vault.totalSupply(), DEPOSIT_AMOUNT, "vault should have initial deposit");
    }

    function test_startFirstEpoch_RevertsIfCalledAfterFirstEpoch() public {
        startFirstEpoch();
        vm.expectRevert(ISTPENDLE.InvalidEpoch.selector);
        vault.startFirstEpoch();
    }

    function test_startFirstEpoch_RevertInvalidPendleBalance() public {
        pendle.mint(address(this), 0);
        vm.expectRevert(ISTPENDLE.InvalidPendleBalance.selector);
        vault.startFirstEpoch();
    }

    function test_Constructor() public view {
        assertEq(address(vault.votingEscrowMainchain()), address(votingEscrowMainchain));
        assertEq(address(vault.merkleDistributor()), address(merkleDistributor));
        assertEq(address(vault.votingController()), address(votingController));
    }

    function test_Deposit() public {
        vm.startPrank(alice);

        pendle.approve(address(vault), DEPOSIT_AMOUNT);
        uint256 shares = vault.deposit(DEPOSIT_AMOUNT, alice);

        assertGt(shares, 0, "Should receive shares");
        assertEq(vault.balanceOf(alice), shares, "User should have correct share balance");
        assertEq(votingEscrowMainchain.balanceOf(address(vault)), DEPOSIT_AMOUNT, "Vault should have locked PENDLE");

        vm.stopPrank();
    }

    function test_ClaimFeesInPENDLE() public {
        startFirstEpoch();
        // Setup claimable fees
        merkleDistributor.setClaimable(address(vault), 100e18);

        // Claim fees
        uint256 aumBefore = vault.totalAssets();
        uint256 veBefore = votingEscrowMainchain.balanceOf(address(vault));
        uint256 lpBefore = pendle.balanceOf(lpFeeReceiver);
        uint256 protocolBefore = pendle.balanceOf(feeReceiver);

        vault.claimFees(100e18, new bytes32[](0));

        uint256 lpDelta = pendle.balanceOf(lpFeeReceiver) - lpBefore;
        uint256 protocolDelta = pendle.balanceOf(feeReceiver) - protocolBefore;
        uint256 aumDelta = vault.totalAssets() - aumBefore;
        assertEq(aumDelta, 90e18, "holders portion should be 90%");
        assertEq(lpDelta, 10e18, "lp portion should be 10%");
        assertEq(protocolDelta, 0, "protocol portion should be 0");
        // Accounting: claimed = aumDelta + transfers out
        assertEq(aumDelta + lpDelta + protocolDelta, 100e18, "fees must split between AUM and transfers");
        // Holders portion should be locked immediately while in window
        assertEq(
            votingEscrowMainchain.balanceOf(address(vault)) - veBefore, aumDelta, "holders portion should be locked"
        );
        // No residual unlocked PENDLE after immediate lock and transfers
        assertEq(pendle.balanceOf(address(vault)), 0, "no unlocked PENDLE after claim within window");
    }

    function test_claimFeesWithPendingRedemptions() public {
        startFirstEpoch();
        // Alice and Bob deposit
        vm.startPrank(alice);
        pendle.approve(address(vault), DEPOSIT_AMOUNT);
        uint256 aliceShares = vault.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();
        vm.startPrank(bob);
        pendle.approve(address(vault), DEPOSIT_AMOUNT);
        uint256 bobShares = vault.deposit(DEPOSIT_AMOUNT, bob);
        vm.stopPrank();

        assertEq(
            pendle.balanceOf(alice), INITIAL_BALANCE - DEPOSIT_AMOUNT, "Alice should have correct balance in pendle"
        );
        assertEq(vault.balanceOf(alice), DEPOSIT_AMOUNT, "Alice should have correct balance in vault");
        assertEq(pendle.balanceOf(bob), INITIAL_BALANCE - DEPOSIT_AMOUNT, "Bob should have correct balance in pendle");
        assertEq(vault.balanceOf(bob), DEPOSIT_AMOUNT, "Bob should have correct balance in vault");
        assertEq(
            votingEscrowMainchain.balanceOf(address(vault)),
            DEPOSIT_AMOUNT * 3,
            "Vault should have correct balance in vependle"
        );
        // Alice and Bob request redemption
        vm.startPrank(alice);
        vault.requestRedemptionForEpoch(aliceShares / 2, 0);
        vm.stopPrank();
        vm.startPrank(bob);
        vault.requestRedemptionForEpoch(bobShares / 2, 0);
        vm.stopPrank();
        // warp to epoch boundary
        vm.warp(vault.currentEpochStart() + vault.epochDuration());
        // start new epoch
        vm.prank(address(this));
        vault.startNewEpoch();
        assertEq(vault.currentEpoch(), 2, "Should have advanced to next epoch");
        uint256 expectedReservedAssets = vault.previewRedeem(aliceShares / 2) + vault.previewRedeem(bobShares / 2);
        assertEq(vault.getAvailableRedemptionAmount(), expectedReservedAssets, "reserved assets must match preview");
        assertEq(
            vault.getUserAvailableRedemption(alice),
            aliceShares / 2,
            "Alice should have correct available redemption amount"
        );
        assertEq(
            vault.getUserAvailableRedemption(bob), bobShares / 2, "Bob should have correct available redemption amount"
        );
        assertEq(pendle.balanceOf(address(vault)), expectedReservedAssets, "vault unlocked equals reserved");
        // Locked equals ve balance; value verification handled by reserved assets assertion above
        assertEq(
            vault.totalLockedPendle(),
            votingEscrowMainchain.balanceOf(address(vault)),
            "Vault locked pendle should equal vependle balance"
        );

        // claim fees
        merkleDistributor.setClaimable(address(vault), 100e18);
        vault.claimFees(100e18, new bytes32[](0));
        assertEq(pendle.balanceOf(address(vault)), expectedReservedAssets, "vault unlocked equals reserved");
        // After fees, holders portion locks; ve balance checked via parity below
        assertEq(
            vault.totalLockedPendle(),
            votingEscrowMainchain.balanceOf(address(vault)),
            "Vault locked pendle should equal vependle balance"
        );
        // share value should have gone up
        assertGt(vault.previewRedeemWithCurrentValues(aliceShares), aliceShares, "Share value should have gone up");
        // snapshot value should be the same
        assertEq(vault.previewRedeem(aliceShares), aliceShares, "Snapshot value should be the same");
    }

    function test_StartNewEpoch() public {
        // Setup: start first epoch (locks initial deposit and sets epoch timing)
        startFirstEpoch();

        uint256 start = vault.currentEpochStart();
        uint128 dur = vault.epochDuration();

        // Too early: should revert
        vm.expectRevert(ISTPENDLE.EpochNotEnded.selector);
        vault.startNewEpoch();

        // Just before boundary: still revert
        vm.warp(start + dur - 1);
        vm.expectRevert(ISTPENDLE.EpochNotEnded.selector);
        vault.startNewEpoch();

        // At boundary or later: should succeed
        vm.warp(start + dur);
        vault.startNewEpoch();
        assertEq(vault.currentEpoch(), 2, "epoch should advance at or after boundary");
    }

    function test_redeembeforeNewEpoch() public {
        startFirstEpoch();
        // Alice and Bob deposit
        vm.startPrank(alice);
        pendle.approve(address(vault), DEPOSIT_AMOUNT);
        uint256 aliceShares = vault.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();
        vm.startPrank(bob);
        pendle.approve(address(vault), DEPOSIT_AMOUNT);
        uint256 bobShares = vault.deposit(DEPOSIT_AMOUNT, bob);
        vm.stopPrank();
        assertEq(
            pendle.balanceOf(alice), INITIAL_BALANCE - DEPOSIT_AMOUNT, "Alice should have correct balance in pendle"
        );
        assertEq(vault.balanceOf(alice), DEPOSIT_AMOUNT, "Alice should have correct balance in vault");
        assertEq(pendle.balanceOf(bob), INITIAL_BALANCE - bobShares, "Bob should have correct balance in pendle");
        assertEq(vault.balanceOf(bob), bobShares, "Bob should have correct balance in vault");
        assertEq(
            votingEscrowMainchain.balanceOf(address(vault)),
            DEPOSIT_AMOUNT * 3,
            "Vault should have correct balance in vependle"
        );
        // request redemptions for next epoch
        vm.startPrank(alice);
        vault.requestRedemptionForEpoch(aliceShares / 2, 0);
        vm.stopPrank();
        vm.startPrank(bob);
        vault.requestRedemptionForEpoch(bobShares / 2, 0);
        vm.stopPrank();
        // warp to epoch boundary
        vm.warp(vault.currentEpochStart() + vault.epochDuration());
        // attempt to redeem before new epoch is started
        vm.prank(alice);
        vm.expectRevert(ISTPENDLE.OutsideRedemptionWindow.selector);
        vault.claimAvailableRedemptionShares(aliceShares / 2);
        assertEq(vault.getUserAvailableRedemption(alice), 0, "Alice shouldn't have current-epoch availability yet");
        // start new epoch
        vm.prank(address(this));
        vault.startNewEpoch();
        assertEq(vault.currentEpoch(), 2, "Should have advanced to next epoch");
        assertEq(
            vault.getAvailableRedemptionAmount(),
            aliceShares / 2 + bobShares / 2,
            "Should have correct available redemption amount"
        );
        assertEq(
            vault.getUserAvailableRedemption(alice),
            aliceShares / 2,
            "Alice should have correct available redemption amount"
        );
        assertEq(
            vault.getUserAvailableRedemption(bob), bobShares / 2, "Bob should have correct available redemption amount"
        );
        // redeem alice
        uint256 alicePendleBefore = pendle.balanceOf(alice);
        vm.prank(alice);
        uint256 aliceRedeemed = vault.claimAvailableRedemptionShares(aliceShares / 2);
        assertEq(vault.getUserAvailableRedemption(alice), 0, "Alice shouldn't have current-epoch availability anymore");
        assertEq(pendle.balanceOf(alice) - alicePendleBefore, aliceRedeemed, "Alice PENDLE delta mismatch");
        assertEq(vault.balanceOf(alice), aliceShares / 2, "Alice should have correct balance in vault");
        assertEq(
            votingEscrowMainchain.balanceOf(address(vault)),
            DEPOSIT_AMOUNT * 3 - (aliceShares / 2 + bobShares / 2),
            "Vault should have correct balance in vependle"
        );
        // redeem bob
        uint256 bobPendleBefore = pendle.balanceOf(bob);
        vm.prank(bob);
        uint256 bobRedeemed = vault.claimAvailableRedemptionShares(bobShares / 2);
        assertEq(vault.getUserAvailableRedemption(bob), 0, "Bob shouldn't have current-epoch availability anymore");
        assertEq(pendle.balanceOf(bob) - bobPendleBefore, bobRedeemed, "Bob PENDLE delta mismatch");
        assertEq(vault.balanceOf(bob), (bobShares / 2), "Bob should have correct balance in vault");
        assertEq(
            votingEscrowMainchain.balanceOf(address(vault)),
            DEPOSIT_AMOUNT * 3 - (aliceShares / 2) - (bobShares / 2),
            "Vault should have correct balance in vependle"
        );
        assertEq(pendle.balanceOf(address(vault)), 0, "Vault should have no balance in pendle");
    }

    function test_WithdrawalQueue() public {
        startFirstEpoch();
        // Alice and Bob deposit
        vm.startPrank(alice);
        pendle.approve(address(vault), DEPOSIT_AMOUNT);
        uint256 aliceShares = vault.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();
        assertEq(
            pendle.balanceOf(alice), INITIAL_BALANCE - DEPOSIT_AMOUNT, "Alice should have correct balance in pendle"
        );
        assertEq(vault.balanceOf(alice), DEPOSIT_AMOUNT, "Alice should have correct balance in vault");
        vm.startPrank(bob);
        pendle.approve(address(vault), DEPOSIT_AMOUNT);
        uint256 bobShares = vault.deposit(DEPOSIT_AMOUNT, bob);
        vm.stopPrank();
        assertEq(pendle.balanceOf(bob), INITIAL_BALANCE - bobShares, "Bob should have correct balance in pendle");
        assertEq(vault.balanceOf(bob), bobShares, "Bob should have correct balance in vault");
        assertEq(
            votingEscrowMainchain.balanceOf(address(vault)),
            DEPOSIT_AMOUNT * 3,
            "Vault should have correct balance in vependle"
        );

        // Initially, all deposited PENDLE is locked; available for redemption should be 0
        assertEq(vault.getAvailableRedemptionAmount(), 0, "No unlocked assets initially");

        // Queue redemptions for the next epoch (epoch=0 aliases to currentEpoch+1)
        uint256 aliceRequestShares = aliceShares / 2; // partial
        uint256 bobRequestShares = bobShares; // full

        // Determine the epoch where requests were queued: currentEpoch + 1 (post _updateEpoch inside calls)
        uint256 requestEpoch = vault.currentEpoch() + 1;

        vm.prank(alice);
        vault.requestRedemptionForEpoch(aliceRequestShares, requestEpoch);

        vm.prank(bob);
        vault.requestRedemptionForEpoch(bobRequestShares, requestEpoch);

        // Per-epoch totals should reflect both users' queued shares
        uint256 totalQueued = vault.totalRequestedRedemptionAmountPerEpoch(requestEpoch);
        assertEq(totalQueued, aliceRequestShares + bobRequestShares, "Queued shares per epoch mismatch");

        // Before the epoch advances, current-epoch availability for users should be 0
        assertEq(vault.getUserAvailableRedemption(alice), 0, "Alice shouldn't have current-epoch availability yet");
        assertEq(vault.getUserAvailableRedemption(bob), 0, "Bob shouldn't have current-epoch availability yet");

        // Claiming during the wrong epoch should revert
        vm.prank(alice);
        vm.expectRevert(ISTPENDLE.NoPendingRedemption.selector);
        vault.claimAvailableRedemptionShares(aliceRequestShares);

        // warp to epoch boundary
        vm.warp(vault.currentEpochStart() + vault.epochDuration());

        assertEq(vault.currentEpoch(), 2, "Should have advanced to next epoch");
        // start new epoch
        vm.prank(address(this));
        vault.startNewEpoch();
        assertEq(
            vault.getAvailableRedemptionAmount(),
            aliceRequestShares + bobRequestShares,
            "Should have correct available redemption amount"
        );
        assertEq(
            pendle.balanceOf(address(vault)),
            aliceRequestShares + bobRequestShares,
            "Vault should have correct balance in pendle"
        );
        // assert available redemption
        assertEq(
            vault.getUserAvailableRedemption(alice), aliceRequestShares, "Alice should have current-epoch availability"
        );
        assertEq(vault.getUserAvailableRedemption(bob), DEPOSIT_AMOUNT, "Bob should have current-epoch availability");

        uint256 alicePendleBefore2 = pendle.balanceOf(alice);
        vm.prank(alice);
        uint256 aliceClaimed = vault.claimAvailableRedemptionShares(aliceRequestShares / 2);
        assertEq(aliceClaimed, aliceRequestShares / 2, "Alice should have claimed half their shares");
        assertEq(
            vault.getUserAvailableRedemption(alice),
            aliceRequestShares / 2,
            "Alice should have current-epoch availability anymore"
        );
        assertEq(pendle.balanceOf(alice) - alicePendleBefore2, aliceClaimed, "Alice PENDLE delta mismatch");

        uint256 bobPendleBefore2 = pendle.balanceOf(bob);
        vm.prank(bob);
        uint256 bobClaimed = vault.claimAvailableRedemptionShares(bobRequestShares / 2);
        assertEq(bobClaimed, bobRequestShares / 2, "Bob should have claimed their shares");
        assertEq(
            vault.getUserAvailableRedemption(bob),
            bobRequestShares / 2,
            "Bob shouldn't have current-epoch availability anymore"
        );
        assertEq(pendle.balanceOf(bob) - bobPendleBefore2, bobClaimed, "Bob PENDLE delta mismatch");

        // warp past redemption window
        vm.warp(block.timestamp + 29 days);
        assertEq(vault.getUserAvailableRedemption(alice), 0, "Alice shouldn't have current-epoch availability anymore");
        assertEq(vault.getUserAvailableRedemption(bob), 0, "Bob shouldn't have current-epoch availability anymore");
        // No changes after window closes
        // (balances asserted via deltas earlier)
    }

    function test_GetNextEpochWithdrawalAmount() public {
        startFirstEpoch();
        // Alice and Bob deposit
        vm.startPrank(alice);
        pendle.approve(address(vault), DEPOSIT_AMOUNT);
        uint256 aliceShares = vault.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();

        vm.startPrank(bob);
        pendle.approve(address(vault), DEPOSIT_AMOUNT);
        uint256 bobShares = vault.deposit(DEPOSIT_AMOUNT, bob);
        vm.stopPrank();

        // Request redemptions for next epoch
        uint256 requestEpoch = vault.currentEpoch() + 1;
        vm.prank(alice);
        vault.requestRedemptionForEpoch(aliceShares / 3, requestEpoch);
        vm.prank(bob);
        vault.requestRedemptionForEpoch(bobShares / 2, requestEpoch);

        // Advance to next epoch and start
        vm.warp(vault.currentEpochStart() + vault.epochDuration());
        vm.prank(address(this));
        vault.startNewEpoch();

        // Expected reserved equals sum of requested shares (under current tests 1:1 to assets at snapshot)
        uint256 expectedReserved = (aliceShares / 3) + (bobShares / 2);
        assertEq(vault.getAvailableRedemptionAmount(), expectedReserved, "reserved assets should equal requests");
        assertEq(pendle.balanceOf(address(vault)), expectedReserved, "vault unlocked equals reserved");
    }

    function test_CanProcessWithdrawal() public {
        startFirstEpoch();
        // Alice deposits and requests for next epoch
        vm.startPrank(alice);
        pendle.approve(address(vault), DEPOSIT_AMOUNT);
        uint256 aliceShares = vault.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();

        uint256 requestEpoch = vault.currentEpoch() + 1;
        vm.prank(alice);
        vault.requestRedemptionForEpoch(aliceShares / 4, requestEpoch);

        // Before next epoch: cannot claim
        vm.prank(alice);
        vm.expectRevert(ISTPENDLE.NoPendingRedemption.selector);
        vault.claimAvailableRedemptionShares(aliceShares / 4);

        // Advance and start next epoch: can claim
        vm.warp(vault.currentEpochStart() + vault.epochDuration());
        vm.prank(address(this));
        vault.startNewEpoch();

        uint256 pendleBefore = pendle.balanceOf(alice);
        vm.prank(alice);
        uint256 claimed = vault.claimAvailableRedemptionShares(aliceShares / 4);
        assertEq(pendle.balanceOf(alice) - pendleBefore, claimed, "claim should transfer assets");
        assertEq(vault.getUserAvailableRedemption(alice), 0, "no more availability for alice");
    }

    function test_RequestRedemption_Reverts() public {
        startFirstEpoch();
        vm.startPrank(alice);
        pendle.approve(address(vault), DEPOSIT_AMOUNT);
        uint256 shares = vault.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();

        // Zero shares
        vm.prank(alice);
        vm.expectRevert(ISTPENDLE.InvalidAmount.selector);
        vault.requestRedemptionForEpoch(0, 0);

        // Insufficient balance
        vm.prank(bob);
        vm.expectRevert(ERC20.InsufficientBalance.selector);
        vault.requestRedemptionForEpoch(20000e18, 0);

        // Epoch too early
        uint256 cur = vault.currentEpoch();
        vm.prank(alice);
        vm.expectRevert(ISTPENDLE.InvalidEpoch.selector);
        vault.requestRedemptionForEpoch(shares / 2, cur); // must be >= cur+1
    }

    function test_Pause_Unpause_Deposit() public {
        vm.prank(address(this));
        vault.pause();

        vm.startPrank(alice);
        pendle.approve(address(vault), DEPOSIT_AMOUNT);
        vm.expectRevert(ISTPENDLE.IsPaused.selector);
        vault.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();

        vm.prank(address(this));
        vault.unpause();

        vm.startPrank(alice);
        pendle.approve(address(vault), DEPOSIT_AMOUNT);
        uint256 minted = vault.deposit(DEPOSIT_AMOUNT, alice);
        assertEq(minted, DEPOSIT_AMOUNT, "1:1 initial deposit");
        vm.stopPrank();
    }

    function test_Disabled_ERC4626_Methods_Revert() public {
        vm.expectRevert(ISTPENDLE.InvalidERC4626Function.selector);
        vault.redeem(1, address(this), address(this));

        vm.expectRevert(ISTPENDLE.InvalidERC4626Function.selector);
        vault.withdraw(1, address(this), address(this));

        vm.expectRevert(ISTPENDLE.InvalidERC4626Function.selector);
        vault.mint(1, address(this));
    }

    function test_setRewardsSplit_ProtocolShare() public {
        startFirstEpoch();
        // Set LP receiver
        vault.setLpFeeReceiver(lpFeeReceiver);
        // Set 80% holders, 10% LP (remainder 10% protocol)
        vm.prank(address(timelockController));
        vault.setRewardsSplit(0.8e18, 0.1e18);

        merkleDistributor.setClaimable(address(vault), 100e18);
        uint256 lpBefore = pendle.balanceOf(lpFeeReceiver);
        uint256 protocolBefore = pendle.balanceOf(feeReceiver);
        uint256 aumBefore = vault.totalAssets();
        vault.claimFees(100e18, new bytes32[](0));
        assertEq(pendle.balanceOf(lpFeeReceiver) - lpBefore, 10e18, "LP 10%");
        assertEq(pendle.balanceOf(feeReceiver) - protocolBefore, 10e18, "Protocol 10%");
        assertEq(vault.totalAssets() - aumBefore, 80e18, "Holders 80%");
    }

    function test_ReserveClamp_OnStartNewEpoch() public {
        startFirstEpoch();
        // Alice deposit
        vm.startPrank(alice);
        pendle.approve(address(vault), DEPOSIT_AMOUNT);
        uint256 aliceShares = vault.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();

        // Request large pending redemptions (greater than unlocked next epoch target)
        vm.prank(alice);
        vault.requestRedemptionForEpoch(aliceShares, 0);

        // Advance time and roll epoch
        vm.warp(vault.currentEpochStart() + vault.epochDuration());
        vm.prank(address(this));
        vault.startNewEpoch();

        // All unlocked should be reserved and pendle balance equals reserved (clamped)
        assertEq(
            pendle.balanceOf(address(vault)),
            vault.getAvailableRedemptionAmount(),
            "Reserved equals unlocked after clamp"
        );
        // Locked equals total locked in ve
        assertEq(vault.totalLockedPendle(), votingEscrowMainchain.balanceOf(address(vault)), "Locked parity");
    }

    function test_PreviewRedeem_SnapshotStableWithinEpoch() public {
        startFirstEpoch();
        // Alice deposit and request next epoch
        vm.startPrank(alice);
        pendle.approve(address(vault), DEPOSIT_AMOUNT);
        uint256 aliceShares = vault.deposit(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();
        vm.prank(alice);
        vault.requestRedemptionForEpoch(aliceShares / 2, 0);

        // check that preview redeem is 0
        assertEq(vault.previewRedeem(aliceShares / 2), 0, "preview redeem should be 0");

        // Roll epoch to set snapshot
        vm.warp(vault.currentEpochStart() + vault.epochDuration());
        // before epoch is updated, preview redeem should be 0
        assertEq(vault.previewRedeem(aliceShares / 2), 0, "preview redeem should be 0");

        vm.prank(address(this));
        vault.startNewEpoch();

        uint256 snapRedeem = vault.previewRedeem(aliceShares / 2);

        // Mid-epoch: deposit by Bob and claim fees; snapshot redeem should not change
        vm.startPrank(bob);
        pendle.approve(address(vault), DEPOSIT_AMOUNT);
        vault.deposit(DEPOSIT_AMOUNT, bob);
        vm.stopPrank();
        merkleDistributor.setClaimable(address(vault), 50e18);
        vault.claimFees(50e18, new bytes32[](0));

        assertEq(vault.previewRedeem(aliceShares / 2), snapRedeem, "snapshot redeem must be stable within epoch");
        // Current-value preview (AUM-based) should be >= snapshot
        assertGe(vault.previewRedeemWithCurrentValues(aliceShares / 2), snapRedeem, "current PPS should not decrease");
    }

    function test_RoundingDust() public {
        // Goal: snapshot AUM = 100e18, totalSupply = 3e18, pending = 2e18 shares
        // Each 1e18 share should redeem floor(100e18 / 3) = 33e18, total 66e18, leaving dust locked.

        // Step 1: initial small supply of shares
        // Deposit 3e18 before first epoch
        pendle.mint(alice, 3e18);
        vm.startPrank(alice);
        pendle.approve(address(vault), 3e18);
        vault.depositBeforeFirstEpoch(3e18, alice);
        vm.stopPrank();

        // Start first epoch
        vault.startFirstEpoch();

        // Step 2: raise AUM to 100e18 via fees (holders 100%)
        // Ensure splits 100/0/0
        vm.prank(address(timelockController));
        vault.setRewardsSplit(1e18, 0);
        // Claim fees of 97e18
        merkleDistributor.setClaimable(address(vault), 97e18);
        vault.claimFees(97e18, new bytes32[](0));

        // Transfer 1e18 share to Bob so both have 1e18 to request
        vm.prank(alice);
        vault.transfer(bob, 1e18);

        // Step 3: queue 1e18 share each for next epoch
        uint256 requestEpoch = vault.currentEpoch() + 1;
        vm.prank(alice);
        vault.requestRedemptionForEpoch(1e18, requestEpoch);
        vm.prank(bob);
        vault.requestRedemptionForEpoch(1e18, requestEpoch);

        // Step 4: roll epoch to take snapshot (AUM ~= 100e18, supply 3e18)
        vm.warp(vault.currentEpochStart() + vault.epochDuration());
        vm.prank(address(this));
        vault.startNewEpoch();

        // Snapshot preview for 1e18 share
        uint256 expectedPerShare = 33333333333333333322; // fullMulDiv(1e18, 100e18, 3e18)
        assertEq(vault.previewRedeem(1e18), expectedPerShare, "snapshot per-share redemption should floor");

        // Alice claims
        uint256 aPendleBefore = pendle.balanceOf(alice);
        vm.prank(alice);
        uint256 aClaimed = vault.claimAvailableRedemptionShares(1e18);
        assertEq(aClaimed, expectedPerShare, "claimed shares should match requested shares");
        assertEq(pendle.balanceOf(alice) - aPendleBefore, expectedPerShare, "Alice claim assets match floor rate");

        // Bob claims
        uint256 bPendleBefore = pendle.balanceOf(bob);
        vm.prank(bob);
        uint256 bClaimed = vault.claimAvailableRedemptionShares(1e18);
        assertEq(bClaimed, expectedPerShare, "claimed shares should match requested shares");
        assertEq(pendle.balanceOf(bob) - bPendleBefore, expectedPerShare, "Bob claim assets match floor rate");

        // Reserved should be consumed exactly (no unlocked left)
        assertLt(pendle.balanceOf(address(vault)), 2, "dust tolerance");
    }

    function test_RevertInvalidrewardsSplit() public {
        vm.expectRevert(ISTPENDLE.InvalidrewardsSplit.selector);
        vm.prank(address(timelockController));
        vault.setRewardsSplit(2e18, 0); // 10.01%
    }

    function test_RevertInvalidEpochDuration() public {
        vm.expectRevert(ISTPENDLE.EpochDurationInvalid.selector);
        vm.prank(address(timelockController));
        vault.setEpochDuration(30 minutes); // Less than 1 hour

        vm.expectRevert(ISTPENDLE.EpochDurationInvalid.selector);
        vm.prank(address(timelockController));
        vault.setEpochDuration(900 days); // More than maximum allowed
    }

    function test_RevertInvalidFeeReceiver() public {
        vm.expectRevert(ISTPENDLE.InvalidFeeReceiver.selector);
        vault.setFeeReceiver(address(0));
    }

    function test_DepositBeforeFirstEpoch_CannotClaimOrWithdraw() public {
        // Alice deposits before first epoch
        vm.startPrank(alice);
        pendle.approve(address(vault), DEPOSIT_AMOUNT);
        uint256 minted = vault.depositBeforeFirstEpoch(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();

        assertEq(minted, DEPOSIT_AMOUNT, "1:1 before first epoch");
        assertEq(vault.balanceOf(alice), DEPOSIT_AMOUNT, "shares minted to alice");

        // Withdraw/redeem paths are disabled
        vm.expectRevert(ISTPENDLE.InvalidERC4626Function.selector);
        vault.redeem(1, address(alice), address(alice));
        vm.expectRevert(ISTPENDLE.InvalidERC4626Function.selector);
        vault.withdraw(1, address(alice), address(alice));

        // Claiming before epoch start must revert due to window
        vm.prank(alice);
        vm.expectRevert(ISTPENDLE.OutsideRedemptionWindow.selector);
        vault.claimAvailableRedemptionShares(DEPOSIT_AMOUNT);

        // No availability before epoch roll
        assertEq(vault.getUserAvailableRedemption(alice), 0, "no availability before first epoch");
    }

    function test_StartFirstEpoch_LocksAndNoImmediateClaim() public {
        // Deposit before first epoch
        vm.startPrank(alice);
        pendle.approve(address(vault), DEPOSIT_AMOUNT);
        vault.depositBeforeFirstEpoch(DEPOSIT_AMOUNT, alice);
        vm.stopPrank();

        // Start first epoch and lock
        vault.startFirstEpoch();
        assertEq(vault.totalLockedPendle(), DEPOSIT_AMOUNT, "locked equals deposit");
        assertEq(votingEscrowMainchain.balanceOf(address(vault)), DEPOSIT_AMOUNT, "ve balance equals locked");

        // Cannot claim without pending request
        vm.prank(alice);
        vm.expectRevert(ISTPENDLE.NoPendingRedemption.selector);
        vault.claimAvailableRedemptionShares(DEPOSIT_AMOUNT);
        assertEq(vault.getUserAvailableRedemption(alice), 0, "no availability without request");

        // Request for next epoch and roll, then claim works
        vm.prank(alice);
        vault.requestRedemptionForEpoch(DEPOSIT_AMOUNT, 0); // next epoch
        vm.warp(vault.currentEpochStart() + vault.epochDuration());
        vm.prank(address(this));
        vault.startNewEpoch();

        uint256 pendleBefore = pendle.balanceOf(alice);
        vm.prank(alice);
        uint256 claimed = vault.claimAvailableRedemptionShares(DEPOSIT_AMOUNT);
        assertEq(claimed, DEPOSIT_AMOUNT, "should redeem full deposit at snapshot rate");
        assertEq(pendle.balanceOf(alice) - pendleBefore, DEPOSIT_AMOUNT, "PENDLE delta equals deposit");
    }
}
/// forge-lint: disable-end
