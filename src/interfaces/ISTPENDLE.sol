// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IPMerkleDistributor} from "src/interfaces/pendle/IPMerkleDistributor.sol";
import {IPVotingEscrowMainchain} from "src/interfaces/pendle/IPVotingEscrowMainchain.sol";
import {IPVotingController} from "src/interfaces/pendle/IPVotingController.sol";

interface ISTPENDLE {
    // ========= Types =========
    struct VaultPosition {
        uint256 aumPendle;
        uint256 totalLockedPendle;
        uint256 currentEpoch;
        uint128 epochDuration;
        uint256 lastEpochUpdate;
        uint256 currentEpochStart;
        uint256 preLockRedemptionPeriod;
    }

    struct RedemptionSnapshot {
        uint256 aumPendleAtEpochStart;
        uint256 totalSupplyAtEpochStart;
        uint256 reservedAssetsAtEpochStart;
        uint256 epochStartTimestamp;
    }

    struct VaultConfig {
        address pendleTokenAddress;
        address merkleDistributorAddress;
        address votingEscrowMainchain;
        address votingControllerAddress;
        address timelockController;
        address admin;
        address lpFeeReceiver;
        address feeReceiver;
        uint256 preLockRedemptionPeriod;
        uint256 epochDuration;
        address ccipRouter;
        address feeToken;
    }

    // ========= Core actions =========
    function claimFees(uint256 totalAccrued, bytes32[] calldata proof) external;
    function startNewEpoch() external;

    // ========= Redemption queue =========
    function requestRedemptionForEpoch(uint256 shares, uint256 epoch) external;
    function claimAvailableRedemptionShares(uint256 shares) external returns (uint256 assetsRedeemed);

    // Per-epoch state
    function totalRequestedRedemptionAmountPerEpoch(uint256 epoch) external view returns (uint256);
    function getAvailableRedemptionAmount() external view returns (uint256);
    function getUserAvailableRedemption(address user) external view returns (uint256);
    function currentEpoch() external returns (uint256);

    // ========= Public views / config =========
    function ADMIN_ROLE() external view returns (uint256);
    function TIMELOCK_CONTROLLER_ROLE() external view returns (uint256);
    function merkleDistributor() external view returns (IPMerkleDistributor);
    function votingEscrowMainchain() external view returns (IPVotingEscrowMainchain);
    function votingController() external view returns (IPVotingController);
    function ASSET() external view returns (address);
    function feeBasisPoints() external view returns (uint256);
    function feeReceiver() external view returns (address);
    function lpFeeReceiver() external view returns (address);
    function paused() external view returns (bool);
    function epochDuration() external view returns (uint128);
    function preLockRedemptionPeriod() external view returns (uint256);
    function totalLockedPendle() external view returns (uint256);
    function rewardsSplit() external view returns (uint256 holders, uint256 lp);

    function lastEpochUpdate() external view returns (uint256);

    // Auto-generated mapping getters
    function pendingRedemptionSharesPerEpoch(address user, uint256 epoch) external view returns (uint256);
    function totalPendingSharesPerEpoch(uint256 epoch) external view returns (uint256);

    // ========= Governance / Admin =========
    function setFeeReceiver(address _feeReceiver) external;
    function setLpFeeReceiver(address _lpFeeReceiver) external;
    function setEpochDuration(uint128 _duration) external;
    function setRewardsSplit(uint256 holders, uint256 lp) external;
    function setOwner(address _owner) external;
    function pause() external;
    function unpause() external;
    function vote(address[] calldata pools, uint64[] calldata weights) external;

    // ========= Events =========
    event FeeReceiverSet(address feeReceiver);
    event RedemptionRequested(address indexed user, uint256 amount, uint256 requestEpoch);
    event RedemptionProcessed(address indexed user, uint256 amount, uint256 amountRedeemed);
    event EpochUpdated(uint256 newEpoch, uint256 lastEpochUpdate);
    event NewEpochStarted(uint256 newEpoch, uint256 lastEpochUpdate, uint256 additionalTime);
    event EpochDurationSet(uint128 duration);
    event AssetPositionIncreased(uint256 amount, uint256 currentEpoch, uint256 additionalTime);
    event FeesClaimed(uint256 amount, uint256 timestamp);
    event Paused(bool paused);
    event rewardsSplitSet(uint256 holders, uint256 lp);
    event LpFeeReceiverSet(address lpFeeReceiver);

    // ========= Errors =========
    // Core flow
    error InvalidPendleBalance();
    error EpochNotEnded();
    error InvalidAmount();
    error InsufficientShares();
    error NoPendingRedemption();
    error IsPaused();
    error OutsideRedemptionWindow();
    error InvalidERC4626Function();
    error InvalidEpoch();

    // Admin/config validation
    error EpochDurationInvalid();
    error InvalidFeeReceiver();
    error InvalidReceiver();
    error InvalidrewardsSplit();
    error InvalidAdmin();
    error InvalidTimelockController();
    error InvalidPendleToken();
    error InvalidMerkleDistributor();
    error InvalidVotingEscrowMainchain();
    error InvalidVotingController();
    error InvalidPreLockRedemptionPeriod();
    error InvalidEpochDuration();
}
