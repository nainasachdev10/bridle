"use client";

import { useState } from "react";
import { short } from "@/lib/format";
import { connect, reason, useWallet, walletClient } from "@/lib/wallet";

/** Header wallet button: connect, then switch network if needed, then show the address. */
export function Connect() {
  const { account, wrongChain } = useWallet();
  const [error, setError] = useState<string | null>(null);
  const run = (f: () => Promise<unknown>) => () => f().then(() => setError(null), (e) => setError(reason(e)));

  if (!account)
    return (
      <button className="btn btn-sm" onClick={run(connect)} title={error ?? undefined}>
        {error?.startsWith("No browser wallet") ? "No wallet found" : "Connect wallet"}
      </button>
    );
  if (wrongChain)
    return (
      <button className="btn btn-sm" onClick={run(walletClient)} title={error ?? undefined}>
        Switch to Unichain Sepolia
      </button>
    );
  return <span className="wallet-chip mono">{short(account)}</span>;
}
