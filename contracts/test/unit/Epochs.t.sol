// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {EpochRecord, IMandate} from "../../src/interfaces/IMandate.sol";
import {BridleHook} from "../../src/BridleHook.sol";
import {BridleVault} from "../../src/BridleVault.sol";
import {BridleFixture} from "../utils/BridleFixture.sol";

contract EpochsTest is BridleFixture {
    uint256 constant WAD = 1e18;

    IERC20 t0;
    IERC20 t1;
    PoolId id;
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");

    function setUp() public override {
        super.setUp();
        id = key.toId();
        t0 = IERC20(Currency.unwrap(currency0));
        t1 = IERC20(Currency.unwrap(currency1));
        for (uint256 i; i < 2; ++i) {
            address u = i == 0 ? alice : bob;
            t0.transfer(u, 1e30);
            t1.transfer(u, 1e30);
            vm.startPrank(u);
            t0.approve(address(vault), type(uint256).max);
            t1.approve(address(vault), type(uint256).max);
            vm.stopPrank();
        }
    }

    // ---------------------------------------------------------------- helpers

    function _deposit(address who, uint256 a0, uint256 a1) internal returns (uint256 shares) {
        vm.prank(who);
        (shares,,) = vault.deposit(a0, a1, 0, who);
    }

    /// @dev Alice deposits 100/100 and the curator deploys it all into one range around the price.
    function _funded() internal {
        _deposit(alice, 100e18, 100e18);
        queue(oneRange(-600, 600));
        hook.executeQueued(id);
    }

    /// @dev Next epoch, with a fresh oracle answer.
    function _nextEpoch(int256 answer) internal {
        vm.warp(block.timestamp + 5 minutes);
        oracle.set(answer);
    }

    /// @dev Round-trip swaps: price ends near where it started, LPs earn the 0.3% fee on each leg.
    function _churn(uint256 rounds) internal {
        for (uint256 i; i < rounds; ++i) {
            swap(key, true, -10e18, ZERO_BYTES);
            swap(key, false, -10e18, ZERO_BYTES);
        }
    }

    function _close() internal returns (EpochRecord memory) {
        return vault.closeEpoch();
    }

    /// @dev Fee from CLAUDE.md, computed independently: f = perfFee * (index - hwm) / index; shares = S f / (1 - f).
    function _expectedFee(uint256 supply, uint256 idx, uint256 hwm) internal view returns (uint256) {
        uint256 f = (idx - hwm) * testMandate().perfFeeBps * 1e14 / idx;
        return supply * f / (WAD - f);
    }

    // ================================================================ scoring

    function test_close_holdOnly_ratioIsOne_noFee() public {
        _deposit(alice, 100e18, 100e18); // all idle: the vault is literally holding
        _nextEpoch(1.2e8); // even a big price move can't make idle differ from holding
        EpochRecord memory r = _close();
        assertEq(r.ratio, WAD);
        assertEq(r.index, WAD);
        assertEq(r.feeShares, 0);
        assertEq(vault.highWaterMark(), WAD);
        assertEq(vault.recordCount(), 1);
    }

    function test_close_lpFees_ratioAboveOne_feeMinted() public {
        _funded();
        _churn(5);
        _nextEpoch(1e8);
        uint256 supply = vault.totalSupply();
        EpochRecord memory r = _close();

        emit log_named_decimal_uint("ratio after 5 round trips", r.ratio, 18);
        assertGt(r.ratio, WAD, "fees beat holding");
        assertEq(r.index, r.ratio);
        assertEq(r.highWaterMark, r.index);
        assertEq(r.feeShares, _expectedFee(supply, r.index, WAD));
        assertGt(r.feeShares, 0);
        // the fee is the curator's bond, held by the vault, worth f of the vault
        assertEq(vault.bondShares(), r.feeShares);
        assertEq(vault.balanceOf(address(vault)), r.feeShares);
        assertEq(vault.balanceOf(curator), 0);
    }

    function test_close_priceMove_impermanentLoss_ratioBelowOne_noFee() public {
        _funded();
        _nextEpoch(1.05e8); // valued at the oracle: the range sold token0 on the way up
        EpochRecord memory r = _close();
        emit log_named_decimal_uint("ratio after +5% oracle move", r.ratio, 18);
        assertLt(r.ratio, WAD, "LP loses to holding on a price move");
        assertEq(r.feeShares, 0);
        assertEq(vault.highWaterMark(), WAD);
    }

    function test_close_feeOnlyAboveHighWaterMark() public {
        _funded();
        _churn(5);
        _nextEpoch(1e8);
        EpochRecord memory r1 = _close();
        uint256 hwm1 = r1.index;
        assertGt(hwm1, WAD);

        // epoch 2: a loss, no fee, hwm stays
        _nextEpoch(1.01e8);
        EpochRecord memory r2 = _close();
        assertLt(r2.index, hwm1);
        assertEq(r2.feeShares, 0);
        assertEq(vault.highWaterMark(), hwm1);

        // epoch 3: enough fees to pass the old peak; the fee is only on the part above hwm1
        _churn(40);
        _nextEpoch(1.01e8);
        uint256 supply = vault.totalSupply();
        EpochRecord memory r3 = _close();
        assertGt(r3.index, hwm1, "recovered past the peak");
        assertEq(r3.feeShares, _expectedFee(supply, r3.index, hwm1));
        assertEq(vault.highWaterMark(), r3.index);
    }

    function test_close_recoveryBelowHighWaterMark_paysNoFee() public {
        _funded();
        _nextEpoch(1.05e8);
        EpochRecord memory r1 = _close();
        assertLt(r1.index, WAD);

        _churn(1); // some fees: ratio > 1 this epoch, but the index is still under the hwm
        _nextEpoch(1.05e8);
        EpochRecord memory r2 = _close();
        assertGt(r2.ratio, WAD);
        assertLt(r2.index, WAD);
        assertEq(r2.feeShares, 0);
    }

    /// @dev Deposits and withdrawals are pro rata in kind, so they must not change what a share is worth
    /// relative to holding. Same epoch (same swaps) with and without a mid-epoch deposit + withdrawal.
    function test_close_midEpochDepositAndWithdraw_dontMoveRatio() public {
        _funded();
        _churn(3); // fees accrue and stay uncollected until the next action
        uint256 snap = vm.snapshotState();

        _nextEpoch(1.002e8);
        uint256 ratioQuiet = _close().ratio;
        vm.revertToState(snap);

        uint256 bobShares = _deposit(bob, 50e18, 50e18);
        vm.prank(bob);
        vault.withdraw(bobShares / 3, 0, 0, bob);
        vm.prank(alice);
        vault.withdraw(10e18, 0, 0, alice);
        _nextEpoch(1.002e8);
        uint256 ratioBusy = _close().ratio;

        emit log_named_decimal_uint("ratio quiet", ratioQuiet, 18);
        emit log_named_decimal_uint("ratio busy ", ratioBusy, 18);
        assertGe(ratioBusy, ratioQuiet, "rounding favours the vault");
        assertApproxEqRel(ratioBusy, ratioQuiet, 1e3); // within 1e-15
    }

    // ================================================================ bond hand-off

    function test_bond_releasedToCuratorAtNextClose() public {
        _funded();
        _churn(5);
        _nextEpoch(1e8);
        uint256 fee = _close().feeShares;
        assertGt(fee, 0);

        _nextEpoch(1e8);
        _close();
        assertEq(vault.balanceOf(curator), fee, "bond survived an epoch");
        assertEq(vault.balanceOf(address(vault)), vault.bondShares());
    }

    // ================================================================ bookkeeping

    function test_close_recordsTurnoverOfTheEpoch() public {
        _funded(); // first deployment in epoch 0: 5,000 bps
        _nextEpoch(1e8);
        assertEq(_close().turnoverBps, 5_000);
        _nextEpoch(1e8);
        assertEq(_close().turnoverBps, 0);
    }

    function test_close_afterSkippedEpochs_coversTheGap() public {
        _deposit(alice, 100e18, 100e18);
        vm.warp(block.timestamp + 3 * 5 minutes);
        oracle.set(1e8);
        EpochRecord memory r = _close();
        assertEq(r.epoch, 0);
        assertEq(vault.currentEpoch(), 3);
    }

    function test_close_snapshotStartsWithFirstDeposit() public {
        vm.warp(block.timestamp + 2 * 5 minutes);
        oracle.set(1e8);
        _deposit(alice, 100e18, 50e18);
        assertEq(vault.currentEpoch(), 2);
        assertEq(vault.holdAmount0(), 100e18);
        assertEq(vault.holdAmount1(), 50e18);
        assertEq(vault.holdSupply(), vault.totalSupply());
    }

    // ================================================================ reverts

    function test_close_revert_noDeposits() public {
        _nextEpoch(1e8);
        vm.expectRevert(BridleVault.NothingToClose.selector);
        _close();
    }

    function test_close_revert_epochNotOver() public {
        _deposit(alice, 100e18, 100e18);
        vm.expectRevert(BridleVault.EpochNotOver.selector);
        _close();
    }

    function test_close_revert_twiceInOneEpoch() public {
        _deposit(alice, 100e18, 100e18);
        _nextEpoch(1e8);
        _close();
        vm.expectRevert(BridleVault.EpochNotOver.selector);
        _close();
    }

    function test_close_revert_oracleStale_withdrawStillWorks() public {
        _deposit(alice, 100e18, 100e18);
        vm.warp(block.timestamp + 2 hours); // no oracle update
        vm.expectRevert(IMandate.OracleStale.selector);
        _close();
        vm.prank(alice);
        vault.withdraw(1e18, 0, 0, alice);
    }

    function test_collectFees_revert_notVault() public {
        vm.expectRevert(BridleHook.NotVault.selector);
        hook.collectFees(id);
    }

    // ================================================================ math

    function test_feeShares_giveCuratorExactlyF() public pure {
        // index 1.2, hwm 1.0, perfFee 10%: f = 0.1 * 0.2 / 1.2 = 1/60 of the vault after minting
        uint256 supply = 1_000_000e18;
        uint256 f = uint256(0.2e18) * 1_000 * 1e14 / 1.2e18;
        uint256 shares = supply * f / (WAD - f);
        assertApproxEqRel(shares * WAD / (supply + shares), WAD / 60, 1e6);
    }
}
