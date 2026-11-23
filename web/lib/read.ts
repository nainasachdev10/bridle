import { client, hookAbi, HOOK, STATE_VIEW, stateViewAbi, TWETH, TUSDC, vaultAbi } from "./chain";

export type Mandate = {
  maxOracleDistanceTicks: number;
  maxTurnoverBpsPerEpoch: number;
  minWidthTicks: number;
  maxRanges: number;
  oracleBandBps: number;
  cooldown: number;
  maxDrawdownBps: number;
  perfFeeBps: number;
  epochLength: number;
  amendmentDelay: number;
  maxIdleEpochs: number;
};

export type EpochRecord = {
  epoch: bigint;
  closedAt: bigint;
  navPerShare: bigint;
  holdPerShare: bigint;
  ratio: bigint;
  index: bigint;
  highWaterMark: bigint;
  feeShares: bigint;
  turnoverBps: number;
  breached: boolean;
};

export type VaultSummary = {
  address: `0x${string}`;
  poolId: `0x${string}`;
  curator: `0x${string}`;
  index: bigint;
  highWaterMark: bigint;
  recordCount: number;
  goodEpochs: bigint;
  capacity: bigint;
  totalSupply: bigint;
  postedBond: bigint;
  minBond: bigint;
  isActive: boolean;
  safeMode: boolean;
};

const MANDATE_KEYS: (keyof Mandate)[] = [
  "maxOracleDistanceTicks", "maxTurnoverBpsPerEpoch", "minWidthTicks", "maxRanges", "oracleBandBps", "cooldown",
  "maxDrawdownBps", "perfFeeBps", "epochLength", "amendmentDelay", "maxIdleEpochs",
];

/** One batched read for the leaderboard row. */
export async function readSummary(address: `0x${string}`): Promise<VaultSummary> {
  const v = { address, abi: vaultAbi } as const;
  const [poolId, index, highWaterMark, recordCount, goodEpochs, capacity, totalSupply, postedBond, minBond, isActive] =
    await client.multicall({
      allowFailure: false,
      contracts: [
        { ...v, functionName: "poolId" },
        { ...v, functionName: "index" },
        { ...v, functionName: "highWaterMark" },
        { ...v, functionName: "recordCount" },
        { ...v, functionName: "goodEpochs" },
        { ...v, functionName: "capacity" },
        { ...v, functionName: "totalSupply" },
        { ...v, functionName: "postedBond" },
        { ...v, functionName: "minBond" },
        { ...v, functionName: "isActive" },
      ],
    });
  const [curator, safeMode] = await client.multicall({
    allowFailure: false,
    contracts: [
      { address: HOOK, abi: hookAbi, functionName: "curatorOf", args: [poolId] },
      { address: HOOK, abi: hookAbi, functionName: "safeMode", args: [poolId] },
    ],
  });
  return {
    address, poolId, curator, index, highWaterMark, recordCount: Number(recordCount), goodEpochs, capacity,
    totalSupply, postedBond, minBond, isActive, safeMode,
  };
}

export type VaultDetail = VaultSummary & {
  records: EpochRecord[];
  mandate: Mandate;
  pending: Mandate | null;
  applyAfter: number;
  positions: { tickLower: number; tickUpper: number; weightBps: number; liquidity: bigint }[];
  oracleUsd: number | null; // null when the feed is stale
  poolUsd: number;
};

/** Everything the vault page shows. Records are read one by one (no unbounded getter). */
export async function readDetail(address: `0x${string}`): Promise<VaultDetail> {
  const s = await readSummary(address);
  const v = { address, abi: vaultAbi } as const;
  const [records, rest, oracle] = await Promise.all([
    client.multicall({
      allowFailure: false,
      contracts: Array.from({ length: s.recordCount }, (_, i) => ({ ...v, functionName: "record" as const, args: [BigInt(i)] as const })),
    }),
    client.multicall({
      allowFailure: false,
      contracts: [
        { address: HOOK, abi: hookAbi, functionName: "mandateOf", args: [s.poolId] },
        { address: HOOK, abi: hookAbi, functionName: "positions", args: [s.poolId] },
        { ...v, functionName: "pendingMandate" },
        { ...v, functionName: "amendmentApplyAfter" },
        { address: STATE_VIEW, abi: stateViewAbi, functionName: "getSlot0", args: [s.poolId] },
      ],
    }),
    // reverts OracleStale when the feed is too old: show that instead of failing the page
    client
      .readContract({ address: HOOK, abi: hookAbi, functionName: "oracleSqrtPriceX96", args: [s.poolId] })
      .catch(() => null),
  ]);
  const [mandate, positions, pendingTuple, applyAfter, slot0] = rest;
  const applyAt = Number(applyAfter);
  return {
    ...s,
    records: records as EpochRecord[],
    mandate: toMandate(mandate),
    pending: applyAt === 0 ? null : toMandate(pendingTuple as readonly number[]),
    applyAfter: applyAt,
    positions: positions.map((p) => ({ ...p })),
    oracleUsd: oracle === null ? null : usdPerEth(oracle),
    poolUsd: usdPerEth(slot0[0]),
  };
}

function toMandate(m: Mandate | readonly number[]): Mandate {
  if (!Array.isArray(m)) return { ...(m as Mandate) };
  return Object.fromEntries(MANDATE_KEYS.map((k, i) => [k, Number(m[i])])) as Mandate;
}

/** Pool price (raw token1 per raw token0) as USD per ETH, for tWETH (18) / tUSDC (6). */
export function usdPerEth(sqrtPriceX96: bigint): number {
  const raw = (Number(sqrtPriceX96) / 2 ** 96) ** 2;
  const wethIsToken0 = BigInt(TWETH) < BigInt(TUSDC);
  return wethIsToken0 ? raw * 1e12 : 1e12 / raw;
}
