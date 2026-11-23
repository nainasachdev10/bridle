import type { VaultSummary } from "@/lib/read";

type Status = { cls: string; text: string; meaning: string };

/** One place that turns contract state into plain words. */
export function status(v: VaultSummary): Status {
  if (v.safeMode) {
    return { cls: "chip-safe", text: "Safe mode", meaning: "Curator stopped. All capital is idle; withdraw any time." };
  }
  if (!v.isActive) {
    return { cls: "chip-paused", text: "Not bonded", meaning: "Curator's bond is below the minimum, so they can't move funds." };
  }
  return { cls: "chip-live", text: "Active", meaning: "Curator is bonded and managing liquidity under the mandate." };
}

/** The strip tells you the state before you read the word: stripes active, hatching paused, rings stopped. */
export function StatusChip({ v }: { v: VaultSummary }) {
  const s = status(v);
  return <span className={`chip ${s.cls}`} title={s.meaning}>{s.text}</span>;
}

export function Stat({ num, unit, text }: { num: string; unit?: string; text: string }) {
  return (
    <div className="stat">
      <span className="num display">
        {num}
        {unit && <small>{unit}</small>}
      </span>
      <p>{text}</p>
    </div>
  );
}

/** A question a depositor would ask, answered in one line. */
export function Answer({ q, a, note, tone }: { q: string; a: string; note: string; tone?: "good" | "bad" }) {
  return (
    <div className={`answer ${tone ?? ""}`}>
      <span className="label">{q}</span>
      <strong className="display">{a}</strong>
      <p>{note}</p>
    </div>
  );
}
