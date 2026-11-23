// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {CurrencySettler} from "@openzeppelin/uniswap-hooks/src/utils/CurrencySettler.sol";
import {IERC20, IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "@uniswap/v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {TransientStateLibrary} from "@uniswap/v4-core/src/libraries/TransientStateLibrary.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {ModifyLiquidityParams, SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {LiquidityAmounts} from "@uniswap/v4-periphery/src/libraries/LiquidityAmounts.sol";
import {AggregatorV3Interface} from "./interfaces/AggregatorV3Interface.sol";
import {FeedConfig, IMandate, Mandate, Range, RebalanceIntent} from "./interfaces/IMandate.sol";
import {MandateLib} from "./libraries/MandateLib.sol";
import {OracleGuard} from "./libraries/OracleGuard.sol";
import {IntentVerifier} from "./IntentVerifier.sol";

/// @dev What the hook asks a pool's vault before taking an intent.
interface IBridleVault {
    /// @return true when the curator's posted bond covers the minimum and the pool is not in safe mode
    function isActive() external view returns (bool);
}

/// @notice Uniswap v4 hook for curated liquidity under an enforceable mandate.
/// Permissions are exactly beforeInitialize, beforeAddLiquidity, beforeSwap.
/// Custody: the hook owns every position in the PoolManager and holds idle balances as ERC-6909 claims,
/// tracked per pool. The pool's BridleVault is the share ledger and the only caller of deposit/withdraw.
contract BridleHook is BaseHook, IntentVerifier, IUnlockCallback {
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;
    using StateLibrary for IPoolManager;
    using TransientStateLibrary for IPoolManager;
    using CurrencySettler for Currency;
    using SafeERC20 for IERC20;

    /// @dev Kept back from execution so the swap always finishes, even when execution runs out of gas
    /// (protects swaps sent before an intent was queued). A swapper who wants the queued rebalance to run
    /// in their swap adds this to their gas estimate; otherwise anyone can call executeQueued.
    uint256 public constant SWAP_RESERVE_GAS = 200_000;
    /// @dev Below this, a rebalance can't finish anyway: skip without trying.
    uint256 public constant MIN_EXECUTE_GAS = SWAP_RESERVE_GAS + 100_000;

    struct PoolConfig {
        PoolKey key;
        address vault;
        address curator;
        Mandate mandate;
        OracleGuard.Feed feed;
    }

    /// @dev A live range. weightBps is the curator's target; liquidity is what the hook actually holds.
    struct Position {
        int24 tickLower;
        int24 tickUpper;
        uint16 weightBps;
        uint128 liquidity;
    }

    struct PoolState {
        uint256 idle0; // ERC-6909 claims of currency0 held for this pool
        uint256 idle1;
        uint64 startTime; // epoch 0 starts at pool initialization
        uint64 lastRebalanceAt;
        uint64 turnoverEpoch;
        uint32 epochTurnoverBps;
    }

    struct QueuedIntent {
        uint256 deadline; // 0 = nothing queued
        Range[] ranges;
    }

    enum Action {
        Deposit,
        Withdraw,
        Rebalance,
        CollectFees,
        Unwind
    }

    mapping(PoolId => PoolConfig) internal _pools;
    mapping(PoolId => PoolState) public poolState;
    mapping(PoolId => Position[]) internal _positions;
    mapping(PoolId => QueuedIntent) internal _queued;
    /// @notice One-way: after a breach or an absent curator the pool only holds. No intents, no positions.
    mapping(PoolId => bool) public safeMode;

    event PoolRegistered(PoolId indexed poolId, address indexed vault, address feed, address indexed curator);
    event IntentQueued(PoolId indexed poolId, address indexed curator, uint256 nonce, uint256 deadline, Range[] ranges);
    event Rebalanced(PoolId indexed poolId, Range[] ranges, uint256 turnoverBps, uint256 epochTurnoverBps);
    event IntentSkipped(PoolId indexed poolId, bytes reason);

    error AlreadyRegistered();
    error PoolNotRegistered();
    error AddLiquidityDisabled();
    error DynamicFeeUnsupported();
    error ZeroAddress();
    error NotVault();
    error NotSelf();
    error NothingQueued();
    error Slippage();
    error CuratorNotActive();

    constructor(IPoolManager _poolManager) BaseHook(_poolManager) {}

    function getHookPermissions() public pure override returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: true,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: false,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: false,
            afterSwapReturnDelta: false,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ================================================================ registration

    /// @notice Called by a BridleVault from its constructor; the caller becomes the pool's vault.
    /// A squatter can only occupy a pool key nobody else uses: depositors choose the vault, not the key.
    function registerPool(PoolKey calldata key, FeedConfig calldata feed, address curator, Mandate calldata mandate)
        external
        onlyValidPools(key.hooks)
    {
        // the hook never sets a fee, so a dynamic-fee pool would pay LPs 0% forever
        if (key.fee.isDynamicFee()) revert DynamicFeeUnsupported();
        if (feed.aggregator == address(0) || curator == address(0)) revert ZeroAddress();
        PoolId id = key.toId();
        if (_pools[id].vault != address(0)) revert AlreadyRegistered();
        MandateLib.validateMandate(mandate);

        PoolConfig storage c = _pools[id];
        c.key = key;
        c.vault = msg.sender;
        c.curator = curator;
        c.mandate = mandate;
        c.feed = OracleGuard.Feed({
            aggregator: AggregatorV3Interface(feed.aggregator),
            maxStaleness: feed.maxStaleness,
            baseIsToken0: feed.baseIsToken0,
            feedDecimals: AggregatorV3Interface(feed.aggregator).decimals(),
            decimals0: IERC20Metadata(Currency.unwrap(key.currency0)).decimals(),
            decimals1: IERC20Metadata(Currency.unwrap(key.currency1)).decimals()
        });
        emit PoolRegistered(id, msg.sender, feed.aggregator, curator);
    }

    // ================================================================ views

    function curatorOf(PoolId id) external view returns (address) {
        return _pools[id].curator;
    }

    function mandateOf(PoolId id) external view returns (Mandate memory) {
        return _pools[id].mandate;
    }

    function positions(PoolId id) external view returns (Position[] memory) {
        return _positions[id];
    }

    function queuedIntent(PoolId id) external view returns (QueuedIntent memory) {
        return _queued[id];
    }

    /// @notice Epoch number: epoch 0 starts at pool initialization. Used by the turnover cap and epoch close.
    function epochOf(PoolId id) public view returns (uint64) {
        return uint64((block.timestamp - poolState[id].startTime) / _pools[id].mandate.epochLength);
    }

    /// @notice Chainlink price as a pool sqrtPriceX96; reverts OracleStale. External so beforeSwap can try it.
    function oracleSqrtPriceX96(PoolId id) public view returns (uint160) {
        return OracleGuard.sqrtPriceX96(_pools[id].feed);
    }

    // ================================================================ hook callbacks

    /// @dev Only pools bound to a registered vault + feed, starting at a price within the oracle band.
    function _beforeInitialize(address, PoolKey calldata key, uint160 sqrtPriceX96) internal override returns (bytes4) {
        PoolId id = key.toId();
        PoolConfig storage c = _pools[id];
        if (c.vault == address(0)) revert PoolNotRegistered();
        if (!MandateLib.withinBand(sqrtPriceX96, oracleSqrtPriceX96(id), c.mandate.oracleBandBps)) {
            revert IMandate.OutOfBand();
        }
        poolState[id].startTime = uint64(block.timestamp);
        return IHooks.beforeInitialize.selector;
    }

    /// @dev All liquidity is the vault's, placed by the hook itself. v4 skips hook callbacks when the
    /// hook is the caller of modifyLiquidity, so this only blocks outside LPs.
    function _beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4)
    {
        revert AddLiquidityDisabled();
    }

    /// @dev Try to execute the queued intent before the swap. Never reverts the swap: any failure leaves the
    /// intent queued (or drops it if expired) and emits IntentSkipped. Returns zero delta and no fee override.
    function _beforeSwap(address, PoolKey calldata key, SwapParams calldata, bytes calldata)
        internal
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        PoolId id = key.toId();
        QueuedIntent storage q = _queued[id];
        if (q.deadline != 0 && _cooldownPassed(id)) {
            if (block.timestamp > q.deadline) {
                delete _queued[id];
                emit IntentSkipped(id, abi.encodeWithSelector(IMandate.IntentExpired.selector));
            } else if (gasleft() < MIN_EXECUTE_GAS) {
                emit IntentSkipped(id, "gas");
            } else if (_bandOk(id)) {
                try this.executeInternal{gas: gasleft() - SWAP_RESERVE_GAS}(id) {}
                catch (bytes memory reason) {
                    emit IntentSkipped(id, reason);
                }
            }
        }
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }

    // ================================================================ intents

    /// @notice Queue a signed rebalance. Anyone may relay it; the signature authenticates the curator.
    /// Replaces any older queued intent for the pool.
    function queueIntent(RebalanceIntent calldata intent, bytes calldata signature) external {
        PoolId id = PoolId.wrap(intent.poolId);
        PoolConfig storage c = _pools[id];
        if (c.vault == address(0)) revert PoolNotRegistered();
        if (intent.curator != c.curator) revert IMandate.NotCurator();
        if (!IBridleVault(c.vault).isActive()) revert CuratorNotActive();
        _useIntent(intent, signature);
        // fail fast on shape; everything is checked again at execution
        int24 oracleTick = TickMath.getTickAtSqrtPrice(oracleSqrtPriceX96(id));
        MandateLib.checkRanges(c.mandate, intent.ranges, oracleTick, c.key.tickSpacing);

        QueuedIntent storage q = _queued[id];
        delete q.ranges;
        q.deadline = intent.deadline;
        for (uint256 i; i < intent.ranges.length; ++i) {
            q.ranges.push(intent.ranges[i]);
        }
        emit IntentQueued(id, intent.curator, intent.nonce, intent.deadline, intent.ranges);
    }

    /// @notice Permissionless: execute the queued intent now. Reverts with the reason if it can't.
    function executeQueued(PoolId id) external {
        if (_queued[id].deadline == 0) revert NothingQueued();
        poolManager.unlock(abi.encode(Action.Rebalance, id, bytes("")));
    }

    /// @notice Self-call target for beforeSwap, so a failure can be caught and rolled back.
    function executeInternal(PoolId id) external {
        if (msg.sender != address(this)) revert NotSelf();
        _rebalance(id);
    }

    // ================================================================ vault entry points

    /// @notice Vault-only. The vault has already sent amount0Max / amount1Max to this contract; the unused
    /// part is refunded to `payer`. Returns the total shares the deposit is worth (the vault mints them).
    function deposit(PoolId id, address payer, uint256 amount0Max, uint256 amount1Max, uint256 supply)
        external
        returns (uint256 shares, uint256 amount0, uint256 amount1)
    {
        if (msg.sender != _pools[id].vault) revert NotVault();
        (shares, amount0, amount1) = abi.decode(
            poolManager.unlock(abi.encode(Action.Deposit, id, abi.encode(amount0Max, amount1Max, supply))),
            (uint256, uint256, uint256)
        );
        PoolKey storage key = _pools[id].key;
        IERC20(Currency.unwrap(key.currency0)).safeTransfer(payer, amount0Max - amount0);
        IERC20(Currency.unwrap(key.currency1)).safeTransfer(payer, amount1Max - amount1);
    }

    /// @notice Vault-only. Pays out shares / supply of every position and idle balance. No price used,
    /// no oracle read: works with the oracle stale.
    function withdraw(PoolId id, uint256 shares, uint256 supply, address receiver)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        if (msg.sender != _pools[id].vault) revert NotVault();
        (amount0, amount1) = abi.decode(
            poolManager.unlock(abi.encode(Action.Withdraw, id, abi.encode(shares, supply, receiver))),
            (uint256, uint256)
        );
    }

    /// @notice Vault-only, for epoch close: pokes every position so accrued fees land in idle.
    function collectFees(PoolId id) external {
        if (msg.sender != _pools[id].vault) revert NotVault();
        poolManager.unlock(abi.encode(Action.CollectFees, id, bytes("")));
    }

    /// @notice Vault-only: apply an amendment the vault has already checked and delayed.
    function setMandate(PoolId id, Mandate calldata mandate) external {
        if (msg.sender != _pools[id].vault) revert NotVault();
        _pools[id].mandate = mandate;
    }

    /// @notice Vault-only, one-way. Drops the queued intent and pulls every position back to idle.
    function enterSafeMode(PoolId id) external {
        if (msg.sender != _pools[id].vault) revert NotVault();
        safeMode[id] = true;
        delete _queued[id];
        poolManager.unlock(abi.encode(Action.Unwind, id, bytes("")));
    }

    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        (Action action, PoolId id, bytes memory args) = abi.decode(data, (Action, PoolId, bytes));
        if (action == Action.Rebalance) {
            _rebalance(id);
            return "";
        }
        if (action == Action.CollectFees) {
            _collectFees(id);
            return "";
        }
        if (action == Action.Unwind) {
            _removeAll(id);
            return "";
        }
        if (action == Action.Deposit) {
            (uint256 max0, uint256 max1, uint256 supply) = abi.decode(args, (uint256, uint256, uint256));
            (uint256 shares, uint256 a0, uint256 a1) = _deposit(id, max0, max1, supply);
            return abi.encode(shares, a0, a1);
        }
        (uint256 s, uint256 sup, address receiver) = abi.decode(args, (uint256, uint256, address));
        (uint256 w0, uint256 w1) = _withdraw(id, s, sup, receiver);
        return abi.encode(w0, w1);
    }

    // ================================================================ internals (inside unlock)

    function _deposit(PoolId id, uint256 max0, uint256 max1, uint256 supply)
        internal
        returns (uint256 shares, uint256 amount0, uint256 amount1)
    {
        PoolKey storage key = _pools[id].key;
        (uint160 poolSqrt,,,) = poolManager.getSlot0(id);
        // deposit amounts depend on the pool price: require it within the oracle band
        if (!MandateLib.withinBand(poolSqrt, oracleSqrtPriceX96(id), _pools[id].mandate.oracleBandBps)) {
            revert IMandate.OutOfBand();
        }

        uint256 idleAdd0;
        uint256 idleAdd1;
        if (supply == 0) {
            shares = Math.sqrt(max0 * max1);
            (idleAdd0, idleAdd1) = (max0, max1);
        } else {
            _collectFees(id);
            shares = _sharesFor(id, poolSqrt, max0, max1, supply);
            if (shares == 0) return (0, 0, 0);
            (idleAdd0, idleAdd1) = _addProRata(id, shares, supply);
        }

        // idle part becomes ERC-6909 claims; then pay the whole debt in ERC-20 from this contract
        PoolState storage st = poolState[id];
        key.currency0.take(poolManager, address(this), idleAdd0, true);
        key.currency1.take(poolManager, address(this), idleAdd1, true);
        st.idle0 += idleAdd0;
        st.idle1 += idleAdd1;
        amount0 = uint256(-poolManager.currencyDelta(address(this), key.currency0));
        amount1 = uint256(-poolManager.currencyDelta(address(this), key.currency1));
        if (amount0 > max0 || amount1 > max1) revert Slippage();
        key.currency0.settle(poolManager, address(this), amount0, false);
        key.currency1.settle(poolManager, address(this), amount1, false);
    }

    /// @dev Largest share count whose exact cost (as the PoolManager will charge it) fits the maxes.
    /// Rounding up per position can overshoot by dust, so shrink until it fits.
    function _sharesFor(PoolId id, uint160 poolSqrt, uint256 max0, uint256 max1, uint256 supply)
        internal
        view
        returns (uint256 shares)
    {
        (uint256 total0, uint256 total1) = _costOf(id, poolSqrt, supply, supply);
        shares = _fit(max0, max1, total0, total1, supply);
        for (uint256 i; i < 3 && shares > 0; ++i) {
            (uint256 need0, uint256 need1) = _costOf(id, poolSqrt, shares, supply);
            if (need0 <= max0 && need1 <= max1) return shares;
            shares = _fit(max0, max1, need0, need1, shares);
        }
    }

    /// @dev How many shares `max` buys when `forShares` costs (cost0, cost1).
    function _fit(uint256 max0, uint256 max1, uint256 cost0, uint256 cost1, uint256 forShares)
        internal
        pure
        returns (uint256 shares)
    {
        shares = type(uint256).max;
        if (cost0 > 0) shares = Math.mulDiv(max0, forShares, cost0);
        if (cost1 > 0) shares = Math.min(shares, Math.mulDiv(max1, forShares, cost1));
        if (shares == type(uint256).max) shares = 0; // nothing held: nothing to price against
    }

    /// @dev Adds shares / supply of every position; returns the idle amounts to add. Rounds up: the depositor
    /// pays the dust, never the vault.
    function _addProRata(PoolId id, uint256 shares, uint256 supply)
        internal
        returns (uint256 idleAdd0, uint256 idleAdd1)
    {
        PoolKey storage key = _pools[id].key;
        Position[] storage ps = _positions[id];
        for (uint256 i; i < ps.length; ++i) {
            uint256 add = Math.mulDiv(ps[i].liquidity, shares, supply, Math.Rounding.Ceil);
            if (add == 0) continue;
            _modify(key, ps[i].tickLower, ps[i].tickUpper, int256(add));
            ps[i].liquidity += uint128(add);
        }
        idleAdd0 = Math.mulDiv(poolState[id].idle0, shares, supply, Math.Rounding.Ceil);
        idleAdd1 = Math.mulDiv(poolState[id].idle1, shares, supply, Math.Rounding.Ceil);
    }

    function _withdraw(PoolId id, uint256 shares, uint256 supply, address receiver)
        internal
        returns (uint256 amount0, uint256 amount1)
    {
        PoolConfig storage c = _pools[id];
        PoolState storage st = poolState[id];
        _collectFees(id);

        // round everything down: the vault keeps the dust
        Position[] storage ps = _positions[id];
        for (uint256 i; i < ps.length; ++i) {
            uint256 remove = Math.mulDiv(ps[i].liquidity, shares, supply);
            if (remove == 0) continue;
            _modify(c.key, ps[i].tickLower, ps[i].tickUpper, -int256(remove));
            ps[i].liquidity -= uint128(remove);
        }
        uint256 idleTake0 = Math.mulDiv(st.idle0, shares, supply);
        uint256 idleTake1 = Math.mulDiv(st.idle1, shares, supply);
        st.idle0 -= idleTake0;
        st.idle1 -= idleTake1;
        c.key.currency0.settle(poolManager, address(this), idleTake0, true);
        c.key.currency1.settle(poolManager, address(this), idleTake1, true);

        amount0 = uint256(poolManager.currencyDelta(address(this), c.key.currency0));
        amount1 = uint256(poolManager.currencyDelta(address(this), c.key.currency1));
        c.key.currency0.take(poolManager, receiver, amount0, false);
        c.key.currency1.take(poolManager, receiver, amount1, false);
    }

    /// @dev Executes the queued intent: check it against the mandate and the oracle, then move liquidity.
    function _rebalance(PoolId id) internal {
        QueuedIntent storage q = _queued[id];
        if (q.deadline == 0) revert NothingQueued();
        if (block.timestamp > q.deadline) revert IMandate.IntentExpired();
        Range[] memory ranges = q.ranges;
        delete _queued[id];

        (uint160 poolSqrt, uint256 turnover, uint256 epochTurnover) = _checkAndRecord(id, ranges);
        _moveLiquidity(id, poolSqrt, ranges);
        emit Rebalanced(id, ranges, turnover, epochTurnover);
    }

    /// @dev Band, staleness, cooldown, range shape vs the oracle tick, per-epoch turnover. Records the turnover.
    function _checkAndRecord(PoolId id, Range[] memory ranges)
        internal
        returns (uint160 poolSqrt, uint256 turnover, uint256 epochTurnover)
    {
        PoolConfig storage c = _pools[id];
        PoolState storage st = poolState[id];
        Mandate memory m = c.mandate;

        uint160 oracleSqrt = oracleSqrtPriceX96(id);
        (poolSqrt,,,) = poolManager.getSlot0(id);
        MandateLib.checkBand(m, poolSqrt, oracleSqrt);
        MandateLib.checkCooldown(m, st.lastRebalanceAt, block.timestamp);
        MandateLib.checkRanges(m, ranges, TickMath.getTickAtSqrtPrice(oracleSqrt), c.key.tickSpacing);

        Position[] storage ps = _positions[id];
        Range[] memory old = new Range[](ps.length);
        for (uint256 i; i < ps.length; ++i) {
            old[i] = Range(ps[i].tickLower, ps[i].tickUpper, ps[i].weightBps);
        }
        turnover = MandateLib.turnoverBps(old, ranges);
        uint64 epoch = epochOf(id);
        uint256 soFar = epoch == st.turnoverEpoch ? st.epochTurnoverBps : 0;
        epochTurnover = MandateLib.checkTurnover(m, soFar, turnover);
        st.turnoverEpoch = epoch;
        st.epochTurnoverBps = uint32(epochTurnover);
        st.lastRebalanceAt = uint64(block.timestamp);
    }

    /// @dev Remove every position (this also collects fees), then add each new range with weightBps of each
    /// idle token. Whatever does not fit a range's ratio stays idle (the hook never swaps).
    /// Deltas are settled as ERC-6909 claims, so the hook's deltas net to zero.
    function _moveLiquidity(PoolId id, uint160 poolSqrt, Range[] memory ranges) internal {
        _removeAll(id);
        PoolKey storage key = _pools[id].key;
        PoolState storage st = poolState[id];
        Position[] storage ps = _positions[id];

        uint256 budget0 = st.idle0;
        uint256 budget1 = st.idle1;
        for (uint256 i; i < ranges.length; ++i) {
            Range memory r = ranges[i];
            uint128 liq = LiquidityAmounts.getLiquidityForAmounts(
                poolSqrt,
                TickMath.getSqrtPriceAtTick(r.tickLower),
                TickMath.getSqrtPriceAtTick(r.tickUpper),
                budget0 * r.weightBps / MandateLib.BPS,
                budget1 * r.weightBps / MandateLib.BPS
            );
            if (liq > 0) _modify(key, r.tickLower, r.tickUpper, int256(uint256(liq)));
            ps.push(Position(r.tickLower, r.tickUpper, r.weightBps, liq));
        }
        _netDeltaToIdle(key, st);
    }

    /// @dev Removes every position (fees come with it) into idle.
    function _removeAll(PoolId id) internal {
        PoolKey storage key = _pools[id].key;
        Position[] storage ps = _positions[id];
        for (uint256 i; i < ps.length; ++i) {
            if (ps[i].liquidity > 0) {
                _modify(key, ps[i].tickLower, ps[i].tickUpper, -int256(uint256(ps[i].liquidity)));
            }
        }
        delete _positions[id];
        _netDeltaToIdle(key, poolState[id]);
    }

    /// @dev Pokes every position so accrued fees land in idle before any pro-rata math.
    function _collectFees(PoolId id) internal {
        PoolConfig storage c = _pools[id];
        Position[] storage ps = _positions[id];
        for (uint256 i; i < ps.length; ++i) {
            if (ps[i].liquidity > 0) _modify(c.key, ps[i].tickLower, ps[i].tickUpper, 0);
        }
        _netDeltaToIdle(c.key, poolState[id]);
    }

    /// @dev Turns the hook's open deltas into ERC-6909 claims (credit) or burns claims (debit).
    function _netDeltaToIdle(PoolKey storage key, PoolState storage st) internal {
        st.idle0 = _netCurrency(key.currency0, st.idle0);
        st.idle1 = _netCurrency(key.currency1, st.idle1);
    }

    function _netCurrency(Currency currency, uint256 idle) internal returns (uint256) {
        int256 d = poolManager.currencyDelta(address(this), currency);
        if (d > 0) {
            currency.take(poolManager, address(this), uint256(d), true);
            return idle + uint256(d);
        }
        if (d < 0) {
            currency.settle(poolManager, address(this), uint256(-d), true);
            return idle - uint256(-d); // reverts if a range costs more than idle holds
        }
        return idle;
    }

    function _modify(PoolKey storage key, int24 tickLower, int24 tickUpper, int256 liquidityDelta) internal {
        poolManager.modifyLiquidity(
            key,
            ModifyLiquidityParams({
                tickLower: tickLower, tickUpper: tickUpper, liquidityDelta: liquidityDelta, salt: bytes32(0)
            }),
            ""
        );
    }

    /// @dev Cost of `shares` new shares: ceil(liquidity * shares / supply) of every position at the pool price
    /// (rounded up, as the PoolManager charges) plus ceil(idle * shares / supply). Mirrors _addProRata.
    function _costOf(PoolId id, uint160 sqrtPrice, uint256 shares, uint256 supply)
        internal
        view
        returns (uint256 cost0, uint256 cost1)
    {
        Position[] storage ps = _positions[id];
        for (uint256 i; i < ps.length; ++i) {
            uint128 add = uint128(Math.mulDiv(ps[i].liquidity, shares, supply, Math.Rounding.Ceil));
            (uint256 a0, uint256 a1) = _amountsForLiquidity(sqrtPrice, ps[i].tickLower, ps[i].tickUpper, add);
            cost0 += a0;
            cost1 += a1;
        }
        cost0 += Math.mulDiv(poolState[id].idle0, shares, supply, Math.Rounding.Ceil);
        cost1 += Math.mulDiv(poolState[id].idle1, shares, supply, Math.Rounding.Ceil);
    }

    function _amountsForLiquidity(uint160 sqrtPrice, int24 tickLower, int24 tickUpper, uint128 liquidity)
        internal
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        uint160 sqrtLower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 sqrtUpper = TickMath.getSqrtPriceAtTick(tickUpper);
        if (sqrtPrice <= sqrtLower) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtLower, sqrtUpper, liquidity, true);
        } else if (sqrtPrice < sqrtUpper) {
            amount0 = SqrtPriceMath.getAmount0Delta(sqrtPrice, sqrtUpper, liquidity, true);
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtPrice, liquidity, true);
        } else {
            amount1 = SqrtPriceMath.getAmount1Delta(sqrtLower, sqrtUpper, liquidity, true);
        }
    }

    function _cooldownPassed(PoolId id) internal view returns (bool) {
        uint256 last = poolState[id].lastRebalanceAt;
        return last == 0 || block.timestamp >= last + _pools[id].mandate.cooldown;
    }

    /// @dev Cheap pre-check for beforeSwap: oracle fresh and pool price within the band. Never reverts.
    function _bandOk(PoolId id) internal returns (bool) {
        try this.oracleSqrtPriceX96(id) returns (uint160 oracleSqrt) {
            (uint160 poolSqrt,,,) = poolManager.getSlot0(id);
            if (MandateLib.withinBand(poolSqrt, oracleSqrt, _pools[id].mandate.oracleBandBps)) return true;
            emit IntentSkipped(id, abi.encodeWithSelector(IMandate.OutOfBand.selector));
        } catch (bytes memory reason) {
            emit IntentSkipped(id, reason);
        }
        return false;
    }
}
