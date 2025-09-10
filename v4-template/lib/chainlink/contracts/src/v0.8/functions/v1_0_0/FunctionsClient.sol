// SPDX-License-Identifier: MIT
pragma solidity ^0.8.0;

abstract contract FunctionsClient {
  bytes32 internal lastEmittedRequestId;

  event RequestSent(bytes32 requestId);

  constructor(address) {}

  function _sendRequest(
    bytes memory /* data */,
    uint64 /* subscriptionId */,
    uint32 /* callbackGasLimit */,
    bytes32 /* donId */
  ) internal returns (bytes32 requestId) {
    requestId = keccak256(abi.encode(block.timestamp, address(this)));
    lastEmittedRequestId = requestId;
    emit RequestSent(requestId);
  }

  function fulfillRequest(bytes32 requestId, bytes memory response, bytes memory err) internal virtual;
}
