// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;

interface IDaemon {
  function getRebateAmount(uint256 blockNumber) external view returns (int128);
  function accomplishDaemonJob() external;
}
