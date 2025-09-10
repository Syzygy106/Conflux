// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {FunctionsRequest} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/libraries/FunctionsRequest.sol";

interface IChainlinkOracle {
    // Events
    event TopRefreshRequested(uint64 epoch, uint256 atBlock);
    event TopIdsUpdated(uint16 count);
    
    // Core functions
    function startRebateEpochs(
        uint256 initialEpochDurationBlocks,
        string calldata source,
        FunctionsRequest.Location secretsLocation,
        bytes calldata encryptedSecretsReference,
        string[] calldata args,
        bytes[] calldata bytesArgs,
        uint64 subscriptionId,
        uint32 callbackGasLimit
    ) external;
    
    function setEpochDuration(uint256 blocks) external;
    function maybeRequestTopUpdate() external;
    
    // View functions
    function getTopDaemonAt(uint256 index) external view returns (uint16);
    function getCurrentTopDaemon() external view returns (address);
    function getTopCount() external view returns (uint16);
    function getTopCursor() external view returns (uint16);
    function getTopEpoch() external view returns (uint64);
    function getEpochDurationBlocks() external view returns (uint256);
    function getLastEpochStartBlock() external view returns (uint256);
    function hasPendingRequest() external view returns (bool);
    
    // Internal functions for hook
    function iterateToNextTop() external;
}
