import { useEffect, useSyncExternalStore } from "react";
import {
  BaseError,
  ContractFunctionRevertedError,
  createWalletClient,
  custom,
  hexToString,
  UserRejectedRequestError,
  type Abi,
  type Address,
  type ContractFunctionArgs,
  type ContractFunctionName,
} from "viem";
import { unichainSepolia } from "viem/chains";
import { client } from "./chain";

/** The browser wallet (MetaMask, Rabby, ...): EIP-1193, through viem only (no wagmi). */
type Eip1193 = {
  request(args: { method: string; params?: unknown[] }): Promise<unknown>;
  on?(event: string, fn: (x: never) => void): void;
};
declare global {
  interface Window {
    ethereum?: Eip1193;
  }
}

type State = { account: Address | null; chainId: number | null };
let state: State = { account: null, chainId: null };
const subs = new Set<() => void>();
const set = (s: Partial<State>) => {
  state = { ...state, ...s };
  subs.forEach((f) => f());
};

let watching = false;
function watch(eth: Eip1193) {
  if (watching) return;
  watching = true;
  eth.on?.("accountsChanged", (a: string[]) => set({ account: (a[0] as Address) ?? null }));
  eth.on?.("chainChanged", (c: string) => set({ chainId: Number(c) }));
}

async function read(eth: Eip1193, method: "eth_accounts" | "eth_requestAccounts") {
  watch(eth);
  const [account] = (await eth.request({ method })) as Address[];
  set({ account: account ?? null, chainId: Number(await eth.request({ method: "eth_chainId" })) });
}

export async function connect() {
  if (!window.ethereum) throw new Error("No browser wallet found. Install MetaMask or Rabby, then reload.");
  await read(window.ethereum, "eth_requestAccounts");
}

/** Current wallet state; restores an already-approved connection on first use without a prompt. */
export function useWallet() {
  useEffect(() => {
    if (window.ethereum) read(window.ethereum, "eth_accounts").catch(() => {});
  }, []);
  const s = useSyncExternalStore(
    (f) => (subs.add(f), () => subs.delete(f)),
    () => state,
    () => state,
  );
  return { ...s, wrongChain: s.account !== null && s.chainId !== unichainSepolia.id };
}

/** A wallet client on Unichain Sepolia, switching (or adding) the network first if needed. */
export async function walletClient() {
  if (!window.ethereum || !state.account) throw new Error("Connect a wallet first.");
  const w = createWalletClient({ account: state.account, chain: unichainSepolia, transport: custom(window.ethereum) });
  if (state.chainId !== unichainSepolia.id) {
    try {
      await w.switchChain({ id: unichainSepolia.id });
    } catch {
      await w.addChain({ chain: unichainSepolia });
    }
    set({ chainId: unichainSepolia.id });
  }
  return w;
}

type Write<abi extends Abi, fn extends ContractFunctionName<abi, "nonpayable">> = {
  address: Address;
  abi: abi;
  functionName: fn;
  args: ContractFunctionArgs<abi, "nonpayable", fn>;
};

/** Simulate first (so a revert shows its reason before the wallet opens), then send and wait for the receipt. */
export async function send<const abi extends Abi, fn extends ContractFunctionName<abi, "nonpayable">>(tx: Write<abi, fn>) {
  const w = await walletClient();
  // viem's generics don't survive the spread; the shape is checked by Write above
  const { request, result } = await client.simulateContract({ ...tx, account: state.account! } as never);
  const hash = await w.writeContract(request);
  const receipt = await client.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") throw new Error("The transaction reverted on chain.");
  return result as unknown;
}

/** Simulate only: what a call would return right now, or why it would revert. */
export async function simulate<const abi extends Abi, fn extends ContractFunctionName<abi, "nonpayable">>(tx: Write<abi, fn>) {
  const { result } = await client.simulateContract({ ...tx, account: state.account! } as never);
  return result as unknown;
}

const PLAIN: Record<string, string> = {
  OutOfBand: "The pool price is too far from the oracle price right now, so this is paused.",
  OracleStale: "The price feed hasn't updated recently enough, so this is paused. Withdrawals still work.",
  SafeModeOn: "This vault has stopped. Only withdrawals work now.",
  CapacityExceeded: "The vault is full. Its capacity grows with each epoch that beats holding.",
  FirstDepositTooSmall: "The first deposit into a vault has to be bigger. Try a larger amount.",
  Slippage: "The price moved while you were signing. Try again.",
  ZeroShares: "That amount is too small to be worth a share.",
  NotCurator: "Only this vault's curator can do that.",
  CuratorNotActive: "The curator has to lock their bond before they can queue moves.",
  IntentExpired: "The signed move expired. Sign it again.",
  BadNonce: "That signature was already used. Sign again.",
  BadSignature: "The signature doesn't match the curator.",
  EpochNotOver: "This epoch hasn't ended yet.",
  NothingToClose: "There's nothing to score: the vault is empty.",
  NothingQueued: "No move is queued.",
};

/** One sentence a person can act on, from whatever a wallet or contract call threw. */
export function reason(e: unknown): string {
  if (e instanceof BaseError) {
    if (e.walk((x) => x instanceof UserRejectedRequestError)) return "You cancelled it in your wallet.";
    const r = e.walk((x) => x instanceof ContractFunctionRevertedError);
    if (r instanceof ContractFunctionRevertedError && r.data) {
      const name = r.data.errorName;
      if (name === "MandateViolation") {
        const term = hexToString(r.data.args?.[0] as `0x${string}`, { size: 32 }).replace(/\0/g, "");
        return `That breaks the curator's mandate: ${term}.`;
      }
      return PLAIN[name] ?? name;
    }
    return e.shortMessage;
  }
  return e instanceof Error ? e.message : String(e);
}
