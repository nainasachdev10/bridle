"use client";

import { useCallback, useEffect, useMemo, useState } from "react";
import { client, HOOK, hookAbi, routerAbi, SWAP_ROUTER, tokenAbi, TUSDC, TWETH, vaultAbi, WETH_IS_TOKEN0 } from "@/lib/chain";
import { shares, short, usd } from "@/lib/format";
import { precheck, tickAt, type Range } from "@/lib/precheck";
import type { VaultDetail } from "@/lib/read";
import { reason, send, useWallet, walletClient } from "@/lib/wallet";

type Chain = {
  nonce: bigint;
  epoch: number; // hook's epoch now
  closedThrough: number; // vault's currentEpoch: the next one to close
  epochEndsAt: number;
  lastRebalanceAt: number;
  epochTurnoverSoFar: number;
  queued: { deadline: number; ranges: readonly Range[] };
  myShares: bigint;
};

const TYPES = {
  RebalanceIntent: [
    { name: "poolId", type: "bytes32" },
    { name: "curator", type: "address" },
    { name: "ranges", type: "Range[]" },
    { name: "nonce", type: "uint256" },
    { name: "deadline", type: "uint256" },
  ],
  Range: [
    { name: "tickLower", type: "int24" },
    { name: "tickUpper", type: "int24" },
    { name: "weightBps", type: "uint16" },
  ],
} as const;

/** USD per ETH at a tick (tWETH 18 decimals, tUSDC 6). */
const usdAt = (tick: number) => (WETH_IS_TOKEN0 ? 1.0001 ** tick * 1e12 : 1e12 / 1.0001 ** tick);
const priceRange = (r: Range) => [usdAt(r.tickLower), usdAt(r.tickUpper)].sort((a, b) => a - b).map((p) => usd(Math.round(p))).join(" – ");

/** Ready-made shapes inside the mandate, so nobody has to type ticks to try the pre-check. */
function presets(t: number, s: number, maxDist: number, maxRanges: number): Record<string, Range[]> {
  const lo = (d: number) => Math.ceil((t - d) / s) * s;
  const hi = (d: number) => Math.floor((t + d) / s) * s;
  const [a, b] = [lo(maxDist), hi(maxDist)];
  const step = Math.floor((b - a) / 3 / s) * s;
  const out: Record<string, Range[]> = {
    Wide: [{ tickLower: a, tickUpper: b, weightBps: 10_000 }],
    Centred: [{ tickLower: lo(maxDist / 2), tickUpper: hi(maxDist / 2), weightBps: 10_000 }],
  };
  if (maxRanges >= 3)
    out.Ladder = [
      { tickLower: a, tickUpper: a + step, weightBps: 3_333 },
      { tickLower: a + step, tickUpper: b - step, weightBps: 3_334 },
      { tickLower: b - step, tickUpper: b, weightBps: 3_333 },
    ];
  return out;
}

