"use client";

import Link from "next/link";
import { useEffect, useState } from "react";
import { VAULTS } from "@/lib/chain";
import { ratio, short } from "@/lib/format";
import { readSummary, type VaultSummary } from "@/lib/read";

type Row = VaultSummary & { label: string; feed: string };

function status(r: VaultSummary) {
  if (r.safeMode) return { text: "Safe mode", cls: "bad" };
  if (!r.isActive) return { text: "Not bonded", cls: "warn" };
  return { text: "Active", cls: "ok" };
}

export default function Leaderboard() {
  const [rows, setRows] = useState<Row[] | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    Promise.all(VAULTS.map(async (v) => ({ ...(await readSummary(v.address)), label: v.label, feed: v.feed })))
      .then((r) => setRows(r.sort((a, b) => (b.index > a.index ? 1 : b.index < a.index ? -1 : 0))))
      .catch((e) => setError(String(e?.shortMessage ?? e)));
  }, []);

  return (
    <>
      <h1>Curator leaderboard</h1>
      <p className="muted">
        Each vault is run by one curator under a signed mandate. The index compounds every epoch's return against
        simply holding the same tokens (1.0000 = same as holding). It is measured before the performance fee.
      </p>
      {error && <p className="bad">Could not read the chain: {error}</p>}
      {!rows && !error && <p className="muted">Reading Unichain Sepolia…</p>}
      {rows && (
        <div className="scroll">
        <table>
          <thead>
            <tr>
              <th>#</th><th>Vault</th><th>Curator</th><th>Index (gross of fees)</th><th>High-water mark</th>
              <th>Epochs</th><th>Good epochs</th><th>Status</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((r, i) => {
              const s = status(r);
              return (
                <tr key={r.address}>
                  <td>{i + 1}</td>
                  <td>
                    <Link href={`/vault/${r.address}`}>{r.label}</Link>
                    <div className="muted small">{r.feed}</div>
                  </td>
                  <td className="mono">{short(r.curator)}</td>
                  <td className="mono">{ratio(r.index)}</td>
                  <td className="mono">{ratio(r.highWaterMark)}</td>
                  <td>{r.recordCount}</td>
                  <td>{r.goodEpochs.toString()}</td>
                  <td className={s.cls}>{s.text}</td>
                </tr>
              );
            })}
          </tbody>
        </table>
        </div>
      )}
    </>
  );
}
