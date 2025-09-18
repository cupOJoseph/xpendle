// SPDX-License-Identifier: MIT
// Acknowledgment: Interface derived from Pendle V2 (pendle-core-v2-public).
// Source: https://github.com/pendle-finance/pendle-core-v2-public
pragma solidity ^0.8.26;

interface IPVotingController {
    function vote(address[] calldata pools, uint64[] calldata weights) external;
}
