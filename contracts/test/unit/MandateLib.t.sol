// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Mandate, Range, IMandate} from "../../src/interfaces/IMandate.sol";
import {MandateLib} from "../../src/libraries/MandateLib.sol";

/// @dev External wrapper so library reverts can be caught with expectRevert.
contract MandateLibHarness {
    function validateMandate(Mandate memory m) external pure {
        MandateLib.validateMandate(m);
    }

    function checkRanges(Mandate memory m, Range[] memory r, int24 oracleTick, int24 spacing) external pure {
        MandateLib.checkRanges(m, r, oracleTick, spacing);
    }

    function turnoverBps(Range[] memory o, Range[] memory n) external pure returns (uint256) {
        return MandateLib.turnoverBps(o, n);
    }

    function checkTurnover(Mandate memory m, uint256 soFar, uint256 t) external pure returns (uint256) {
        return MandateLib.checkTurnover(m, soFar, t);
    }

    function checkCooldown(Mandate memory m, uint256 last, uint256 nowTs) external pure {
        MandateLib.checkCooldown(m, last, nowTs);
    }

    function checkBand(Mandate memory m, uint160 pool, uint160 oracle) external pure {
        MandateLib.checkBand(m, pool, oracle);
    }

    function isBreached(Mandate memory m, uint256 index, uint256 peak) external pure returns (bool) {
        return MandateLib.isBreached(m, index, peak);
    }
}

