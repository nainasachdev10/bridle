// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {FullMath} from "@uniswap/v4-core/src/libraries/FullMath.sol";
import {FixedPoint96} from "@uniswap/v4-core/src/libraries/FixedPoint96.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Mandate, Range, IMandate} from "../interfaces/IMandate.sol";

/// @notice Pure checks of a mandate, and of an intent against a mandate and the current state.
/// Every failure reverts MandateViolation(term) where term names the field that was broken.
library MandateLib {
    uint256 internal constant BPS = 10_000;
    /// @dev Immutable cap on the performance fee (20%).
    uint16 internal constant MAX_PERF_FEE_BPS = 2_000;
    /// @dev Hard cap on ranges, bounds the gas of turnover and NAV loops.
    uint8 internal constant MAX_RANGES_CAP = 10;
    /// @dev Widest allowed oracle band (5%). A wider band would let a curator sandwich their own rebalance.
    uint16 internal constant MAX_BAND_BPS = 500;

    /// @notice Sanity-check a mandate when a pool is registered (and later, when it is amended).
    function validateMandate(Mandate memory m) internal pure {
        if (m.maxOracleDistanceTicks == 0) _violation("maxOracleDistanceTicks");
        // Deploying from all-idle costs BPS/2 (weights sum to BPS, old weights are 0); a lower cap could never deploy.
        if (m.maxTurnoverBpsPerEpoch < BPS / 2) _violation("maxTurnoverBpsPerEpoch");
        if (m.minWidthTicks == 0) _violation("minWidthTicks");
        if (m.maxRanges == 0 || m.maxRanges > MAX_RANGES_CAP) _violation("maxRanges");
        if (m.oracleBandBps == 0 || m.oracleBandBps > MAX_BAND_BPS) _violation("oracleBandBps");
        // cooldown = 0 is a valid choice (no wait between rebalances).
        if (m.maxDrawdownBps == 0 || m.maxDrawdownBps >= BPS) _violation("maxDrawdownBps");
        if (m.perfFeeBps > MAX_PERF_FEE_BPS) _violation("perfFeeBps");
        if (m.epochLength == 0) _violation("epochLength");
        if (m.amendmentDelay == 0) _violation("amendmentDelay");
        if (m.maxIdleEpochs == 0) _violation("maxIdleEpochs");
    }

    /// @notice Shape checks on the target ranges of an intent.
    function checkRanges(Mandate memory m, Range[] memory ranges, int24 oracleTick, int24 tickSpacing) internal pure {
        if (ranges.length > m.maxRanges) _violation("maxRanges");

        uint256 weightSum;
        for (uint256 i; i < ranges.length; ++i) {
            Range memory r = ranges[i];
            if (r.tickLower % tickSpacing != 0 || r.tickUpper % tickSpacing != 0) _violation("tickSpacing");
            if (r.tickLower < TickMath.MIN_TICK || r.tickUpper > TickMath.MAX_TICK) _violation("tickBounds");
            if (int256(r.tickUpper) - r.tickLower < int256(uint256(m.minWidthTicks))) _violation("minWidthTicks");
            if (
                _absDiff(r.tickLower, oracleTick) > m.maxOracleDistanceTicks
                    || _absDiff(r.tickUpper, oracleTick) > m.maxOracleDistanceTicks
            ) _violation("maxOracleDistanceTicks");
            if (r.weightBps == 0) _violation("weights");
            for (uint256 j; j < i; ++j) {
                if (_sameKey(ranges[j], r)) _violation("duplicateRange");
            }
            weightSum += r.weightBps;
        }
        if (weightSum != BPS) _violation("weights");
    }

    /// @notice Turnover of one rebalance: 1/2 * sum |w_new(r) - w_old(r)| over the union of ranges
    /// keyed by (tickLower, tickUpper). Both sides sum to 10000 (or old is empty), so the sum is even.
    function turnoverBps(Range[] memory oldRanges, Range[] memory newRanges) internal pure returns (uint256) {
        uint256 sum;
        for (uint256 i; i < newRanges.length; ++i) {
            uint256 wOld;
            for (uint256 j; j < oldRanges.length; ++j) {
                if (_sameKey(oldRanges[j], newRanges[i])) wOld = oldRanges[j].weightBps;
            }
            uint256 wNew = newRanges[i].weightBps;
            sum += wNew > wOld ? wNew - wOld : wOld - wNew;
        }
        for (uint256 j; j < oldRanges.length; ++j) {
            bool kept;
            for (uint256 i; i < newRanges.length; ++i) {
                if (_sameKey(oldRanges[j], newRanges[i])) kept = true;
            }
            if (!kept) sum += oldRanges[j].weightBps;
        }
        return sum / 2;
    }

    /// @notice Adds a rebalance's turnover to the epoch's running sum and checks the cap.
    function checkTurnover(Mandate memory m, uint256 epochTurnoverSoFar, uint256 turnover)
        internal
        pure
        returns (uint256 newEpochTurnover)
    {
        newEpochTurnover = epochTurnoverSoFar + turnover;
        if (newEpochTurnover > m.maxTurnoverBpsPerEpoch) _violation("maxTurnoverBpsPerEpoch");
    }

    function checkCooldown(Mandate memory m, uint256 lastRebalanceAt, uint256 nowTs) internal pure {
        if (lastRebalanceAt != 0 && nowTs < lastRebalanceAt + m.cooldown) _violation("cooldown");
    }

    function checkBand(Mandate memory m, uint160 poolSqrtPriceX96, uint160 oracleSqrtPriceX96) internal pure {
        if (!withinBand(poolSqrtPriceX96, oracleSqrtPriceX96, m.oracleBandBps)) _violation("oracleBandBps");
    }

    /// @notice |poolPrice / oraclePrice - 1| <= bandBps, with price = sqrtPrice^2.
    function withinBand(uint160 poolSqrtPriceX96, uint160 oracleSqrtPriceX96, uint256 bandBps)
        internal
        pure
        returns (bool)
    {
        uint256 sqrtRatioX96 = FullMath.mulDiv(poolSqrtPriceX96, FixedPoint96.Q96, oracleSqrtPriceX96);
        // price ratio >= 4 is far outside any allowed band; also keeps the square below from overflowing.
        if (sqrtRatioX96 >= 2 * FixedPoint96.Q96) return false;
        uint256 priceRatioX96 = FullMath.mulDiv(sqrtRatioX96, sqrtRatioX96, FixedPoint96.Q96);
        uint256 lower = FixedPoint96.Q96 * (BPS - bandBps) / BPS;
        uint256 upper = FixedPoint96.Q96 * (BPS + bandBps) / BPS;
        return priceRatioX96 >= lower && priceRatioX96 <= upper;
    }

    /// @notice Drawdown breach on the excess-return index (1e18 = 1.0).
    function isBreached(Mandate memory m, uint256 index, uint256 peakIndex) internal pure returns (bool) {
        return index * BPS < peakIndex * (BPS - m.maxDrawdownBps);
    }

    function _sameKey(Range memory a, Range memory b) private pure returns (bool) {
        return a.tickLower == b.tickLower && a.tickUpper == b.tickUpper;
    }

    function _absDiff(int24 a, int24 b) private pure returns (uint256) {
        int256 d = int256(a) - int256(b);
        return uint256(d >= 0 ? d : -d);
    }

    function _violation(bytes32 term) private pure {
        revert IMandate.MandateViolation(term);
    }
}
