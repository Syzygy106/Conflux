// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {UnknownRequest, FunctionsError, AlreadyInitialized, IndexOutOfBounds, EmptyTop, ZeroValue} from "./Errors.sol";

import {FunctionsClient} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/FunctionsClient.sol";
import {FunctionsRequest} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/libraries/FunctionsRequest.sol";

import {DaemonRegistry} from "./DaemonRegistry.sol";

contract ChainLinkConsumer is FunctionsClient {
  using FunctionsRequest for FunctionsRequest.Request;

  bytes32 public donId;
  uint256[8] public topPacked; // packed 128 uint16 ids (16 ids per 256-bit word)
  uint16 public topCount; // optional; may be <=128, 0 if unknown
  uint16 public topCursor; // current index in top list
  bytes32 public lastRequestId;
  uint64 public topEpoch; // increments on each successful top update
  uint256 public epochDurationBlocks; // 0 disables block-based expiration
  uint256 public lastEpochStartBlock; // block when current epoch started
  bool public hasPendingTopRequest; // prevents spamming requests

  event TopRefreshRequested(uint64 epoch, uint256 atBlock);

  event TopIdsUpdated(uint16 count);

  constructor(address router, bytes32 _donId) FunctionsClient(router) {
    donId = _donId;
  }

  function _sendRequestInternal(
    string calldata source,
    FunctionsRequest.Location secretsLocation,
    bytes calldata encryptedSecretsReference,
    string[] calldata args,
    bytes[] calldata bytesArgs,
    uint64 subscriptionId,
    uint32 callbackGasLimit
  ) internal {
    FunctionsRequest.Request memory req;
    req.initializeRequest(FunctionsRequest.Location.Inline, FunctionsRequest.CodeLanguage.JavaScript, source);
    req.secretsLocation = secretsLocation;
    req.encryptedSecretsReference = encryptedSecretsReference;
    if (args.length > 0) {
      req.setArgs(args);
    }
    if (bytesArgs.length > 0) {
      req.setBytesArgs(bytesArgs);
    }
    lastRequestId = _sendRequest(req.encodeCBOR(), subscriptionId, callbackGasLimit, donId);
  }

  // --- Admin methods (internal control) ---
  function setEpochDurationBlocks(uint256 blocks_) internal {
    if (blocks_ == 0) revert ZeroValue();
    epochDurationBlocks = blocks_;
  }

  // removed external requestTopUpdate per design

  function fulfillRequest(bytes32 requestId, bytes memory response, bytes memory err) internal override {
    if (requestId != lastRequestId) revert UnknownRequest();
    if (err.length != 0) revert FunctionsError();
    uint256[8] memory words = abi.decode(response, (uint256[8]));
    // Single SSTORE per word (8 total) to keep callback gas low
    for (uint256 i = 0; i < 8; i++) {
      topPacked[i] = words[i];
    }
    // Derive topCount from non-sentinel ids (0xFFFF) packed in words
    uint16 count = 0;
    for (uint256 i = 0; i < 128; i++) {
      uint256 wordIndex = i / 16;
      uint256 slot = i % 16;
      uint256 word = words[wordIndex];
      uint16 id = uint16((word >> (slot * 16)) & 0xffff);
      if (id == 0xffff) {
        break;
      }
      unchecked {
        count++;
      }
    }
    topCount = count;
    topCursor = 0;
    topEpoch++;
    hasPendingTopRequest = false;
    lastEpochStartBlock = block.number;
    emit TopIdsUpdated(topCount);
  }

  /// If epoch expired and no request is pending, mark pending and emit event
  function _maybeRequestTopUpdate() internal {
    if (epochDurationBlocks == 0) {
      return;
    }
    bool expired = block.number >= lastEpochStartBlock + epochDurationBlocks;
    if (expired && !hasPendingTopRequest) {
      hasPendingTopRequest = true;
      emit TopRefreshRequested(topEpoch, block.number);
    }
  }

  // Start rebate epochs with initial duration and send first request (hook exposes a wrapper)
  function _startRebateEpochs(
    uint256 initialEpochDurationBlocks,
    string calldata source,
    FunctionsRequest.Location secretsLocation,
    bytes calldata encryptedSecretsReference,
    string[] calldata args,
    bytes[] calldata bytesArgs,
    uint64 subscriptionId,
    uint32 callbackGasLimit
  ) internal {
    if (epochDurationBlocks != 0) revert AlreadyInitialized();
    setEpochDurationBlocks(initialEpochDurationBlocks);
    hasPendingTopRequest = true;
    _sendRequestInternal(
      source,
      secretsLocation,
      encryptedSecretsReference,
      args,
      bytesArgs,
      subscriptionId,
      callbackGasLimit
    );
  }

  function topIdsAt(uint256 index) external view returns (uint16) {
    if (index >= topCount) revert IndexOutOfBounds();
    uint256 wordIndex = index / 16;
    uint256 slot = index % 16;
    uint256 word = topPacked[wordIndex];
    return uint16((word >> (slot * 16)) & 0xffff);
  }

  function getCurrentTop() public view returns (address daemon) {
    if (topCount == 0) revert EmptyTop();
    uint256 wordIndex = uint256(topCursor) / 16;
    uint256 slot = uint256(topCursor) % 16;
    uint256 word = topPacked[wordIndex];
    uint16 id = uint16((word >> (slot * 16)) & 0xffff);
    daemon = DaemonRegistry(address(this)).getById(id);
  }

  function iterNextTop() internal {
    if (topCount == 0) revert EmptyTop();
    unchecked {
      uint16 next = topCursor + 1;
      if (next >= topCount) {
        next = 0;
      }
      topCursor = next;
    }
  }
}
