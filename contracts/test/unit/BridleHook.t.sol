// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {LPFeeLibrary} from "@uniswap/v4-core/src/libraries/LPFeeLibrary.sol";
import {CustomRevert} from "@uniswap/v4-core/src/libraries/CustomRevert.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {BaseHook} from "@openzeppelin/uniswap-hooks/src/base/BaseHook.sol";
import {FeedConfig, Mandate, IMandate} from "../../src/interfaces/IMandate.sol";
import {BridleHook} from "../../src/BridleHook.sol";
import {BridleVault} from "../../src/BridleVault.sol";
import {BridleFixture} from "../utils/BridleFixture.sol";

contract BridleHookTest is BridleFixture {
    using StateLibrary for IPoolManager;

    // ---------------------------------------------------------------- permissions + address mining

    function test_permissions_exactlyThree() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeInitialize && p.beforeAddLiquidity && p.beforeSwap);
        assertFalse(
            p.afterInitialize || p.afterAddLiquidity || p.beforeRemoveLiquidity || p.afterRemoveLiquidity || p.afterSwap
                || p.beforeDonate || p.afterDonate || p.beforeSwapReturnDelta || p.afterSwapReturnDelta
                || p.afterAddLiquidityReturnDelta || p.afterRemoveLiquidityReturnDelta
        );
        assertEq(uint160(address(hook)) & Hooks.ALL_HOOK_MASK, BRIDLE_FLAGS);
    }

    function test_mining_findsValidAddress() public {
        bytes memory args = abi.encode(manager);
        (address expected, bytes32 salt) =
            HookMiner.find(address(this), BRIDLE_FLAGS, type(BridleHook).creationCode, args);
        BridleHook mined = new BridleHook{salt: salt}(manager);

        assertEq(address(mined), expected);
        assertEq(uint160(address(mined)) & Hooks.ALL_HOOK_MASK, BRIDLE_FLAGS);
        Hooks.validateHookPermissions(IHooks(address(mined)), mined.getHookPermissions());
    }

    function test_revert_deployAtUnminedAddress() public {
        // a plain CREATE address almost surely has the wrong flag bits; the BaseHook constructor rejects it
        vm.expectRevert();
        new BridleHook(manager);
    }

    // ---------------------------------------------------------------- beforeInitialize: registration

    function test_init_registeredPool() public view {
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(key.toId());
        assertEq(sqrtPriceX96, SQRT_PRICE_1_1);
        BridleHook.PoolConfig memory c = hook.poolConfig(key.toId());
        assertEq(c.vault, address(vault));
        assertEq(address(c.feed.aggregator), address(oracle));
        assertEq(c.feed.feedDecimals, 8);
        assertEq(c.curator, curator);
        assertEq(c.mandate.perfFeeBps, testMandate().perfFeeBps);
    }

    function test_init_revert_unregisteredPool() public {
        PoolKey memory other = PoolKey(currency0, currency1, 500, 10, IHooks(address(hook)));
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeInitialize.selector,
                abi.encodeWithSelector(BridleHook.PoolNotRegistered.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        manager.initialize(other, SQRT_PRICE_1_1);
    }

    function test_register_revert_alreadyRegistered() public {
        vm.expectRevert(BridleHook.AlreadyRegistered.selector);
        new BridleVault(hook, key, feedConfig(), curator, testMandate(), MIN_BOND, "x", "x");
    }

    function test_register_revert_otherHook() public {
        PoolKey memory other = PoolKey(currency0, currency1, 500, 10, IHooks(address(0xBEEF)));
        vm.expectRevert(BaseHook.InvalidPool.selector);
        hook.registerPool(other, feedConfig(), curator, testMandate());
    }

    function test_register_revert_badMandate() public {
        PoolKey memory other = PoolKey(currency0, currency1, 500, 10, IHooks(address(hook)));
        Mandate memory m = testMandate();
        m.perfFeeBps = 2_001;
        vm.expectRevert(abi.encodeWithSelector(IMandate.MandateViolation.selector, bytes32("perfFeeBps")));
        new BridleVault(hook, other, feedConfig(), curator, m, MIN_BOND, "x", "x");
    }

    function test_register_revert_dynamicFee() public {
        PoolKey memory other = PoolKey(currency0, currency1, LPFeeLibrary.DYNAMIC_FEE_FLAG, 10, IHooks(address(hook)));
        vm.expectRevert(BridleHook.DynamicFeeUnsupported.selector);
        new BridleVault(hook, other, feedConfig(), curator, testMandate(), MIN_BOND, "x", "x");
    }

    function test_register_revert_zeroFeedOrCurator() public {
        PoolKey memory other = PoolKey(currency0, currency1, 500, 10, IHooks(address(hook)));
        vm.expectRevert(BridleHook.ZeroAddress.selector);
        FeedConfig memory f = feedConfig();
        f.aggregator = address(0);
        new BridleVault(hook, other, f, curator, testMandate(), MIN_BOND, "x", "x");
        vm.expectRevert(BridleHook.ZeroAddress.selector);
        new BridleVault(hook, other, feedConfig(), address(0), testMandate(), MIN_BOND, "x", "x");
    }

    // ---------------------------------------------------------------- beforeAddLiquidity

    function test_addLiquidity_revert_outsideLp() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                CustomRevert.WrappedError.selector,
                address(hook),
                IHooks.beforeAddLiquidity.selector,
                abi.encodeWithSelector(BridleHook.AddLiquidityDisabled.selector),
                abi.encodeWithSelector(Hooks.HookCallFailed.selector)
            )
        );
        modifyLiquidityRouter.modifyLiquidity(key, LIQUIDITY_PARAMS, ZERO_BYTES);
    }

    // ---------------------------------------------------------------- beforeSwap

    function test_swap_passesWithoutHookData() public {
        // no liquidity yet: the swap only moves the price, but it runs through beforeSwap with empty hookData
        swap(key, true, -1e15, ZERO_BYTES);
        (uint160 sqrtPriceX96,,,) = manager.getSlot0(key.toId());
        assertLt(sqrtPriceX96, SQRT_PRICE_1_1);
    }

    // ---------------------------------------------------------------- only PoolManager

    function test_revert_callbacksOnlyFromPoolManager() public {
        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.beforeInitialize(address(this), key, SQRT_PRICE_1_1);

        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.beforeAddLiquidity(address(this), key, LIQUIDITY_PARAMS, ZERO_BYTES);

        vm.expectRevert(BaseHook.NotPoolManager.selector);
        hook.beforeSwap(address(this), key, SwapParams(true, -1, MIN_PRICE_LIMIT), ZERO_BYTES);
    }
}
