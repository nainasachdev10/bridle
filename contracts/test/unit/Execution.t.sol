// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {stdError} from "forge-std/StdError.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {IMandate, Mandate, Range, RebalanceIntent} from "../../src/interfaces/IMandate.sol";
import {BridleHook} from "../../src/BridleHook.sol";
import {BridleVault} from "../../src/BridleVault.sol";
import {BridleFixture} from "../utils/BridleFixture.sol";

contract ExecutionTest is BridleFixture {
    using StateLibrary for IPoolManager;

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
        _deposit(alice, 100e18, 100e18);
        bondCurator();
    }

    // ---------------------------------------------------------------- helpers

    function _deposit(address who, uint256 a0, uint256 a1) internal returns (uint256 shares) {
        vm.prank(who);
        (shares,,) = vault.deposit(a0, a1, 0, who);
    }

    function _idle() internal view returns (uint256 i0, uint256 i1) {
        (i0, i1,,,,) = hook.poolState(id);
    }

    function _queued() internal view returns (bool) {
        return hook.queuedIntent(id).deadline != 0;
    }

    /// @dev Idle claims the hook holds must equal what the pool's accounting says.
    function _assertClaimsMatchIdle() internal view {
        (uint256 i0, uint256 i1) = _idle();
        assertEq(manager.balanceOf(address(hook), currency0.toId()), i0, "claims0");
        assertEq(manager.balanceOf(address(hook), currency1.toId()), i1, "claims1");
    }

    function _deployed() internal {
        queue(oneRange(-600, 600));
        hook.executeQueued(id);
    }

    function _violation(bytes32 term) internal pure returns (bytes memory) {
        return abi.encodeWithSelector(IMandate.MandateViolation.selector, term);
    }

    // ================================================================ deposits: oracle guard

    function test_deposit_revert_outOfBand() public {
        oracle.set(1.05e8); // pool 1.0 vs oracle 1.05: 5% > 1% band
        vm.prank(bob);
        vm.expectRevert(IMandate.OutOfBand.selector);
        vault.deposit(1e18, 1e18, 0, bob);
    }

    function test_deposit_revert_oracleStale() public {
        vm.warp(block.timestamp + 1 hours + 1);
        vm.prank(bob);
        vm.expectRevert(IMandate.OracleStale.selector);
        vault.deposit(1e18, 1e18, 0, bob);
    }

    function test_deposit_insideBand() public {
        oracle.set(1.009e8);
        assertGt(_deposit(bob, 1e18, 1e18), 0);
    }

    function test_deposit_refundsUnused() public {
        uint256 before1 = t1.balanceOf(bob);
        vm.prank(bob);
        (, uint256 a0, uint256 a1) = vault.deposit(1e18, 5e18, 0, bob);
        assertEq(a0, 1e18);
        assertEq(a1, 1e18);
        assertEq(before1 - t1.balanceOf(bob), 1e18);
        assertEq(t0.balanceOf(address(hook)), 0);
        assertEq(t1.balanceOf(address(hook)), 0);
    }

    function test_init_revert_outOfBand() public {
        PoolKey memory other = PoolKey(currency0, currency1, 500, 10, IHooks(address(hook)));
        new BridleVault(hook, other, feedConfig(), curator, testMandate(), MIN_BOND, "x", "x");
        oracle.set(1.05e8);
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(IMandate.OutOfBand.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        manager.initialize(other, SQRT_PRICE_1_1);
    }

    // ================================================================ withdrawals: never need the oracle

    function test_withdraw_worksWithOracleStale() public {
        _deployed();
        vm.warp(block.timestamp + 30 days);
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        (uint256 a0, uint256 a1) = vault.withdraw(shares, 0, 0, alice);
        assertApproxEqAbs(a0, 100e18, 1e6);
        assertApproxEqAbs(a1, 100e18, 1e6);
    }

    function test_withdraw_worksWithOracleReverting() public {
        _deployed();
        oracle.setBroken(true);
        uint256 shares = vault.balanceOf(alice);
        vm.prank(alice);
        vault.withdraw(shares / 2, 0, 0, alice);
    }

    function test_withdraw_proRataAcrossPositionsAndIdle() public {
        _deployed();
        BridleHook.Position[] memory ps = hook.positions(id);
        (uint256 idle0,) = _idle();
        uint256 supply = vault.totalSupply();
        uint256 half = vault.balanceOf(alice) / 2;

        vm.prank(alice);
        vault.withdraw(half, 0, 0, alice);

        BridleHook.Position[] memory after_ = hook.positions(id);
        (uint256 idle0After,) = _idle();
        assertEq(after_[0].liquidity, ps[0].liquidity - uint128(uint256(ps[0].liquidity) * half / supply));
        assertEq(idle0After, idle0 - idle0 * half / supply);
        _assertClaimsMatchIdle();
    }

    // ================================================================ deposits across positions

    function test_deposit_proRataAcrossPositions() public {
        _deployed();
        uint128 liqBefore = hook.positions(id)[0].liquidity;
        uint256 supply = vault.totalSupply();
        uint256 shares = _deposit(bob, 10e18, 10e18);

        uint128 liqAfter = hook.positions(id)[0].liquidity;
        assertApproxEqAbs(liqAfter - liqBefore, uint256(liqBefore) * shares / supply, 1);
        _assertClaimsMatchIdle();

        // and back out: bob gets what he paid, minus rounding dust
        vm.prank(bob);
        (uint256 a0, uint256 a1) = vault.withdraw(shares, 0, 0, bob);
        assertApproxEqAbs(a0, 10e18, 1e6);
        assertApproxEqAbs(a1, 10e18, 1e6);
    }

    function testFuzz_deposit_neverPullsMoreThanMax(uint256 max0, uint256 max1) public {
        _deployed();
        max0 = bound(max0, 1e12, 1e24);
        max1 = bound(max1, 1e12, 1e24);
        uint256 b0 = t0.balanceOf(bob);
        uint256 b1 = t1.balanceOf(bob);
        vm.prank(bob);
        (uint256 shares, uint256 a0, uint256 a1) = vault.deposit(max0, max1, 0, bob);
        assertGt(shares, 0);
        assertLe(a0, max0);
        assertLe(a1, max1);
        assertEq(b0 - t0.balanceOf(bob), a0);
        assertEq(b1 - t1.balanceOf(bob), a1);
        _assertClaimsMatchIdle();
    }

    function test_deposit_revert_slippageOnMinShares() public {
        _deployed();
        vm.prank(bob);
        vm.expectRevert(BridleVault.Slippage.selector);
        vault.deposit(1e18, 1e18, 2e18, bob);
    }

    function test_fees_notStolenByLateWithdrawer() public {
        _deployed();
        uint256 bobShares = _deposit(bob, 1e18, 1e18);
        // trading inside the range accrues fees to the hook's position
        for (uint256 i; i < 5; ++i) {
            swap(key, true, -20e18, ZERO_BYTES);
            swap(key, false, -20e18, ZERO_BYTES);
        }
        vm.prank(bob);
        (uint256 a0, uint256 a1) = vault.withdraw(bobShares, 0, 0, bob);
        // ~200e18 volume at 0.3% = ~0.6e18 fees; bob owns ~1% of the vault so earns ~0.006e18, not all of it
        assertLt(a0 + a1, 2e18 + 0.02e18);
        assertGt(a0 + a1, 2e18 - 0.02e18);
        _assertClaimsMatchIdle();
    }

    // ================================================================ queueIntent

    function test_queue_storesIntent() public {
        queue(oneRange(-600, 600));
        BridleHook.QueuedIntent memory q = hook.queuedIntent(id);
        assertEq(q.deadline, block.timestamp + 1 hours);
        assertEq(q.ranges.length, 1);
        assertEq(hook.nonces(curator), 1);
    }

    function test_queue_replacesOlder() public {
        queue(oneRange(-600, 600));
        queue(oneRange(-1200, 1200));
        BridleHook.QueuedIntent memory q = hook.queuedIntent(id);
        assertEq(q.ranges.length, 1);
        assertEq(q.ranges[0].tickLower, -1200);
    }

    function test_queue_revert_notCurator() public {
        uint256 otherPk = 0xBAD;
        RebalanceIntent memory i =
            RebalanceIntent(PoolId.unwrap(id), vm.addr(otherPk), oneRange(-600, 600), 0, block.timestamp + 1);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(otherPk, hook.hashIntent(i));
        vm.expectRevert(IMandate.NotCurator.selector);
        hook.queueIntent(i, abi.encodePacked(r, s, v));
    }

    function test_queue_revert_badSignature() public {
        RebalanceIntent memory i =
            RebalanceIntent(PoolId.unwrap(id), curator, oneRange(-600, 600), 0, block.timestamp + 1);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(0xBAD, hook.hashIntent(i));
        vm.expectRevert(IMandate.BadSignature.selector);
        hook.queueIntent(i, abi.encodePacked(r, s, v));
    }

    function test_queue_revert_unregisteredPool() public {
        RebalanceIntent memory i =
            RebalanceIntent(keccak256("nope"), curator, oneRange(-600, 600), 0, block.timestamp + 1);
        vm.expectRevert(BridleHook.PoolNotRegistered.selector);
        hook.queueIntent(i, "");
    }

    function test_queue_revert_rangeViolation() public {
        RebalanceIntent memory i =
            RebalanceIntent(PoolId.unwrap(id), curator, oneRange(-600, 1800), 0, block.timestamp + 1);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(curatorPk, hook.hashIntent(i));
        vm.expectRevert(_violation("maxOracleDistanceTicks"));
        hook.queueIntent(i, abi.encodePacked(r, s, v));
    }

    function test_queue_revert_oracleStale() public {
        RebalanceIntent memory i =
            RebalanceIntent(PoolId.unwrap(id), curator, oneRange(-600, 600), 0, block.timestamp + 2 hours);
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(curatorPk, hook.hashIntent(i));
        vm.warp(block.timestamp + 1 hours + 1);
        vm.expectRevert(IMandate.OracleStale.selector);
        hook.queueIntent(i, abi.encodePacked(r, s, v));
    }

    // ================================================================ executeQueued

    function test_execute_deploysAndNetsToZero() public {
        _deployed();
        BridleHook.Position[] memory ps = hook.positions(id);
        assertEq(ps.length, 1);
        assertGt(ps[0].liquidity, 0);
        assertFalse(_queued());
        // a symmetric range at price 1.0 takes (almost) all of both tokens
        (uint256 i0, uint256 i1) = _idle();
        assertLt(i0, 1e6);
        assertLt(i1, 1e6);
        _assertClaimsMatchIdle();
        assertEq(
            manager.getPositionLiquidity(
                id, keccak256(abi.encodePacked(address(hook), int24(-600), int24(600), bytes32(0)))
            ),
            ps[0].liquidity
        );
    }

    function test_execute_revert_nothingQueued() public {
        vm.expectRevert(BridleHook.NothingQueued.selector);
        hook.executeQueued(id);
    }

    function test_execute_revert_cooldown() public {
        _deployed();
        queue(oneRange(-1200, 1200));
        vm.expectRevert(_violation("cooldown"));
        hook.executeQueued(id);
    }

    function test_execute_revert_turnoverRunningSum() public {
        _deployed(); // 5000 bps
        vm.warp(block.timestamp + 60);
        oracle.set(1e8);
        queue(oneRange(-1200, 1200)); // full switch: 10000 bps -> 15000 > 10000
        vm.expectRevert(_violation("maxTurnoverBpsPerEpoch"));
        hook.executeQueued(id);

        vm.warp(block.timestamp + 5 minutes); // next epoch resets the running sum
        oracle.set(1e8);
        hook.executeQueued(id);
        assertEq(hook.positions(id)[0].tickLower, -1200);
    }

    function test_execute_revert_band() public {
        queue(oneRange(-600, 600));
        oracle.set(1.05e8);
        vm.expectRevert(_violation("oracleBandBps"));
        hook.executeQueued(id);
    }

    function test_execute_revert_oracleStale() public {
        queue(oneRange(-600, 600));
        oracle.setUpdatedAt(block.timestamp - 1 hours - 1);
        vm.expectRevert(IMandate.OracleStale.selector);
        hook.executeQueued(id);
    }

    function test_execute_revert_expired() public {
        queue(oneRange(-600, 600));
        vm.warp(block.timestamp + 1 hours + 1);
        oracle.set(1e8);
        vm.expectRevert(IMandate.IntentExpired.selector);
        hook.executeQueued(id);
    }

    function test_execute_revert_distanceCheckedAgainstOracleAtExecution() public {
        queue(oneRange(-1200, 0)); // fine at oracle tick 0
        oracle.set(1.008e8); // oracle tick ~79: lower edge now 1279 away; still inside the 1% band
        vm.expectRevert(_violation("maxOracleDistanceTicks"));
        hook.executeQueued(id);
    }

    function test_executeInternal_revert_notSelf() public {
        queue(oneRange(-600, 600));
        vm.expectRevert(BridleHook.NotSelf.selector);
        hook.executeInternal(id);
    }

    function test_vaultEntryPoints_revert_notVault() public {
        vm.expectRevert(BridleHook.NotVault.selector);
        hook.deposit(id, address(this), 1, 1, 1);
        vm.expectRevert(BridleHook.NotVault.selector);
        hook.withdraw(id, 1, 1, address(this));
    }

    // ================================================================ beforeSwap execution

    function test_swap_executesQueuedIntent() public {
        queue(oneRange(-600, 600));
        vm.expectEmit(true, false, false, false, address(hook));
        emit BridleHook.Rebalanced(id, new Range[](0), 0, 0);
        swap(key, true, -1e18, ZERO_BYTES); // the swap itself trades against the new liquidity
        assertFalse(_queued());
        assertGt(hook.positions(id)[0].liquidity, 0);
        _assertClaimsMatchIdle(); // the hook's own deltas settled to zero inside beforeSwap
    }

    function _three(int24 o) internal pure returns (Range[] memory r) {
        r = new Range[](3);
        r[0] = Range(-600 + o, 600 + o, 5_000);
        r[1] = Range(-1140 + o, 1140 + o, 3_000);
        r[2] = Range(-300 + o, 300 + o, 2_000);
    }

    function _swapWithGas(uint256 gasLimit) internal {
        // limit 1% below the start price: in an empty pool, swapping to MIN_PRICE walks every tick
        swapRouter.swap{gas: gasLimit}(
            key,
            SwapParams({zeroForOne: true, amountSpecified: -1e15, sqrtPriceLimitX96: SQRT_PRICE_1_1 * 99 / 100}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
    }

    /// @dev Wallets set the gas limit to about the gas a successful run used. Adding SWAP_RESERVE_GAS to that
    /// estimate must be enough for a 3 -> 3 rebalance to run inside the swap.
    function test_swap_estimatePlusReserve_executes() public {
        queue(_three(0));
        hook.executeQueued(id);
        vm.warp(block.timestamp + 5 minutes);
        oracle.set(1e8);
        queue(_three(60)); // 3 removes + 3 adds

        uint256 snap = vm.snapshotState();
        uint256 g = gasleft();
        _swapWithGas(30_000_000);
        uint256 used = g - gasleft();
        assertFalse(_queued(), "executes with plenty of gas");
        emit log_named_uint("swap + 3->3 rebalance gas", used);
        vm.revertToState(snap);

        _swapWithGas(used + hook.SWAP_RESERVE_GAS());
        assertFalse(_queued(), "executes at estimate + reserve");
        assertEq(hook.positions(id)[0].tickLower, -540);
        _assertClaimsMatchIdle();
    }

    function test_swap_lowGas_skipsWithoutTrying() public {
        queue(oneRange(-600, 600));
        vm.expectEmit(true, false, false, true, address(hook));
        emit BridleHook.IntentSkipped(id, "gas");
        _swapWithGas(250_000);
        assertTrue(_queued());
        assertEq(hook.positions(id).length, 0);
    }

    /// @dev A swap sent before the intent was queued: execution starts, runs out of gas, is rolled back,
    /// and the reserve still finishes the swap.
    function test_swap_executionOutOfGas_swapStillFinishes() public {
        queue(_three(0));
        (uint160 before,,,) = manager.getSlot0(id);
        vm.expectEmit(true, false, false, true, address(hook));
        emit BridleHook.IntentSkipped(id, "");
        _swapWithGas(450_000);
        (uint160 afterSwap,,,) = manager.getSlot0(id);
        assertLt(afterSwap, before, "swap went through");
        assertTrue(_queued());
        assertEq(hook.positions(id).length, 0);
        _assertClaimsMatchIdle();
    }

    function test_swap_failingIntent_staysQueued_swapContinues() public {
        queue(oneRange(-1200, 0));
        oracle.set(1.008e8); // execution now fails the distance check, band still fine
        vm.expectEmit(true, false, false, true, address(hook));
        emit BridleHook.IntentSkipped(id, _violation("maxOracleDistanceTicks"));
        swap(key, true, -1e15, ZERO_BYTES);
        assertTrue(_queued());
        assertEq(hook.positions(id).length, 0);
        _assertClaimsMatchIdle();
    }

    function test_swap_staleOracle_skips() public {
        queue(oneRange(-600, 600));
        oracle.setUpdatedAt(block.timestamp - 1 hours - 1);
        vm.expectEmit(true, false, false, true, address(hook));
        emit BridleHook.IntentSkipped(id, abi.encodeWithSelector(IMandate.OracleStale.selector));
        swap(key, true, -1e15, ZERO_BYTES);
        assertTrue(_queued());
    }

    function test_swap_outOfBand_skips() public {
        queue(oneRange(-600, 600));
        oracle.set(1.05e8);
        vm.expectEmit(true, false, false, true, address(hook));
        emit BridleHook.IntentSkipped(id, abi.encodeWithSelector(IMandate.OutOfBand.selector));
        swap(key, true, -1e15, ZERO_BYTES);
        assertTrue(_queued());
    }

    function test_swap_expiredIntent_isDropped() public {
        queue(oneRange(-600, 600));
        vm.warp(block.timestamp + 1 hours + 1);
        oracle.set(1e8);
        vm.expectEmit(true, false, false, true, address(hook));
        emit BridleHook.IntentSkipped(id, abi.encodeWithSelector(IMandate.IntentExpired.selector));
        swap(key, true, -1e15, ZERO_BYTES);
        assertFalse(_queued());
    }

    function test_swap_duringCooldown_waits() public {
        _deployed();
        queue(oneRange(-1200, 1200));
        swap(key, true, -1e15, ZERO_BYTES);
        assertTrue(_queued());
        assertEq(hook.positions(id)[0].tickLower, -600);

        vm.warp(block.timestamp + 5 minutes); // cooldown passed, new epoch for turnover
        oracle.set(1e8);
        swap(key, true, -1e15, ZERO_BYTES);
        assertFalse(_queued());
        assertEq(hook.positions(id)[0].tickLower, -1200);
    }

    function test_swap_withoutIntent_noop() public {
        swap(key, true, -1e15, ZERO_BYTES);
        assertEq(hook.positions(id).length, 0);
    }

    // ================================================================ isolation between pools

    /// @dev Claims are pooled per token across every Bridle pool. A rogue vault on another pool with the same
    /// tokens must not be able to reach this pool's funds through bad share math or unpaid deposits.
    function test_rogueVault_cannotTouchOtherPoolsFunds() public {
        _deployed();
        (uint256 a0, uint256 a1) = _idle();
        uint256 claims0 = manager.balanceOf(address(hook), currency0.toId());
        uint256 liqA = hook.positions(id)[0].liquidity;

        // this test contract registers pool B (same tokens) and so becomes its vault
        PoolKey memory keyB = PoolKey(currency0, currency1, 500, 10, IHooks(address(hook)));
        PoolId idB = keyB.toId();
        hook.registerPool(keyB, feedConfig(), curator, testMandate());
        manager.initialize(keyB, SQRT_PRICE_1_1);

        // deposit without sending tokens: nothing to pay with
        vm.expectRevert();
        hook.deposit(idB, address(this), 1e18, 1e18, 0);

        // small honest deposit into B, then withdraw more shares than exist
        t0.transfer(address(hook), 1e6);
        t1.transfer(address(hook), 1e6);
        hook.deposit(idB, address(this), 1e6, 1e6, 0);
        vm.expectRevert(stdError.arithmeticError); // pool B's own idle can't cover it
        hook.withdraw(idB, 1_000_000, 1, address(this));

        (uint256 b0, uint256 b1) = _idle();
        assertEq(b0, a0, "A idle0");
        assertEq(b1, a1, "A idle1");
        assertEq(hook.positions(id)[0].liquidity, liqA, "A liquidity");
        assertEq(manager.balanceOf(address(hook), currency0.toId()), claims0 + 1e6, "only B's deposit added");
    }
}
