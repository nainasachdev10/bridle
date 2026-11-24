/**
 * TS port of the hook's checks (MandateLib.checkRanges, turnoverBps, checkTurnover, checkCooldown, band,
 * staleness), so a curator sees every rule pass or fail while editing. Advisory only: the chain simulation
 * before signing is the authoritative check.
 */

export type Range = { tickLower: number; tickUpper: number; weightBps: number };

export type Terms = {
  maxRanges: number;
  minWidthTicks: number;
  maxOracleDistanceTicks: number;
  maxTurnoverBpsPerEpoch: number;
  cooldown: number;
};

export type Live = {
  oracleTick: number | null; // null when the feed is stale
  tickSpacing: number;
  current: Range[]; // live positions
  epochTurnoverSoFar: number; // already used this epoch
  lastRebalanceAt: number;
  now: number;
  bandOk: boolean;
};

export type Check = { label: string; ok: boolean; detail: string };

const MIN_TICK = -887272;
const MAX_TICK = 887272;
const BPS = 10_000;
const same = (a: Range, b: Range) => a.tickLower === b.tickLower && a.tickUpper === b.tickUpper;

/** 1/2 * sum |w_new - w_old| over the union of ranges keyed by (tickLower, tickUpper). */
export function turnoverBps(old: Range[], next: Range[]): number {
  let sum = 0;
  for (const r of next) sum += Math.abs(r.weightBps - (old.find((o) => same(o, r))?.weightBps ?? 0));
  for (const o of old) if (!next.some((r) => same(o, r))) sum += o.weightBps;
  return Math.floor(sum / 2);
}

/** Tick at a sqrtPriceX96 (floor), like TickMath.getTickAtSqrtPrice up to float rounding at exact edges. */
export const tickAt = (sqrtPriceX96: bigint) => Math.floor(Math.log((Number(sqrtPriceX96) / 2 ** 96) ** 2) / Math.log(1.0001));

export function precheck(m: Terms, ranges: Range[], live: Live): Check[] {
  const t = live.oracleTick;
  const weights = ranges.reduce((s, r) => s + r.weightBps, 0);
  const turnover = turnoverBps(live.current, ranges);
  const epochTotal = live.epochTurnoverSoFar + turnover;
  const readyAt = live.lastRebalanceAt + m.cooldown;
  const dup = ranges.some((r, i) => ranges.slice(0, i).some((o) => same(o, r)));
  const far = t === null ? [] : ranges.filter((r) => Math.abs(r.tickLower - t) > m.maxOracleDistanceTicks || Math.abs(r.tickUpper - t) > m.maxOracleDistanceTicks);

  return [
    { label: "Fresh oracle price", ok: t !== null, detail: t === null ? "The price feed is stale: nothing can move until it updates." : "The price feed is recent enough." },
    { label: "Pool near the oracle", ok: live.bandOk, detail: live.bandOk ? "The pool price is inside the band." : "The pool price is outside the band: moves wait until it comes back." },
    { label: "Number of ranges", ok: ranges.length > 0 && ranges.length <= m.maxRanges && !dup, detail: dup ? "Two ranges are the same." : `${ranges.length} of at most ${m.maxRanges}.` },
    { label: "Aligned to the pool", ok: ranges.every((r) => r.tickLower % live.tickSpacing === 0 && r.tickUpper % live.tickSpacing === 0 && r.tickLower >= MIN_TICK && r.tickUpper <= MAX_TICK), detail: `Every edge must be a multiple of ${live.tickSpacing} ticks.` },
    { label: "Wide enough", ok: ranges.every((r) => r.tickUpper - r.tickLower >= m.minWidthTicks), detail: `Each range at least ${m.minWidthTicks} ticks wide.` },
    { label: "Close to the oracle", ok: t !== null && far.length === 0, detail: `Every edge within ${m.maxOracleDistanceTicks} ticks of the oracle${t === null ? "" : ` (tick ${t})`}.` },
    { label: "Weights add up", ok: weights === BPS && ranges.every((r) => r.weightBps > 0), detail: `${weights / 100}% of 100%, none at zero.` },
    { label: "Turnover this epoch", ok: epochTotal <= m.maxTurnoverBpsPerEpoch, detail: `${live.epochTurnoverSoFar / 100}% used + ${turnover / 100}% for this move, limit ${m.maxTurnoverBpsPerEpoch / 100}%.` },
    { label: "Cooldown", ok: live.lastRebalanceAt === 0 || live.now >= readyAt, detail: live.lastRebalanceAt === 0 || live.now >= readyAt ? "Enough time since the last move." : `Ready in ${readyAt - live.now} s.` },
  ];
}