contract MandateLibTest is Test {
    MandateLibHarness h;
    int24 constant SPACING = 60;
    int24 constant ORACLE_TICK = 0;

    function setUp() public {
        h = new MandateLibHarness();
    }

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
            epochLength: 300,
            amendmentDelay: 600,
            maxIdleEpochs: 12
        });
    }

    function _one(int24 lo, int24 hi, uint16 w) internal pure returns (Range[] memory r) {
        r = new Range[](1);
        r[0] = Range(lo, hi, w);
    }

    function _two(int24 lo0, int24 hi0, uint16 w0, int24 lo1, int24 hi1, uint16 w1)
        internal
        pure
        returns (Range[] memory r)
    {
        r = new Range[](2);
        r[0] = Range(lo0, hi0, w0);
        r[1] = Range(lo1, hi1, w1);
    }

    function _expectViolation(bytes32 term) internal {
        vm.expectRevert(abi.encodeWithSelector(IMandate.MandateViolation.selector, term));
    }

    // ---------------------------------------------------------------- validateMandate (one per term)

    function test_validate_pass() public view {
        h.validateMandate(_mandate());
    }

    function test_validate_cooldownZeroAllowed() public view {
        Mandate memory m = _mandate();
        m.cooldown = 0;
        h.validateMandate(m);
    }

    function test_validate_perfFeeAtCap() public view {
        Mandate memory m = _mandate();
        m.perfFeeBps = 2_000;
        h.validateMandate(m);
    }

    function test_validate_revert_maxOracleDistanceTicks() public {
        Mandate memory m = _mandate();
        m.maxOracleDistanceTicks = 0;
        _expectViolation("maxOracleDistanceTicks");
        h.validateMandate(m);
    }

    function test_validate_revert_maxTurnoverBpsPerEpoch() public {
        Mandate memory m = _mandate();
        m.maxTurnoverBpsPerEpoch = 0;
        _expectViolation("maxTurnoverBpsPerEpoch");
        h.validateMandate(m);
    }

    /// @dev A cap below 5,000 could never pay for the first deployment, so the vault would stay idle forever.
    function test_validate_turnoverFloor_isFirstDeploymentCost() public {
        Mandate memory m = _mandate();
        m.maxTurnoverBpsPerEpoch = 5_000;
        h.validateMandate(m);
        m.maxTurnoverBpsPerEpoch = 4_999;
        _expectViolation("maxTurnoverBpsPerEpoch");
        h.validateMandate(m);
    }

    function test_validate_revert_minWidthTicks() public {
        Mandate memory m = _mandate();
        m.minWidthTicks = 0;
        _expectViolation("minWidthTicks");
        h.validateMandate(m);
    }

    function test_validate_revert_maxRanges_zero() public {
        Mandate memory m = _mandate();
        m.maxRanges = 0;
        _expectViolation("maxRanges");
        h.validateMandate(m);
    }

    function test_validate_revert_maxRanges_aboveCap() public {
        Mandate memory m = _mandate();
        m.maxRanges = 11;
        _expectViolation("maxRanges");
        h.validateMandate(m);
    }

    function test_validate_revert_oracleBandBps() public {
        Mandate memory m = _mandate();
        m.oracleBandBps = 0;
        _expectViolation("oracleBandBps");
        h.validateMandate(m);
        m.oracleBandBps = 501; // just past the 5% cap
        _expectViolation("oracleBandBps");
        h.validateMandate(m);
        m.oracleBandBps = 500;
        h.validateMandate(m);
    }

    function test_validate_revert_maxDrawdownBps() public {
        Mandate memory m = _mandate();
        m.maxDrawdownBps = 0;
        _expectViolation("maxDrawdownBps");
        h.validateMandate(m);
        m.maxDrawdownBps = 10_000;
        _expectViolation("maxDrawdownBps");
        h.validateMandate(m);
    }

    function test_validate_revert_perfFeeBps() public {
        Mandate memory m = _mandate();
        m.perfFeeBps = 2_001;
        _expectViolation("perfFeeBps");
        h.validateMandate(m);
    }

    function test_validate_revert_epochLength() public {
        Mandate memory m = _mandate();
        m.epochLength = 0;
        _expectViolation("epochLength");
        h.validateMandate(m);
    }

    function test_validate_revert_amendmentDelay() public {
        Mandate memory m = _mandate();
        m.amendmentDelay = 0;
        _expectViolation("amendmentDelay");
        h.validateMandate(m);
    }

    function test_validate_revert_maxIdleEpochs() public {
        Mandate memory m = _mandate();
        m.maxIdleEpochs = 0;
        _expectViolation("maxIdleEpochs");
        h.validateMandate(m);
    }

    // ---------------------------------------------------------------- checkRanges

    function test_ranges_pass() public view {
        h.checkRanges(_mandate(), _two(-600, 600, 6_000, -1200, 1200, 4_000), ORACLE_TICK, SPACING);
    }

    function test_ranges_pass_atExactLimits() public view {
        // edges exactly maxOracleDistanceTicks away, width exactly minWidthTicks
        h.checkRanges(_mandate(), _two(-1200, -1080, 5_000, 1080, 1200, 5_000), ORACLE_TICK, SPACING);
    }

    function test_ranges_revert_maxOracleDistanceTicks_lower() public {
        _expectViolation("maxOracleDistanceTicks");
        h.checkRanges(_mandate(), _one(-1260, 0, 10_000), ORACLE_TICK, SPACING);
    }

    function test_ranges_revert_maxOracleDistanceTicks_upper() public {
        _expectViolation("maxOracleDistanceTicks");
        h.checkRanges(_mandate(), _one(0, 1260, 10_000), ORACLE_TICK, SPACING);
    }

    function test_ranges_distanceIsFromOracleTick() public {
        // same range is fine when the oracle has moved next to it
        h.checkRanges(_mandate(), _one(6000, 6600, 10_000), 6000, SPACING);
        _expectViolation("maxOracleDistanceTicks");
        h.checkRanges(_mandate(), _one(6000, 6600, 10_000), ORACLE_TICK, SPACING);
    }

    function test_ranges_revert_minWidthTicks() public {
        _expectViolation("minWidthTicks");
        h.checkRanges(_mandate(), _one(0, 60, 10_000), ORACLE_TICK, SPACING);
    }

    function test_ranges_revert_invertedRange() public {
        _expectViolation("minWidthTicks");
        h.checkRanges(_mandate(), _one(600, -600, 10_000), ORACLE_TICK, SPACING);
    }

    function test_ranges_revert_maxRanges() public {
        Range[] memory r = new Range[](4);
        r[0] = Range(-600, 600, 2_500);
        r[1] = Range(-660, 600, 2_500);
        r[2] = Range(-720, 600, 2_500);
        r[3] = Range(-780, 600, 2_500);
        _expectViolation("maxRanges");
        h.checkRanges(_mandate(), r, ORACLE_TICK, SPACING);
    }

    function test_ranges_revert_weightsNot10000() public {
        _expectViolation("weights");
        h.checkRanges(_mandate(), _two(-600, 600, 5_000, -1200, 1200, 4_999), ORACLE_TICK, SPACING);
    }

    function test_ranges_revert_emptyRanges() public {
        _expectViolation("weights");
        h.checkRanges(_mandate(), new Range[](0), ORACLE_TICK, SPACING);
    }

    function test_ranges_revert_zeroWeight() public {
        _expectViolation("weights");
        h.checkRanges(_mandate(), _two(-600, 600, 10_000, -1200, 1200, 0), ORACLE_TICK, SPACING);
    }

    function test_ranges_revert_tickSpacing() public {
        _expectViolation("tickSpacing");
        h.checkRanges(_mandate(), _one(-610, 600, 10_000), ORACLE_TICK, SPACING);
    }

    function test_ranges_revert_duplicate() public {
        _expectViolation("duplicateRange");
        h.checkRanges(_mandate(), _two(-600, 600, 5_000, -600, 600, 5_000), ORACLE_TICK, SPACING);
    }

    function test_ranges_revert_tickBounds() public {
        Mandate memory m = _mandate();
        m.maxOracleDistanceTicks = type(uint24).max;
        int24 lo = (TickMath.MIN_TICK / SPACING - 1) * SPACING;
        _expectViolation("tickBounds");
        h.checkRanges(m, _one(lo, 0, 10_000), ORACLE_TICK, SPACING);
    }

    // ---------------------------------------------------------------- turnover

    function test_turnover_fromEmpty() public view {
        assertEq(h.turnoverBps(new Range[](0), _one(-600, 600, 10_000)), 5_000);
    }

    function test_turnover_noChange() public view {
        Range[] memory a = _two(-600, 600, 6_000, -1200, 1200, 4_000);
        assertEq(h.turnoverBps(a, a), 0);
    }

    function test_turnover_fullSwitch() public view {
        assertEq(h.turnoverBps(_one(-600, 600, 10_000), _one(-1200, 1200, 10_000)), 10_000);
    }

    function test_turnover_partialReweight() public view {
        // 60/40 -> 40/60: |20%| + |20%|, halved = 20%
        uint256 t =
            h.turnoverBps(_two(-600, 600, 6_000, -1200, 1200, 4_000), _two(-1200, 1200, 6_000, -600, 600, 4_000));
        assertEq(t, 2_000);
    }

    function test_turnover_pass_underCap() public view {
        assertEq(h.checkTurnover(_mandate(), 4_000, 6_000), 10_000);
    }

    function test_turnover_revert_maxTurnoverBpsPerEpoch_runningSum() public {
        // A -> B -> A counts twice: 10000 + 10000 > 10000
        Range[] memory a = _one(-600, 600, 10_000);
        Range[] memory b = _one(-1200, 1200, 10_000);
        uint256 soFar = h.checkTurnover(_mandate(), 0, h.turnoverBps(a, b));
        uint256 back = h.turnoverBps(b, a);
        _expectViolation("maxTurnoverBpsPerEpoch");
        h.checkTurnover(_mandate(), soFar, back);
    }

    // ---------------------------------------------------------------- cooldown

    function test_cooldown_pass_firstRebalance() public view {
        h.checkCooldown(_mandate(), 0, 1);
    }

    function test_cooldown_pass_exactlyElapsed() public view {
        h.checkCooldown(_mandate(), 1_000, 1_060);
    }

    function test_cooldown_revert() public {
        _expectViolation("cooldown");
        h.checkCooldown(_mandate(), 1_000, 1_059);
    }

    // ---------------------------------------------------------------- band (1% = 100 bps)

    uint160 constant ORACLE_SQRT = 79228162514264337593543950336; // 1.0 in Q96

    function test_band_pass_equal() public view {
        h.checkBand(_mandate(), ORACLE_SQRT, ORACLE_SQRT);
    }

    function test_band_pass_justInside() public view {
        // sqrt(1.0099) ~= 1.004938 -> price +0.99%
        h.checkBand(_mandate(), uint160(uint256(ORACLE_SQRT) * 1_004_938 / 1_000_000), ORACLE_SQRT);
        // sqrt(0.9901) ~= 0.995038 -> price -0.99%
        h.checkBand(_mandate(), uint160(uint256(ORACLE_SQRT) * 995_038 / 1_000_000), ORACLE_SQRT);
    }

    function test_band_revert_above() public {
        // sqrt(1.0102) ~= 1.005087 -> price +1.02%
        _expectViolation("oracleBandBps");
        h.checkBand(_mandate(), uint160(uint256(ORACLE_SQRT) * 1_005_087 / 1_000_000), ORACLE_SQRT);
    }

    function test_band_revert_below() public {
        // sqrt(0.9898) ~= 0.994887 -> price -1.02%
        _expectViolation("oracleBandBps");
        h.checkBand(_mandate(), uint160(uint256(ORACLE_SQRT) * 994_887 / 1_000_000), ORACLE_SQRT);
    }

    function test_band_revert_extremeRatioDoesNotOverflow() public {
        _expectViolation("oracleBandBps");
        h.checkBand(_mandate(), TickMath.MAX_SQRT_PRICE - 1, TickMath.MIN_SQRT_PRICE);
    }

    // ---------------------------------------------------------------- drawdown (10%)

    function test_drawdown_notBreached_atLimit() public view {
        assertFalse(h.isBreached(_mandate(), 0.9e18, 1e18));
    }

    function test_drawdown_breached() public view {
        assertTrue(h.isBreached(_mandate(), 0.9e18 - 1, 1e18));
    }
}
