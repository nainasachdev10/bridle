import { createWalletClient, http, parseAbi, type PrivateKeyAccount } from "viem";
import { unichainSepolia } from "viem/chains";
import {
  client, EXPLORER, HOOK, hookAbi, INTENT_DOMAIN, INTENT_TYPES, routerAbi, SWAP_ROUTER, tokenAbi, TUSDC, TWETH, vaultAbi, VAULTS,
} from "../web/lib/chain.ts";
import { tickAt, type Live, type Range } from "../web/lib/precheck.ts";
import { inBand, readDetail, realignCall, type VaultDetail } from "../web/lib/read.ts";

export type Vault = (typeof VAULTS)[number];
export const vault = (label: string) => {
  const v = VAULTS.find((x) => x.label.toLowerCase() === label.toLowerCase());
  if (!v) throw new Error(`No vault "${label}". Use one of: ${VAULTS.map((x) => x.label).join(", ")}.`);
  return v;
};

export const DEMO_FEED = "0x3353e250a2af035e4afc86615186d6cdf9f16e9e" as const; // Reckless vault's owner-only demo price
export const demoFeedAbi = parseAbi([
  "function set(int256 answer)",
  "function latestRoundData() view returns (uint80, int256, uint256, uint256, uint80)",
]);

type Tx = { address: `0x${string}`; abi: readonly unknown[]; functionName: string; args?: readonly unknown[] };

/** Simulate (a revert shows its reason before anything is sent), send, wait, print the explorer link. */
export async function send(account: PrivateKeyAccount, tx: Tx): Promise<unknown> {
  const wallet = createWalletClient({ account, chain: unichainSepolia, transport: http() });
  // web/lib's client and this package's wallet client come from two copies of the same viem version
  const { request, result } = await client.simulateContract({ ...tx, account } as never);
  const hash = await wallet.writeContract(request as never);
  const receipt = await client.waitForTransactionReceipt({ hash });
  if (receipt.status !== "success") throw new Error(`${tx.functionName} reverted on chain: ${EXPLORER}/tx/${hash}`);
  console.log(`  ${tx.functionName}: ${EXPLORER}/tx/${hash}`);
  return result;
}

/** Everything the pre-check and the console need about one vault right now. */
export async function state(v: Vault) {
  const d = await readDetail(v.address);
  const [nonce, epoch, st, closedThrough] = await client.multicall({
    allowFailure: false,
    contracts: [
      { address: HOOK, abi: hookAbi, functionName: "nonces", args: [d.curator] },
      { address: HOOK, abi: hookAbi, functionName: "epochOf", args: [d.poolId] },
      { address: HOOK, abi: hookAbi, functionName: "poolState", args: [d.poolId] },
      { address: v.address, abi: vaultAbi, functionName: "currentEpoch" },
    ],
  });
  const [, , , lastRebalanceAt, turnoverEpoch, epochTurnoverBps] = st;
  const live: Live = {
    oracleTick: d.oracleSqrt === null ? null : tickAt(d.oracleSqrt),
    tickSpacing: v.tickSpacing,
    current: d.positions.map(({ tickLower, tickUpper, weightBps }) => ({ tickLower, tickUpper, weightBps })),
    epochTurnoverSoFar: turnoverEpoch === epoch ? epochTurnoverBps : 0,
    lastRebalanceAt: Number(lastRebalanceAt),
    now: Math.floor(Date.now() / 1000),
    bandOk: inBand(d),
  };
  return { d, live, nonce, closable: epoch > closedThrough && d.totalSupply > 0n };
}

/** Curator signs the move (EIP-712), queues it, then anyone (here: the same account) executes it. */
export async function queueAndExecute(curator: PrivateKeyAccount, d: VaultDetail, nonce: bigint, ranges: Range[]) {
  if (curator.address.toLowerCase() !== d.curator.toLowerCase())
    throw new Error(`This keystore is ${curator.address}, but the vault's curator is ${d.curator}.`);
  const intent = { poolId: d.poolId, curator: d.curator, ranges, nonce, deadline: BigInt(Math.floor(Date.now() / 1000) + 3600) };
  const signature = await curator.signTypedData({ domain: INTENT_DOMAIN, types: INTENT_TYPES, primaryType: "RebalanceIntent", message: intent });
  await send(curator, { address: HOOK, abi: hookAbi, functionName: "queueIntent", args: [intent, signature] });
  await send(curator, { address: HOOK, abi: hookAbi, functionName: "executeQueued", args: [d.poolId] });
}

/** Swap the pool back to the oracle price (testnet pools have no arbitrageurs). Mints test tokens if it has to pay. */
export async function realign(account: PrivateKeyAccount, v: Vault, d: VaultDetail) {
  const { tokenIn, paying, args } = realignCall(d, v.fee, v.tickSpacing);
  if (paying) {
    await faucet(account);
    const balance = await client.readContract({ address: tokenIn, abi: tokenAbi, functionName: "balanceOf", args: [account.address] });
    await send(account, { address: tokenIn, abi: tokenAbi, functionName: "approve", args: [SWAP_ROUTER, balance] });
  }
  await send(account, { address: SWAP_ROUTER, abi: routerAbi, functionName: "swap", args });
  if (paying) await send(account, { address: tokenIn, abi: tokenAbi, functionName: "approve", args: [SWAP_ROUTER, 0n] });
}

/** 1 tWETH + 3,000 tUSDC from the open test-token faucet. */
export async function faucet(account: PrivateKeyAccount) {
  await send(account, { address: TWETH, abi: tokenAbi, functionName: "mint", args: [account.address, 10n ** 18n] });
  await send(account, { address: TUSDC, abi: tokenAbi, functionName: "mint", args: [account.address, 3000n * 10n ** 6n] });
}
