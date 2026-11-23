// Self-check for the TS port of MandateLib: `npm test` (node's own test runner, no dependency).
import { test } from "node:test";
import assert from "node:assert/strict";
import { precheck, tickAt, turnoverBps } from "./precheck.ts";

const A = { tickLower: -600, tickUpper: 600, weightBps: 10_000 };
const B = { tickLower: -1200, tickUpper: 0, weightBps: 10_000 };
const m = { maxRanges: 3, minWidthTicks: 200, maxOracleDistanceTicks: 1200, maxTurnoverBpsPerEpoch: 10_000, cooldown: 60 };
const live = { oracleTick: 0, tickSpacing: 60, current: [], epochTurnoverSoFar: 0, lastRebalanceAt: 0, now: 1000, bandOk: true };
const failed = (ranges, l = live) => precheck(m, ranges, l).filter((c) => !c.ok).map((c) => c.label);

test("turnover matches MandateLib: half the sum of weight changes over the union", () => {
  assert.equal(turnoverBps([], [A]), 5_000); // from nothing: half, as on chain
  assert.equal(turnoverBps([A], [A]), 0);
  assert.equal(turnoverBps([A], [B]), 10_000);
  assert.equal(turnoverBps([A], [{ ...A, weightBps: 5_000 }, { ...B, weightBps: 5_000 }]), 5_000);
});

test("a valid intent passes every check", () => assert.deepEqual(failed([A]), []));

test("each broken term fails its own check", () => {
  assert.deepEqual(failed([{ ...A, tickLower: -590 }]), ["Aligned to the pool"]);
  assert.deepEqual(failed([{ tickLower: 0, tickUpper: 120, weightBps: 10_000 }]), ["Wide enough"]);
  assert.deepEqual(failed([{ tickLower: -1260, tickUpper: 0, weightBps: 10_000 }]), ["Close to the oracle"]);
  assert.deepEqual(failed([{ ...A, weightBps: 9_000 }]), ["Weights add up"]);
  assert.deepEqual(failed([{ ...A, weightBps: 5_000 }, { ...A, weightBps: 5_000 }]), ["Number of ranges"]);
  assert.deepEqual(failed([B], { ...live, current: [A], epochTurnoverSoFar: 1 }), ["Turnover this epoch"]);
  assert.deepEqual(failed([A], { ...live, lastRebalanceAt: 990 }), ["Cooldown"]);
  assert.deepEqual(failed([A], { ...live, oracleTick: null }), ["Fresh oracle price", "Close to the oracle"]);
});

test("tickAt agrees with TickMath on known points", () => {
  assert.equal(tickAt(2n ** 96n), 0); // price 1
  assert.equal(tickAt(79623284919044209682004574208n), 99); // halfway between ticks 99 and 100
});
