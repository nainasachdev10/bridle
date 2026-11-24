/**
 * The Agent vault's curator: Claude proposes ranges, gate.ts checks them against the mandate, and only a passing
 * answer is signed (EIP-712, keystore bridle-agent) and queued. Also does the vault's chores: closes a finished
 * epoch and moves the pool back to the oracle price when it drifts out of the band.
 *   npm run agent            one round
 *   npm run agent -- --loop  one round per epoch until Ctrl-C
 */
import Anthropic from "@anthropic-ai/sdk";
import { vaultAbi, WETH_IS_TOKEN0 } from "../web/lib/chain.ts";
import { gate } from "./gate.ts";
import { queueAndExecute, realign, send, state, vault } from "./chain.ts";
import { unlock } from "./keys.ts";

const AGENT = vault("Agent");
const MODEL = "claude-opus-5-5";
const usdAt = (tick: number) => Math.round(WETH_IS_TOKEN0 ? 1.0001 ** tick * 1e12 : 1e12 / 1.0001 ** tick);

const SYSTEM = `You are the curator of a Uniswap v4 liquidity vault (tWETH/tUSDC). Each epoch your positions are scored
against simply holding the tokens the vault started the epoch with, valued at the oracle price. Concentrated ranges
earn more fees while the price stays inside them but lose more against holding when it leaves them; wide ranges
lose less. Propose the ranges for the next epoch.

Hard rules (a move that breaks one is rejected and nothing happens):
- 1 to maxRanges ranges, no duplicates; weights are basis points summing to exactly 10000, none zero
- tickLower < tickUpper, both multiples of tickSpacing, both inside the allowed tick window given
- each range at least minWidthTicks wide
- turnover (half the sum of weight changes against the current ranges) counts against the epoch's limit

Changing nothing is fine and costs nothing: return the current ranges if they still fit the market.
"why" is one plain sentence a depositor would understand.`;

const SCHEMA = {
  type: "object",
  additionalProperties: false,
  required: ["ranges", "why"],
  properties: {
    ranges: {
      type: "array",
      items: {
        type: "object",
        additionalProperties: false,
        required: ["tickLower", "tickUpper", "weightBps"],
        properties: { tickLower: { type: "integer" }, tickUpper: { type: "integer" }, weightBps: { type: "integer" } },
      },
    },
    why: { type: "string" },
  },
};

async function ask(facts: object): Promise<string> {
  const res = await new Anthropic().beta.messages.create({
    model: MODEL,
    max_tokens: 16000,
    betas: ["server-side-fallback-2026-07-01"],
    fallbacks: "default", // a refused request is retried on a fallback model inside the same call
    output_config: { effort: "medium", format: { type: "json_schema", schema: SCHEMA } },
    system: SYSTEM,
    messages: [{ role: "user", content: JSON.stringify(facts, null, 2) }],
  });
  if (res.stop_reason === "refusal") throw new Error("Claude declined to answer.");
  return res.content.flatMap((b) => (b.type === "text" ? [b.text] : [])).join("");
}

const log = (s: string) => console.log(`[${new Date().toISOString().slice(11, 19)}] ${s}`);

async function round() {
  const curator = await unlock("bridle-agent");
  let { d, live, nonce, closable } = await state(AGENT);
  if (d.safeMode) return log("Safe mode: the vault has stopped, so the agent does nothing.");
  if (closable) {
    log("The epoch is over: closing it.");
    await send(curator, { address: AGENT.address, abi: vaultAbi, functionName: "closeEpoch", args: [] });
    ({ d, live, nonce } = await state(AGENT));
  }
  if (live.oracleTick === null) return log("The oracle price is stale: waiting.");
  if (!live.bandOk) {
    log(`Pool $${d.poolUsd.toFixed(0)} is outside the band of oracle $${d.oracleUsd!.toFixed(0)}: moving it back.`);
    await realign(curator, AGENT, d);
    ({ d, live, nonce } = await state(AGENT));
  }
  if (!d.isActive) return log("The curator's bond isn't locked yet (npm run demo seed).");
  const readyAt = live.lastRebalanceAt + d.mandate.cooldown;
  if (live.lastRebalanceAt > 0 && live.now < readyAt) return log(`Cooldown: next move possible in ${readyAt - live.now} s.`);

  const m = d.mandate;
  const t = live.oracleTick!;
  const s = AGENT.tickSpacing;
  const facts = {
    oracle: { usdPerEth: Math.round(d.oracleUsd!), tick: t },
    tickToUsd: WETH_IS_TOKEN0 ? "usd = 1.0001^tick * 1e12" : "usd = 1e12 / 1.0001^tick",
    allowedTickWindow: [Math.ceil((t - m.maxOracleDistanceTicks) / s) * s, Math.floor((t + m.maxOracleDistanceTicks) / s) * s],
    tickSpacing: s,
    mandate: { maxRanges: m.maxRanges, minWidthTicks: m.minWidthTicks, maxTurnoverBpsPerEpoch: m.maxTurnoverBpsPerEpoch, epochSeconds: m.epochLength },
    turnoverUsedThisEpochBps: live.epochTurnoverSoFar,
    currentRanges: live.current.map((r) => ({ ...r, usd: [usdAt(r.tickLower), usdAt(r.tickUpper)].sort((a, b) => a - b) })),
    lastEpochs: d.records.slice(-5).map((r) => ({ vsHold: Number(r.ratio) / 1e18, index: Number(r.index) / 1e18 })),
  };
  log(`Asking ${MODEL} (oracle $${facts.oracle.usdPerEth}, ${live.current.length} live ranges)…`);
  const decision = gate(await ask(facts), m, live);
  log(decision.why);
  if (!decision.act) return;
  await queueAndExecute(curator, d, nonce, decision.ranges);
  log(`Moved to ${decision.ranges.map((r) => `$${usdAt(r.tickLower)}–$${usdAt(r.tickUpper)} (${r.weightBps / 100}%)`).join(", ")}.`);
}

const loop = process.argv.includes("--loop");
const EPOCH_MS = 5 * 60_000; // the testnet mandates use 5-minute epochs (Deploy.s.sol)
do {
  await round().catch((e) => log(e instanceof Error ? e.message : String(e)));
  if (loop) await new Promise((r) => setTimeout(r, EPOCH_MS));
} while (loop);
process.exit(0);
