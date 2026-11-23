// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {Currency} from "@uniswap/v4-core/src/types/Currency.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {PoolId} from "@uniswap/v4-core/src/types/PoolId.sol";
import {FeedConfig, Mandate, Range, RebalanceIntent} from "../../src/interfaces/IMandate.sol";
import {MockAggregator} from "../mocks/MockAggregator.sol";
import {BridleHook} from "../../src/BridleHook.sol";
import {BridleVault} from "../../src/BridleVault.sol";

/// @dev Fresh PoolManager + routers, two sorted mock tokens, a BridleHook at a flag address,
/// a registered vault and an initialized pool.
abstract contract BridleFixture is Test, Deployers {
    uint160 constant BRIDLE_FLAGS =
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG;

    BridleHook hook;
    BridleVault vault;
    MockAggregator oracle;
    uint256 constant MIN_BOND = 1e18;
    uint256 constant BASE_CAP = 1e30; // effectively uncapped; capacity has its own tests
    uint256 constant MAX_MULT = 4;
    uint256 curatorPk = 0xC0FFEE;
    address curator = vm.addr(curatorPk);

    function setUp() public virtual {
        vm.warp(1_700_000_000);
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        address hookAddr = address(BRIDLE_FLAGS ^ (0x4444 << 144));
        deployCodeTo("BridleHook.sol:BridleHook", abi.encode(manager), hookAddr);
        hook = BridleHook(hookAddr);

        // 8-decimal feed at 1.0 and two 18-decimal tokens: oracle sqrtPrice == SQRT_PRICE_1_1
        oracle = new MockAggregator(8, 1e8);
        key = PoolKey(currency0, currency1, 3000, 60, IHooks(hookAddr));
        vault = new BridleVault(
            hook, key, feedConfig(), curator, testMandate(), MIN_BOND, BASE_CAP, MAX_MULT, "Bridle Steady", "bSTEADY"
        );
        manager.initialize(key, SQRT_PRICE_1_1);
    }

    /// @dev The curator deposits like anyone and locks MIN_BOND of their shares, so the vault takes intents.
    function bondCurator() internal {
        IERC20 a = IERC20(Currency.unwrap(currency0));
        IERC20 b = IERC20(Currency.unwrap(currency1));
        a.transfer(curator, 2e18);
        b.transfer(curator, 2e18);
        vm.startPrank(curator);
        a.approve(address(vault), 2e18);
        b.approve(address(vault), 2e18);
        vault.deposit(2e18, 2e18, 0, curator);
        vault.lockBond(MIN_BOND);
        vm.stopPrank();
    }

    function feedConfig() internal view returns (FeedConfig memory) {
        return FeedConfig({aggregator: address(oracle), maxStaleness: 1 hours, baseIsToken0: true});
    }

    /// @dev Signs and queues an intent from the pool curator.
    function queue(Range[] memory ranges) internal {
        RebalanceIntent memory i = RebalanceIntent({
            poolId: PoolId.unwrap(key.toId()),
            curator: curator,
            ranges: ranges,
            nonce: hook.nonces(curator),
            deadline: block.timestamp + 1 hours
        });
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(curatorPk, hook.hashIntent(i));
        hook.queueIntent(i, abi.encodePacked(r, s, v));
    }

    function oneRange(int24 lo, int24 hi) internal pure returns (Range[] memory r) {
        r = new Range[](1);
        r[0] = Range(lo, hi, 10_000);
    }

    /// @dev Testnet params from CLAUDE.md: epochLength 5 min, amendmentDelay 10 min.
    function testMandate() internal pure returns (Mandate memory) {
        return Mandate({
            maxOracleDistanceTicks: 1200,
            maxTurnoverBpsPerEpoch: 10_000,
            minWidthTicks: 120,
            maxRanges: 3,
            oracleBandBps: 100,
            cooldown: 60,
            maxDrawdownBps: 1_000,
            perfFeeBps: 1_000,
            epochLength: 5 minutes,
            amendmentDelay: 10 minutes,
            maxIdleEpochs: 12
        });
    }
}
