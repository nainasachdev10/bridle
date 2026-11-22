// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId, PoolIdLibrary} from "@uniswap/v4-core/src/types/PoolId.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "@uniswap/v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {Mandate} from "./interfaces/IMandate.sol";
import {MandateLib} from "./libraries/MandateLib.sol";
import {IntentVerifier} from "./IntentVerifier.sol";

/// @notice Uniswap v4 hook for curated liquidity under an enforceable mandate.
/// Permissions are exactly beforeInitialize, beforeAddLiquidity, beforeSwap.
contract BridleHook is BaseHook, IntentVerifier {
    using PoolIdLibrary for PoolKey;
    using LPFeeLibrary for uint24;

    struct PoolConfig {
        address vault;
        address feed; // Chainlink aggregator
        address curator;
        Mandate mandate;
    }

    mapping(PoolId => PoolConfig) internal _pools;

    event PoolRegistered(PoolId indexed poolId, address indexed vault, address feed, address indexed curator);

    error AlreadyRegistered();
    error PoolNotRegistered();
    error AddLiquidityDisabled();
    error DynamicFeeUnsupported();
    error ZeroAddress();

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

    /// @notice Called by a BridleVault from its constructor; the caller becomes the pool's vault.
    /// A squatter can only occupy a pool key nobody else uses: depositors choose the vault, not the key.
    function registerPool(PoolKey calldata key, address feed, address curator, Mandate calldata mandate)
        external
        onlyValidPools(key.hooks)
    {
        // the hook never sets a fee, so a dynamic-fee pool would pay LPs 0% forever
        if (key.fee.isDynamicFee()) revert DynamicFeeUnsupported();
        if (feed == address(0) || curator == address(0)) revert ZeroAddress();
        PoolId id = key.toId();
        if (_pools[id].vault != address(0)) revert AlreadyRegistered();
        MandateLib.validateMandate(mandate);
        _pools[id] = PoolConfig({vault: msg.sender, feed: feed, curator: curator, mandate: mandate});
        emit PoolRegistered(id, msg.sender, feed, curator);
    }

    function poolConfig(PoolId id) external view returns (PoolConfig memory) {
        return _pools[id];
    }

    /// @dev Only pools bound to a registered vault + feed can be created with this hook.
    function _beforeInitialize(address, PoolKey calldata key, uint160) internal view override returns (bytes4) {
        if (_pools[key.toId()].vault == address(0)) revert PoolNotRegistered();
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

    /// @dev Phase 2a: execute a queued intent here. Returns zero delta and no fee override.
    function _beforeSwap(address, PoolKey calldata, SwapParams calldata, bytes calldata)
        internal
        pure
        override
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
    }
}
