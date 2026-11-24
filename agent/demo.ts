/**
 * Demo scenes on Unichain Sepolia. Each scene is one command and safe to run again (it skips what is already done).
 * Keys come from your Foundry keystores (asked once per run): bridle-deployer (depositor + DemoFeed owner),
 * bridle-steady, bridle-agent, bridle-reckless (curators).
 *
 *   npm run demo status              read-only: every vault's state (no keys)
 *   npm run demo feed [usd]          refresh the Reckless demo price (default: the live Chainlink price)
 *   npm run demo realign             move every out-of-band pool back to its oracle price
 *   npm run demo seed                depositor + each curator deposit 0.1 tWETH; curators lock their bond
 *   npm run demo move <vault> [shape]  curator signs, queues and executes a preset (Wide, Centred, Ladder)
 *   npm run demo close               close every finished epoch (scores it against holding)
 *   npm run demo breach              Reckless: demo price -20%, wait for the epoch, close: bond burned, safe mode;
 *                                    then the depositor withdraws 25% to show the exit still works
 *   npm run demo all                 feed, realign, seed, move steady Ladder, move reckless Centred
 */
import { parseUnits } from "viem";
import { client, HOOK, hookAbi, tokenAbi, TUSDC, TWETH, vaultAbi, VAULTS, WETH_IS_TOKEN0 } from "../web/lib/chain.ts";
import { presets } from "../web/lib/precheck.ts";
import { DEMO_FEED, demoFeedAbi, faucet, queueAndExecute, realign, send, state, vault, type Vault } from "./chain.ts";
import { unlock } from "./keys.ts";

const CURATOR_KEYSTORE: Record<string, string> = { Steady: "bridle-steady", Agent: "bridle-agent", Reckless: "bridle-reckless" };
const deployer = () => unlock("bridle-deployer");
const SEED_WETH = 0.1; // 0.1 tWETH at ~$1,700 mints ~4e12 shares: above MIN_BOND (1e12), far below capacity (4e15)

async function status() {
  for (const v of VAULTS) {
    const { d, live, closable } = await state(v);
    const oracle = d.oracleUsd === null ? "STALE" : `$${d.oracleUsd.toFixed(0)}`;
    console.log(
      `${v.label.padEnd(9)} oracle ${oracle}  pool $${d.poolUsd.toFixed(0)}  band ${live.bandOk ? "ok" : "OUT"}  ` +
        `${d.safeMode ? "SAFE MODE" : d.isActive ? "active" : "not bonded"}  supply ${d.totalSupply}  ` +
        `ranges ${d.positions.length}  epochs scored ${d.recordCount}${closable ? "  (epoch closable)" : ""}`,
    );
  }
}

async function feed(usd?: number) {
  const price = usd ?? (await state(vault("Steady"))).d.oracleUsd;
  if (price == null) throw new Error("The Chainlink price is stale; pass a price: npm run demo feed 1750");
  await send(await deployer(), { address: DEMO_FEED, abi: demoFeedAbi, functionName: "set", args: [BigInt(Math.round(price * 1e8))] });
  console.log(`Demo price set to $${price.toFixed(2)}.`);
}

async function realignAll() {
  for (const v of VAULTS) {
    const { d, live } = await state(v);
    if (d.oracleSqrt === null) console.log(`${v.label}: oracle stale, skipped (run: npm run demo feed).`);
    else if (live.bandOk) console.log(`${v.label}: pool already in band.`);
    else {
      console.log(`${v.label}: pool $${d.poolUsd.toFixed(0)} -> oracle $${d.oracleUsd!.toFixed(0)}`);
      await realign(await deployer(), v, d);
    }
  }
}

/** Deposit ~SEED_WETH tWETH plus tUSDC at the pool price (2% extra on later deposits; the vault refunds the rest). */
async function deposit(keystore: string, v: Vault) {
  const who = await unlock(keystore);
  const { d } = await state(v);
  const weth = parseUnits(String(SEED_WETH), 18);
  const usdc = parseUnits((SEED_WETH * d.poolUsd * (d.totalSupply === 0n ? 1 : 1.02)).toFixed(6), 6);
  const [wb, ub] = await Promise.all([TWETH, TUSDC].map((t) => client.readContract({ address: t, abi: tokenAbi, functionName: "balanceOf", args: [who.address] })));
  if (wb < weth || ub < usdc) await faucet(who);
  await send(who, { address: TWETH, abi: tokenAbi, functionName: "approve", args: [v.address, weth] });
  await send(who, { address: TUSDC, abi: tokenAbi, functionName: "approve", args: [v.address, usdc] });
  const [a0, a1] = WETH_IS_TOKEN0 ? [weth, usdc] : [usdc, weth];
  // shortcut: minShares 0 (testnet demo, no MEV); the web app passes 99% of a simulation
  await send(who, { address: v.address, abi: vaultAbi, functionName: "deposit", args: [a0, a1, 0n, who.address] });
}

const sharesOf = (v: Vault, a: `0x${string}`) => client.readContract({ address: v.address, abi: vaultAbi, functionName: "balanceOf", args: [a] });

