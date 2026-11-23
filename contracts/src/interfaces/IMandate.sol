// SPDX-License-Identifier: MIT
pragma solidity ^0.8.26;

/// @notice A curator's terms. Every field is enforced on-chain by MandateLib / BridleHook.
struct Mandate {
    uint24 maxOracleDistanceTicks; // every range edge within this many ticks of the oracle tick
    uint32 maxTurnoverBpsPerEpoch; // running sum of rebalance turnovers per epoch (can exceed 10000)
    uint24 minWidthTicks; // tickUpper - tickLower >= this
    uint8 maxRanges; // number of ranges per rebalance
    uint16 oracleBandBps; // |poolPrice / oraclePrice - 1| <= this
    uint32 cooldown; // seconds between rebalances
    uint16 maxDrawdownBps; // breach when index < peakIndex * (1 - this)
    uint16 perfFeeBps; // <= MandateLib.MAX_PERF_FEE_BPS
    uint32 epochLength; // seconds
    uint32 amendmentDelay; // seconds between proposing and applying an amendment
    uint16 maxIdleEpochs; // epochs without a rebalance before liveness kicks in
}

/// @notice One liquidity range and the share of capital it gets.
struct Range {
    int24 tickLower;
    int24 tickUpper;
    uint16 weightBps; // all weights in an intent sum to 10000
}

/// @notice What a curator signs (EIP-712). Stored on-chain once queued; the hook never needs hookData.
struct RebalanceIntent {
    bytes32 poolId;
    address curator;
    Range[] ranges;
    uint256 nonce;
    uint256 deadline;
}

/// @notice Chainlink feed for a pool, given at registration.
struct FeedConfig {
    address aggregator;
    uint32 maxStaleness; // seconds; match the feed's heartbeat
    bool baseIsToken0; // feed quotes token0 in token1 (e.g. ETH/USD for WETH/USDC with WETH as token0)
}

interface IMandate {
    error MandateViolation(bytes32 term);
    error IntentExpired();
    error BadSignature();
    error BadNonce();
    error OracleStale();
    error OutOfBand();
    error NotCurator();
    error CapacityExceeded();
}
