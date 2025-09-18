// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

import {Script} from "lib/forge-std/src/Script.sol";
import {Contracts} from "script/Contracts.sol";
import {stPENDLE} from "src/stPENDLE.sol";
import {console} from "forge-std/console.sol";

contract stPendleDeploy is Script, Contracts {
    function run() public {
        uint256 epochDuration = 30 days;
        uint256 preLockRedemptionPeriod = 20 days;
        vm.startBroadcast();
        /**
         * address _pendleTokenAddress,
         *     address _merkleDistributorAddress,
         *     address _votingEscrowMainchain,
         *     address _votingControllerAddress,
         *     address _timelockController,
         *     address _admin,
         *     address _lpFeeReceiver,
         *     address _feeReceiver,
         *     uint256 _preLockRedemptionPeriod,
         *     uint256 _epochDuration
         */
        stPENDLE vault = new stPENDLE(
            pendleTokenAddress,
            merkleDistributor,
            votingEscrowMainchain,
            votingController,
            timelockController,
            admin,
            lpFeeReceiver,
            feeReceiver,
            preLockRedemptionPeriod,
            epochDuration
        );

        console.log("stPENDLE deployed at", address(vault));
        vm.stopBroadcast();
    }
}
