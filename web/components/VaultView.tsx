"use client";

import { useEffect, useState } from "react";
import { EXPLORER } from "@/lib/chain";
import { bps, minutes, ratio, shares, short, usd } from "@/lib/format";
import { readDetail, type Mandate, type VaultDetail } from "@/lib/read";
import { NavChart } from "./NavChart";

const TERMS: { key: keyof Mandate; label: string; fmt: (v: number) => string }[] = [
  { key: "perfFeeBps", label: "Performance fee (above high-water mark)", fmt: bps },
  { key: "maxDrawdownBps", label: "Breach line (index below peak)", fmt: bps },
  { key: "oracleBandBps", label: "Pool vs oracle price band", fmt: bps },
  { key: "maxOracleDistanceTicks", label: "Ranges within ticks of oracle", fmt: String },
  { key: "minWidthTicks", label: "Min range width (ticks)", fmt: String },
  { key: "maxRanges", label: "Max ranges", fmt: String },
  { key: "maxTurnoverBpsPerEpoch", label: "Max turnover per epoch", fmt: bps },
  { key: "cooldown", label: "Cooldown between rebalances", fmt: (s) => `${s} s` },
  { key: "epochLength", label: "Epoch length", fmt: minutes },
  { key: "amendmentDelay", label: "Amendment delay (exit window)", fmt: minutes },
  { key: "maxIdleEpochs", label: "Idle epochs before safe mode", fmt: String },
];

export function VaultView({ address, label, feed }: { address: `0x${string}`; label: string; feed: string }) {
  const [d, setD] = useState<VaultDetail | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [now, setNow] = useState(() => Math.floor(Date.now() / 1000));

  useEffect(() => {
    readDetail(address).then(setD).catch((e) => setError(String(e?.shortMessage ?? e)));
    const t = setInterval(() => setNow(Math.floor(Date.now() / 1000)), 1000);
    return () => clearInterval(t);
  }, [address]);

  if (error) return <p className="bad">Could not read the chain: {error}</p>;
  if (!d) return <p className="muted">Reading Unichain Sepolia…</p>;

  const breached = d.records.some((r) => r.breached);
  const bandOk = d.oracleUsd !== null && Math.abs(d.poolUsd / d.oracleUsd - 1) * 10_000 <= d.mandate.oracleBandBps;
  const changed = d.pending ? TERMS.filter((t) => d.pending![t.key] !== d.mandate[t.key]) : [];

  return (
    <>
      <h1>
        {label} <span className="muted small">{feed}</span>
      </h1>
      <p className="muted">
        Vault <a href={`${EXPLORER}/address/${d.address}`} className="mono">{short(d.address)}</a> · curator{" "}
        <a href={`${EXPLORER}/address/${d.curator}`} className="mono">{short(d.curator)}</a>
      </p>

      {d.pending && (
        <div className="banner">
          <strong>Mandate change pending.</strong>{" "}
          {now < d.applyAfter
            ? `It can apply in ${minutes(d.applyAfter - now)}. Withdraw before then if you disagree: withdrawals never need permission.`
            : "Its delay has passed; anyone can apply it now."}
          <ul>
            {changed.map((t) => (
              <li key={t.key}>
                {t.label}: {t.fmt(d.mandate[t.key])} → <strong>{t.fmt(d.pending![t.key])}</strong>
              </li>
            ))}
          </ul>
        </div>
      )}
      {d.safeMode && (
        <div className="banner bad">
          <strong>Safe mode{breached ? " after a breach" : " (curator inactive)"}.</strong> No rebalances or deposits;
          every position is idle and withdrawals work as always.
          {breached && " The curator's bond was burned, so every other holder's share grew."}
        </div>
      )}

      <section className="stats">
        <Stat label="Index (gross of fees)" value={ratio(d.index)} />
        <Stat label="High-water mark" value={ratio(d.highWaterMark)} />
        <Stat label="Epochs closed" value={String(d.recordCount)} />
        <Stat label="Good epochs" value={d.goodEpochs.toString()} />
        <Stat label="Curator bond" value={`${shares(d.postedBond)} / ${shares(d.minBond)} shares`} />
        <Stat label="Supply / capacity" value={`${shares(d.totalSupply)} / ${shares(d.capacity)}`} />
      </section>

      <h2>NAV per share vs simply holding</h2>
      <NavChart records={d.records} />

      <h2>Prices</h2>
      <p>
        Oracle {d.oracleUsd === null ? <span className="bad">stale (deposits and rebalances paused)</span> : usd(d.oracleUsd)} ·
        Pool {usd(d.poolUsd)}
        {d.oracleUsd !== null && (
          <>
            {" · "}
            <span className={bandOk ? "ok" : "warn"}>{bandOk ? "within" : "outside"} the {bps(d.mandate.oracleBandBps)} band</span>
          </>
        )}
      </p>

      <h2>Live positions</h2>
      {d.positions.length === 0 ? (
        <p className="muted">None: all capital is idle.</p>
      ) : (
        <table>
          <thead><tr><th>Ticks</th><th>Weight</th><th>Liquidity</th></tr></thead>
          <tbody>
            {d.positions.map((p) => (
              <tr key={`${p.tickLower}:${p.tickUpper}`}>
                <td className="mono">{p.tickLower} → {p.tickUpper}</td>
                <td>{bps(p.weightBps)}</td>
                <td className="mono">{shares(p.liquidity)}</td>
              </tr>
            ))}
          </tbody>
        </table>
      )}

      <h2>Mandate</h2>
      <table>
        <tbody>
          {TERMS.map((t) => (
            <tr key={t.key}><td>{t.label}</td><td className="mono">{t.fmt(d.mandate[t.key])}</td></tr>
          ))}
        </tbody>
      </table>

      {d.records.length > 0 && (
        <>
          <h2>Track record</h2>
          <table>
            <thead><tr><th>Epoch</th><th>Ratio vs hold</th><th>Index</th><th>Fee shares</th><th>Turnover</th><th></th></tr></thead>
            <tbody>
              {[...d.records].reverse().map((r) => (
                <tr key={String(r.epoch)}>
                  <td>{String(r.epoch)}</td>
                  <td className={r.ratio >= 10n ** 18n ? "ok mono" : "warn mono"}>{ratio(r.ratio)}</td>
                  <td className="mono">{ratio(r.index)}</td>
                  <td className="mono">{shares(r.feeShares)}</td>
                  <td>{bps(r.turnoverBps)}</td>
                  <td className="bad">{r.breached ? "breach" : ""}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </>
      )}
    </>
  );
}

function Stat({ label, value }: { label: string; value: string }) {
  return (
    <div className="stat">
      <div className="muted small">{label}</div>
      <div className="mono big">{value}</div>
    </div>
  );
}
