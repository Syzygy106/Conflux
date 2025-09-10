// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

interface IPoints {
  function getPoints() external view returns (uint256);
}

contract PointsRegistry {
  event Added(address indexed target, uint16 id);
  event ActivationChanged(address indexed target, uint16 id, bool active);

  address[] private _addrs;
  mapping(address => bool) public exists;
  mapping(address => uint16) public addressToId;
  mapping(uint16 => address) public idToAddress;
  mapping(address => bool) public active;

  // Compact activation bitmap: bit i corresponds to id i
  // Stored as 256-bit words for efficient updates
  mapping(uint256 => uint256) private _activationBitWords;
  uint256 public bitWordCount; // number of 256-bit words used to cover current ids

  function _ensureBitCapacity(uint256 numIds) internal {
    uint256 needed = (numIds + 255) / 256;
    if (needed > bitWordCount) {
      bitWordCount = needed;
    }
  }

  function _setActiveBit(uint16 id, bool value) internal {
    uint256 wordIndex = uint256(id) / 256;
    uint256 bitIndex = uint256(id) % 256;
    uint256 mask = (uint256(1) << bitIndex);
    uint256 w = _activationBitWords[wordIndex];
    if (value) {
      w |= mask;
    } else {
      w &= ~mask;
    }
    _activationBitWords[wordIndex] = w;
  }

  function addMany(address[] memory addrs) external {
    for (uint256 i = 0; i < addrs.length; i++) {
      address t = addrs[i];
      require(t != address(0), "zero");
      require(!exists[t], "dup");
      require(_addrs.length < 3200, "cap 3200");
      uint16 id = uint16(_addrs.length);
      exists[t] = true;
      addressToId[t] = id;
      idToAddress[id] = t;
      _addrs.push(t);
      emit Added(t, id);
      // active[t] is false by default
      _ensureBitCapacity(_addrs.length);
    }
  }

  function add(address t) external {
    require(t != address(0), "zero");
    require(!exists[t], "dup");
    require(_addrs.length < 3200, "cap 3200");
    uint16 id = uint16(_addrs.length);
    exists[t] = true;
    addressToId[t] = id;
    idToAddress[id] = t;
    _addrs.push(t);
    emit Added(t, id);
    // active[t] is false by default
    _ensureBitCapacity(_addrs.length);
  }

  function length() external view returns (uint256) {
    return _addrs.length;
  }

  function getAt(uint256 idx) external view returns (address) {
    return _addrs[idx];
  }

  function getAll() external view returns (address[] memory) {
    return _addrs;
  }

  function getById(uint16 id) external view returns (address) {
    address a = idToAddress[id];
    require(a != address(0), "id !exist");
    return a;
  }

  /// Packed addresses: 20*N bytes
  function packedAll() external view returns (bytes memory) {
    return abi.encodePacked(_addrs);
  }

  function packedHash() external view returns (bytes32) {
    return keccak256(abi.encodePacked(_addrs));
  }

  function setActive(address t, bool a) external {
    require(exists[t], "!exist");
    uint16 id = addressToId[t];
    active[t] = a;
    _setActiveBit(id, a);
    emit ActivationChanged(t, id, a);
  }

  function setActiveById(uint16 id, bool a) external {
    address t = idToAddress[id];
    require(t != address(0), "!exist");
    active[t] = a;
    _setActiveBit(id, a);
    emit ActivationChanged(t, id, a);
  }

  function activateMany(address[] calldata addrs) external {
    for (uint256 i = 0; i < addrs.length; i++) {
      address t = addrs[i];
      if (exists[t] && !active[t]) {
        active[t] = true;
        _setActiveBit(addressToId[t], true);
        emit ActivationChanged(t, addressToId[t], true);
      }
    }
  }

  function deactivateMany(address[] calldata addrs) external {
    for (uint256 i = 0; i < addrs.length; i++) {
      address t = addrs[i];
      if (exists[t] && active[t]) {
        active[t] = false;
        _setActiveBit(addressToId[t], false);
        emit ActivationChanged(t, addressToId[t], false);
      }
    }
  }

  /// Packed pairs: [id(1) | address(20)] * N
  function packedPairs() external view returns (bytes memory out) {
    uint256 n = _addrs.length;
    out = new bytes(n * 21);
    for (uint256 i = 0; i < n; i++) {
      uint8 id = uint8(addressToId[_addrs[i]]);
      uint256 base = 32 + i * 21;
      assembly {
        let p := add(out, base)
        mstore8(p, id)
      }
      bytes20 ab = bytes20(_addrs[i]);
      for (uint256 j = 0; j < 20; j++) {
        bytes1 b = ab[j];
        assembly {
          mstore8(add(add(out, base), add(1, j)), byte(0, b))
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
    uint256 n = _addrs.length;
    uint256 byteLen = (n + 7) / 8;
    out = new bytes(byteLen);
    for (uint256 i = 0; i < n; i++) {
      if (active[_addrs[i]]) {
        uint256 byteIndex = i / 8;
        uint256 bitIndex = i % 8;
        uint8 cur = uint8(out[byteIndex]);
        uint8 mask = uint8(1) << uint8(bitIndex);
        out[byteIndex] = bytes1(cur | mask);
      }
    }
  }

  function activationMeta() external view returns (uint256 total, bytes memory bitmap) {
    total = _addrs.length;
    bitmap = this.activationBitmap();
  }

  function aggregatePointsRange(uint256 start, uint256 count) external view returns (uint128[] memory points) {
    require(count > 0 && count <= 800, "count");
    uint256 n = _addrs.length;
    require(start <= n, "start");
    uint256 available = n > start ? n - start : 0;
    uint256 m = count < available ? count : available;
    points = new uint128[](m);
    if (m == 0) {
      return points;
    }
    bytes4 sel = IPoints.getPoints.selector;
    for (uint256 i = 0; i < m; i++) {
      address a = _addrs[start + i];
      if (!active[a]) {
        points[i] = 0;
        continue;
      }
      (bool ok, bytes memory data) = a.staticcall{gas: 50000}(abi.encodeWithSelector(sel));
      if (ok && data.length >= 32) {
        uint256 v = abi.decode(data, (uint256));
        points[i] = v > type(uint128).max ? type(uint128).max : uint128(v);
      } else {
        points[i] = 0;
      }
    }
  }

  /// Aggregate getPoints() for all addresses in id order
  function aggregatePointsAll() external view returns (uint256[] memory points) {
    uint256 n = _addrs.length;
    points = new uint256[](n);
    for (uint256 i = 0; i < n; i++) {
      points[i] = IPoints(_addrs[i]).getPoints();
    }
  }

  /// Aggregate getPoints() for all addresses in id order, returning 0 for inactive
  function aggregatePointsMasked() external view returns (uint256[] memory points) {
    uint256 n = _addrs.length;
    points = new uint256[](n);
    for (uint256 i = 0; i < n; i++) {
      address a = _addrs[i];
      if (active[a]) {
        points[i] = IPoints(a).getPoints();
      } else {
        points[i] = 0;
      }
    }
  }
}
