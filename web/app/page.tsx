"use client";

import Link from "next/link";
import { useRouter } from "next/navigation";
import { useEffect, useMemo, useState } from "react";
import { Bars, BluePanel, HeroArt } from "@/components/Art";
import { LineChart } from "@/components/LineChart";
import { Stat, status, StatusChip } from "@/components/ui";
import { VAULTS } from "@/lib/chain";
import { short, vsHold } from "@/lib/format";
import { indexSeries, readRecords, readSummary, type EpochRecord, type VaultSummary } from "@/lib/read";

type Row = VaultSummary & Omit<(typeof VAULTS)[number], "address"> & { records: EpochRecord[] };

const COLORS = ["var(--cobalt)", "var(--ink)", "var(--ink-50)"];
const FILTERS = [
  { key: "all", label: "All" },
  { key: "Active", label: "Active" },
  { key: "Not bonded", label: "Not bonded" },
  { key: "Safe mode", label: "Safe mode" },
] as const;

const STEPS = [
  ["Deposit two tokens", "Add both tokens of the pair in the vault's ratio and get vault shares back. Deposits pause whenever the pool and Chainlink disagree, so nobody can sell you a fake price."],
  ["The curator moves it, inside the rules", "Every rebalance is an intent the curator signs. The hook checks it against their mandate (range width, distance from the oracle, turnover) before it can touch a cent."],
  ["Every epoch is scored against holding", "Each epoch the vault is valued at the Chainlink price and compared with simply holding the same tokens. The fee is only paid on new highs."],
  ["Fall too far and the bond burns", "If the score drops past the breach line, the curator's bond is burned in your favour and the vault stops moving. Your exit never closes."],
];

