"use client";

import Link from "next/link";
import { useEffect, useState } from "react";
import { VAULTS, EXPLORER } from "@/lib/chain";
import { bps, minutes, shares, short, usd, vsHold } from "@/lib/format";
import { readDetail, type Mandate, type VaultDetail } from "@/lib/read";
import { HeroArt } from "./Art";
import { LineChart } from "./LineChart";
import { Answer, Stat, status, StatusChip } from "./ui";

const TERMS: { key: keyof Mandate; label: string; fmt: (v: number) => string; hint: string }[] = [
  { key: "perfFeeBps", label: "Performance fee", fmt: bps, hint: "Paid in new shares, only on gains above the previous best. Can only go down." },
  { key: "maxDrawdownBps", label: "Breach line", fmt: bps, hint: "If the score falls this far below its best, the curator's bond burns and the vault stops." },
  { key: "oracleBandBps", label: "Price band", fmt: bps, hint: "Moves and deposits only happen while the pool is this close to the oracle price." },
  { key: "maxOracleDistanceTicks", label: "Range distance", fmt: (v) => `${v} ticks`, hint: "Every range has to sit within this many ticks of the oracle price." },
  { key: "minWidthTicks", label: "Minimum range width", fmt: (v) => `${v} ticks`, hint: "No razor-thin ranges: each one must be at least this wide." },
  { key: "maxRanges", label: "Maximum ranges", fmt: String, hint: "How many separate ranges the curator may hold at once." },
  { key: "maxTurnoverBpsPerEpoch", label: "Turnover limit", fmt: bps, hint: "How much of the vault may be moved around in one epoch." },
  { key: "cooldown", label: "Cooldown", fmt: (s) => `${s} s`, hint: "The shortest wait between two rebalances." },
  { key: "epochLength", label: "Epoch length", fmt: minutes, hint: "How often the vault is scored against holding." },
  { key: "amendmentDelay", label: "Notice for rule changes", fmt: minutes, hint: "New terms wait this long before applying, so you can leave first." },
  { key: "maxIdleEpochs", label: "Idle limit", fmt: (v) => `${v} epochs`, hint: "A curator who does nothing for this long is treated as gone, and the vault stops safely." },
];

