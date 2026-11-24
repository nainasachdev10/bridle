import { precheck, turnoverBps, type Live, type Range, type Terms } from "../web/lib/precheck.ts";

export type Decision = { act: true; ranges: Range[]; why: string } | { act: false; why: string };

/** Claude proposes; this decides. An answer runs only if it parses, has the right shape and passes every mandate
 * check the hook will apply (same TS port the web console uses). The chain simulation is still the final word. */
export function gate(text: string, m: Terms, live: Live): Decision {
  let a: { ranges?: unknown; why?: unknown };
  try {
    a = JSON.parse(text);
  } catch {
    return { act: false, why: "The answer was not JSON." };
  }
  const ok = (r: unknown): r is Range =>
    typeof r === "object" && r !== null && ["tickLower", "tickUpper", "weightBps"].every((k) => Number.isInteger((r as Record<string, unknown>)[k]));
  if (!Array.isArray(a.ranges) || !a.ranges.every(ok)) return { act: false, why: "The answer had the wrong shape." };
  const ranges = a.ranges.map(({ tickLower, tickUpper, weightBps }) => ({ tickLower, tickUpper, weightBps }));
  const why = typeof a.why === "string" ? a.why : "";
  if (turnoverBps(live.current, ranges) === 0) return { act: false, why: `Keeps the current ranges. ${why}` };
  const failed = precheck(m, ranges, live).filter((c) => !c.ok);
  if (failed.length) return { act: false, why: `Rejected, breaks the mandate: ${failed.map((c) => `${c.label} (${c.detail})`).join("; ")}` };
  return { act: true, ranges, why };
}
