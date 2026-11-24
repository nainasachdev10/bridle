// Self-checks: `npm test`. No network, no real keys.
import { test } from "node:test";
import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdtempSync, readdirSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { gate } from "./gate.ts";
import { decryptKeystore } from "./keys.ts";

const m = { maxRanges: 3, minWidthTicks: 200, maxOracleDistanceTicks: 1200, maxTurnoverBpsPerEpoch: 10_000, cooldown: 60 };
const live = { oracleTick: 0, tickSpacing: 10, current: [], epochTurnoverSoFar: 0, lastRebalanceAt: 0, now: 1000, bandOk: true };
const answer = (ranges: object[]) => JSON.stringify({ ranges, why: "test" });

test("a valid answer is acted on", () => {
  const d = gate(answer([{ tickLower: -600, tickUpper: 600, weightBps: 10_000 }]), m, live);
  assert.equal(d.act, true);
});

test("an answer that breaks the mandate is never acted on", () => {
  const far = gate(answer([{ tickLower: -5000, tickUpper: 600, weightBps: 10_000 }]), m, live);
  assert.equal(far.act, false);
  assert.match(far.why, /Close to the oracle/);
  const weights = gate(answer([{ tickLower: -600, tickUpper: 600, weightBps: 9_000 }]), m, live);
  assert.match(weights.why, /Weights add up/);
  assert.equal(gate("not json", m, live).act, false);
  assert.equal(gate(answer([{ tickLower: "-600", tickUpper: 600, weightBps: 10_000 }]), m, live).act, false);
});

test("keeping the current ranges sends nothing", () => {
  const r = { tickLower: -600, tickUpper: 600, weightBps: 10_000 };
  assert.equal(gate(answer([r]), m, { ...live, current: [r] }).act, false);
});

test("decrypts a Foundry keystore to the right address (throwaway key made here)", () => {
  const dir = mkdtempSync(join(tmpdir(), "bridle-ks-"));
  const out = execFileSync("cast", ["wallet", "new", dir, "--unsafe-password", "pw"], { encoding: "utf8" });
  const address = out.match(/0x[0-9a-fA-F]{40}/)![0];
  const json = readFileSync(join(dir, readdirSync(dir)[0]), "utf8");
  assert.equal(decryptKeystore(json, "pw").address.toLowerCase(), address.toLowerCase());
  assert.throws(() => decryptKeystore(json, "wrong"), /Wrong password/);
});
