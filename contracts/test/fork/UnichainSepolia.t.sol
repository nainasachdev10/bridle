// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {StateLibrary} from "@uniswap/v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "@uniswap/v4-core/src/libraries/TickMath.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {SwapParams} from "@uniswap/v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "@uniswap/v4-core/src/test/PoolSwapTest.sol";
import {AggregatorV3Interface} from "../../src/interfaces/AggregatorV3Interface.sol";
import {EpochRecord, Range, RebalanceIntent} from "../../src/interfaces/IMandate.sol";
import {BridleHook} from "../../src/BridleHook.sol";
import {BridleVault} from "../../src/BridleVault.sol";
import {Deploy} from "../../script/Deploy.s.sol";
import {TestToken} from "../../script/DemoContracts.sol";

/// @dev Runs the real deploy against Unichain Sepolia's PoolManager and Chainlink ETH/USD feed.
/// Skipped unless UNICHAIN_SEPOLIA_RPC is set:  UNICHAIN_SEPOLIA_RPC=https://sepolia.unichain.org forge test --mc Fork
contract UnichainSepoliaForkTest is Test {
    using StateLibrary for IPoolManager;

    PoolSwapTest constant SWAP_ROUTER = PoolSwapTest(0x9140a78c1A137c7fF1c151EC8231272aF78a99A4);
    address constant ETH_USD = 0xd9c93081210dFc33326B2af4C2c11848095E6a9a;

    Deploy.Deployment d;
    uint256 curatorPk = 0xC0FFEE;
    address curator = vm.addr(curatorPk);
    address alice = makeAddr("alice");

    function setUp() public {
        string memory rpc = vm.envOr("UNICHAIN_SEPOLIA_RPC", string(""));
        vm.skip(bytes(rpc).length == 0);
        vm.createSelectFork(rpc);
        Deploy deployer = new Deploy();
        d = deployer.deploy(
            IPoolManager(0x00B036B58a818B1BC34d502D3fE730Db729e62AC),
            ETH_USD,
            [curator, curator, curator],
            address(this)
        );
    }

    function _key(BridleVault v) internal view returns (PoolKey memory k) {
        (address c0, address c1) =
            address(d.weth) < address(d.usdc) ? (address(d.weth), address(d.usdc)) : (address(d.usdc), address(d.weth));
        (uint24 fee, int24 spacing) = v == d.steady ? (uint24(3_000), int24(60)) : (uint24(500), int24(10));
        k = PoolKey(Currency.wrap(c0), Currency.wrap(c1), fee, spacing, IHooks(address(d.hook)));
    }

    function _fund(address who, BridleVault v) internal {
        d.weth.mint(who, 100e18);
        d.usdc.mint(who, 500_000e6);
        vm.startPrank(who);
        d.weth.approve(address(v), type(uint256).max);
        d.usdc.approve(address(v), type(uint256).max);
        d.weth.approve(address(SWAP_ROUTER), type(uint256).max);
        d.usdc.approve(address(SWAP_ROUTER), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev (weth, usdc) amounts in the pool's currency order.
    function _ordered(uint256 wethAmt, uint256 usdcAmt) internal view returns (uint256, uint256) {
        return address(d.weth) < address(d.usdc) ? (wethAmt, usdcAmt) : (usdcAmt, wethAmt);
    }

    function _depositEthUsd(address who, BridleVault v, uint256 wethAmt, uint256 usdcAmt) internal {
        (uint256 a0, uint256 a1) = _ordered(wethAmt, usdcAmt);
        vm.prank(who);
        v.deposit(a0, a1, 0, who);
    }

    // ================================================================ deployment

    function test_fork_hookAddressAndPermissions() public view {
        assertEq(
            uint160(address(d.hook)) & Hooks.ALL_HOOK_MASK,
            Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG
        );
        Hooks.validateHookPermissions(IHooks(address(d.hook)), d.hook.getHookPermissions());
    }

    /// @dev The hook's price must equal the real Chainlink price: decimals (8 feed, 18 tWETH, 6 tUSDC) and
    /// currency order are right, and the pool starts exactly there.
    function test_fork_oraclePriceMatchesChainlink() public view {
        (, int256 answer,,,) = AggregatorV3Interface(ETH_USD).latestRoundData();
        uint160 sqrtP = d.hook.oracleSqrtPriceX96(d.steady.poolId());
        // usdc per weth in whole tokens, 1e8 scale like the feed
        uint256 priceX192 = uint256(sqrtP) * uint256(sqrtP);
        uint256 usdPerEth = address(d.weth) < address(d.usdc)
            ? Math.mulDiv(priceX192, 1e18 * 1e8, uint256(1e6) << 192)
            : Math.mulDiv(uint256(1) << 192, 1e18 * 1e8, priceX192 * 1e6);
        assertApproxEqRel(usdPerEth, uint256(answer), 1e14, "hook price vs Chainlink"); // 0.01%
        (uint160 poolSqrt,,,) = IPoolManager(address(d.hook.poolManager())).getSlot0(d.steady.poolId());
        assertEq(poolSqrt, sqrtP, "pool starts at the oracle price");
    }

    // ================================================================ full flow, cold storage

    function test_fork_depositRebalanceInsideSwap_closeEpoch_gas() public {
        BridleVault v = d.steady;
        PoolId id = v.poolId();
        _fund(alice, v);
        _fund(curator, v);
        _depositEthUsd(alice, v, 10e18, 17_400e6); // ~10 ETH of each side at ~$1,724
        vm.startPrank(curator);
        (uint256 c0, uint256 c1) = _ordered(1e18, 2_000e6);
        v.deposit(c0, c1, 0, curator);
        v.lockBond(1e12);
        vm.stopPrank();

        // three ranges around the oracle tick
        int24 center = TickMath.getTickAtSqrtPrice(d.hook.oracleSqrtPriceX96(id)) / 60 * 60;
        Range[] memory r = new Range[](3);
        r[0] = Range(center - 600, center + 600, 5_000);
        r[1] = Range(center - 1_140, center + 1_140, 3_000);
        r[2] = Range(center - 300, center + 300, 2_000);
        RebalanceIntent memory it = RebalanceIntent({
            poolId: PoolId.unwrap(id),
            curator: curator,
            ranges: r,
            nonce: d.hook.nonces(curator),
            deadline: block.timestamp + 1 hours
        });
        (uint8 v8, bytes32 rs, bytes32 s) = vm.sign(curatorPk, d.hook.hashIntent(it));
        d.hook.queueIntent(it, abi.encodePacked(rs, s, v8));

        // a real swap through Uniswap's deployed test router executes the rebalance in beforeSwap
        bool zeroForOne = true;
        (uint160 p,,,) = IPoolManager(address(d.hook.poolManager())).getSlot0(id);
        uint256 g = gasleft();
        vm.prank(alice);
        SWAP_ROUTER.swap(
            _key(v),
            SwapParams({
                zeroForOne: zeroForOne, amountSpecified: -1e15, sqrtPriceLimitX96: uint160(uint256(p) * 99 / 100)
            }),
            PoolSwapTest.TestSettings({takeClaims: false, settleUsingBurn: false}),
            ""
        );
        uint256 swapGas = g - gasleft();
        emit log_named_uint("cold: swap + 3-range deployment in beforeSwap", swapGas);
        assertEq(d.hook.queuedIntent(id).deadline, 0, "executed inside the swap");
        assertEq(d.hook.positions(id).length, 3);

        // next epoch: score it with the real (up to 24 h old) Chainlink price
        vm.warp(block.timestamp + 5 minutes);
        g = gasleft();
        EpochRecord memory rec = v.closeEpoch();
        emit log_named_uint("cold: closeEpoch with 3 positions", g - gasleft());
        emit log_named_decimal_uint("epoch ratio", rec.ratio, 18);
        assertEq(v.recordCount(), 1);
    }
}
