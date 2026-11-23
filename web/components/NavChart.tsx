import type { EpochRecord } from "@/lib/read";

const W = 640;
const H = 220;
const PAD = 32;

/**
 * NAV per share vs simply holding, both starting at 1.0. The hold line is NAV / index: the index compounds
 * NAV/hold every epoch, so dividing it out gives what a share would be worth if the curator had only held.
 */
export function NavChart({ records }: { records: EpochRecord[] }) {
  if (records.length === 0) return <p className="muted">No closed epochs yet. The chart starts after the first epoch close.</p>;

  const base = Number(records[0].holdPerShare); // value of the starting tokens: 1.0 on the chart
  const nav = [1, ...records.map((r) => Number(r.navPerShare) / base)];
  const hold = [1, ...records.map((r) => Number((r.navPerShare * 10n ** 18n) / r.index) / base)];
  const all = [...nav, ...hold];
  const lo = Math.min(...all);
  const hi = Math.max(...all);
  const span = hi - lo || 0.01;
  const x = (i: number) => PAD + (i * (W - 2 * PAD)) / Math.max(nav.length - 1, 1);
  const y = (v: number) => H - PAD - ((v - lo) / span) * (H - 2 * PAD);
  const path = (s: number[]) => s.map((v, i) => `${i ? "L" : "M"}${x(i).toFixed(1)},${y(v).toFixed(1)}`).join(" ");
  const breach = records.findIndex((r) => r.breached);

  return (
    <figure className="chart">
      <svg viewBox={`0 0 ${W} ${H}`} role="img" aria-label="NAV per share versus holding, per epoch">
        <line x1={PAD} x2={W - PAD} y1={y(1)} y2={y(1)} className="axis" />
        <text x={4} y={y(1) + 4} className="tick">1.00</text>
        <text x={4} y={PAD} className="tick">{hi.toFixed(3)}</text>
        <text x={4} y={H - PAD + 4} className="tick">{lo.toFixed(3)}</text>
        <path d={path(hold)} className="line hold" />
        <path d={path(nav)} className="line nav" />
        {breach >= 0 && <circle cx={x(breach + 1)} cy={y(nav[breach + 1])} r={6} className="breach" />}
      </svg>
      <figcaption>
        <span className="key nav">Vault NAV per share</span> <span className="key hold">If simply held</span>
        {breach >= 0 && <span className="key breach">Breach</span>} · {records.length} closed epochs, valued at the oracle price
      </figcaption>
    </figure>
  );
}
