// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {FeedConfig, Mandate} from "./interfaces/IMandate.sol";
import {BridleHook} from "./BridleHook.sol";

/// @notice ERC-20 shares over one Bridle pool. The hook holds the assets (positions + idle claims);
/// this contract is the share ledger. Deposits and withdrawals are in kind and pro rata on every position
/// and idle balance, so no price is used for share math.
/// shortcut: plain ERC-20s only (no fee-on-transfer/rebasing): internal accounting would overstate holdings and
/// the last withdrawers would revert. The curator picks the pair; list this in the README limits.
contract BridleVault is ERC20, ReentrancyGuardTransient {
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

    event Deposit(address indexed sender, address indexed receiver, uint256 shares, uint256 amount0, uint256 amount1);
    event Withdraw(address indexed owner, address indexed receiver, uint256 shares, uint256 amount0, uint256 amount1);

    error NativeCurrencyUnsupported();
    error ZeroShares();
    error FirstDepositTooSmall();
    error Slippage();

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
}
