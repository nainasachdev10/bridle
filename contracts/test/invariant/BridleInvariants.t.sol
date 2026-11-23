// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {EpochRecord, Mandate, Range, RebalanceIntent} from "../../src/interfaces/IMandate.sol";
import {BridleHook} from "../../src/BridleHook.sol";
import {BridleVault} from "../../src/BridleVault.sol";
import {MockAggregator} from "../mocks/MockAggregator.sol";
import {BridleFixture} from "../utils/BridleFixture.sol";

/// @dev Random sequences of what users, the curator, swappers and time can do. Every call is bounded and
/// wrapped in try/catch: a revert is a valid outcome, the invariants are checked after each call.
contract Handler is Test {
    using StateLibrary for IPoolManager;

    IPoolManager immutable manager;
    BridleHook immutable hook;
    BridleVault immutable vault;
    MockAggregator immutable oracle;
    PoolSwapTest immutable router;
    PoolKey key;
    PoolId immutable id;
    uint256 immutable curatorPk;
    address immutable curator;
    address[3] public actors;

    // ghosts for invariants 4 and 5
    uint256 public hwmDecreased;
    uint256 public feeWithoutNewHigh;
    uint256 public breachHurtHolder;
    uint256 public breaches;
    uint256 public rebalances;
    uint256 public closes;

    constructor(
        IPoolManager _manager,
        BridleHook _hook,
        BridleVault _vault,
        MockAggregator _oracle,
        PoolSwapTest _router,
        PoolKey memory _key,
        uint256 _curatorPk,
        address[3] memory _actors
    ) {
        manager = _manager;
        hook = _hook;
        vault = _vault;
        oracle = _oracle;
        router = _router;
        key = _key;
        id = _key.toId();
        curatorPk = _curatorPk;
        curator = vm.addr(_curatorPk);
        actors = _actors;
        IERC20(Currency.unwrap(_key.currency0)).approve(address(_router), type(uint256).max);
        IERC20(Currency.unwrap(_key.currency1)).approve(address(_router), type(uint256).max);
    }

    function deposit(uint256 who, uint256 a0, uint256 a1) external {
        address u = actors[who % 3];
        vm.prank(u);
        try vault.deposit(bound(a0, 1e15, 50e18), bound(a1, 1e15, 50e18), 0, u) {} catch {}
    }

    function withdraw(uint256 who, uint256 fraction) external {
        address u = actors[who % 3];
        uint256 shares = vault.balanceOf(u) * bound(fraction, 1, 100) / 100;
        if (shares == 0) return;
        vm.prank(u);
        vault.withdraw(shares, 0, 0, u); // must never revert (invariant 3 in its strongest form)
    }

    /// @dev Curator signs 1-2 ranges around the oracle tick, then anyone executes.
    function rebalance(uint256 seed) external {
        int24 center;
        try hook.oracleSqrtPriceX96(id) returns (uint160 p) {
            center = TickMath.getTickAtSqrtPrice(p) / 60 * 60;
        } catch {
            return;
        }
        uint256 n = 1 + seed % 2;
        Range[] memory r = new Range[](n);
        for (uint256 i; i < n; ++i) {
            int24 half = int24(int256(2 + (seed >> (8 * (i + 1))) % 14)) * 60; // 120..900
            r[i] = Range(center - half, center + half, uint16(10_000 / n));
        }
        if (n == 2 && r[0].tickLower == r[1].tickLower) r[1].tickUpper += 60;
        RebalanceIntent memory it = RebalanceIntent({
            poolId: PoolId.unwrap(id),
            curator: curator,
            ranges: r,
            nonce: hook.nonces(curator),
            deadline: block.timestamp + 1 hours
        });
        (uint8 v, bytes32 rs, bytes32 s) = vm.sign(curatorPk, hook.hashIntent(it));
        try hook.queueIntent(it, abi.encodePacked(rs, s, v)) {} catch {}
        try hook.executeQueued(id) {
            rebalances++;
        } catch {}
    }

    /// @dev Swaps at most ~1% of price at a time so the pool stays near the oracle and the system stays explorable.
    function swap(bool zeroForOne, uint256 amount) external {
        (uint160 p,,,) = manager.getSlot0(id);
        uint160 limit = zeroForOne ? uint160(uint256(p) * 995 / 1000) : uint160(uint256(p) * 1005 / 1000);
        try router.swap(
            key,
            SwapParams({
                zeroForOne: zeroForOne, amountSpecified: -int256(bound(amount, 1e12, 20e18)), sqrtPriceLimitX96: limit
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) {}
            catch {}
    }

    function closeEpoch() external {
        uint256 hwmBefore = vault.highWaterMark();
        uint256 supplyBefore = vault.totalSupply();
        uint256[3] memory before;
        for (uint256 i; i < 3; ++i) {
            before[i] = vault.balanceOf(actors[i]);
        }
        try vault.closeEpoch() returns (EpochRecord memory r) {
            closes++;
            if (vault.highWaterMark() < hwmBefore) hwmDecreased++;
            if (r.feeShares > 0 && r.index <= hwmBefore) feeWithoutNewHigh++;
            if (r.breached) {
                breaches++;
                // a holder's claim per share = their fraction of supply (holdings don't change in the burn)
                uint256 supplyAfter = vault.totalSupply();
                for (uint256 i; i < 3; ++i) {
                    if (before[i] * supplyAfter > vault.balanceOf(actors[i]) * supplyBefore) breachHurtHolder++;
                }
            }
        } catch {}
    }

    function warp(uint256 secs) external {
        vm.warp(block.timestamp + bound(secs, 30, 10 minutes));
    }

    /// @dev Moves the oracle up to +-3% (kept between 0.5 and 2.0), then an arbitrageur swaps the pool to it,
    /// as on a live market. Without this the pool leaves the band and nothing can happen.
    function moveOracle(int256 bps) external {
        (, int256 answer,,,) = oracle.latestRoundData();
        int256 next = answer * (10_000 + bound(bps, -300, 300)) / 10_000;
        oracle.set(next < 0.5e8 ? int256(0.5e8) : next > 2e8 ? int256(2e8) : next);
        uint160 target = hook.oracleSqrtPriceX96(id);
        (uint160 p,,,) = manager.getSlot0(id);
        if (p == target) return;
        try router.swap(
            key,
            SwapParams({zeroForOne: target < p, amountSpecified: -1_000e18, sqrtPriceLimitX96: target}),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        ) {}
            catch {}
    }
}

contract BridleInvariants is BridleFixture {
    using StateLibrary for IPoolManager;

    Handler handler;
    PoolId id;
    address[3] actors;

    function setUp() public override {
        super.setUp();
        id = key.toId();
        actors = [makeAddr("alice"), makeAddr("bob"), curator];
        IERC20 t0 = IERC20(Currency.unwrap(currency0));
        IERC20 t1 = IERC20(Currency.unwrap(currency1));
        for (uint256 i; i < 2; ++i) {
            t0.transfer(actors[i], 1e27);
            t1.transfer(actors[i], 1e27);
            vm.startPrank(actors[i]);
            t0.approve(address(vault), type(uint256).max);
            t1.approve(address(vault), type(uint256).max);
            vm.stopPrank();
        }
        vm.prank(actors[0]);
        vault.deposit(100e18, 100e18, 0, actors[0]);
        bondCurator();

        // tighten the breach line to 2% (through a real amendment) so random runs reach breaches and safe mode
        Mandate memory m = testMandate();
        m.maxDrawdownBps = 200;
        vm.prank(curator);
        vault.proposeAmendment(m);
        vm.warp(block.timestamp + m.amendmentDelay);
        oracle.set(1e8);
        vault.applyAmendment();

        handler = new Handler(manager, hook, vault, oracle, swapRouter, key, curatorPk, actors);
        t0.transfer(address(handler), 1e27);
        t1.transfer(address(handler), 1e27);
        targetContract(address(handler));
    }

    /// @dev 1a. The hook's ERC-6909 claims equal its idle accounting, and every recorded position's liquidity
    /// equals what the PoolManager holds for the hook. (Single Bridle pool, so claims belong to it alone.)
    function invariant_1_holdingsMatchAccounting() public view {
        (uint256 idle0, uint256 idle1,,,,) = hook.poolState(id);
        assertEq(manager.balanceOf(address(hook), currency0.toId()), idle0, "claims0");
        assertEq(manager.balanceOf(address(hook), currency1.toId()), idle1, "claims1");
        BridleHook.Position[] memory ps = hook.positions(id);
        for (uint256 i; i < ps.length; ++i) {
            (uint128 liq,,) = manager.getPositionInfo(id, address(hook), ps[i].tickLower, ps[i].tickUpper, 0);
            assertEq(liq, ps[i].liquidity, "position liquidity");
        }
    }

    /// @dev 1b. Rounding favours the vault: after any withdrawal, every remaining share holds at least as much
    /// of each position's liquidity and of each idle token as before. No price involved.
    function invariant_1_roundingFavoursTheVault() public {
        uint256 snap = vm.snapshotState();
        for (uint256 i; i < 3; ++i) {
            uint256 shares = vault.balanceOf(actors[i]);
            if (shares == 0) continue;
            uint256 sBefore = vault.totalSupply();
            BridleHook.Position[] memory before = hook.positions(id);
            (uint256 i0, uint256 i1,,,,) = hook.poolState(id);
            vm.prank(actors[i]);
            vault.withdraw(shares, 0, 0, actors[i]);
            uint256 sAfter = vault.totalSupply();
            BridleHook.Position[] memory ps = hook.positions(id);
            for (uint256 k; k < ps.length; ++k) {
                assertGe(uint256(ps[k].liquidity) * sBefore, uint256(before[k].liquidity) * sAfter, "liquidity/share");
            }
            (uint256 j0, uint256 j1,,,,) = hook.poolState(id);
            assertGe(j0 * sBefore, i0 * sAfter, "idle0/share"); // fees collected on withdraw only add
            assertGe(j1 * sBefore, i1 * sAfter, "idle1/share");
        }
        vm.revertToState(snap);
    }

    /// @dev 2. Turnover within the cap; live positions keep count, width and tick spacing.
    function invariant_2_mandateHoldsOnLivePositions() public view {
        Mandate memory m = hook.mandateOf(id);
        (,,,,, uint32 turnover) = hook.poolState(id);
        assertLe(turnover, m.maxTurnoverBpsPerEpoch, "turnover");
        BridleHook.Position[] memory ps = hook.positions(id);
        assertLe(ps.length, m.maxRanges, "count");
        for (uint256 i; i < ps.length; ++i) {
            assertGe(int256(ps[i].tickUpper) - ps[i].tickLower, int256(uint256(m.minWidthTicks)), "width");
            assertEq(ps[i].tickLower % 60, 0, "spacing");
        }
    }

    /// @dev 3. Any holder can always withdraw everything in kind: oracle stale, out of band or safe mode.
    function invariant_3_everyoneCanExit() public {
        uint256 snap = vm.snapshotState();
        for (uint256 i; i < 3; ++i) {
            uint256 shares = vault.balanceOf(actors[i]);
            if (shares == 0) continue;
            vm.prank(actors[i]);
            vault.withdraw(shares, 0, 0, actors[i]); // reverts the invariant if it can't
        }
        vm.revertToState(snap);
    }

    /// @dev 4. Fee only on a new high; hwm never decreases.
    function invariant_4_feeOnlyAboveHighWaterMark() public view {
        assertEq(handler.hwmDecreased(), 0, "hwm decreased");
        assertEq(handler.feeWithoutNewHigh(), 0, "fee without new high");
        assertGe(vault.highWaterMark(), vault.WAD());
    }

    /// @dev 5. A breach never lowers any holder's share of the vault (only the bond is burned).
    function invariant_5_breachOnlyHelpsHolders() public view {
        assertEq(handler.breachHurtHolder(), 0);
    }

    function afterInvariant() external {
        emit log_named_uint("rebalances", handler.rebalances());
        emit log_named_uint("closes", handler.closes());
        emit log_named_uint("breaches", handler.breaches());
        emit log_named_uint("safe mode", hook.safeMode(id) ? 1 : 0);
    }
}
