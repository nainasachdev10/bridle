// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {SqrtPriceMath} from "@uniswap/v4-core/src/libraries/SqrtPriceMath.sol";
import {EpochRecord, FeedConfig, Mandate} from "./interfaces/IMandate.sol";
import {BridleHook} from "./BridleHook.sol";
import {TrackRecord} from "./TrackRecord.sol";

/// @notice ERC-20 shares over one Bridle pool. The hook holds the assets (positions + idle claims);
/// this contract is the share ledger. Deposits and withdrawals are in kind and pro rata on every position
/// and idle balance, so no price is used for share math.
/// shortcut: plain ERC-20s only (no fee-on-transfer/rebasing): internal accounting would overstate holdings and
/// the last withdrawers would revert. The curator picks the pair; list this in the README limits.
contract BridleVault is ERC20, ReentrancyGuardTransient, TrackRecord {
    using SafeERC20 for IERC20;
    using PoolIdLibrary for PoolKey;

    /// @dev Burned to a dead address on the first deposit so the share price can never be reset or inflated.
    uint256 public constant DEAD_SHARES = 1_000;
    /// @dev Smallest first deposit, measured in shares (sqrt(amount0 * amount1)).
    uint256 public constant MIN_FIRST_DEPOSIT_SHARES = 1_000_000;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    BridleHook public immutable hook;
    PoolId public immutable poolId;
    IERC20 public immutable token0;
    IERC20 public immutable token1;

    /// @notice The epoch being scored, and its start snapshot: the tokens the vault held, valued at the
    /// oracle price, and the share supply. Deposits and withdrawals are pro rata, so per share this is fixed.
    uint64 public currentEpoch;
    uint256 public holdAmount0;
    uint256 public holdAmount1;
    uint256 public holdSupply;
    /// @notice Last close's fee shares, held here as the curator's bond until the next close.
    uint256 public bondShares;

    event Deposit(address indexed sender, address indexed receiver, uint256 shares, uint256 amount0, uint256 amount1);
    event Withdraw(address indexed owner, address indexed receiver, uint256 shares, uint256 amount0, uint256 amount1);

    error NativeCurrencyUnsupported();
    error ZeroShares();
    error FirstDepositTooSmall();
    error Slippage();
    error NothingToClose();
    error EpochNotOver();

    constructor(
        BridleHook _hook,
        PoolKey memory key,
        FeedConfig memory feed,
        address curator,
        Mandate memory mandate,
        string memory name_,
        string memory symbol_
    ) ERC20(name_, symbol_) {
        // shortcut: ERC-20 pairs only (use WETH); native ETH needs payable deposit paths.
        if (key.currency0.isAddressZero()) revert NativeCurrencyUnsupported();
        hook = _hook;
        poolId = key.toId();
        token0 = IERC20(Currency.unwrap(key.currency0));
        token1 = IERC20(Currency.unwrap(key.currency1));
        _hook.registerPool(key, feed, curator, mandate);
    }

    /// @notice Deposit up to amount0Max / amount1Max in the vault's current ratio; the unused part is refunded.
    /// The first deposit takes both amounts exactly and sets the ratio.
    /// Reverts OutOfBand / OracleStale unless the pool price is within the mandate's band of a fresh oracle.
    function deposit(uint256 amount0Max, uint256 amount1Max, uint256 minShares, address receiver)
        external
        nonReentrant
        returns (uint256 shares, uint256 amount0, uint256 amount1)
    {
        uint256 supply = totalSupply();
        token0.safeTransferFrom(msg.sender, address(hook), amount0Max);
        token1.safeTransferFrom(msg.sender, address(hook), amount1Max);
        (shares, amount0, amount1) = hook.deposit(poolId, msg.sender, amount0Max, amount1Max, supply);

        if (supply == 0) {
            if (shares < MIN_FIRST_DEPOSIT_SHARES) revert FirstDepositTooSmall();
            shares -= DEAD_SHARES;
            _mint(DEAD, DEAD_SHARES);
        }
        if (shares == 0) revert ZeroShares();
        if (shares < minShares) revert Slippage();
        _mint(receiver, shares);
        // first deposit: everything is idle, so the start snapshot is exactly what was paid in
        if (supply == 0) _snapshot(amount0, amount1, hook.epochOf(poolId));
        emit Deposit(msg.sender, receiver, shares, amount0, amount1);
    }

    /// @notice Burn shares for a pro-rata slice of every position and idle balance. No price, no pause,
    /// no fee: works with the curator suspended, the oracle stale or safe mode on.
    function withdraw(uint256 shares, uint256 amount0Min, uint256 amount1Min, address receiver)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        if (shares == 0) revert ZeroShares();
        uint256 supply = totalSupply();
        _burn(msg.sender, shares);
        (amount0, amount1) = hook.withdraw(poolId, shares, supply, receiver);
        if (amount0 < amount0Min || amount1 < amount1Min) revert Slippage();
        emit Withdraw(msg.sender, receiver, shares, amount0, amount1);
    }

    /// @notice Permissionless. Scores the finished epoch against simply holding, compounds the index, and
    /// pays the performance fee on index above the high-water mark (CLAUDE.md "Key formulas").
    /// All values at the Chainlink price, never the pool price. Reverts OracleStale; withdrawals don't need it.
    function closeEpoch() external nonReentrant returns (EpochRecord memory r) {
        uint256 supply = totalSupply();
        if (supply == 0) revert NothingToClose();
        uint64 nowEpoch = hook.epochOf(poolId);
        if (nowEpoch <= currentEpoch) revert EpochNotOver();

        (uint256 amount0, uint256 amount1, uint160 sqrtP) = _holdings();
        r.epoch = currentEpoch;
        r.closedAt = uint64(block.timestamp);
        r.navPerShare = Math.mulDiv(_value(amount0, amount1, sqrtP), WAD, supply);
        r.holdPerShare = Math.mulDiv(_value(holdAmount0, holdAmount1, sqrtP), WAD, holdSupply);
        r.ratio = Math.mulDiv(r.navPerShare, WAD, r.holdPerShare);
        r.index = Math.mulDiv(index, r.ratio, WAD);

        BridleHook.PoolConfig memory c = hook.poolConfig(poolId);
        // the bond survived an epoch: hand it to the curator (2c burns it instead on a breach)
        if (bondShares > 0) {
            _transfer(address(this), c.curator, bondShares);
            bondShares = 0;
        }
        if (r.index > highWaterMark) {
            // f = perfFee * (index - hwm) / index; minting supply * f / (1 - f) gives the curator exactly f
            uint256 f = Math.mulDiv(r.index - highWaterMark, uint256(c.mandate.perfFeeBps) * WAD / 10_000, r.index);
            r.feeShares = Math.mulDiv(supply, f, WAD - f);
            highWaterMark = r.index;
            if (r.feeShares > 0) {
                bondShares = r.feeShares;
                _mint(address(this), r.feeShares);
                emit FeeMinted(c.curator, r.feeShares, r.index, r.index);
            }
        }
        index = r.index;
        r.highWaterMark = highWaterMark;
        (,,,, uint64 turnoverEpoch, uint32 turnoverBps) = hook.poolState(poolId);
        if (turnoverEpoch == currentEpoch) r.turnoverBps = turnoverBps;
        _records.push(r);
        emit EpochClosed(r.epoch, r.navPerShare, r.holdPerShare, r.ratio, r.index, r.highWaterMark);

        _snapshot(amount0, amount1, nowEpoch);
    }

    /// @dev What the pool holds, valued at the ORACLE price: fees collected into idle first, then each
    /// position's amounts at the oracle sqrtPrice (rounded down) plus idle. Reverts OracleStale.
    function _holdings() internal returns (uint256 amount0, uint256 amount1, uint160 sqrtP) {
        sqrtP = hook.oracleSqrtPriceX96(poolId);
        hook.collectFees(poolId);
        BridleHook.Position[] memory ps = hook.positions(poolId);
        for (uint256 i; i < ps.length; ++i) {
            (uint256 a0, uint256 a1) = _amountsAt(sqrtP, ps[i].tickLower, ps[i].tickUpper, ps[i].liquidity);
            amount0 += a0;
            amount1 += a1;
        }
        (uint256 idle0, uint256 idle1,,,,) = hook.poolState(poolId);
        amount0 += idle0;
        amount1 += idle1;
    }

    /// @dev A position's token amounts if the pool were at sqrtP, rounded down (we are valuing, not paying).
    function _amountsAt(uint160 sqrtP, int24 tickLower, int24 tickUpper, uint128 liquidity)
        internal
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        uint160 lower = TickMath.getSqrtPriceAtTick(tickLower);
        uint160 upper = TickMath.getSqrtPriceAtTick(tickUpper);
        if (sqrtP < lower) sqrtP = lower;
        if (sqrtP > upper) sqrtP = upper;
        amount0 = SqrtPriceMath.getAmount0Delta(sqrtP, upper, liquidity, false);
        amount1 = SqrtPriceMath.getAmount1Delta(lower, sqrtP, liquidity, false);
    }

    function _snapshot(uint256 amount0, uint256 amount1, uint64 epoch) internal {
        holdAmount0 = amount0;
        holdAmount1 = amount1;
        holdSupply = totalSupply();
        currentEpoch = epoch;
    }

    /// @dev Value in token1 raw units at sqrtPriceX96: amount0 * price + amount1.
    function _value(uint256 amount0, uint256 amount1, uint160 sqrtP) internal pure returns (uint256) {
        return Math.mulDiv(Math.mulDiv(amount0, sqrtP, 1 << 96), sqrtP, 1 << 96) + amount1;
    }
}
