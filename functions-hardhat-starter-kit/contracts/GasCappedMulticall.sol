// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// Batch staticcalls with a gas cap per sub-call.
/// Use only for view/pure (staticcall).
contract GasCappedMulticall {
  struct Call {
    address target;
    bytes callData;
  }
  struct Result {
    bool success;
    bytes returnData;
  }

  /// Same gas limit for all calls.
  function aggregateGasLimited(
    Call[] calldata calls,
    uint64 perCallGas,
    bool allowFailure
  ) external view returns (uint256 blockNumber, Result[] memory results) {
    blockNumber = block.number;
    uint256 len = calls.length;
    results = new Result[](len);

    for (uint256 i = 0; i < len; ) {
      (bool ok, bytes memory ret) = calls[i].target.staticcall{gas: perCallGas}(calls[i].callData);

      if (!allowFailure && !ok) revert("CALL_FAILED");
      results[i] = Result(ok, ret);
      unchecked {
        ++i;
      }
    }
  }

  /// Individual gas limits per call.
  function aggregatePerCallGas(
    Call[] calldata calls,
    uint64[] calldata gasCaps,
    bool allowFailure
  ) external view returns (uint256 blockNumber, Result[] memory results) {
    require(calls.length == gasCaps.length, "len mismatch");
    blockNumber = block.number;
    uint256 len = calls.length;
    results = new Result[](len);

    for (uint256 i = 0; i < len; ) {
      (bool ok, bytes memory ret) = calls[i].target.staticcall{gas: gasCaps[i]}(calls[i].callData);

      if (!allowFailure && !ok) revert("CALL_FAILED");
      results[i] = Result(ok, ret);
      unchecked {
        ++i;
      }
    }
  }
}
