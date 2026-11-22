// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

import {Test} from "forge-std/Test.sol";
import {Deployers} from "@uniswap/v4-core/test/utils/Deployers.sol";
import {IHooks} from "@uniswap/v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "@uniswap/v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "@uniswap/v4-core/src/types/PoolKey.sol";
import {Mandate} from "../../src/interfaces/IMandate.sol";
import {BridleHook} from "../../src/BridleHook.sol";
import {BridleVault} from "../../src/BridleVault.sol";

/// @dev Fresh PoolManager + routers, two sorted mock tokens, a BridleHook at a flag address,
/// a registered vault and an initialized pool.
abstract contract BridleFixture is Test, Deployers {
    uint160 constant BRIDLE_FLAGS =
        Hooks.BEFORE_INITIALIZE_FLAG | Hooks.BEFORE_ADD_LIQUIDITY_FLAG | Hooks.BEFORE_SWAP_FLAG;

    BridleHook hook;
    BridleVault vault;
    address feed = makeAddr("feed");
    address curator = makeAddr("curator");

    function setUp() public virtual {
        deployFreshManagerAndRouters();
        deployMintAndApprove2Currencies();

        address hookAddr = address(BRIDLE_FLAGS ^ (0x4444 << 144));
        deployCodeTo("BridleHook.sol:BridleHook", abi.encode(manager), hookAddr);
        hook = BridleHook(hookAddr);

        key = PoolKey(currency0, currency1, 3000, 60, IHooks(hookAddr));
        vault = new BridleVault(hook, key, feed, curator, testMandate(), "Bridle Steady", "bSTEADY");
        manager.initialize(key, SQRT_PRICE_1_1);
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
