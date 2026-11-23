/** basis points -> "1%" */
export const bps = (v: number) => `${v / 100}%`;

export const short = (a: string) => `${a.slice(0, 6)}…${a.slice(-4)}`;

export const usd = (v: number) => `$${v.toLocaleString("en-US", { maximumFractionDigits: 2 })}`;

/** Shares are sqrt(amount0 * amount1) in raw units; show them compactly. */
export const shares = (v: bigint) => (v === 0n ? "0" : Number(v).toExponential(2));

export const minutes = (s: number) => (s >= 3600 ? `${(s / 3600).toFixed(1)} h` : `${Math.round(s / 60)} min`);

/** Index (1e18 = same as holding) as a plain "vs holding" percentage: 1.0015e18 -> "+0.15%". */
export const vsHold = (index: bigint) => {
  const p = (Number(index) / 1e18 - 1) * 100;
  if (Math.abs(p) < 0.005) return "±0.00%";
  return `${p > 0 ? "+" : "−"}${Math.abs(p).toFixed(2)}%`;
};
