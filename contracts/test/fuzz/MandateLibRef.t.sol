// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Mandate, Range} from "../../src/interfaces/IMandate.sol";
import {MandateLibHarness} from "../unit/MandateLib.t.sol";

/// @dev MandateLib checked against a plain reference written a different way.
contract MandateLibRefTest is Test {
    MandateLibHarness h = new MandateLibHarness();
    int24 constant SPACING = 60;

    function _mandate() internal pure returns (Mandate memory) {
        return Mandate({
            maxOracleDistanceTicks: 1200,
            maxTurnoverBpsPerEpoch: 10_000,
            minWidthTicks: 120,
            maxRanges: 3,
            oracleBandBps: 100,
            cooldown: 60,
            maxDrawdownBps: 1_000,
            perfFeeBps: 1_000,
            epochLength: 5 minutes,
            amendmentDelay: 10 minutes,
            maxIdleEpochs: 12
        });
    }

    /// @dev Small tick domain so duplicates, misalignment, narrow and far ranges all show up often.
    function _ranges(uint256 seed, bool normalize) internal pure returns (Range[] memory r) {
        r = new Range[](seed % 5); // 0..4 ranges; maxRanges is 3
        uint256 sum;
        for (uint256 i; i < r.length; ++i) {
            uint256 x = uint256(keccak256(abi.encode(seed, i)));
            int24 lo = (int24(int256(x % 41)) - 20) * SPACING;
            int24 width = int24(int256((x >> 8) % 12)) * SPACING; // 0..660
            if ((x >> 16) % 8 == 0) lo += 7; // misaligned sometimes
            r[i] = Range(lo, lo + width, uint16((x >> 24) % 6_000));
            sum += r[i].weightBps;
        }
        if (normalize && r.length > 0 && sum - r[r.length - 1].weightBps < 10_000) {
            r[r.length - 1].weightBps = uint16(10_000 - (sum - r[r.length - 1].weightBps));
        }
    }

    // ---------------------------------------------------------------- reference: checkRanges

    function _refValid(Mandate memory m, Range[] memory r, int24 oracleTick) internal pure returns (bool) {
        if (r.length > m.maxRanges) return false;
        uint256 total;
        for (uint256 i; i < r.length; ++i) {
            int256 lo = r[i].tickLower;
            int256 hi = r[i].tickUpper;
            int256 o = oracleTick;
            int256 d = int256(uint256(m.maxOracleDistanceTicks));
            bool aligned = lo % SPACING == 0 && hi % SPACING == 0;
            bool inBounds = lo >= -887272 && hi <= 887272;
            bool wide = hi - lo >= int256(uint256(m.minWidthTicks));
            bool near = lo >= o - d && lo <= o + d && hi >= o - d && hi <= o + d;
            if (!aligned || !inBounds || !wide || !near || r[i].weightBps == 0) return false;
            for (uint256 j = i + 1; j < r.length; ++j) {
                if (r[j].tickLower == lo && r[j].tickUpper == hi) return false;
            }
            total += r[i].weightBps;
        }
        return total == 10_000;
    }

    function testFuzz_checkRanges_matchesReference(uint256 seed, int16 oracleTick, bool normalize) public view {
        Mandate memory m = _mandate();
        Range[] memory r = _ranges(seed, normalize);
        bool lib;
        try h.checkRanges(m, r, oracleTick, SPACING) {
            lib = true;
        } catch {}
        assertEq(lib, _refValid(m, r, oracleTick));
    }

    // ---------------------------------------------------------------- reference: turnover

    /// @dev Turnover = (sum old + sum new) / 2 - overlap, overlap = sum over shared keys of min(old, new).
    /// Equal to 1/2 * sum |new - old| over the union, but computed differently.
    function _refTurnover(Range[] memory o, Range[] memory n) internal pure returns (uint256) {
        uint256 so;
        uint256 sn;
        uint256 overlap;
        for (uint256 i; i < o.length; ++i) {
            so += o[i].weightBps;
        }
        for (uint256 i; i < n.length; ++i) {
            sn += n[i].weightBps;
            for (uint256 j; j < o.length; ++j) {
                if (o[j].tickLower == n[i].tickLower && o[j].tickUpper == n[i].tickUpper) {
                    overlap += o[j].weightBps < n[i].weightBps ? o[j].weightBps : n[i].weightBps;
                }
            }
        }
        return (so + sn) / 2 - overlap;
    }

    function testFuzz_turnover_matchesReference(uint256 seedOld, uint256 seedNew) public view {
        Mandate memory m = _mandate();
        Range[] memory o = _ranges(seedOld, true);
        Range[] memory n = _ranges(seedNew, true);
        // turnover is only defined between valid range sets (unique keys, weights summing to 10000)
        vm.assume(_refValid(m, n, 0) && (o.length == 0 || _refValid(m, o, 0)));
        assertEq(h.turnoverBps(o, n), _refTurnover(o, n));
    }
}
