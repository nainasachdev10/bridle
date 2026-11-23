// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {AggregatorV3Interface} from "../interfaces/AggregatorV3Interface.sol";
import {IMandate} from "../interfaces/IMandate.sol";

/// @notice Chainlink price -> pool sqrtPriceX96, with staleness checks.
/// Pool price is raw token1 per raw token0. The feed quotes `base` in `quote` with `feedDecimals`.
library OracleGuard {
    struct Feed {
        AggregatorV3Interface aggregator;
        uint32 maxStaleness; // seconds
        bool baseIsToken0; // true: feed = token1 per token0 (e.g. ETH/USD with WETH < USDC)
        uint8 feedDecimals;
        uint8 decimals0;
        uint8 decimals1;
    }

    /// @notice Oracle price as a pool sqrtPriceX96. Reverts OracleStale on a stale, zero/negative or unusable answer.
    function sqrtPriceX96(Feed memory f) internal view returns (uint160) {
        (, int256 answer,, uint256 updatedAt,) = f.aggregator.latestRoundData();
        if (answer <= 0 || updatedAt == 0 || block.timestamp > updatedAt + f.maxStaleness) {
            revert IMandate.OracleStale();
        }
        return toSqrtPriceX96(f, uint256(answer));
    }

    /// @notice price(token1/token0, raw units) = answer * 10^dec1 / (10^feedDec * 10^dec0), inverted if base is token1.
    function toSqrtPriceX96(Feed memory f, uint256 answer) internal pure returns (uint160) {
        uint256 num;
        uint256 den;
        if (f.baseIsToken0) {
            num = answer * 10 ** f.decimals1;
            den = 10 ** (uint256(f.feedDecimals) + f.decimals0);
        } else {
            num = 10 ** (uint256(f.feedDecimals) + f.decimals1);
            den = answer * 10 ** f.decimals0;
        }
        // price < 2^64 keeps priceX192 in 256 bits.
        // shortcut: raw price must be < 2^64 (fine for WETH/USDC-style pairs); exotic pairs need a split sqrt
        if (num / den >= 1 << 64) revert IMandate.OracleStale();
        uint256 sqrtP = Math.sqrt(FullMath.mulDiv(num, 1 << 192, den));
        if (sqrtP < TickMath.MIN_SQRT_PRICE || sqrtP >= TickMath.MAX_SQRT_PRICE) revert IMandate.OracleStale();
        return uint160(sqrtP);
    }
}
