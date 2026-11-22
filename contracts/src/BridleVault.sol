// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {ERC20} from "@openzeppelin/contracts/token/ERC20/ERC20.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuardTransient} from "@openzeppelin/contracts/utils/ReentrancyGuardTransient.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Mandate} from "./interfaces/IMandate.sol";
import {BridleHook} from "./BridleHook.sol";

/// @notice ERC-20 shares over one Bridle pool. Deposits and withdrawals are in kind and pro rata,
/// so no price is used for share math. Holdings are tracked internally: donations do not move the share price.
/// shortcut: plain ERC-20s only (no fee-on-transfer/rebasing): internal accounting would overstate holdings and
/// the last withdrawers would revert. The curator picks the pair; list this in the README limits.
contract BridleVault is ERC20, ReentrancyGuardTransient {
    using SafeERC20 for IERC20;

    /// @dev Burned to a dead address on the first deposit so the share price can never be reset or inflated.
    uint256 public constant DEAD_SHARES = 1_000;
    /// @dev Smallest first deposit, measured in shares (sqrt(amount0 * amount1)).
    uint256 public constant MIN_FIRST_DEPOSIT_SHARES = 1_000_000;
    address internal constant DEAD = 0x000000000000000000000000000000000000dEaD;

    BridleHook public immutable hook;
    IERC20 public immutable token0;
    IERC20 public immutable token1;

    // shortcut: idle balances only; positions are added to holdings in phase 2a.
    uint256 public idle0;
    uint256 public idle1;

    event Deposit(address indexed sender, address indexed receiver, uint256 shares, uint256 amount0, uint256 amount1);
    event Withdraw(address indexed owner, address indexed receiver, uint256 shares, uint256 amount0, uint256 amount1);

    error NativeCurrencyUnsupported();
    error ZeroShares();
    error FirstDepositTooSmall();
    error Slippage();

    constructor(
        BridleHook _hook,
        PoolKey memory key,
        address feed,
        address curator,
        Mandate memory mandate,
        string memory name_,
        string memory symbol_
    ) ERC20(name_, symbol_) {
        // shortcut: ERC-20 pairs only (use WETH); native ETH needs payable deposit paths.
        if (key.currency0.isAddressZero()) revert NativeCurrencyUnsupported();
        hook = _hook;
        token0 = IERC20(Currency.unwrap(key.currency0));
        token1 = IERC20(Currency.unwrap(key.currency1));
        _hook.registerPool(key, feed, curator, mandate);
    }

    /// @notice Deposit up to amount0Max / amount1Max in the vault's current ratio.
    /// shortcut: oracle band check on deposits arrives with OracleGuard in phase 2a.
    function deposit(uint256 amount0Max, uint256 amount1Max, uint256 minShares, address receiver)
        external
        nonReentrant
        returns (uint256 shares, uint256 amount0, uint256 amount1)
    {
        uint256 supply = totalSupply();
        if (supply == 0) {
            (amount0, amount1) = (amount0Max, amount1Max);
            uint256 total = Math.sqrt(amount0 * amount1);
            if (total < MIN_FIRST_DEPOSIT_SHARES) revert FirstDepositTooSmall();
            shares = total - DEAD_SHARES;
            _mint(DEAD, DEAD_SHARES);
        } else {
            shares = type(uint256).max;
            if (idle0 > 0) shares = Math.mulDiv(amount0Max, supply, idle0);
            if (idle1 > 0) shares = Math.min(shares, Math.mulDiv(amount1Max, supply, idle1));
            if (shares == type(uint256).max) shares = 0; // nothing held: nothing to price against
            // round amounts up: the depositor pays the dust, never the vault
            amount0 = Math.mulDiv(shares, idle0, supply, Math.Rounding.Ceil);
            amount1 = Math.mulDiv(shares, idle1, supply, Math.Rounding.Ceil);
        }
        if (shares == 0) revert ZeroShares();
        if (shares < minShares) revert Slippage();

        idle0 += amount0;
        idle1 += amount1;
        _mint(receiver, shares);
        token0.safeTransferFrom(msg.sender, address(this), amount0);
        token1.safeTransferFrom(msg.sender, address(this), amount1);
        emit Deposit(msg.sender, receiver, shares, amount0, amount1);
    }

    /// @notice Burn shares for a pro-rata slice of every holding. No price, no pause, no fee: always available.
    function withdraw(uint256 shares, uint256 amount0Min, uint256 amount1Min, address receiver)
        external
        nonReentrant
        returns (uint256 amount0, uint256 amount1)
    {
        if (shares == 0) revert ZeroShares();
        uint256 supply = totalSupply();
        // round down: the vault keeps the dust
        amount0 = Math.mulDiv(shares, idle0, supply);
        amount1 = Math.mulDiv(shares, idle1, supply);
        if (amount0 < amount0Min || amount1 < amount1Min) revert Slippage();

        _burn(msg.sender, shares);
        idle0 -= amount0;
        idle1 -= amount1;
        token0.safeTransfer(receiver, amount0);
        token1.safeTransfer(receiver, amount1);
        emit Withdraw(msg.sender, receiver, shares, amount0, amount1);
    }
}
