// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {FunctionsClient} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/FunctionsClient.sol";
import {ConfirmedOwner} from "@chainlink/contracts/src/v0.8/shared/access/ConfirmedOwner.sol";
import {FunctionsRequest} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/libraries/FunctionsRequest.sol";
import {PointsRegistry} from "./PointsRegistry.sol";

contract Top3Consumer is FunctionsClient, ConfirmedOwner {
  using FunctionsRequest for FunctionsRequest.Request;

  bytes32 public donId;
  PointsRegistry public registry;
  uint256[8] public topPacked; // packed 128 uint16 ids (16 ids per 256-bit word)
  uint16 public topCount; // optional; may be <=128, 0 if unknown
  bytes32 public lastRequestId;

  event TopIdsUpdated(uint16 count);

  constructor(address router, bytes32 _donId, address registryAddr) FunctionsClient(router) ConfirmedOwner(msg.sender) {
    donId = _donId;
    registry = PointsRegistry(registryAddr);
  }

  function sendRequest(
    string calldata source,
    FunctionsRequest.Location secretsLocation,
    bytes calldata encryptedSecretsReference,
    string[] calldata args,
    bytes[] calldata bytesArgs,
    uint64 subscriptionId,
    uint32 callbackGasLimit
  ) external onlyOwner {
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

  function fulfillRequest(bytes32 requestId, bytes memory response, bytes memory err) internal override {
    require(requestId == lastRequestId, "unknown request");
    require(err.length == 0, "functions error");
    uint256[8] memory words = abi.decode(response, (uint256[8]));
    // Single SSTORE per word (8 total) to keep callback gas low
    for (uint256 i = 0; i < 8; i++) {
      topPacked[i] = words[i];
    }
    topCount = 128;
    emit TopIdsUpdated(topCount);
  }

  function topIdsAt(uint256 index) external view returns (uint16) {
    require(index < 128, "oob");
    uint256 wordIndex = index / 16;
    uint256 slot = index % 16;
    uint256 word = topPacked[wordIndex];
    return uint16((word >> (slot * 16)) & 0xffff);
  }
}
