import { createPublicClient, http, parseAbi } from "viem";
import { unichainSepolia } from "viem/chains";

/** Deployed on Unichain Sepolia, Nov 23 2026 (see PROGRESS.md). */
export const HOOK = "0x5a2017AA16Cde9e88f5e8Ed0928FFBcff1eA6880" as const;
export const STATE_VIEW = "0xc199f1072a74d4e905aba1a84d9a45e2546b6222" as const; // Uniswap v4 StateView
export const TWETH = "0x01163d86A5A3a818879f116e3cd66d5aff8aC855" as const;
export const TUSDC = "0x518a298ffACd7703c45C397823DDfD4C158ABBEF" as const;
export const WETH_IS_TOKEN0 = BigInt(TWETH) < BigInt(TUSDC);

export const VAULTS = [
  {
    address: "0x38dE68042435098bE0c8296a2F6FC0b3c22F7372",
    label: "Steady",
    fee: 3000,
    tickSpacing: 60, // fee + tickSpacing: Deploy.s.sol (they make up the pool key)
    feed: "Chainlink ETH/USD",
    strip: "stripes",
    blurb: "Wide ranges, few moves. The curator you pick when you'd rather not watch.",
  },
  {
    address: "0x5eFD71dB1A7dA5e3314Be8112174a76c26b20495",
    label: "Agent",
    fee: 500,
    tickSpacing: 10, // Deploy.s.sol
    feed: "Chainlink ETH/USD",
    strip: "hatch",
    blurb: "An automated curator that proposes ranges and signs its own intents.",
  },
  {
    address: "0xd0F560B18D535acc5C3F1ED6620de35eE0D8760F",
    label: "Reckless",
    fee: 10000,
    tickSpacing: 200, // Deploy.s.sol
    feed: "Demo price feed",
    strip: "rings",
    blurb: "Narrow ranges on a demo feed, with a tight 5% breach line. Built to show what a breach does.",
  },
] as const;

/** EIP-712 domain and types of a curator's signed move (BridleHook's RebalanceIntent). */
export const INTENT_DOMAIN = { name: "Bridle", version: "1", chainId: 1301, verifyingContract: HOOK } as const;
export const INTENT_TYPES = {
  RebalanceIntent: [
    { name: "poolId", type: "bytes32" },
    { name: "curator", type: "address" },
    { name: "ranges", type: "Range[]" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
  Range: [
    { name: "tickLower", type: "int24" },
    { name: "tickUpper", type: "int24" },
    { name: "weightBps", type: "uint16" },
  ],
} as const;

export const EXPLORER = "https://unichain-sepolia.blockscout.com";

export const client = createPublicClient({ chain: unichainSepolia, transport: http() });

const MANDATE =
  "(uint24 maxOracleDistanceTicks, uint32 maxTurnoverBpsPerEpoch, uint24 minWidthTicks, uint8 maxRanges, uint16 oracleBandBps, uint32 cooldown, uint16 maxDrawdownBps, uint16 perfFeeBps, uint32 epochLength, uint32 amendmentDelay, uint16 maxIdleEpochs)";

// every custom error the vault and hook can revert with, so viem can name them
const ERRORS = [
  "error MandateViolation(bytes32 term)", "error IntentExpired()", "error BadSignature()", "error BadNonce()",
  "error OracleStale()", "error OutOfBand()", "error NotCurator()", "error CapacityExceeded()", "error CuratorNotActive()",
  "error EpochNotOver()", "error FirstDepositTooSmall()", "error InDrawdown()", "error NothingQueued()",
  "error NothingToClose()", "error NoticeNotOver()", "error PoolNotRegistered()", "error SafeModeOn()", "error Slippage()",
  "error ZeroShares()", "error BondTooLarge()", "error NoAmendmentReady()",
] as const;

const RANGE = "(int24 tickLower, int24 tickUpper, uint16 weightBps)";

export const vaultAbi = parseAbi([
  ...ERRORS,
  "function balanceOf(address) view returns (uint256)",
  "function currentEpoch() view returns (uint64)",
  "function deposit(uint256 amount0Max, uint256 amount1Max, uint256 minShares, address receiver) returns (uint256 shares, uint256 amount0, uint256 amount1)",
  "function withdraw(uint256 shares, uint256 amount0Min, uint256 amount1Min, address receiver) returns (uint256 amount0, uint256 amount1)",
  "function lockBond(uint256 shares)",
  "function closeEpoch()",
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
  ...ERRORS,
  "function nonces(address) view returns (uint256)",
  "function epochOf(bytes32) view returns (uint64)",
  "function poolState(bytes32) view returns (uint256 idle0, uint256 idle1, uint64 startTime, uint64 lastRebalanceAt, uint64 turnoverEpoch, uint32 epochTurnoverBps)",
  `function queuedIntent(bytes32) view returns ((uint256 deadline, ${RANGE}[] ranges))`,
  `function queueIntent((bytes32 poolId, address curator, ${RANGE}[] ranges, uint256 nonce, uint256 deadline) intent, bytes signature)`,
  "function executeQueued(bytes32 id)",
  "function curatorOf(bytes32) view returns (address)",
  `function mandateOf(bytes32) view returns (${MANDATE})`,
  "function safeMode(bytes32) view returns (bool)",
  "function positions(bytes32) view returns ((int24 tickLower, int24 tickUpper, uint16 weightBps, uint128 liquidity)[])",
  "function oracleSqrtPriceX96(bytes32) view returns (uint160)",
]);

export const stateViewAbi = parseAbi([
  "function getSlot0(bytes32 poolId) view returns (uint160 sqrtPriceX96, int24 tick, uint24 protocolFee, uint24 lpFee)",
]);

export const tokenAbi = parseAbi([
  "function balanceOf(address) view returns (uint256)",
  "function allowance(address, address) view returns (uint256)",
  "function approve(address, uint256) returns (bool)",
  "function mint(address to, uint256 amount)", // open faucet on the test tokens
]);

/** Uniswap's v4 PoolSwapTest on Unichain Sepolia (its manager() is the PoolManager above). Used to move an idle
 * testnet pool back to the oracle price, since nobody arbitrages testnet pools. */
export const SWAP_ROUTER = "0x9140a78c1a137c7ff1c151ec8231272af78a99a4" as const;
export const routerAbi = parseAbi([
  // payable on chain; declared nonpayable here because we never send ETH
  "function swap((address currency0, address currency1, uint24 fee, int24 tickSpacing, address hooks) key, (bool zeroForOne, int256 amountSpecified, uint160 sqrtPriceLimitX96) params, (bool takeClaims, bool settleUsingBurn) testSettings, bytes hookData) returns (int256)",
]);
