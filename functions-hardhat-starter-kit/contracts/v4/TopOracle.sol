// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {FunctionsClient} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/FunctionsClient.sol";
import {FunctionsRequest} from "@chainlink/contracts/src/v0.8/functions/v1_0_0/libraries/FunctionsRequest.sol";

// Minimal interface for accessing daemon addresses by id
interface IDaemonRegistryView {
  function getById(uint16 daemonId) external view returns (address);
  function length() external view returns (uint256);
}

/**
 * @title TopOracle
 * @notice Stores and updates the "top" daemons via Chainlink Functions.
 *         Instead of storing/building the request on the contract, a
 *         pre-prepared CBOR (req.encodeCBOR()) is used, stored
 *         in a template. This saves bytecode and gas.
 */
contract TopOracle is FunctionsClient {
  using FunctionsRequest for FunctionsRequest.Request;
  // === Chainlink Configuration ===
  bytes32 public donId;
  address public registry; // daemon registry address (for getById)

  // Owner (simple ownable without dependencies to avoid bloating the code)
  address public owner;
  address public hookAuthority; // Hook contract that can call restricted functions
  
  modifier onlyOwner() {
    require(msg.sender == owner, "only owner");
    _;
  }
  
  modifier onlyHookAuthority() {
    require(msg.sender == hookAuthority, "only hook authority");
    _;
  }

  event OwnerTransferred(address indexed previousOwner, address indexed newOwner);
  event RegistryUpdated(address indexed newRegistry);
  event HookAuthoritySet(address indexed hookAuthority);

  // === Top data (128 ids packed into 8 words) ===
  uint256[8] public topPacked;   // 16 * 8 ids in 8 * 256-bit words
  uint16 public topCount;        // [0..128]
  uint16 public topCursor;       // current index in the top
  bytes32 public lastRequestId;  // last Functions request
  uint64 public topEpoch;        // increments on successful update
  uint256 public epochDurationBlocks;   // epoch duration in blocks (0 — disabled)
  uint256 public lastEpochStartBlock;   // block when current epoch started
  bool public hasPendingTopRequest;     // true if request is already sent and waiting for fulfill

  event TopRefreshRequested(uint64 epoch, uint256 atBlock);
  event TopIdsUpdated(uint16 count);

  // === Request template (direct parameters) ===
  struct RequestTemplate {
    string source;
    FunctionsRequest.Location secretsLocation;
    bytes encryptedSecretsReference;
    string[] args;
    bytes[] bytesArgs;
    uint64 subscriptionId;
    uint32 callbackGasLimit;
  }
  RequestTemplate private _tpl;

  event TemplateUpdated(uint64 subscriptionId, uint32 callbackGasLimit);
  event EpochDurationUpdated(uint256 blocks);

  constructor(address router, bytes32 _donId, address _registry, address _hookAuthority) FunctionsClient(router) {
    donId = _donId;
    registry = _registry;
    hookAuthority = _hookAuthority;
    owner = msg.sender;
    emit OwnerTransferred(address(0), msg.sender);
    emit RegistryUpdated(_registry);
    emit HookAuthoritySet(_hookAuthority);
  }

  // ===== Admin =====

  function transferOwnership(address newOwner) external onlyOwner {
    require(newOwner != address(0), "zero owner");
    emit OwnerTransferred(owner, newOwner);
    owner = newOwner;
  }

  function setRegistry(address _registry) external onlyOwner {
    registry = _registry;
    emit RegistryUpdated(_registry);
  }

  function setHookAuthority(address _hookAuthority) external onlyOwner {
    require(_hookAuthority != address(0), "zero hook authority");
    hookAuthority = _hookAuthority;
    emit HookAuthoritySet(_hookAuthority);
  }

  /**
   * @notice Sets the request template with direct parameters for Functions request.
   */
  function setRequestTemplate(
    string calldata source,
    FunctionsRequest.Location secretsLocation,
    bytes calldata encryptedSecretsReference,
    string[] calldata args,
    bytes[] calldata bytesArgs,
    uint64 subscriptionId,
    uint32 callbackGasLimit
  ) external onlyOwner {
    require(bytes(source).length > 0, "empty source");
    require(subscriptionId != 0, "zero sub");
    require(callbackGasLimit != 0, "zero gas");
    _tpl = RequestTemplate(source, secretsLocation, encryptedSecretsReference, args, bytesArgs, subscriptionId, callbackGasLimit);
    emit TemplateUpdated(subscriptionId, callbackGasLimit);
  }

  /**
   * @notice Sets the epoch duration (in blocks).
   */
  function setEpochDuration(uint256 blocks_) external onlyOwner {
    require(blocks_ > 0, "zero epoch");
    epochDurationBlocks = blocks_;
    emit EpochDurationUpdated(blocks_);
  }

  /**
   * @notice Initialization: sets epoch duration and starts first Functions request.
   *         Requires that setRequestTemplate() has been called first.
   */
  function startRebateEpochs(uint256 initialEpochDurationBlocks) external onlyOwner {
    require(epochDurationBlocks == 0, "already initialized");
    require(initialEpochDurationBlocks > 0, "zero epoch");
    require(bytes(_tpl.source).length > 0, "template not set");

    epochDurationBlocks = initialEpochDurationBlocks;

    // Send first request immediately using the template
    hasPendingTopRequest = true;
    lastRequestId = _sendRequestFromTemplate();
    emit EpochDurationUpdated(initialEpochDurationBlocks);
    emit TopRefreshRequested(topEpoch, block.number);
  }

  /**
   * @notice Force update manually (by admin), without waiting for epoch expiration.
   */
  function refreshTopNow() external onlyOwner {
    require(bytes(_tpl.source).length > 0, "tpl not set");
    hasPendingTopRequest = true;
    lastRequestId = _sendRequestFromTemplate();
    emit TopRefreshRequested(topEpoch, block.number);
  }

  // ===== Auto-trigger from on-chain side (called by hook) =====

  /**
   * @notice If epoch has expired and there is no pending request — sends new Functions request,
   *         using saved template. This is NO LONGER a mockup.
   */
  function maybeRequestTopUpdate() external onlyHookAuthority {
    if (epochDurationBlocks == 0) return;

    bool expired = block.number >= lastEpochStartBlock + epochDurationBlocks;
    if (expired && !hasPendingTopRequest) {
      // Check if there are any daemons in the registry to avoid wasting LINK tokens
      if (registry == address(0)) return;
      
      uint256 daemonCount = IDaemonRegistryView(registry).length();
      if (daemonCount == 0) return; // Skip request if no daemons registered
      
      require(bytes(_tpl.source).length > 0, "tpl not set");

      hasPendingTopRequest = true;
      lastRequestId = _sendRequestFromTemplate();

      emit TopRefreshRequested(topEpoch, block.number);
    }
  }

  // ===== Helper functions =====

  /**
   * @dev Helper function to send a request using the stored template
   */
  function _sendRequestFromTemplate() internal returns (bytes32) {
    RequestTemplate memory t = _tpl;
    
    FunctionsRequest.Request memory req;
    req.initializeRequest(FunctionsRequest.Location.Inline, FunctionsRequest.CodeLanguage.JavaScript, t.source);
    req.secretsLocation = t.secretsLocation;
    req.encryptedSecretsReference = t.encryptedSecretsReference;
    
    // Set args and bytesArgs directly since they're already memory arrays
    req.args = t.args;
    req.bytesArgs = t.bytesArgs;
    
    return _sendRequest(req.encodeCBOR(), t.subscriptionId, t.callbackGasLimit, donId);
  }

  // ===== Chainlink Functions fulfill =====

  /**
   * @dev Response processing: write 8 words, recalculate topCount,
   *      reset cursor, increment epoch and reset pending flag.
   */
  function fulfillRequest(bytes32 requestId, bytes memory response, bytes memory err) internal override {
    require(requestId == lastRequestId, "UnknownRequest");
    require(err.length == 0, "FunctionsError");

    uint256[8] memory words = abi.decode(response, (uint256[8]));
    // 8 SSTORE — one word at a time
    for (uint256 i = 0; i < 8; i++) {
      topPacked[i] = words[i];
    }

    // Calculate real topCount: stop at 0xFFFF
    uint16 count = 0;
    for (uint256 i = 0; i < 128; i++) {
      uint256 wordIndex = i / 16;
      uint256 slot = i % 16;
      uint256 word = words[wordIndex];
      uint16 id = uint16((word >> (slot * 16)) & 0xffff);
      if (id == 0xffff) break;
      unchecked { count++; }
    }

    topCount = count;
    topCursor = 0;
    topEpoch++;
    hasPendingTopRequest = false;
    lastEpochStartBlock = block.number;

    emit TopIdsUpdated(topCount);
  }

  // ===== View / Iteration for hook =====

  function topIdsAt(uint256 index) external view returns (uint16) {
    require(index < topCount, "oob");
    uint256 wordIndex = index / 16;
    uint256 slot = index % 16;
    uint256 word = topPacked[wordIndex];
    return uint16((word >> (slot * 16)) & 0xffff);
  }

  function getCurrentTop() external view returns (address daemon) {
    require(topCount > 0, "EmptyTop");
    uint256 wordIndex = uint256(topCursor) / 16;
    uint256 slot = uint256(topCursor) % 16;
    uint256 word = topPacked[wordIndex];
    uint16 id = uint16((word >> (slot * 16)) & 0xffff);
    daemon = IDaemonRegistryView(registry).getById(id);
  }

  function iterNextTop() external onlyHookAuthority {
    require(topCount > 0, "EmptyTop");
    unchecked {
      uint16 next = topCursor + 1;
      if (next >= topCount) next = 0;
      topCursor = next;
    }
  }
}
