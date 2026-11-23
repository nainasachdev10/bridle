"use client";

import { useCallback, useEffect, useState } from "react";
import { formatUnits, parseUnits } from "viem";
import { client, tokenAbi, TUSDC, TWETH, vaultAbi, WETH_IS_TOKEN0 } from "@/lib/chain";
import { shares as fmtShares } from "@/lib/format";
import type { VaultDetail } from "@/lib/read";
import { connect, reason, send, simulate, useWallet } from "@/lib/wallet";

const FAUCET = { weth: parseUnits("1", 18), usdc: parseUnits("3000", 6) };
const pct99 = (v: bigint) => (v * 99n) / 100n; // 1% slippage room between the simulation and the block

type Balances = { weth: bigint; usdc: bigint; shares: bigint };

/** A depositor's three jobs: get test tokens, deposit, withdraw. */
export function Act({ vault, d, canDeposit, why, onDone }: {
  vault: `0x${string}`;
  d: VaultDetail;
  canDeposit: boolean;
  why: string;
  onDone: () => void;
}) {
  const { account, wrongChain } = useWallet();
  const [tab, setTab] = useState<"deposit" | "withdraw">("deposit");
  const [bal, setBal] = useState<Balances | null>(null);
  const [eth, setEth] = useState("0.1");
  const [busy, setBusy] = useState<string | null>(null);
  const [msg, setMsg] = useState<{ ok: boolean; text: string } | null>(null);

  const load = useCallback(async () => {
    if (!account) return setBal(null);
    const [weth, usdc, shares] = await client.multicall({
      allowFailure: false,
      contracts: [
        { address: TWETH, abi: tokenAbi, functionName: "balanceOf", args: [account] },
        { address: TUSDC, abi: tokenAbi, functionName: "balanceOf", args: [account] },
        { address: vault, abi: vaultAbi, functionName: "balanceOf", args: [account] },
      ],
    });
    setBal({ weth, usdc, shares });
  }, [account, vault]);
  useEffect(() => void load().catch(() => {}), [load]);

  const run = (steps: () => Promise<string>) => async () => {
    setMsg(null);
    try {
      const text = await steps();
      setMsg({ ok: true, text });
      await load();
      onDone();
    } catch (e) {
      setMsg({ ok: false, text: reason(e) });
    } finally {
      setBusy(null);
    }
  };

  // the first deposit sets the ratio and is taken exactly; later ones refund what doesn't fit, so allow 2% extra USDC
  const first = d.totalSupply === 0n;
  const wethIn = (() => {
    try {
      return parseUnits(eth || "0", 18);
    } catch {
      return 0n;
    }
  })();
  const usdcIn = parseUnits(((Number(eth) || 0) * d.poolUsd * (first ? 1 : 1.02)).toFixed(6), 6);
  const short = bal !== null && (bal.weth < wethIn || bal.usdc < usdcIn);

  const approve = async (token: `0x${string}`, amount: bigint, label: string) => {
    const allowed = await client.readContract({ address: token, abi: tokenAbi, functionName: "allowance", args: [account!, vault] });
    if (allowed >= amount) return;
    setBusy(`Approving ${label}…`);
    await send({ address: token, abi: tokenAbi, functionName: "approve", args: [vault, amount] });
  };

  const faucet = run(async () => {
    setBusy("Minting tWETH…");
    await send({ address: TWETH, abi: tokenAbi, functionName: "mint", args: [account!, FAUCET.weth] });
    setBusy("Minting tUSDC…");
    await send({ address: TUSDC, abi: tokenAbi, functionName: "mint", args: [account!, FAUCET.usdc] });
    return "You received 1 tWETH and 3,000 tUSDC.";
  });

  const deposit = run(async () => {
    await approve(TWETH, wethIn, "tWETH");
    await approve(TUSDC, usdcIn, "tUSDC");
    const [a0, a1] = WETH_IS_TOKEN0 ? [wethIn, usdcIn] : [usdcIn, wethIn];
    setBusy("Depositing…");
    const [expected] = (await simulate({ address: vault, abi: vaultAbi, functionName: "deposit", args: [a0, a1, 0n, account!] })) as bigint[];
    const [got, p0, p1] = (await send({ address: vault, abi: vaultAbi, functionName: "deposit", args: [a0, a1, pct99(expected), account!] })) as bigint[];
    const [w, u] = WETH_IS_TOKEN0 ? [p0, p1] : [p1, p0];
    return `Deposited ${formatUnits(w, 18)} tWETH and ${Number(formatUnits(u, 6)).toFixed(2)} tUSDC for ${fmtShares(got)} shares. Anything that didn't fit the vault's ratio was refunded.`;
  });

  const withdraw = (pct: bigint) =>
    run(async () => {
      const s = (bal!.shares * pct) / 100n;
      setBusy("Withdrawing…");
      const [e0, e1] = (await simulate({ address: vault, abi: vaultAbi, functionName: "withdraw", args: [s, 0n, 0n, account!] })) as bigint[];
      const [p0, p1] = (await send({ address: vault, abi: vaultAbi, functionName: "withdraw", args: [s, pct99(e0), pct99(e1), account!] })) as bigint[];
      const [w, u] = WETH_IS_TOKEN0 ? [p0, p1] : [p1, p0];
      return `Withdrew ${formatUnits(w, 18)} tWETH and ${Number(formatUnits(u, 6)).toFixed(2)} tUSDC.`;
    });

  if (!account)
    return (
      <div className="card act">
        <p className="lede">Connect a wallet on Unichain Sepolia to get free test tokens, deposit and withdraw.</p>
        <div className="actions"><button className="btn" onClick={() => connect().catch((e) => setMsg({ ok: false, text: reason(e) }))}>Connect wallet</button></div>
        {msg && <p className="note bad">{msg.text}</p>}
      </div>
    );

  return (
    <div className="card act">
      <div className="tabs" role="tablist" aria-label="Deposit or withdraw">
        {(["deposit", "withdraw"] as const).map((t) => (
          <button key={t} role="tab" aria-selected={tab === t} className={tab === t ? "on" : undefined} onClick={() => setTab(t)}>
            {t === "deposit" ? "Deposit" : "Withdraw"}
          </button>
        ))}
      </div>

      <dl className="balances">
        <div><dt className="label">tWETH</dt><dd className="mono">{bal ? Number(formatUnits(bal.weth, 18)).toFixed(4) : "…"}</dd></div>
        <div><dt className="label">tUSDC</dt><dd className="mono">{bal ? Number(formatUnits(bal.usdc, 6)).toFixed(2) : "…"}</dd></div>
        <div><dt className="label">Your shares</dt><dd className="mono">{bal ? fmtShares(bal.shares) : "…"}</dd></div>
      </dl>

      {tab === "deposit" ? (
        <>
          <label className="field">
            <span className="label">You put in</span>
            <span className="input"><input inputMode="decimal" value={eth} onChange={(e) => setEth(e.target.value.replace(",", "."))} /><b>tWETH</b></span>
          </label>
          <p className="muted small">
            plus about <strong>{Number(formatUnits(usdcIn, 6)).toLocaleString("en-US", { maximumFractionDigits: 2 })} tUSDC</strong> at the pool price
            {first ? ". This first deposit sets the vault's ratio." : ". Whatever doesn't fit the vault's ratio comes straight back."}
          </p>
          <div className="actions">
            <button className="btn" disabled={!!busy || wrongChain || !canDeposit || short || wethIn === 0n} onClick={deposit}>
              {busy ?? "Deposit"}
            </button>
            <button className="btn btn-line" disabled={!!busy} onClick={faucet}>Get test tokens</button>
          </div>
          {!canDeposit && <p className="note">{why}</p>}
          {canDeposit && short && <p className="note">Not enough test tokens for this amount. Use “Get test tokens” first.</p>}
        </>
      ) : (
        <>
          <p className="muted small">You get your exact share of every position and idle balance, in both tokens. No fee, no lockup, and it works in any state.</p>
          <div className="actions">
            {[25n, 50n, 100n].map((p) => (
              <button key={String(p)} className={p === 100n ? "btn" : "btn btn-line"} disabled={!!busy || wrongChain || !bal || bal.shares === 0n} onClick={withdraw(p)}>
                {p === 100n ? "Withdraw all" : `${p}%`}
              </button>
            ))}
          </div>
          {busy && <p className="note">{busy}</p>}
          {bal?.shares === 0n && <p className="note">You don't hold shares in this vault yet.</p>}
        </>
      )}
      {wrongChain && <p className="note">Switch your wallet to Unichain Sepolia (button at the top).</p>}
      {msg && <p className={msg.ok ? "note good" : "note bad"}>{msg.text}</p>}
    </div>
  );
}
