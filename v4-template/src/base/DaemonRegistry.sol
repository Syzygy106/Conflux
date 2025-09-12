// SPDX-License-Identifier: MIT
pragma solidity ^0.8.30;
import {IDaemon} from "../interfaces/IDaemon.sol";
import {ZeroAddress, DuplicateDaemon, CapacityExceeded, IdDoesNotExist, NotExist, DaemonIsBanned, NotDaemonOwner, CountInvalid, StartInvalid} from "./Errors.sol";

contract DaemonRegistry {
  event Added(address indexed target, uint16 id);
  event ActivationChanged(address indexed target, uint16 id, bool active);
  event DaemonBanned(address indexed target, uint16 id);

  // List of daemon contract addresses, index also serves as id (uint16)
  address[] private _daemonAddresses;
  mapping(address => bool) public exists;
  mapping(address => uint16) public addressToId;
  mapping(uint16 => address) public idToAddress;
  mapping(address => bool) public active;
  mapping(address => address) public daemonOwner; // daemon address => owner address
  mapping(address => bool) public banned; // banned daemon cannot be activated

  // Compact activation bitmap: bit i corresponds to id i
  // Stored as 256-bit words for efficient updates
  mapping(uint256 => uint256) private _activationBitmaskWords;
  uint256 public bitWordCount; // number of 256-bit words used to cover current ids

  function _ensureBitCapacity(uint256 numberOfIds) internal {
    uint256 needed = (numberOfIds + 255) / 256;
    if (needed > bitWordCount) {
      bitWordCount = needed;
    }
  }

  function _setActiveBit(uint16 daemonId, bool isActive) internal {
    uint256 wordIndex = uint256(daemonId) / 256;
    uint256 bitIndex = uint256(daemonId) % 256;
    uint256 bitMask = (uint256(1) << bitIndex);
    uint256 currentWord = _activationBitmaskWords[wordIndex];
    if (isActive) {
      currentWord |= bitMask;
    } else {
      currentWord &= ~bitMask;
    }
    _activationBitmaskWords[wordIndex] = currentWord;
  }

  // Note: bulk add is handled in the hook to also capture per-daemon owners

  // TODO: ADD OnlyHookOwner
  function _add(address daemon, address owner) internal {
    if (daemon == address(0)) revert ZeroAddress();
    if (exists[daemon]) revert DuplicateDaemon();
    if (_daemonAddresses.length >= 3200) revert CapacityExceeded();
    uint16 daemonId = uint16(_daemonAddresses.length);
    exists[daemon] = true;
    addressToId[daemon] = daemonId;
    idToAddress[daemonId] = daemon;
    _daemonAddresses.push(daemon);
    daemonOwner[daemon] = owner;
    emit Added(daemon, daemonId);
    // active[daemon] is false by default
    _ensureBitCapacity(_daemonAddresses.length);
  }

  function length() external view returns (uint256) {
    return _daemonAddresses.length;
  }

  function getAt(uint256 index) external view returns (address) {
    return _daemonAddresses[index];
  }

  function getAll() external view returns (address[] memory) {
    return _daemonAddresses;
  }

  function getById(uint16 daemonId) external view returns (address) {
    address daemon = idToAddress[daemonId];
    if (daemon == address(0)) revert IdDoesNotExist();
    return daemon;
  }

  /// Packed addresses: 20*N bytes
  function packedAll() external view returns (bytes memory) {
    return abi.encodePacked(_daemonAddresses);
  }

  function packedHash() external view returns (bytes32) {
    return keccak256(abi.encodePacked(_daemonAddresses));
  }

  function _setActive(address daemon, bool isActive) internal {
    if (!exists[daemon]) revert NotExist();
    if (isActive) {
      if (banned[daemon]) revert DaemonIsBanned();
    }
    uint16 daemonId = addressToId[daemon];
    active[daemon] = isActive;
    _setActiveBit(daemonId, isActive);
    emit ActivationChanged(daemon, daemonId, isActive);
  }

  function _setActiveById(uint16 daemonId, bool isActive) internal {
    address daemon = idToAddress[daemonId];
    if (daemon == address(0)) revert NotExist();
    if (isActive) {
      if (banned[daemon]) revert DaemonIsBanned();
    }
    active[daemon] = isActive;
    _setActiveBit(daemonId, isActive);
    emit ActivationChanged(daemon, daemonId, isActive);
  }

  // Internal ban API for hook admin: disables daemon and prevents later activation by owner
  function _banDaemon(address daemon) internal {
    if (!exists[daemon]) revert NotExist();
    uint16 daemonId = addressToId[daemon];
    banned[daemon] = true;
    if (active[daemon]) {
      active[daemon] = false;
      _setActiveBit(daemonId, false);
      emit ActivationChanged(daemon, daemonId, false);
    }
    emit DaemonBanned(daemon, daemonId);
  }

  // Single-activation APIs restricted to daemon owner
  function setActive(address daemon, bool isActive) external {
    if (!exists[daemon]) revert NotExist();
    if (msg.sender != daemonOwner[daemon]) revert NotDaemonOwner();
    _setActive(daemon, isActive);
  }

  function setActiveById(uint16 daemonId, bool isActive) external {
    address daemon = idToAddress[daemonId];
    if (daemon == address(0)) revert NotExist();
    if (msg.sender != daemonOwner[daemon]) revert NotDaemonOwner();
    _setActive(daemon, isActive);
  }

  // TODO: ADD OnlyHookOwner
  function _activateMany(address[] calldata daemonAddresses) internal {
    for (uint256 index = 0; index < daemonAddresses.length; index++) {
      address daemon = daemonAddresses[index];
      if (exists[daemon] && !active[daemon]) {
        active[daemon] = true;
        _setActiveBit(addressToId[daemon], true);
        emit ActivationChanged(daemon, addressToId[daemon], true);
      }
    }
  }

  // TODO: ADD OnlyHookOwner
  function _deactivateMany(address[] calldata daemonAddresses) internal {
    for (uint256 index = 0; index < daemonAddresses.length; index++) {
      address daemon = daemonAddresses[index];
      if (exists[daemon] && active[daemon]) {
        active[daemon] = false;
        _setActiveBit(addressToId[daemon], false);
        emit ActivationChanged(daemon, addressToId[daemon], false);
      }
    }
  }

  /// Packed pairs: [id(2) | address(20)] * N
  /// - id is uint16, big-endian (high byte first)
  function packedPairs() external view returns (bytes memory out) {
    uint256 total = _daemonAddresses.length;
    out = new bytes(total * 22);
    for (uint256 index = 0; index < total; index++) {
      uint16 daemonId = addressToId[_daemonAddresses[index]];
      uint256 base = 32 + index * 22;
      // write id (2 bytes, big-endian)
      assembly {
        let p := add(out, base)
        mstore8(p, byte(1, daemonId))         // high byte
        mstore8(add(p, 1), byte(0, daemonId)) // low byte
      }
      // write address (20 bytes)
      bytes20 daemonBytes = bytes20(_daemonAddresses[index]);
      for (uint256 j = 0; j < 20; j++) {
        bytes1 b = daemonBytes[j];
        assembly {
          mstore8(add(add(out, base), add(2, j)), byte(0, b))
        }
      }
    }
  }

  function packedPairsHash() external view returns (bytes32) {
    return keccak256(this.packedPairs());
  }

  /// Returns compact activation bitmap. Bit i corresponds to id i.
  /// Length of the returned bytes is ceil(length()/8).
  function activationBitmap() external view returns (bytes memory out) {
    uint256 total = _daemonAddresses.length;
    uint256 byteLen = (total + 7) / 8;
    out = new bytes(byteLen);
    for (uint256 index = 0; index < total; index++) {
      if (active[_daemonAddresses[index]]) {
        uint256 byteIndex = index / 8;
        uint256 bitIndex = index % 8;
        uint8 cur = uint8(out[byteIndex]);
        uint8 mask = uint8(1) << uint8(bitIndex);
        out[byteIndex] = bytes1(cur | mask);
      }
    }
  }

  function activationMeta() external view returns (uint256 total, bytes memory bitmap) {
    total = _daemonAddresses.length;
    bitmap = this.activationBitmap();
  }

  function aggregatePointsRange(
    uint256 start,
    uint256 count,
    uint256 blockNumber
  ) external view returns (int128[] memory points) {
    if (!(count > 0 && count <= 800)) revert CountInvalid();
    uint256 total = _daemonAddresses.length;
    if (start > total) revert StartInvalid();
    uint256 available = total > start ? total - start : 0;
    uint256 toTake = count < available ? count : available;
    points = new int128[](toTake);
    if (toTake == 0) {
      return points;
    }
    for (uint256 index = 0; index < toTake; index++) {
      address daemon = _daemonAddresses[start + index];
      if (!active[daemon]) {
        points[index] = 0;
        continue;
      }
      try IDaemon(daemon).getRebateAmount(blockNumber) returns (int128 value) {
        points[index] = value;
      } catch {
        points[index] = 0;
      }
    }
  }

  /// Overload for Chainlink Functions script compatibility: uses current block number and returns uint128[]
  function aggregatePointsRange(uint256 start, uint256 count) external view returns (uint128[] memory points) {
    int128[] memory signedPoints = this.aggregatePointsRange(start, count, block.number);
    points = new uint128[](signedPoints.length);
    for (uint256 i = 0; i < signedPoints.length; i++) {
      int128 value = signedPoints[i];
      points[i] = value > 0 ? uint128(uint256(int256(value))) : uint128(0);
    }
  }

  /// Aggregate getRebateAmount() for all addresses in id order
  function aggregatePointsAll(uint256 blockNumber) external view returns (int128[] memory points) {
    uint256 total = _daemonAddresses.length;
    points = new int128[](total);
    for (uint256 index = 0; index < total; index++) {
      address daemon = _daemonAddresses[index];
      try IDaemon(daemon).getRebateAmount(blockNumber) returns (int128 value) {
        points[index] = value;
      } catch {
        points[index] = 0;
      }
    }
  }

  /// Aggregate getRebateAmount() for all addresses in id order, returning 0 for inactive
  function aggregatePointsMasked(uint256 blockNumber) external view returns (int128[] memory points) {
    uint256 total = _daemonAddresses.length;
    points = new int128[](total);
    for (uint256 index = 0; index < total; index++) {
      address daemon = _daemonAddresses[index];
      if (active[daemon]) {
        try IDaemon(daemon).getRebateAmount(blockNumber) returns (int128 value) {
          points[index] = value;
        } catch {
          points[index] = 0;
        }
      } else {
        points[index] = 0;
      }
    }
  }
}
