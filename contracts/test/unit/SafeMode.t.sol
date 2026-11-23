// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {EpochRecord, Range, RebalanceIntent} from "../../src/interfaces/IMandate.sol";
import {BridleHook} from "../../src/BridleHook.sol";
import {BridleVault} from "../../src/BridleVault.sol";
import {TrackRecord} from "../../src/TrackRecord.sol";
import {BridleFixture} from "../utils/BridleFixture.sol";

contract SafeModeTest is BridleFixture {
    uint256 constant WAD = 1e18;

    IERC20 t0;
    IERC20 t1;
    PoolId id;
    address alice = makeAddr("alice");
    uint256 aliceShares;
    uint256 _curatorFree; // curator's own unlocked shares

    function setUp() public override {
        super.setUp();
        id = key.toId();
        t0 = IERC20(Currency.unwrap(currency0));
        t1 = IERC20(Currency.unwrap(currency1));
        t0.transfer(alice, 1e30);
        t1.transfer(alice, 1e30);
        vm.startPrank(alice);
        t0.approve(address(vault), type(uint256).max);
        t1.approve(address(vault), type(uint256).max);
        (aliceShares,,) = vault.deposit(100e18, 100e18, 0, alice);
        vm.stopPrank();
        bondCurator();
        _curatorFree = vault.balanceOf(curator);
    }

    // ---------------------------------------------------------------- helpers

    function _nextEpoch(int256 answer) internal {
        vm.warp(block.timestamp + 5 minutes);
        oracle.set(answer);
    }

    function _toEpoch(uint64 e, int256 answer) internal {
        (,, uint64 start,,,) = hook.poolState(id);
        vm.warp(start + uint256(e) * 5 minutes);
        oracle.set(answer);
    }

    /// @dev Narrow range (+-1.2%) around 1.0, deployed in epoch 0.
    function _narrow() internal {
        queue(oneRange(-120, 120));
        hook.executeQueued(id);
    }

    function _churn(uint256 rounds) internal {
        for (uint256 i; i < rounds; ++i) {
            swap(key, true, -10e18, ZERO_BYTES);
            swap(key, false, -10e18, ZERO_BYTES);
        }
    }

    /// @dev Arbitrage the pool to the oracle price 1.3 (through the range, then free above it).
    function _poolTo1_3() internal {
        uint160 limit = uint160(Math.sqrt(uint256(13) * (1 << 192) / 10));
        swapRouter.swap(
            key,
            SwapParams({zeroForOne: false, amountSpecified: -1_000e18, sqrtPriceLimitX96: limit}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ZERO_BYTES
        );
    }

    /// @dev Epoch 0 earns fees (bond minted at the close), epoch 1 loses >10% to holding: breach at its close.
    function _breach() internal returns (EpochRecord memory r) {
        _narrow();
        _churn(5);
        _nextEpoch(1e8);
        assertGt(vault.closeEpoch().feeShares, 0, "bond to burn");
        _nextEpoch(1.3e8);
        _poolTo1_3();
        r = vault.closeEpoch();
    }

    function _signedIntent(Range[] memory ranges) internal view returns (RebalanceIntent memory i, bytes memory sig) {
        i = RebalanceIntent({
            poolId: PoolId.unwrap(id),
            curator: curator,
            ranges: ranges,
            nonce: hook.nonces(curator),
            deadline: block.timestamp + 1 hours
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(curatorPk, hook.hashIntent(i));
        sig = abi.encodePacked(r, s, v);
    }

    function _valueAtOracle(uint256 a0, uint256 a1) internal view returns (uint256) {
        uint160 p = hook.oracleSqrtPriceX96(id);
        return Math.mulDiv(Math.mulDiv(a0, p, 1 << 96), p, 1 << 96) + a1;
    }

    // ================================================================ breach

    function test_breach_burnsBond_entersSafeMode_unwinds() public {
        uint256 bond = vault.bondShares(); // 0 before the fee epoch
        assertEq(bond, 0);
        EpochRecord memory r = _breach();

        assertTrue(r.breached);
        assertLt(r.index * 10_000, vault.highWaterMark() * 9_000, "index > 10% below peak");
        assertEq(vault.bondShares(), 0);
        assertEq(vault.balanceOf(address(vault)), 0, "posted bond and fee bond burned, not released");
        assertEq(vault.postedBond(), 0);
        assertEq(vault.balanceOf(curator), _curatorFree, "curator's unlocked shares untouched");
        assertEq(r.feeShares, 0);
        assertTrue(hook.safeMode(id));
        assertEq(hook.positions(id).length, 0, "all liquidity back to idle");
        assertEq(vault.holdSupply(), vault.totalSupply());
    }

    function test_breach_emitsBreachAndSafeMode() public {
        _narrow();
        _churn(5);
        _nextEpoch(1e8);
        uint256 bond = vault.closeEpoch().feeShares;
        _nextEpoch(1.3e8);
        _poolTo1_3();
        vm.expectEmit(true, false, false, false, address(vault));
        emit TrackRecord.Breach(curator, 0, 0, bond);
        vm.expectEmit(false, false, false, true, address(vault));
        emit TrackRecord.SafeMode("breach");
        vault.closeEpoch();
    }

    /// @dev Invariant 5: after a breach, each non-curator holder's claim per share >= before the burn.
    function test_breach_holdersClaimPerShareRises() public {
        _narrow();
        _churn(5);
        _nextEpoch(1e8);
        vault.closeEpoch();
        _nextEpoch(1.3e8);
        _poolTo1_3();
        uint256 supplyBefore = vault.totalSupply();
        uint256 bond = vault.bondShares();
        EpochRecord memory r = vault.closeEpoch(); // navPerShare is measured before the burn
        assertEq(vault.totalSupply(), supplyBefore - bond - MIN_BOND, "only the fee bond + posted bond burned");

        vm.prank(alice);
        (uint256 a0, uint256 a1) = vault.withdraw(aliceShares, 0, 0, alice);
        uint256 claimPerShare = Math.mulDiv(_valueAtOracle(a0, a1), WAD, aliceShares);
        emit log_named_decimal_uint("breach ratio", r.ratio, 18);
        emit log_named_decimal_uint("navPerShare before burn", r.navPerShare, 18);
        emit log_named_decimal_uint("claim per share after", claimPerShare, 18);
        assertGe(claimPerShare, r.navPerShare, "burn only helps holders");
    }

    /// @dev The case the posted bond exists for: a curator who only ever lost has no fee bond, so without a
    /// posted bond a breach would burn nothing. Invariant 5 with a visible burn.
    function test_breach_losingCurator_postedBondBurned_holdersGain() public {
        _narrow();
        _nextEpoch(1.3e8); // straight into a breach, no fee epoch before it
        _poolTo1_3();
        assertEq(vault.bondShares(), 0, "no fee bond");
        uint256 supplyBefore = vault.totalSupply();

        vm.expectEmit(true, false, false, false, address(vault));
        emit TrackRecord.Breach(curator, 0, 0, MIN_BOND);
        EpochRecord memory r = vault.closeEpoch();
        assertTrue(r.breached);
        assertEq(vault.totalSupply(), supplyBefore - MIN_BOND, "posted bond burned");
        assertEq(vault.postedBond(), 0);

        vm.prank(alice);
        (uint256 a0, uint256 a1) = vault.withdraw(aliceShares, 0, 0, alice);
        uint256 claimPerShare = Math.mulDiv(_valueAtOracle(a0, a1), WAD, aliceShares);
        // the burned bond is ~1% of supply: alice's claim per share rises by about that much
        assertGt(claimPerShare, r.navPerShare * 1_005 / 1_000, "burn is visible to holders");
    }

    /// @dev A curator who sees a breach coming can't pull the bond out first: it stays burnable during notice.
    function test_breach_burnsBondDuringUnbondNotice() public {
        _narrow();
        vm.prank(curator);
        vault.requestUnbond(MIN_BOND);
        _nextEpoch(1.3e8);
        _poolTo1_3();
        assertTrue(vault.closeEpoch().breached);
        assertEq(vault.postedBond(), 0);
        assertEq(vault.unbondPending(), 0);
        vm.prank(curator);
        vm.expectRevert(BridleVault.ZeroShares.selector);
        vault.completeUnbond();
    }

    /// @dev Reckless curator sees the drawdown building and tries to take the bond out before the breach.
    function test_unbond_blockedWhileInDrawdown() public {
        _narrow();
        _nextEpoch(1.02e8);
        vault.closeEpoch(); // a loss, no breach yet
        assertLt(vault.index(), vault.highWaterMark());
        vm.prank(curator);
        vault.requestUnbond(MIN_BOND);
        _nextEpoch(1.02e8);
        vault.closeEpoch(); // notice served, still underwater
        vm.prank(curator);
        vm.expectRevert(BridleVault.InDrawdown.selector);
        vault.completeUnbond();
    }

    /// @dev The way out while losing: stop managing; once liveness turns safe mode on, the bond is free.
    function test_unbond_allowedAfterIdleSafeMode() public {
        _narrow();
        _nextEpoch(1.02e8);
        vault.closeEpoch();
        vm.prank(curator);
        vault.requestUnbond(MIN_BOND);
        _toEpoch(13, 1.02e8);
        vault.closeEpoch(); // idle -> safe mode, no breach
        assertTrue(hook.safeMode(id));
        assertLt(vault.index(), vault.highWaterMark());
        vm.prank(curator);
        vault.completeUnbond();
        assertEq(vault.balanceOf(curator), _curatorFree + MIN_BOND);
    }

    function test_breach_dropsQueuedIntent() public {
        _narrow();
        _churn(5);
        _nextEpoch(1e8);
        vault.closeEpoch();
        _nextEpoch(1e8);
        queue(oneRange(-600, 600)); // queued but not executed yet
        oracle.set(1.3e8);
        _poolTo1_3();
        assertTrue(vault.closeEpoch().breached);
        assertEq(hook.queuedIntent(id).deadline, 0);
    }

    function test_noBreach_smallLoss() public {
        _narrow();
        _nextEpoch(1.02e8); // a loss to holding, but well under 10%
        EpochRecord memory r = vault.closeEpoch();
        assertLt(r.ratio, WAD);
        assertFalse(r.breached);
        assertFalse(hook.safeMode(id));
    }

    // ================================================================ liveness

    function test_liveness_atMaxIdleEpochs_stillActive() public {
        _narrow(); // rebalance in epoch 0
        _toEpoch(12, 1e8); // maxIdleEpochs = 12
        vault.closeEpoch();
        assertFalse(hook.safeMode(id));
    }

    function test_liveness_oneMoreEpoch_safeModeWithoutBurn() public {
        _narrow();
        _churn(5);
        _nextEpoch(1e8);
        uint256 bond = vault.closeEpoch().feeShares; // epoch 0 earns a fee
        _toEpoch(13, 1e8);
        vm.expectEmit(false, false, false, true, address(vault));
        emit TrackRecord.SafeMode("idle");
        EpochRecord memory r = vault.closeEpoch();
        assertFalse(r.breached);
        assertTrue(hook.safeMode(id));
        assertEq(hook.positions(id).length, 0);
        assertEq(vault.balanceOf(curator), _curatorFree + bond, "absent is not misconduct: fee bond released");
        assertEq(vault.postedBond(), MIN_BOND, "posted bond kept, not burned");
    }

    function test_liveness_rebalanceResetsTheClock() public {
        _narrow();
        _toEpoch(10, 1e8);
        queue(oneRange(-600, 600));
        hook.executeQueued(id); // active again in epoch 10
        _toEpoch(13, 1e8);
        vault.closeEpoch();
        assertFalse(hook.safeMode(id));
    }

    /// @dev The curator is present (a signed intent stays queued) but execution is blocked: the pool sits
    /// outside the oracle band, as on a testnet pool nobody arbitrages. Not idle until that intent expires.
    function test_liveness_liveQueuedIntentCountsAsPresent() public {
        _narrow();
        _toEpoch(1, 1.05e8); // oracle moves 5%, pool stays at 1.0
        queue(oneRange(-600, 600)); // deadline = epoch 1 + 1 hour = start of epoch 13
        vm.expectRevert();
        hook.executeQueued(id); // blocked by the band

        _toEpoch(13, 1.05e8);
        vault.closeEpoch();
        assertFalse(hook.safeMode(id), "live intent: curator is present");

        _toEpoch(14, 1.05e8); // intent expired, still no rebalance
        vault.closeEpoch();
        assertTrue(hook.safeMode(id));
    }

    function test_liveness_curatorThatNeverActed() public {
        _toEpoch(13, 1e8); // deposit in epoch 0, never a rebalance
        vault.closeEpoch();
        assertTrue(hook.safeMode(id));
    }

    // ================================================================ in safe mode

    function test_safeMode_blocksIntentsAndDeposits() public {
        _breach();
        (RebalanceIntent memory i, bytes memory sig) = _signedIntent(oneRange(-600, 600));
        vm.expectRevert(BridleHook.CuratorNotActive.selector);
        hook.queueIntent(i, sig);
        vm.expectRevert(BridleHook.NothingQueued.selector);
        hook.executeQueued(id);
        vm.prank(alice);
        vm.expectRevert(BridleVault.SafeModeOn.selector);
        vault.deposit(1e18, 1e18, 0, alice);
    }

    function test_safeMode_withdrawWorks_evenWithOracleStale() public {
        _breach();
        vm.warp(block.timestamp + 1 days); // oracle stale too
        vm.prank(alice);
        (uint256 a0, uint256 a1) = vault.withdraw(aliceShares, 0, 0, alice);
        assertGt(a0 + a1, 0);
        assertEq(vault.balanceOf(alice), 0);
    }

    function test_safeMode_closeEpochStillScores_noFee() public {
        _breach();
        uint256 indexAfterBreach = vault.index();
        _nextEpoch(0.7e8); // big move: an all-idle vault is exactly holding
        EpochRecord memory r = vault.closeEpoch();
        assertEq(r.ratio, WAD);
        assertEq(r.feeShares, 0);
        assertFalse(r.breached, "breach is reported once");
        assertEq(vault.index(), indexAfterBreach);
    }

    function test_safeMode_swapsStillWork() public {
        _breach();
        swap(key, true, -1e15, ZERO_BYTES); // no intent, no liquidity of ours: beforeSwap is a no-op
    }

    function test_enterSafeMode_revert_notVault() public {
        vm.expectRevert(BridleHook.NotVault.selector);
        hook.enterSafeMode(id);
    }
}