export function VaultView({ address }: { address: `0x${string}` }) {
  const meta = VAULTS.find((v) => v.address === address)!;
  const [d, setD] = useState<VaultDetail | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [now, setNow] = useState(() => Math.floor(Date.now() / 1000));

  useEffect(() => {
    readDetail(address).then(setD).catch((e) => setError(String(e?.shortMessage ?? e)));
    const t = setInterval(() => setNow(Math.floor(Date.now() / 1000)), 1000);
    return () => clearInterval(t);
  }, [address]);

  const breach = d ? d.records.findIndex((r) => r.breached) : -1;
  const bandOk = d !== null && d.oracleUsd !== null && Math.abs(d.poolUsd / d.oracleUsd - 1) * 10_000 <= d.mandate.oracleBandBps;
  const changed = d?.pending ? TERMS.filter((t) => d.pending![t.key] !== d.mandate[t.key]) : [];
  // one share vs holding, both starting at 1.0; the hold line is NAV / index (the index compounds NAV/hold)
  const base = d && d.records.length > 0 ? Number(d.records[0].holdPerShare) : 1;
  const nav = d ? [1, ...d.records.map((r) => Number(r.navPerShare) / base)] : [];
  const hold = d ? [1, ...d.records.map((r) => Number((r.navPerShare * 10n ** 18n) / r.index) / base)] : [];

  return (
    <div className="wrap">
      <div className="crumbs">
        <Link href="/#vaults">← All vaults</Link>
      </div>

      <div className="hero hero-vault">
        <div className="hero-copy" style={{ paddingTop: "var(--s7)" }}>
          <span className="label">Vault · priced by {meta.feed}</span>
          <h1 className="display">{meta.label}</h1>
          <p className="lede">{meta.blurb}</p>
          <div className="actions">
            {d ? <StatusChip v={d} /> : <span className="label">Reading the vault…</span>}
            {breach >= 0 && <span className="chip chip-breach">Breached</span>}
            {d && (
              <span className="mono small">
                curator <a href={`${EXPLORER}/address/${d.curator}`}>{short(d.curator)}</a> · vault{" "}
                <a href={`${EXPLORER}/address/${address}`}>{short(address)}</a>
              </span>
            )}
          </div>
        </div>
        <div className="hero-art">
          <HeroArt count={d ? String(d.recordCount) : "…"} caption="epochs scored" />
        </div>
      </div>

      {error && <p className="empty">Couldn't reach Unichain Sepolia right now ({error}). Refresh to try again.</p>}

      {d && (
        <>
          {d.pending && (
            <div className="notice">
              <strong>New rules proposed.</strong>{" "}
              {d.safeMode
                ? "This vault has stopped, so these rules will never apply."
                : now < d.applyAfter
                  ? `They can apply in ${minutes(d.applyAfter - now)}. If you disagree, withdraw before then: withdrawals never need permission.`
                  : "Their notice period is over; anyone can apply them now."}
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
            <div className="notice bad">
              <strong>This vault has stopped{breach >= 0 ? " after a breach" : " because its curator went quiet"}.</strong> Nothing
              moves any more and every position is idle. Withdrawals work as always.
              {breach >= 0 && " The curator's bond was burned, so every other holder's share grew."}
            </div>
          )}

          <section className="section" style={{ paddingTop: "var(--s8)" }}>
            <div className="answers">
              <Answer
                q="Is it beating holding?"
                a={d.recordCount === 0 ? "Not scored yet" : vsHold(d.index)}
                note={
                  d.recordCount === 0
                    ? `Scoring starts once the vault holds deposits and its first ${minutes(d.mandate.epochLength)} epoch closes.`
                    : `Across ${d.recordCount} epochs, before the curator's fee. Best so far ${vsHold(d.highWaterMark)}.`
                }
                tone={d.recordCount === 0 ? undefined : d.index >= 10n ** 18n ? "good" : "bad"}
              />
              <Answer q="Can I withdraw?" a="Yes, any time" note="Your exact share of every position and idle balance. No lockup, no fee, no permission needed." tone="good" />
              <Answer
                q="Are the rules changing?"
                a={d.pending ? (now < d.applyAfter ? `In ${minutes(d.applyAfter - now)}` : "Ready to apply") : "No"}
                note={
                  d.pending
                    ? `${changed.length} ${changed.length === 1 ? "term changes" : "terms change"}; see the notice above.`
                    : `Any change needs ${minutes(d.mandate.amendmentDelay)} notice, so you'd see it here first.`
                }
                tone={d.pending ? "bad" : undefined}
              />
            </div>
            <p className="muted" style={{ marginTop: "var(--s5)" }}>
              <strong>{status(d).text}.</strong> {status(d).meaning}
            </p>
          </section>

          <section className="section">
            <div className="section-head">
              <h2 className="display">One share, read as one line</h2>
              <p className="lede">What one share of this vault is worth, against what the same tokens would be worth if simply held. Both are valued at the oracle price.</p>
            </div>
            <div className="split">
              <div className="card">
                <div className="card-head">
                  <h3 className="display">{meta.label}, every epoch</h3>
                  <span className="chip chip-live">On chain</span>
                </div>
                <LineChart
                  series={[
                    { label: "If simply held", color: "var(--ink)", values: hold, dashed: true },
                    { label: "One vault share", color: "var(--cobalt)", values: nav },
                  ]}
                  knot={breach >= 0 ? { series: 1, index: breach + 1 } : undefined}
                  empty={`Nothing scored yet. The lines start when the first ${minutes(d.mandate.epochLength)} epoch closes.`}
                />
              </div>
              <div className="stats">
                <Stat num={d.recordCount === 0 ? "–" : vsHold(d.index)} text="score against holding, before fees" />
                <Stat num={String(d.goodEpochs)} unit={`of ${d.recordCount}`} text="epochs that beat holding" />
                <Stat num={shares(d.postedBond)} unit="shares" text={`curator's bond at stake (minimum ${shares(d.minBond)})`} />
                <Stat num={shares(d.totalSupply)} unit="shares" text={`deposited, of a ${shares(d.capacity)} capacity`} />
              </div>
            </div>
          </section>

          <section className="section">
            <div className="section-head">
              <h2 className="display">Where the liquidity sits</h2>
              <p className="lede">The ranges the curator has placed right now, and the two prices every move is checked against.</p>
            </div>
            <div className="split">
              <div>
                {d.positions.length === 0 ? (
                  <p className="empty">No positions: all capital is sitting idle in the vault.</p>
                ) : (
                  <table>
                    <thead><tr><th>Range, in ticks</th><th className="num">Weight</th><th className="num">Liquidity</th></tr></thead>
                    <tbody>
                      {d.positions.map((p) => (
                        <tr key={`${p.tickLower}:${p.tickUpper}`}>
                          <td className="mono">{p.tickLower} → {p.tickUpper}</td>
                          <td className="num">{bps(p.weightBps)}</td>
                          <td className="num">{shares(p.liquidity)}</td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                )}
              </div>
              <div className="stats">
                <Stat
                  num={d.oracleUsd === null ? "Stale" : usd(d.oracleUsd)}
                  text={d.oracleUsd === null ? "oracle too old: deposits and moves pause, withdrawals don't" : `oracle price, ${meta.feed}`}
                />
                <Stat num={usd(d.poolUsd)} text="pool price on Uniswap" />
                {d.oracleUsd !== null && (
                  <div style={{ gridColumn: "1 / -1" }}>
                    <span className={bandOk ? "chip chip-live" : "chip chip-paused"}>
                      {bandOk ? "Within" : "Outside"} the {bps(d.mandate.oracleBandBps)} band: {bandOk ? "moves allowed" : "moves paused"}
                    </span>
                  </div>
                )}
              </div>
            </div>
          </section>

          <section className="section" id="rules">
            <div className="section-head">
              <h2 className="display">The rules this curator signed</h2>
              <p className="lede">The hook checks every move against these terms. The curator can't break them, only propose new ones with notice.</p>
            </div>
            <table>
              <tbody>
                {TERMS.map((t) => (
                  <tr key={t.key}>
                    <td>
                      <strong>{t.label}</strong>
                      <span className="sub">{t.hint}</span>
                    </td>
                    <td className="num" style={{ fontSize: 17 }}>{t.fmt(d.mandate[t.key])}</td>
                  </tr>
                ))}
              </tbody>
            </table>
          </section>

          {d.records.length > 0 && (
            <section className="section">
              <div className="section-head">
                <h2 className="display">Track record</h2>
                <p className="lede">Every closed epoch, newest first, exactly as the contract recorded it.</p>
              </div>
              <div className="scroll">
                <table>
                  <thead>
                    <tr><th>Epoch</th><th className="num">That epoch</th><th className="num">Score so far</th><th className="num">Fee shares</th><th className="num">Turnover</th><th></th></tr>
                  </thead>
                  <tbody>
                    {[...d.records].reverse().map((r) => (
                      <tr key={String(r.epoch)}>
                        <td className="mono">{String(r.epoch).padStart(3, "0")}</td>
                        <td className={`num ${r.ratio >= 10n ** 18n ? "up" : "down"}`}>{vsHold(r.ratio)}</td>
                        <td className="num">{vsHold(r.index)}</td>
                        <td className="num">{shares(r.feeShares)}</td>
                        <td className="num">{bps(r.turnoverBps)}</td>
                        <td>{r.breached && <span className="chip chip-breach">Breach</span>}</td>
                      </tr>
                    ))}
                  </tbody>
                </table>
              </div>
            </section>
          )}
        </>
      )}
      <div style={{ height: "var(--s10)" }} />
    </div>
  );
}
