# Bridle progress

Source of truth for status. Read at the start of every session. Workflow: see CLAUDE.md "## Workflow".

| Milestone | Dates | Branch | Status |
|---|---|---|---|
| 1 Skeleton | Nov 22-23 | feat/phase-1-skeleton | done, merged (PR #1) |
| 2a Execution path + oracle guard | Nov 24-25 | feat/phase-2a-execution | done (Nov 22), awaiting review + merge |
| 2b Epochs, NAV, index, HWM fee | Nov 26-27 | feat/phase-2b-epochs | not started |
| 2c Bond, breach, safe mode, liveness | Nov 28 | feat/phase-2c-breach | not started |
| 3a Amendments + capacity | Nov 29 | feat/phase-3a-amendments | not started |
| 3b Invariant suite + MandateLib fuzz | Nov 30 | feat/phase-3b-invariants | not started |
| 3c Reactive watcher, Unichain Sepolia deploy, fork test | Dec 1 | feat/phase-3c-deploy | not started |
| 4a Web (leaderboard, vault page, curator console) | Dec 2 | feat/phase-4a-web | not started |
| 4b Agent, demo script, README | Dec 3 | feat/phase-4b-ship | not started |

## Current milestone: 2a Execution path + oracle guard
Acceptance (CLAUDE.md phase 2, part a): queueIntent; executeQueued via unlock; beforeSwap path; OracleGuard with a mock aggregator. Unit tests for every revert and skip path, including low-gas swaps leaving the intent queued and the hook's deltas netting to zero. Security: never slot0 alone (band + staleness on rebalances AND deposits); withdrawals in kind, pro rata on every position and idle, no price, work with oracle stale.

- [x] Custody moves to the hook: positions owned by the hook in the PoolManager, idle balances held as ERC-6909 claims, tracked per pool. Vault = share token + entry points.
- [x] libraries/OracleGuard.sol: staleness, bad answer, Chainlink + token decimals, currency order -> sqrtPriceX96 / tick; band check. Mock aggregator.
- [x] Deposit: band + staleness (OutOfBand / OracleStale), fees collected first, pro rata on every position and idle, amount maxes + minShares
- [x] Withdraw: fees collected first, pro rata on every position and idle, no oracle, amount mins
- [x] beforeInitialize: initial price within band of the oracle
- [x] queueIntent: NotCurator, signature (phase 1), shape checks against the current oracle tick; replaces an older queued intent
- [x] executeQueued (permissionless, via unlock): band, staleness, cooldown, ranges vs oracle tick, per-epoch turnover; remove all, add new by weight; settle deltas as ERC-6909
- [x] beforeSwap: cheap checks -> try this.executeInternal() -> on failure or low gas keep the intent queued, emit IntentSkipped, swap continues
- [x] Tests for every revert and skip path; deltas net to zero; fees not stolen by a withdrawer
- [x] forge build + forge test green; hook under 24 KB

Result: `forge test` 144 passed, 0 failed (MandateLib 45, Execution 40, IntentVerifier 19, BridleVault 18, BridleHook 13, OracleGuard 9; deposit fuzz 256 runs). Sizes (via_ir): BridleHook 23,202 B (1,374 B under the 24,576 B limit), BridleVault 3,385 B. Swap + 3->3 range rebalance inside beforeSwap: ~688k gas (warm storage, test).

## Decisions
- Phase 1: solc pinned to 0.8.26 because v4-core PoolManager is `pragma =0.8.26`.
- Phase 1: `@openzeppelin/contracts` maps to uniswap-hooks' own OZ copy (newer than v4-core's; has ReentrancyGuardTransient). The template maps it to v4-core's copy.
- Phase 1: pool registration is permissionless. The BridleVault constructor calls `hook.registerPool(key, feed, curator, mandate)` and the caller becomes the vault. First registration per pool key wins. A squatter only blocks that exact key, and depositors choose the vault, not the key.
- Phase 1: first deposit mints sqrt(amount0 * amount1) shares, so both tokens are required. Minimum is 1e6 shares; 1,000 shares are burned to 0xdead. Later deposits are pro rata to holdings (no price used), with amounts rounded up and withdrawals rounded down.
- Phase 1: the vault tracks holdings internally (idle0/idle1), so donations don't move the share price.
- Phase 1: `withdraw` takes amount0Min/amount1Min. With positions (2a), removal amounts depend on pool price, so the user needs slippage bounds.
- Phase 1: band check in MandateLib reverts `MandateViolation("oracleBandBps")` (rebalances). `OutOfBand` is reserved for deposits in OracleGuard (2a). Both use `MandateLib.withinBand`.
- Phase 1: extra range checks beyond the listed terms: `tickSpacing`, `tickBounds`, `weights` (sum 10000, no zero weight), `duplicateRange`.
- Phase 1: turnover from no ranges follows the formula literally: first full deployment = 5,000 bps of the epoch budget. Decided (Nov 23): keep it. It is the CLAUDE.md formula as written, and counting idle as a range would make one deployment use a whole 10,000 cap. `validateMandate` now rejects caps below 5,000, because the vault could never deploy under them.
- Phase 1: added error `BadNonce` (not in the CLAUDE.md list) to separate wrong nonce from bad signature.
- Phase 1: EIP-712 lives in `src/IntentVerifier.sol` (abstract, inherited by BridleHook; verifyingContract = hook). This file isn't in the CLAUDE.md layout.
- Phase 1: `MAX_RANGES_CAP = 10` bounds loop gas. ERC-20 pairs only (WETH, not native ETH).

