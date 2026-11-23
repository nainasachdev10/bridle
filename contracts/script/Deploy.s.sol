// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Script, console} from "forge-std/Script.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "@uniswap/v4-core/src/interfaces/IPoolManager.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {HookMiner} from "@uniswap/v4-periphery/src/utils/HookMiner.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";
import {FeedConfig, Mandate} from "../src/interfaces/IMandate.sol";
import {BridleHook} from "../src/BridleHook.sol";
import {BridleVault} from "../src/BridleVault.sol";
import {DemoFeed, TestToken} from "./DemoContracts.sol";

/// @notice Deploys Bridle on Unichain Sepolia: test tokens, the hook at a mined CREATE2 address, a DEMO feed,
/// and three vaults (Steady + Agent on the real Chainlink ETH/USD feed, Reckless on the demo feed).
/// forge script script/Deploy.s.sol --rpc-url $UNICHAIN_SEPOLIA_RPC --account bridle-deployer --broadcast
contract Deploy is Script {
    // verified on chain 1301, Nov 23 2026 (see PROGRESS.md)
    IPoolManager constant POOL_MANAGER = IPoolManager(0x00B036B58a818B1BC34d502D3fE730Db729e62AC);
    address constant CHAINLINK_ETH_USD = 0xd9c93081210dFc33326B2af4C2c11848095E6a9a;

    uint32 constant REAL_MAX_STALENESS = 25 hours; // feed heartbeat is 24 h (or a 0.5% move)
    uint32 constant DEMO_MAX_STALENESS = 1 hours;
    uint160 constant FLAGS = Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG;

    // shares are sqrt(amount0 * amount1): 1 tWETH + 1,724 tUSDC is ~4.2e13 shares
    uint256 constant MIN_BOND = 1e12;
    uint256 constant BASE_CAP = 4e15;
    uint256 constant MAX_MULT = 4;

    struct Deployment {
        BridleHook hook;
        TestToken weth;
        TestToken usdc;
        DemoFeed demoFeed;
        BridleVault steady;
        BridleVault agent;
        BridleVault reckless;
    }

    function run() external returns (Deployment memory d) {
        address[3] memory curators = [
            vm.envOr("STEADY_CURATOR", msg.sender),
            vm.envOr("AGENT_CURATOR", msg.sender),
            vm.envOr("RECKLESS_CURATOR", msg.sender)
        ];
        vm.startBroadcast();
        d = deploy(POOL_MANAGER, CHAINLINK_ETH_USD, curators, msg.sender);
        vm.stopBroadcast();

        console.log("BridleHook ", address(d.hook));
        console.log("tWETH      ", address(d.weth));
        console.log("tUSDC      ", address(d.usdc));
        console.log("DemoFeed   ", address(d.demoFeed));
        console.log("Steady     ", address(d.steady));
        console.log("Agent      ", address(d.agent));
        console.log("Reckless   ", address(d.reckless));
    }

    function deploy(IPoolManager manager, address ethUsd, address[3] memory curators, address demoFeedOwner)
        public
        returns (Deployment memory d)
    {
        d.hook = _deployHook(manager);
        d.weth = new TestToken("Bridle Test WETH", "tWETH", 18);
        d.usdc = new TestToken("Bridle Test USDC", "tUSDC", 6);
        (, int256 ethPrice,,,) = AggregatorV3Interface(ethUsd).latestRoundData();
        d.demoFeed = new DemoFeed(demoFeedOwner, ethPrice); // starts at the real price

        d.steady = _vault(d, ethUsd, REAL_MAX_STALENESS, 3_000, 60, curators[0], 1_000, "Bridle Steady", "bSTEADY");
        d.agent = _vault(d, ethUsd, REAL_MAX_STALENESS, 500, 10, curators[1], 1_000, "Bridle Agent", "bAGENT");
        d.reckless = _vault(
            d,
            address(d.demoFeed),
            DEMO_MAX_STALENESS,
            10_000,
            200,
            curators[2],
            500,
            "Bridle Reckless (DEMO feed)",
            "bRECK"
        );
    }

    /// @dev CREATE2 through the standard factory, so the mined address is the same in a broadcast and a fork test.
    function _deployHook(IPoolManager manager) internal returns (BridleHook hook) {
        bytes memory args = abi.encode(manager);
        (address expected, bytes32 salt) = HookMiner.find(CREATE2_FACTORY, FLAGS, type(BridleHook).creationCode, args);
        (bool ok,) = CREATE2_FACTORY.call(abi.encodePacked(salt, type(BridleHook).creationCode, args));
        require(ok && expected.code.length > 0, "hook deploy failed");
        hook = BridleHook(expected);
        Hooks.validateHookPermissions(IHooks(expected), hook.getHookPermissions());
    }

    function _vault(
        Deployment memory d,
        address feed,
        uint32 maxStaleness,
        uint24 fee,
        int24 tickSpacing,
        address curator,
        uint16 maxDrawdownBps,
        string memory name,
        string memory symbol
    ) internal returns (BridleVault v) {
        bool wethFirst = address(d.weth) < address(d.usdc);
        (address c0, address c1) = wethFirst ? (address(d.weth), address(d.usdc)) : (address(d.usdc), address(d.weth));
        PoolKey memory key = PoolKey(Currency.wrap(c0), Currency.wrap(c1), fee, tickSpacing, IHooks(address(d.hook)));
        v = new BridleVault(
            d.hook,
            key,
            FeedConfig({aggregator: feed, maxStaleness: maxStaleness, baseIsToken0: wethFirst}),
            curator,
            mandate(maxDrawdownBps),
            MIN_BOND,
            BASE_CAP,
            MAX_MULT,
            name,
            symbol
        );
        // start the pool exactly at the oracle price (beforeInitialize rejects anything outside the band)
        d.hook.poolManager().initialize(key, d.hook.oracleSqrtPriceX96(key.toId()));
    }

    /// @dev Testnet terms from CLAUDE.md: 5-minute epochs, 10-minute amendment delay.
    function mandate(uint16 maxDrawdownBps) public pure returns (Mandate memory) {
        return Mandate({
            maxOracleDistanceTicks: 1_200,
            maxTurnoverBpsPerEpoch: 10_000,
            minWidthTicks: 200,
            maxRanges: 3,
            oracleBandBps: 100,
            cooldown: 60,
            maxDrawdownBps: maxDrawdownBps,
            perfFeeBps: 1_000,
            epochLength: 5 minutes,
            amendmentDelay: 10 minutes,
            maxIdleEpochs: 12
        });
    }
}
