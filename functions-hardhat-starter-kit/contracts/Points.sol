// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {IPoints} from "./IPoints.sol";

contract Points is IPoints {
  uint256 private immutable _points;

  constructor(uint256 points_) {
    require(points_ > 0, "Points: zero");
    _points = points_;
  }

  function getPoints() external view override returns (uint256) {
    return _points;
  }
}