export default function Home() {
  const router = useRouter();
  const [rows, setRows] = useState<Row[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [filter, setFilter] = useState<(typeof FILTERS)[number]["key"]>("all");

  useEffect(() => {
    Promise.all(
      VAULTS.map(async (v) => {
        const s = await readSummary(v.address);
        return { ...v, ...s, records: await readRecords(v.address, s.recordCount) };
      }),
    )
      .then((r) => setRows(r.sort((a, b) => (b.index > a.index ? 1 : b.index < a.index ? -1 : 0))))
      .catch((e) => setError(String(e?.shortMessage ?? e)));
  }, []);

  const shown = useMemo(() => rows?.filter((r) => filter === "all" || status(r).text === filter) ?? [], [rows, filter]);
  const count = (k: string) => rows?.filter((r) => k === "all" || status(r).text === k).length ?? 0;
  const epochs = rows?.reduce((n, r) => n + r.recordCount, 0);
  const best = rows?.find((r) => r.recordCount > 0);

  return (
    <>
      <div className="wrap">
        <div className="hero">
          <div className="hero-copy">
            <span className="label">A Uniswap v4 hook · Unichain</span>
            <h1 className="display">Liquidity, on a short rein</h1>
            <p className="lede">
              Let a curator run your Uniswap liquidity without handing over the keys. They can only move it inside rules
              they signed, they're scored against simply holding, and their bond burns if they fall too far behind.
            </p>
            <div className="actions">
              <a className="btn" href="#vaults">Browse the vaults</a>
              <a className="link-hatch" href="#how">How it works</a>
            </div>
          </div>
          <div className="hero-art">
            <HeroArt count={String(VAULTS.length)} caption="curators on the rein" />
          </div>
        </div>

        <section className="section" id="scoring">
          <div className="section-head">
            <h2 className="display">Every curator, read as one line</h2>
            <p className="lede">
              Each line is a vault's score against holding the same tokens. Above 1.000 the curator is adding value;
              below it, holding would have done better. The scores are before the curator's fee.
            </p>
          </div>
          <div className="split">
            <div className="card">
              <div className="card-head">
                <h3 className="display">Score against holding</h3>
                <span className="chip chip-live">Live</span>
              </div>
              <LineChart
                series={(rows ?? VAULTS.map((v) => ({ ...v, records: [] }))).map((r, i) => ({
                  label: r.label,
                  color: COLORS[VAULTS.findIndex((v) => v.address === r.address)] ?? COLORS[i],
                  values: indexSeries(r.records),
                  dashed: r.label === "Reckless",
                }))}
                empty="The lines start when the first epoch closes. Each vault is scored every 5 minutes once it holds deposits."
              />
            </div>
            <div className="stats">
              <Stat num={rows ? String(rows.length) : "…"} text="vaults live on Unichain Sepolia" />
              <Stat num={epochs === undefined ? "…" : String(epochs)} unit="epochs" text="closed and scored against holding" />
              <Stat num={best ? vsHold(best.index) : "–"} text={best ? `best score so far, by ${best.label}` : "best score so far: nothing scored yet"} />
              <Stat num={rows ? String(count("Safe mode")) : "…"} text="vaults stopped in safe mode" />
            </div>
          </div>
        </section>

        <section className="section" id="vaults">
          <div className="section-head">
            <h2 className="display">Pick a curator, then follow their line</h2>
            <p className="lede">Open any vault to see its score, its live positions and the exact rules its curator signed.</p>
          </div>
          <div className="tabs" role="tablist" aria-label="Filter vaults by status">
            {FILTERS.map((f) => (
              <button key={f.key} role="tab" aria-selected={filter === f.key} className={filter === f.key ? "on" : undefined} onClick={() => setFilter(f.key)}>
                {f.label}<span>{rows ? count(f.key) : ""}</span>
              </button>
            ))}
          </div>
          {error && <p className="empty">Couldn't reach Unichain Sepolia right now ({error}). Refresh to try again.</p>}
          {!rows && !error && <p className="empty">Reading the vaults from Unichain Sepolia…</p>}
          {rows && shown.length === 0 && <p className="empty">No vault is in this state right now.</p>}
          {rows && shown.length > 0 && (
            <div className="scroll">
              <table>
                <thead>
                  <tr>
                    <th>Vault</th><th>Curator</th><th>Status</th><th className="num">Score vs holding</th>
                    <th className="num">Epochs</th><th className="num">Beat holding</th>
                  </tr>
                </thead>
                <tbody>
                  {shown.map((r) => (
                    <tr key={r.address} className="link" onClick={() => router.push(`/vault/${r.address}`)}>
                      <td>
                        <Link href={`/vault/${r.address}`} style={{ textDecoration: "none" }}><strong>{r.label}</strong></Link>
                        <span className="sub">{r.feed}</span>
                      </td>
                      <td className="mono">{short(r.curator)}</td>
                      <td><StatusChip v={r} /></td>
                      <td className="num">{r.recordCount === 0 ? "not scored yet" : vsHold(r.index)}</td>
                      <td className="num">{r.recordCount}</td>
                      <td className="num">{r.goodEpochs.toString()}</td>
                    </tr>
                  ))}
                </tbody>
              </table>
            </div>
          )}
        </section>
      </div>

      <section className="section" id="how">
        <div className="wrap split-art">
          <BluePanel />
          <div>
            <div className="section-head" style={{ marginBottom: "var(--s6)" }}>
              <h2 className="display">A curator who can't break the rules</h2>
              <p className="lede">Bridle sits inside the pool as a Uniswap v4 hook, so the rules aren't a promise: they're checked on every move.</p>
            </div>
            <ol className="steps">
              {STEPS.map(([title, text], i) => (
                <li key={title}>
                  <span className="n">0{i + 1}</span>
                  <div>
                    <h3 className="display">{title}</h3>
                    <p>{text}</p>
                  </div>
                </li>
              ))}
            </ol>
          </div>
        </div>
      </section>

      <div className="wrap">
        <section className="section">
          <div className="section-head">
            <h2 className="display">Three curators, three temperaments</h2>
            <p className="lede">The strip on each vault tells you its character before you read a word: stripes for calm, hatching for automated, rings for the demo.</p>
          </div>
          <div className="entries">
            {VAULTS.map((v) => {
              const r = rows?.find((x) => x.address === v.address);
              return (
                <Link key={v.address} href={`/vault/${v.address}`} className="entry">
                  <span className={`strip strip-${v.strip}`} />
                  <div className="entry-body">
                    <h3 className="display">{v.label}</h3>
                    <p>{v.blurb}</p>
                    <div>{r ? <StatusChip v={r} /> : <span className="label">Reading…</span>}</div>
                    {r && r.recordCount > 0 ? (
                      <div className="entry-score">
                        <strong className="display">{vsHold(r.index)}</strong>
                        <span>vs holding</span>
                      </div>
                    ) : (
                      <span className="label">Not scored yet</span>
                    )}
                    <span className="entry-go">Open vault →</span>
                  </div>
                </Link>
              );
            })}
          </div>
        </section>

        <section className="band">
          <div>
            <div className="section-head">
              <h2 className="display">Your exit never closes</h2>
              <p className="lede">
                Withdraw your exact share of every position at any time: no lockup, no exit fee, no permission. It works
                even if the curator walks away or the price feed goes quiet.
              </p>
            </div>
            <div className="actions">
              <a className="btn" href="#vaults">Choose a vault</a>
              <a className="btn btn-line" href="#how">Read the rules</a>
            </div>
          </div>
          <Bars />
        </section>
      </div>
    </>
  );
}
