// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";

/// @notice Testnet-only token with an open faucet, so demo users and curators can get funds.
contract TestToken is ERC20 {
    uint8 private immutable _decimals;

    constructor(string memory name_, string memory symbol_, uint8 decimals_) ERC20(name_, symbol_) {
        _decimals = decimals_;
    }

    function decimals() public view override returns (uint8) {
        return _decimals;
    }

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}

/// @notice DEMO price feed for the breach scene: the real Chainlink price can't be moved on camera.
/// Owner-only, so nobody else can trigger the demo vault's breach. Never use it for a real vault.
contract DemoFeed is AggregatorV3Interface {
    address public immutable owner;
    int256 public answer;
    uint256 public updatedAt;

    error NotOwner();

    constructor(address owner_, int256 answer_) {
        owner = owner_;
        set(answer_);
    }

    function set(int256 answer_) public {
        if (msg.sender != owner && updatedAt != 0) revert NotOwner();
        answer = answer_;
        updatedAt = block.timestamp;
    }

    function description() external pure returns (string memory) {
        return "Bridle DEMO ETH / USD (not Chainlink)";
    }

    function decimals() external pure returns (uint8) {
        return 8;
    }

    function latestRoundData() external view returns (uint80, int256, uint256, uint256, uint80) {
        return (1, answer, updatedAt, updatedAt, 1);
    }
}
