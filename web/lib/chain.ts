import { createPublicClient, http, parseAbi } from "viem";
import { unichainSepolia } from "viem/chains";

/** Deployed on Unichain Sepolia, Nov 23 2026 (see PROGRESS.md). */
export const HOOK = "0x5a2017AA16Cde9e88f5e8Ed0928FFBcff1eA6880" as const;
export const STATE_VIEW = "0xc199f1072a74d4e905aba1a84d9a45e2546b6222" as const; // Uniswap v4 StateView
export const TWETH = "0x01163d86A5A3a818879f116e3cd66d5aff8aC855" as const;
export const TUSDC = "0x518a298ffACd7703c45C397823DDfD4C158ABBEF" as const;

export const VAULTS = [
  {
    address: "0x38dE68042435098bE0c8296a2F6FC0b3c22F7372",
    label: "Steady",
    feed: "Chainlink ETH/USD",
    strip: "stripes",
    blurb: "Wide ranges, few moves. The curator you pick when you'd rather not watch.",
  },
  {
    address: "0x5eFD71dB1A7dA5e3314Be8112174a76c26b20495",
    label: "Agent",
    feed: "Chainlink ETH/USD",
    strip: "hatch",
    blurb: "An automated curator that proposes ranges and signs its own intents.",
  },
  {
    address: "0xd0F560B18D535acc5C3F1ED6620de35eE0D8760F",
    label: "Reckless",
    feed: "Demo price feed",
    strip: "rings",
    blurb: "Narrow ranges on a demo feed, with a tight 5% breach line. Built to show what a breach does.",
  },
] as const;

export const EXPLORER = "https://unichain-sepolia.blockscout.com";

export const client = createPublicClient({ chain: unichainSepolia, transport: http() });

const MANDATE =
  "(uint24 maxOracleDistanceTicks, uint32 maxTurnoverBpsPerEpoch, uint24 minWidthTicks, uint8 maxRanges, uint16 oracleBandBps, uint32 cooldown, uint16 maxDrawdownBps, uint16 perfFeeBps, uint32 epochLength, uint32 amendmentDelay, uint16 maxIdleEpochs)";

export const vaultAbi = parseAbi([
  "function poolId() view returns (bytes32)",
  "function totalSupply() view returns (uint256)",
  "function index() view returns (uint256)",
  "function highWaterMark() view returns (uint256)",
  "function recordCount() view returns (uint256)",
  `function record(uint256) view returns ((uint64 epoch, uint64 closedAt, uint256 navPerShare, uint256 holdPerShare, uint256 ratio, uint256 index, uint256 highWaterMark, uint256 feeShares, uint32 turnoverBps, bool breached))`,
  "function goodEpochs() view returns (uint256)",
  "function capacity() view returns (uint256)",
  "function postedBond() view returns (uint256)",
  "function minBond() view returns (uint256)",
  "function isActive() view returns (bool)",
  "function amendmentApplyAfter() view returns (uint64)",
  `function pendingMandate() view returns ${MANDATE}`, // a public struct getter returns the fields one by one
]);

export const hookAbi = parseAbi([
  "function curatorOf(bytes32) view returns (address)",
  `function mandateOf(bytes32) view returns (${MANDATE})`,
  "function safeMode(bytes32) view returns (bool)",
  "function positions(bytes32) view returns ((int24 tickLower, int24 tickUpper, uint16 weightBps, uint128 liquidity)[])",
  "function oracleSqrtPriceX96(bytes32) view returns (uint160)",
]);

export const stateViewAbi = parseAbi([
  "function getSlot0(bytes32 poolId) view returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)",
]);
