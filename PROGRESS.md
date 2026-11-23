# Bridle progress

Source of truth for status. Read at the start of every session. Workflow: see CLAUDE.md "## Workflow".

| Milestone | Dates | Branch | Status |
|---|---|---|---|
| 1 Skeleton | Nov 22-23 | feat/phase-1-skeleton | done, merged (PR #1) |
| 2a Execution path + oracle guard | Nov 24-25 | feat/phase-2a-execution | done, merged (PR #2) |
| 2b Epochs, NAV, index, HWM fee | Nov 26-27 | feat/phase-2b-epochs | done (Nov 23), awaiting review + merge |
| 2c Bond, breach, safe mode, liveness | Nov 28 | feat/phase-2c-breach | not started |
| 3a Amendments + capacity | Nov 29 | feat/phase-3a-amendments | not started |
| 3b Invariant suite + MandateLib fuzz | Nov 30 | feat/phase-3b-invariants | not started |
| 3c Reactive watcher, Unichain Sepolia deploy, fork test | Dec 1 | feat/phase-3c-deploy | not started |
| 4a Web (leaderboard, vault page, curator console) | Dec 2 | feat/phase-4a-web | not started |
| 4b Agent, demo script, README | Dec 3 | feat/phase-4b-ship | not started |

## Current milestone: 2b (done) Epochs, NAV, index, HWM fee
Acceptance (CLAUDE.md phase 2, part b): epoch close, NAV, index, HWM fee. NAV in token1 at the ORACLE price (positions via LiquidityAmounts at the oracle sqrtPrice + uncollected fees + idle). Per-share hold snapshot at epoch start; ratio = navPerShareEnd / holdValuePerShareEnd; index *= ratio; fee only when index > hwm: f = perfFeeBps * (index - hwm) / index, feeShares = supply * f / (1 - f), locked as bond for 1 epoch; hwm = index. Events EpochClosed, FeeMinted. Unit tests for every revert path.

- [x] Hook: `epochOf(id)` view (one epoch formula, used by the turnover cap and the vault)
- [x] Hook: vault-only `collectFees(id)` (fees into idle before valuing). NAV valuation itself lives in the vault (size budget)
- [x] IMandate: `EpochRecord` schema
- [x] TrackRecord.sol: per-vault epoch ledger (recordCount, record(i); no whole-array getter, it would outgrow RPC gas caps), index + hwm state, EpochClosed / FeeMinted events
- [x] BridleVault.closeEpoch (permissionless, nonReentrant): NAV, hold value of the start snapshot, ratio, index, fee shares, bond hand-off, next snapshot
- [x] First deposit sets the first snapshot
- [x] Fee shares minted to the vault as the curator's bond; released to the curator at the next close (2c burns it on a breach instead)
- [x] Tests for scoring, fee/hwm, bond, bookkeeping and every revert path
- [x] forge build + forge test green; hook under 24 KB

Result: `forge test` 161 passed, 0 failed (Execution 40, MandateLib 45, IntentVerifier 19, BridleVault 18, Epochs 17, BridleHook 13, OracleGuard 9). Sizes: BridleHook 23,491 B (1,085 B under the limit), BridleVault 9,484 B. Sanity numbers from the tests: 5 round trips of 10-token swaps at 0.3% on 200 of capital score exactly 1.0015; a +5% oracle move against a +-6% range scores 0.9899 (impermanent loss); a mid-epoch deposit + withdrawals leave the ratio identical to 18 decimals.

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

- 2b: NAV = positions' token amounts at the ORACLE sqrtPrice (rounded down) + idle, after collecting fees into idle (so "uncollected fees" are real tokens, no fee-growth math). Valued in token1. All of it is computed in the vault from hook views; the hook only adds `collectFees` and `epochOf`.
- 2b: scoring per share via a start snapshot (holdAmount0/1 + holdSupply). ratio = (NAV / supply) / (value of the snapshot tokens at the end price / holdSupply). Deposits and withdrawals are pro rata in kind, so they don't move it (tested).
- 2b: the hold benchmark resets every epoch (it holds the tokens the vault had at the epoch start). A price move then a move back scores below 1.0 both times: that is the real cost of LPing vs holding, and fees must beat it.
- 2b: an epoch nobody closed folds into the next close (record.epoch = first epoch covered, currentEpoch jumps to now). closeEpoch needs a fresh oracle; withdrawals never do.
- 2b: hwm doubles as the peak index for 2c's drawdown check (hwm = highest index ever reached, since it moves whenever index passes it).
- 2b: fee shares are minted to the vault itself as the curator's bond and handed to the curator at the next close; 2c burns them instead on a breach. Fee rounds down (in depositors' favour).
- 2b: TrackRecord is per vault (inherited by BridleVault), not a shared per-curator registry. Registration is permissionless, so a shared registry would let anyone write fake records under a real curator's name. The leaderboard lists known vaults; each vault has one curator.

## Known issues
- SIZE BUDGET: BridleHook has 1.4 KB left. 2b must put epoch close / NAV / index / fee math in BridleVault + TrackRecord (as the CLAUDE.md layout already says) and keep only small hooks (views, safe-mode flag) in BridleHook. Making MandateLib an external library saves only ~0.4 KB.
- Rebalance sandwich: someone can push the pool price inside the band, then trigger execution; the loss is bounded by oracleBandBps. Inherent to the design; the band is the mitigation.
- No L2 sequencer-uptime check on the Chainlink feed (check whether Unichain Sepolia has one in 3c).
- Rebalance gas (~687k for swap + 3->3) is from a warm-storage test; re-measure on the fork test (3c). Demo/web must add SWAP_RESERVE_GAS to swap gas estimates for in-swap execution.
- No reentrancy test (needs a malicious token). `nonReentrant` is on deposit and withdraw.
- GitHub repo is private; CLAUDE.md says public (user's call: keep private for now).
- Performance fee has no per-depositor equalization: whoever holds at close shares the fee, so a deposit just before close pays a little of it and a withdrawal just before skips it. Dust at 5-minute epochs; list in README limits (`shortcut:` comment in closeEpoch).
- SIZE BUDGET: BridleHook has 1,085 B left for 2c (safe-mode flag) and 3a (amendments). Plan: amendments live in the vault and call one small vault-only setter on the hook.
- closeEpoch is permissionless, so whoever closes first picks the exact oracle reading inside the window after the epoch ends. The 3c Reactive watcher should close promptly.
- Anyone can deploy a vault naming any curator. 2c's idle-epoch liveness must not harm a curator who never queued an intent for that vault.

## Next
Milestone 2c, Bond, breach, safe mode, liveness (branch `feat/phase-2c-breach`): breach when index < hwm * (1 - maxDrawdownBps) at closeEpoch -> suspend curator, burn the pending bond (instead of releasing it), safe mode on (no rebalances, queued intent dropped, beforeSwap skips; withdrawals unaffected); Breach and SafeMode events; idle-epoch liveness (maxIdleEpochs without a rebalance -> safe mode or suspension, per CLAUDE.md); invariant 5 test (after a breach each non-curator holder's claim per share >= before the burn).