/** Anyone can try ranges against the live pre-check; only the curator can sign. Permissionless calls at the bottom. */
export function Console({ vault, d, fee, tickSpacing, bandOk, onDone }: {
  vault: `0x${string}`;
  d: VaultDetail;
  fee: number;
  tickSpacing: number;
  bandOk: boolean;
  onDone: () => void;
}) {
  const { account } = useWallet();
  const isCurator = account?.toLowerCase() === d.curator.toLowerCase();
  const [c, setC] = useState<Chain | null>(null);
  const [now, setNow] = useState(() => Math.floor(Date.now() / 1000));
  const [busy, setBusy] = useState<string | null>(null);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);
  const oracleTick = d.oracleSqrt === null ? null : tickAt(d.oracleSqrt);
  const options = useMemo(
    () => presets(oracleTick ?? 0, tickSpacing, d.mandate.maxOracleDistanceTicks, d.mandate.maxRanges),
    [oracleTick, tickSpacing, d.mandate],
  );
  const [ranges, setRanges] = useState<Range[]>(() =>
    d.positions.length ? d.positions.map(({ tickLower, tickUpper, weightBps }) => ({ tickLower, tickUpper, weightBps })) : options.Wide,
  );

  const load = useCallback(async () => {
    const [nonce, epoch, st, queued, closedThrough, myShares] = await client.multicall({
      allowFailure: false,
      contracts: [
        { address: HOOK, abi: hookAbi, functionName: "nonces", args: [d.curator] },
        { address: HOOK, abi: hookAbi, functionName: "epochOf", args: [d.poolId] },
        { address: HOOK, abi: hookAbi, functionName: "poolState", args: [d.poolId] },
        { address: HOOK, abi: hookAbi, functionName: "queuedIntent", args: [d.poolId] },
        { address: vault, abi: vaultAbi, functionName: "currentEpoch" },
        { address: vault, abi: vaultAbi, functionName: "balanceOf", args: [account ?? d.curator] },
      ],
    });
    const [, , startTime, lastRebalanceAt, turnoverEpoch, epochTurnoverBps] = st;
    setC({
      nonce,
      epoch: Number(epoch),
      closedThrough: Number(closedThrough),
      epochEndsAt: Number(startTime) + (Number(epoch) + 1) * d.mandate.epochLength,
      lastRebalanceAt: Number(lastRebalanceAt),
      epochTurnoverSoFar: turnoverEpoch === epoch ? epochTurnoverBps : 0,
      queued: { deadline: Number(queued.deadline), ranges: queued.ranges },
      myShares,
    });
  }, [vault, d, account]);

  useEffect(() => {
    load().catch(() => {});
    const t = setInterval(() => setNow(Math.floor(Date.now() / 1000)), 1000);
    return () => clearInterval(t);
  }, [load]);

  const checks = precheck(d.mandate, ranges, {
    oracleTick,
    tickSpacing,
    current: d.positions,
    epochTurnoverSoFar: c?.epochTurnoverSoFar ?? 0,
    lastRebalanceAt: c?.lastRebalanceAt ?? 0,
    now,
    bandOk,
  });
  const allOk = checks.every((x) => x.ok);
  const bondNeeded = d.minBond > d.postedBond ? d.minBond - d.postedBond : 0n;

  const run = (label: string, f: () => Promise<string>) => async () => {
    setMsg(null);
    setBusy(label);
    try {
      setMsg({ ok: true, text: await f() });
      await load();
      onDone();
    } catch (e) {
      setMsg({ ok: false, text: reason(e) });
    } finally {
      setBusy(null);
    }
  };

  const queue = run("Signing…", async () => {
    const w = await walletClient();
    const intent = { poolId: d.poolId, curator: d.curator, ranges, nonce: c!.nonce, deadline: BigInt(now + 3600) };
    const signature = await w.signTypedData({
      account: account!,
      domain: { name: "Bridle", version: "1", chainId: 1301, verifyingContract: HOOK },
      types: TYPES,
      primaryType: "RebalanceIntent",
      message: intent,
    });
    setBusy("Queuing…");
    await send({ address: HOOK, abi: hookAbi, functionName: "queueIntent", args: [intent, signature] });
    return "Queued. It runs inside the next swap that finds it executable, or right now with “Execute queued move”.";
  });
  const lock = run("Locking bond…", async () => {
    await send({ address: vault, abi: vaultAbi, functionName: "lockBond", args: [bondNeeded] });
    return "Bond locked. You can queue moves now.";
  });
  const execute = run("Executing…", async () => {
    await send({ address: HOOK, abi: hookAbi, functionName: "executeQueued", args: [d.poolId] });
    return "The queued move ran: the new ranges are live.";
  });
  // swap to the oracle price with it as the limit: free while the pool holds no liquidity there
  const realign = run("Moving the pool…", async () => {
    const zeroForOne = d.poolSqrt > d.oracleSqrt!;
    const [c0, c1] = WETH_IS_TOKEN0 ? [TWETH, TUSDC] : [TUSDC, TWETH];
    if (d.positions.some((p) => p.liquidity > 0n)) {
      const tokenIn = zeroForOne ? c0 : c1;
      const balance = await client.readContract({ address: tokenIn, abi: tokenAbi, functionName: "balanceOf", args: [account!] });
      setBusy("Approving the swap…");
      await send({ address: tokenIn, abi: tokenAbi, functionName: "approve", args: [SWAP_ROUTER, balance] });
    }
    setBusy("Moving the pool…");
    await send({
      address: SWAP_ROUTER,
      abi: routerAbi,
      functionName: "swap",
      args: [
        { currency0: c0, currency1: c1, fee, tickSpacing, hooks: HOOK },
        { zeroForOne, amountSpecified: -(2n ** 128n), sqrtPriceLimitX96: d.oracleSqrt! }, // exact input, stopped by the limit
        { takeClaims: false, settleUsingBurn: false },
        "0x",
      ],
    });
    return "The pool is back at the oracle price: deposits and moves can run again.";
  });
  const close = run("Closing epoch…", async () => {
    await send({ address: vault, abi: vaultAbi, functionName: "closeEpoch", args: [] });
    return "Epoch closed and scored against holding.";
  });

  // the inputs keep what you type ("-", "1."); a new list (preset, add, remove) bumps gen to redraw them
  const [gen, setGen] = useState(0);
  const replace = (rs: Range[]) => (setRanges(rs), setGen(gen + 1));
  const set = (i: number, k: keyof Range, text: string, scale = 1) => {
    const v = Number(text);
    if (text.trim() !== "" && Number.isFinite(v)) setRanges(ranges.map((r, j) => (j === i ? { ...r, [k]: Math.round(v * scale) } : r)));
  };
  const closable = c !== null && c.epoch > c.closedThrough && d.totalSupply > 0n;
  const queuedLive = c !== null && c.queued.deadline > now;

  return (
    <div className="split">
      <div className="card">
        <div className="card-head">
          <h3 className="display">Propose new ranges</h3>
          <div className="presets">
            {Object.entries(options).map(([name, rs]) => (
              <button key={name} className="btn btn-line btn-sm" onClick={() => replace(rs)}>{name}</button>
            ))}
          </div>
        </div>
        <div className="scroll">
        <table className="ranges">
          <thead><tr><th>Lower tick</th><th>Upper tick</th><th className="num">Weight %</th><th>Price range</th><th></th></tr></thead>
          <tbody>
            {ranges.map((r, i) => (
              <tr key={`${gen}-${i}`}>
                <td><input inputMode="numeric" defaultValue={r.tickLower} onChange={(e) => set(i, "tickLower", e.target.value)} aria-label="Lower tick" /></td>
                <td><input inputMode="numeric" defaultValue={r.tickUpper} onChange={(e) => set(i, "tickUpper", e.target.value)} aria-label="Upper tick" /></td>
                <td className="num"><input inputMode="decimal" defaultValue={r.weightBps / 100} onChange={(e) => set(i, "weightBps", e.target.value, 100)} aria-label="Weight in percent" /></td>
                <td className="mono small">{priceRange(r)}</td>
                <td><button className="x" aria-label="Remove range" onClick={() => replace(ranges.filter((_, j) => j !== i))}>×</button></td>
              </tr>
            ))}
          </tbody>
        </table>
        </div>
        <div className="actions" style={{ marginTop: "var(--s5)" }}>
          <button className="btn btn-line btn-sm" onClick={() => replace([...ranges, { tickLower: ranges.at(-1)?.tickUpper ?? 0, tickUpper: (ranges.at(-1)?.tickUpper ?? 0) + d.mandate.minWidthTicks, weightBps: 0 }])}>
            Add a range
          </button>
        </div>
      </div>

      <div>
        <ul className="checks" aria-live="polite">
          {checks.map((x) => (
            <li key={x.label} className={x.ok ? "ok" : "no"}>
              <strong>{x.label}</strong>
              <span>{x.detail}</span>
            </li>
          ))}
        </ul>
        <p className="muted small" style={{ marginTop: "var(--s4)" }}>
          Band, cooldown and turnover are checked again when the move runs. Signing simulates the call on chain first, so the hook has the final word.
        </p>
        <div className="actions" style={{ marginTop: "var(--s5)" }}>
          {isCurator && d.safeMode ? (
            <span className="note">This vault has stopped. No more moves; withdrawals still work.</span>
          ) : isCurator ? (
            d.isActive ? (
              <button className="btn" disabled={!!busy || !c || !allOk} onClick={queue}>{busy ?? (allOk ? "Sign and queue" : "Fix the red checks first")}</button>
            ) : (
              <button className="btn" disabled={!!busy || bondNeeded === 0n || (c?.myShares ?? 0n) < bondNeeded} onClick={lock}>
                {busy ?? `Lock bond (${shares(bondNeeded)} shares)`}
              </button>
            )
          ) : (
            <span className="note">Only the curator, {short(d.curator)}, can sign. Connect that wallet to queue this.</span>
          )}
        </div>
        {isCurator && !d.isActive && c && c.myShares < bondNeeded && !d.safeMode && (
          <p className="note">Deposit first: the bond is locked from your own vault shares ({shares(c.myShares)} now).</p>
        )}

        <div className="anyone">
          <span className="label">Anyone can</span>
          <div className="actions">
            <button className="btn btn-line btn-sm" disabled={!!busy || !queuedLive} onClick={execute}>Execute queued move</button>
            <button className="btn btn-line btn-sm" disabled={!!busy || !closable} onClick={close}>Close epoch</button>
            {!bandOk && d.oracleSqrt !== null && (
              <button className="btn btn-sm" disabled={!!busy || !account} onClick={realign}>Move pool to the oracle price</button>
            )}
          </div>
          <p className="muted small">
            {!bandOk && d.oracleSqrt !== null && "Nobody trades on a testnet pool, so its price drifts from the oracle; one swap brings it back (free while it holds no liquidity there). "}
            {queuedLive ? `A move is queued (${c!.queued.ranges.length} ranges, expires in ${Math.ceil((c!.queued.deadline - now) / 60)} min). ` : "No move queued. "}
            {c === null ? "" : closable ? "The epoch is over: it can be scored now." : `This epoch can be scored in ${Math.max(0, c.epochEndsAt - now)} s${d.totalSupply === 0n ? ", once the vault holds deposits" : ""}.`}
          </p>
        </div>
        {msg && <p className={msg.ok ? "note good" : "note bad"}>{msg.text}</p>}
      </div>
    </div>
  );
}
