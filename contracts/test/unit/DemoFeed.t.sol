// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {DemoFeed} from "../../script/DemoContracts.sol";

/// @dev The demo feed moves the Reckless vault's price, so only its owner may set it.
contract DemoFeedTest is Test {
    address owner = makeAddr("owner");
    DemoFeed feed;

    function setUp() public {
        vm.prank(makeAddr("deployer")); // the constructor's one free set doesn't depend on who deploys
        feed = new DemoFeed(owner, 1_724e8);
    }

    function test_constructor_setsPrice() public view {
        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        assertEq(answer, 1_724e8);
        assertEq(updatedAt, block.timestamp);
    }

    function test_set_revert_notOwner() public {
        vm.prank(makeAddr("stranger"));
        vm.expectRevert(DemoFeed.NotOwner.selector);
        feed.set(1e8);
    }

    function test_set_owner() public {
        vm.warp(block.timestamp + 1 hours);
        vm.prank(owner);
        feed.set(1_500e8);
        (, int256 answer,, uint256 updatedAt,) = feed.latestRoundData();
        assertEq(answer, 1_500e8);
        assertEq(updatedAt, block.timestamp);
    }
}
