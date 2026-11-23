export type Series = { label: string; color: string; values: number[]; dashed?: boolean };

const W = 720;
const H = 300;
const L = 56; // label gutter
const R = 16;
const T = 18;
const B = 36;

/**
 * Lines that all start at 1.0 (= simply holding). With no data yet it still draws the 1.0 line and says why,
 * so an empty vault reads as "not started", not "broken". `knot` marks one point (a breach) in vermilion.
 */
export function LineChart({
  series,
  empty,
  knot,
  xLabel = "Epoch",
}: {
  series: Series[];
  empty: string;
  knot?: { series: number; index: number };
  xLabel?: string;
}) {
  const n = Math.max(0, ...series.map((s) => s.values.length));
  const all = series.flatMap((s) => s.values);
  const lo = Math.min(1, ...all);
  const hi = Math.max(1, ...all);
  const pad = (hi - lo) * 0.15 || 0.01;
  const [y0, y1] = [lo - pad, hi + pad];
  const x = (i: number) => L + (i * (W - L - R)) / Math.max(n - 1, 1);
  const y = (v: number) => T + (1 - (v - y0) / (y1 - y0)) * (H - T - B);
  const path = (v: number[]) => v.map((p, i) => `${i ? "L" : "M"}${x(i).toFixed(1)},${y(p).toFixed(1)}`).join(" ");
  const ticks = [0, 0.25, 0.5, 0.75, 1].map((f) => y0 + f * (y1 - y0));
  const xs = n > 1 ? [...new Set([0, Math.floor((n - 1) / 2), n - 1])] : [];

  return (
    <figure className="chart">
      <div className="chart-wrap">
        <svg viewBox={`0 0 ${W} ${H}`} role="img" aria-label={series.map((s) => s.label).join(" versus ")}>
          {ticks.map((t) => (
            <g key={t}>
              <line x1={L} x2={W - R} y1={y(t)} y2={y(t)} className="grid" />
              <text x={L - 10} y={y(t) + 4} textAnchor="end" className="tick">{t.toFixed(3)}</text>
            </g>
          ))}
          <line x1={L} x2={W - R} y1={y(1)} y2={y(1)} className="base" />
          {xs.map((i) => (
            <text key={i} x={x(i)} y={H - 12} textAnchor="middle" className="tick">
              {i === 0 ? "START" : `${xLabel.toUpperCase()} ${i}`}
            </text>
          ))}
          {n > 1 &&
            series.map((s) => (
              <path
                key={s.label}
                d={path(s.values)}
                className="line"
                stroke={s.color}
                strokeDasharray={s.dashed ? "6 5" : undefined}
              />
            ))}
          {knot && n > 1 && (
            <circle cx={x(knot.index)} cy={y(series[knot.series].values[knot.index])} r={5.5} className="knot-dot" />
          )}
        </svg>
        {n < 2 && (
          <div className="chart-empty">
            <span className="label">1.000 = simply holding</span>
            <p className="muted small">{empty}</p>
          </div>
        )}
      </div>
      <figcaption>
        {series.map((s) => (
          <span key={s.label} className="key" style={{ ["--c" as string]: s.color }}>{s.label}</span>
        ))}
        {knot && <span className="key" style={{ ["--c" as string]: "var(--vermilion)" }}>Breach</span>}
      </figcaption>
    </figure>
  );
}
