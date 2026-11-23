// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {AggregatorV3Interface} from "../../src/interfaces/AggregatorV3Interface.sol";
import {IMandate} from "../../src/interfaces/IMandate.sol";
import {OracleGuard} from "../../src/libraries/OracleGuard.sol";
import {MockAggregator} from "../mocks/MockAggregator.sol";

contract OracleGuardHarness {
    function sqrtPriceX96(OracleGuard.Feed memory f) external view returns (uint160) {
        return OracleGuard.sqrtPriceX96(f);
    }
}

contract OracleGuardTest is Test {
    OracleGuardHarness h;
    MockAggregator agg;

    function setUp() public {
        vm.warp(1_700_000_000);
        h = new OracleGuardHarness();
        agg = new MockAggregator(8, 3000e8); // ETH/USD
    }

    function _feed(bool baseIsToken0, uint8 dec0, uint8 dec1) internal view returns (OracleGuard.Feed memory) {
        return OracleGuard.Feed(AggregatorV3Interface(address(agg)), 1 hours, baseIsToken0, 8, dec0, dec1);
    }

    /// @dev raw price (token1 per token0) scaled by 1e36, from a sqrtPriceX96.
    function _priceE36(uint160 sqrtP) internal pure returns (uint256) {
        return FullMath.mulDiv(FullMath.mulDiv(sqrtP, sqrtP, 1 << 96), 1e36, 1 << 96);
    }

    function test_parity_18_18() public {
        agg.set(1e8);
        assertEq(h.sqrtPriceX96(_feed(true, 18, 18)), 1 << 96);
    }

    function test_wethToken0_usdcToken1() public view {
        // 1 WETH (1e18 raw) = 3000 USDC (3000e6 raw) -> raw price 3e-9
        uint256 p = _priceE36(h.sqrtPriceX96(_feed(true, 18, 6)));
        assertApproxEqRel(p, 3e27, 1e12); // 1e-6 relative
    }

    function test_usdcToken0_wethToken1() public view {
        // feed base (ETH) is token1: raw WETH per raw USDC = 1e18 / (3000 * 1e6) = 3.333e8
        uint256 p = _priceE36(h.sqrtPriceX96(_feed(false, 6, 18)));
        assertApproxEqRel(p, uint256(1e36) * 1e12 / 3000, 1e12);
    }

    function test_freshAtExactLimit() public {
        agg.setUpdatedAt(block.timestamp - 1 hours);
        h.sqrtPriceX96(_feed(true, 18, 6));
    }

    function test_revert_stale() public {
        agg.setUpdatedAt(block.timestamp - 1 hours - 1);
        vm.expectRevert(IMandate.OracleStale.selector);
        h.sqrtPriceX96(_feed(true, 18, 6));
    }

    function test_revert_neverUpdated() public {
        agg.setUpdatedAt(0);
        vm.expectRevert(IMandate.OracleStale.selector);
        h.sqrtPriceX96(_feed(true, 18, 6));
    }

    function test_revert_zeroAnswer() public {
        agg.set(0);
        vm.expectRevert(IMandate.OracleStale.selector);
        h.sqrtPriceX96(_feed(true, 18, 6));
    }

    function test_revert_negativeAnswer() public {
        agg.set(-1);
        vm.expectRevert(IMandate.OracleStale.selector);
        h.sqrtPriceX96(_feed(true, 18, 6));
    }

    function test_revert_priceOutsideV4Range() public {
        // raw price 1e30 is beyond what a v4 pool can represent
        agg.set(1e8);
        vm.expectRevert(IMandate.OracleStale.selector);
        h.sqrtPriceX96(_feed(true, 0, 30));
    }
}
