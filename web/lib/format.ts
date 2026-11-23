/** 1e18-scaled ratio -> "1.0015" */
export const ratio = (v: bigint, digits = 4) => (Number(v) / 1e18).toFixed(digits);

/** basis points -> "1%" */
export const bps = (v: number) => `${v / 100}%`;

export const short = (a: string) => `${a.slice(0, 6)}…${a.slice(-4)}`;

export const usd = (v: number) => `$${v.toLocaleString("en-US", { maximumFractionDigits: 2 })}`;

/** Shares are sqrt(amount0 * amount1) in raw units; show them compactly. */
export const shares = (v: bigint) => (v === 0n ? "0" : Number(v).toExponential(2));

export const minutes = (s: number) => (s >= 3600 ? `${(s / 3600).toFixed(1)} h` : `${Math.round(s / 60)} min`);