async function seed() {
  for (const v of VAULTS) {
    console.log(`${v.label}:`);
    const dep = await deployer();
    if ((await sharesOf(v, dep.address)) === 0n) await deposit("bridle-deployer", v);
    const { d } = await state(v);
    if (d.isActive || d.safeMode) {
      console.log("  curator already bonded (or the vault is in safe mode).");
      continue;
    }
    const cur = await unlock(CURATOR_KEYSTORE[v.label]);
    if (cur.address.toLowerCase() !== d.curator.toLowerCase()) throw new Error(`${CURATOR_KEYSTORE[v.label]} is ${cur.address}, not the curator ${d.curator}.`);
    const need = d.minBond - d.postedBond;
    if ((await sharesOf(v, cur.address)) < need) await deposit(CURATOR_KEYSTORE[v.label], v);
    await send(cur, { address: v.address, abi: vaultAbi, functionName: "lockBond", args: [need] });
  }
}

async function move(label: string, shape = "Wide") {
  const v = vault(label);
  const { d, live, nonce } = await state(v);
  if (live.oracleTick === null) throw new Error(`${v.label}: oracle stale (npm run demo feed).`);
  const options = presets(live.oracleTick, v.tickSpacing, d.mandate.maxOracleDistanceTicks, d.mandate.maxRanges);
  const ranges = options[shape];
  if (!ranges) throw new Error(`No shape "${shape}". Use one of: ${Object.keys(options).join(", ")}.`);
  console.log(`${v.label}: ${shape}, ${ranges.length} range(s)`);
  await queueAndExecute(await unlock(CURATOR_KEYSTORE[v.label]), d, nonce, ranges);
}

async function close() {
  for (const v of VAULTS) {
    const { closable } = await state(v);
    if (!closable) {
      console.log(`${v.label}: nothing to close yet.`);
      continue;
    }
    await send(await deployer(), { address: v.address, abi: vaultAbi, functionName: "closeEpoch", args: [] });
    const { d } = await state(v);
    const r = d.records.at(-1)!;
    console.log(`${v.label}: epoch ${r.epoch} vs hold ${(Number(r.ratio) / 1e18).toFixed(4)}, index ${(Number(r.index) / 1e18).toFixed(4)}${r.breached ? ", BREACH" : ""}`);
  }
}

async function breach() {
  const v = vault("Reckless");
  let { d } = await state(v);
  if (d.safeMode) return console.log("Reckless is already in safe mode.");
  if (d.positions.length === 0) throw new Error("Reckless has no live ranges yet: npm run demo move reckless Centred");
  const [, answer] = await client.readContract({ address: DEMO_FEED, abi: demoFeedAbi, functionName: "latestRoundData" });
  const dep = await deployer();
  await send(dep, { address: DEMO_FEED, abi: demoFeedAbi, functionName: "set", args: [(answer * 80n) / 100n] });
  console.log(`Demo price: $${Number(answer) / 1e8} -> $${(Number(answer) * 0.8) / 1e8}. Waiting for the epoch to end…`);
  for (;;) {
    const s = await state(v);
    if (s.closable) break;
    const [, , startTime] = await client.readContract({ address: HOOK, abi: hookAbi, functionName: "poolState", args: [d.poolId] });
    const left = d.mandate.epochLength - ((s.live.now - Number(startTime)) % d.mandate.epochLength);
    process.stdout.write(`\r  about ${left} s left   `);
    await new Promise((r) => setTimeout(r, 15_000));
  }
  console.log();
  const bondBefore = d.postedBond;
  await send(dep, { address: v.address, abi: vaultAbi, functionName: "closeEpoch", args: [] });
  ({ d } = await state(v));
  const r = d.records.at(-1)!;
  console.log(`Epoch ${r.epoch}: vs hold ${(Number(r.ratio) / 1e18).toFixed(4)}, index ${(Number(r.index) / 1e18).toFixed(4)}, breached: ${r.breached}`);
  console.log(`Bond ${bondBefore} -> ${d.postedBond} shares, safe mode: ${d.safeMode}`);
  const mine = await sharesOf(v, dep.address);
  if (mine > 0n) {
    console.log("The depositor withdraws 25%:");
    await send(dep, { address: v.address, abi: vaultAbi, functionName: "withdraw", args: [mine / 4n, 0n, 0n, dep.address] });
  }
}

const [scene, ...rest] = process.argv.slice(2);
const scenes: Record<string, () => Promise<unknown>> = {
  status,
  feed: () => feed(rest[0] ? Number(rest[0]) : undefined),
  realign: realignAll,
  seed,
  move: () => move(rest[0] ?? "", rest[1]),
  close,
  breach,
  all: async () => (await feed(), await realignAll(), await seed(), await move("Steady", "Ladder"), await move("Reckless", "Centred")),
};
if (!scenes[scene]) {
  console.log(`Scenes: ${Object.keys(scenes).join(", ")}  (see the top of agent/demo.ts)`);
  process.exit(1);
}
try {
  await scenes[scene]();
  process.exit(0);
} catch (e) {
  console.error(e instanceof Error ? e.message : e);
  process.exit(1);
}