- 2a: custody moved to the hook. Positions are owned by the hook in the PoolManager; idle balances are ERC-6909 claims tracked per pool (`poolState.idle0/1`). BridleVault is now only the share ledger + entry points, and only the registered vault can call `hook.deposit/withdraw`. Isolation: a rogue registrant can only touch its own pool's accounting.
- 2a: deposit flow. The vault sends amount0Max/amount1Max to the hook; the hook collects fees, computes shares from the exact cost (mirrors PoolManager rounding, shrinks to fit the maxes), adds pro rata to every position + idle, pays, and refunds the rest. Users approve the vault, never the hook.
- 2a: every deposit/withdraw/rebalance first collects fees into idle, so a late depositor or withdrawer can't take accrued fees.
- 2a: rebalance = remove all positions, then add each range with weightBps of EACH idle token at the pool price; leftovers stay idle (the hook never swaps).
- 2a: epoch number for the turnover cap = (now - pool init time) / epochLength. 2b's closeEpoch should use the same numbering.
- 2a: `maxStaleness` and the feed direction live in `FeedConfig` at registration (feed properties, not mandate terms).
- 2a: beforeSwap tries execution only with gasleft >= 300,000 (MIN_EXECUTE_GAS = reserve + 100k), forwards gasleft - 200,000 to `executeInternal`, so the swap always finishes, even for swaps sent before an intent was queued. Expired intents are dropped. During cooldown it waits silently. Every other failure (including out of gas) emits `IntentSkipped(reason)` and keeps the intent queued. Review fix (Nov 23): the old 1,000,000 floor blocked every wallet-estimated swap. Tested: a wallet estimate (+3%) still skips, because the reserve holds back gas the rebalance needs; estimate + SWAP_RESERVE_GAS executes. So the demo script and web app add SWAP_RESERVE_GAS to the gas estimate when an intent is queued; executeQueued stays the reliable path.
- 2a: oracle answers outside v4's price range, zero/negative answers, and updatedAt == 0 all revert `OracleStale`.
- 2a: `via_ir = true` (needed for stack depth and size). Builds take ~15 s.

## Known issues
- SIZE BUDGET: BridleHook has 1.4 KB left. 2b must put epoch close / NAV / index / fee math in BridleVault + TrackRecord (as the CLAUDE.md layout already says) and keep only small hooks (views, safe-mode flag) in BridleHook. Making MandateLib an external library saves only ~0.4 KB.
- Rebalance sandwich: someone can push the pool price inside the band, then trigger execution; the loss is bounded by oracleBandBps. Inherent to the design; the band is the mitigation.
- No L2 sequencer-uptime check on the Chainlink feed (check whether Unichain Sepolia has one in 3c).
- Rebalance gas (~687k for swap + 3->3) is from a warm-storage test; re-measure on the fork test (3c). Demo/web must add SWAP_RESERVE_GAS to swap gas estimates for in-swap execution.
- No reentrancy test (needs a malicious token). `nonReentrant` is on deposit and withdraw.
- GitHub repo is private; CLAUDE.md says public.

## Next
Milestone 2b, Epochs, NAV, index, HWM fee (branch `feat/phase-2b-epochs`): closeEpoch (permissionless, epoch numbering as in 2a); NAV in token1 at the ORACLE price (positions via LiquidityAmounts at oracle sqrtPrice + idle; fees are already collected into idle on every action); per-share hold snapshot at epoch start; ratio, index, high-water mark; fee shares minted to the curator; TrackRecord ledger + IMandate record schema; EpochClosed and FeeMinted events. Keep the math in BridleVault/TrackRecord to protect the hook's size budget.
