// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {AggregatorV3Interface} from "../../src/interfaces/AggregatorV3Interface.sol";

contract MockAggregator is AggregatorV3Interface {
    uint8 public immutable decimals;
    int256 public answer;
    uint256 public updatedAt;
    bool public broken;

    constructor(uint8 _decimals, int256 _answer) {
        decimals = _decimals;
        set(_answer);
    }

    function set(int256 _answer) public {
        answer = _answer;
        updatedAt = block.timestamp;
    }

    function setUpdatedAt(uint256 t) external {
        updatedAt = t;
    }

    function setBroken(bool b) external {
        broken = b;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        require(!broken, "feed down");
        return (1, answer, updatedAt, updatedAt, 1);
    }
}
