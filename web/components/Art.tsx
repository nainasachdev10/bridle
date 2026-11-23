/** Engraved-plane artwork, drawn with CSS only (see globals.css "art"). Purely decorative. */

export function HeroArt({ count, caption }: { count: string; caption: string }) {
  return (
    <div className="art" aria-hidden="true">
      <div className="art-grid" />
      <div className="art-stripes" />
      <div className="art-hatch" />
      <div className="art-ink" />
      <div className="art-ink art-ink-2" />
      <span className="knot" style={{ top: "48%", left: "62%" }} />
      <span className="knot" style={{ top: "79%", left: "9%" }} />
      <span className="knot" style={{ top: "22%", left: "27%" }} />
      <div className="art-badge">
        <strong className="display">{count}</strong>
        <span>{caption}</span>
      </div>
    </div>
  );
}

export function BluePanel() {
  return (
    <div className="blue-panel" aria-hidden="true">
      <span className="knot" />
    </div>
  );
}

export function Bars() {
  return (
    <div className="bars" aria-hidden="true">
      {Array.from({ length: 8 }, (_, i) => <i key={i} />)}
    </div>
  );
}

export function Logo({ height = 30 }: { height?: number }) {
  return <img src="/logo.svg" alt="Bridle" height={height} style={{ height, width: "auto", display: "block" }} />;
}
