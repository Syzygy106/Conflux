// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

import {IDaemon} from "../interfaces/IDaemon.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/// @title LinearDaemon
/// @notice Example implementation of IDaemon with a linear rebate model
/// Price increases from startPrice to endPrice by priceInterest every growPeriod blocks starting at startBlock
contract LinearDaemon is IDaemon {
  // Parameters (int128 used to match registry expectations)
  int128 public immutable startPrice; // initial rebate amount
  int128 public immutable endPrice; // maximum rebate amount (cap)
  int128 public immutable priceInterest; // increment per period (must be > 0)
  uint256 public immutable growPeriod; // blocks per period (must be > 0)
  uint256 public immutable startBlock; // schedule start block

  // Telemetry
  uint256 public jobsExecuted;
  uint256 public lastJobBlock;

  // Simple ownable and token config for rebate flow
  address public owner;
  address public rebateToken; // ERC20 that will be pulled by the hook via transferFrom

  event LinearDaemonJobExecuted(address indexed caller, uint256 blockNumber);
  event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
  event RebateTokenSet(address indexed token);

  modifier onlyOwner() {
    require(msg.sender == owner, "only owner");
    _;
  }

  constructor(int128 _startPrice, int128 _endPrice, int128 _priceInterest, uint256 _growPeriod, uint256 _startBlock) {
    require(_priceInterest > 0, "interest");
    require(_growPeriod > 0, "period");
    require(_endPrice >= _startPrice, "order");
    startPrice = _startPrice;
    endPrice = _endPrice;
    priceInterest = _priceInterest;
    growPeriod = _growPeriod;
    startBlock = _startBlock;
    owner = msg.sender;
    emit OwnershipTransferred(address(0), msg.sender);
  }

  /// @inheritdoc IDaemon
  function getRebateAmount(uint256 blockNumber) external view returns (int128) {
    if (blockNumber < startBlock) {
      return 0;
    }
    // Compute number of periods elapsed since last job (or start)
    uint256 baseline = lastJobBlock;
    if (baseline < startBlock) baseline = startBlock;
    uint256 elapsedBlocks = blockNumber - baseline;
    uint256 periods = elapsedBlocks / growPeriod;

    // Compute startPrice + priceInterest * periods with capping at endPrice
    int256 increment = int256(priceInterest) * int256(periods);
    int256 candidate = int256(startPrice) + increment;
    if (candidate > int256(endPrice)) {
      candidate = int256(endPrice);
    }
    if (candidate < 0) {
      return 0;
    }
    return int128(candidate);
  }

  /// @inheritdoc IDaemon
  function accomplishDaemonJob() external {
    unchecked {
      jobsExecuted += 1;
    }
    lastJobBlock = block.number;
    emit LinearDaemonJobExecuted(msg.sender, block.number);
  }

  // ===== Admin: funding/approvals for rebate pulling =====

  function transferOwnership(address newOwner) external onlyOwner {
    require(newOwner != address(0), "zero owner");
    emit OwnershipTransferred(owner, newOwner);
    owner = newOwner;
  }

  /// @notice Sets the ERC20 token used for rebates (must match hook's rebateToken)
  function setRebateToken(address token) external onlyOwner {
    require(token != address(0), "zero token");
    rebateToken = token;
    emit RebateTokenSet(token);
  }

  /// @notice Approves a spender (e.g., ConfluxHook) to pull tokens from this daemon via transferFrom
  function approveRebateSpender(address spender, uint256 amount) external onlyOwner {
    require(rebateToken != address(0), "token not set");
    IERC20(rebateToken).approve(spender, amount);
  }

  /// @notice Generic token approval helper
  function approveToken(address token, address spender, uint256 amount) external onlyOwner {
    IERC20(token).approve(spender, amount);
  }

  // Accept plain ETH transfers (for funding gas or other admin needs)
  receive() external payable {}
}
