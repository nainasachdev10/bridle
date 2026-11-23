# Bridle progress

Source of truth for status. Read at the start of every session. Workflow: see CLAUDE.md "## Workflow".

| Milestone | Dates | Branch | Status |
|---|---|---|---|
| 1 Skeleton | Nov 22-23 | feat/phase-1-skeleton | done, merged (PR #1) |
| 2a Execution path + oracle guard | Nov 24-25 | feat/phase-2a-execution | done, merged (PR #2) |
| 2b Epochs, NAV, index, HWM fee | Nov 26-27 | feat/phase-2b-epochs | done, merged (PR #3) |
| 2c Bond, breach, safe mode, liveness | Nov 28 | feat/phase-2c-breach | done, merged (PR #4) |
| 2d Curator-posted bond (added after an outside review) | Nov 23 | feat/phase-2d-bond | done (Nov 23), awaiting review + merge |
| 3a Amendments + capacity | Nov 29 | feat/phase-3a-amendments | not started (plan drafted, see Next) |
| 3b Invariant suite + MandateLib fuzz | Nov 30 | feat/phase-3b-invariants | not started |
| 3c Reactive watcher, Unichain Sepolia deploy, fork test | Dec 1 | feat/phase-3c-deploy | not started |
| 4a Web (leaderboard, vault page, curator console) | Dec 2 | feat/phase-4a-web | not started |
| 4b Agent, demo script, README | Dec 3 | feat/phase-4b-ship | not started |

## Current milestone: 2d (done) Curator-posted bond
Why (outside review, Nov 23): the only bond so far is the last epoch's fee, and a curator heading into a breach has usually been losing, so there is nothing to burn. Also, anyone can deploy a vault naming any curator.
Acceptance: the curator locks their own vault shares as a bond; the vault takes no intents until the named curator's bond >= minBond (set at creation); unbonding needs notice (requestUnbond, completeUnbond only after the next close) and stays burnable during it; a breach burns the posted bond + the pending fee bond; the fee bond is released only when there was no breach; invariant 5 with a non-zero posted bond.

- [x] Vault: `minBond` (constructor, > 0), `lockBond(shares)` (curator only, not in safe mode), `postedBond`, `requestUnbond(shares)`, `completeUnbond()` after the next close, `isActive()` = bond (minus pending unbond) >= minBond and not in safe mode
- [x] Hook: `queueIntent` reverts CuratorNotActive unless the vault says active (replaces the safe-mode check there)
- [x] closeEpoch: breach burns posted bond + pending fee bond (Breach.bondBurned = both); fee bond released only without a breach
- [x] Tests: Bond.t.sol (10) + 2 breach tests in SafeMode.t.sol; existing tests bond the curator via `bondCurator()` in the fixture
- [x] CLAUDE.md: posted-bond rule in Key formulas; PROGRESS: 3c demo notes
- [x] forge build + forge test green; hook under 24 KB

Result: `forge test` 190 passed, 0 failed (MandateLib 45, Execution 40, IntentVerifier 19, BridleVault 18, Epochs 17, SafeMode 19, BridleHook 13, Bond 10, OracleGuard 9). Sizes: BridleHook 23,974 B (602 B under the limit), BridleVault 12,822 B. The outside review's scenario is a test now: a curator who only lost (no fee bond) breaches, the 1e18 posted bond is burned and alice's claim per share rises by > 0.5%. Mutation check: not burning the posted bond fails 3 tests.

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

- 2c: "suspend curator" = safe mode. Safe mode is one-way and per vault: queued intent dropped, no new intents, every position pulled back to idle, deposits revert, no fee. Withdrawals and closeEpoch keep working (an all-idle vault scores exactly 1.0). Nothing can turn it off, which keeps the safe-mode rules immutable.
- 2c: "all bond shares" = the pending bond (last close's fee, still held by the vault). Fees from earlier epochs were already released to the curator after surviving their epoch.
- 2c: breach and liveness are checked inside closeEpoch, so anyone can trigger them; there's no separate entry point. A breach is reported once (safe mode skips the check afterwards).
- 2c: liveness = more than maxIdleEpochs epochs since the last successful rebalance (or since the first deposit, if there was none) AND no live queued intent -> safe mode with reason "idle". Review fix: a live intent counts as present, because execution can be blocked for a while (pool out of band, stale oracle) through no fault of the curator. No burn: an absent curator hasn't misbehaved, and a curator named on a vault they never used loses nothing.
- 2c: unwinding reuses a new `_removeAll` (split out of `_moveLiquidity`). Calling `_moveLiquidity` with no ranges cost ~1 KB of hook size because via_ir duplicated it.

- 2d (outside review): the curator posts their own vault shares as a bond (`lockBond`), at least `minBond` (vault constructor, > 0). Until then the vault takes no intents: the hook asks `vault.isActive()` in queueIntent. Deposits stay open (the curator needs shares to post a bond); an unbonded vault just holds, and liveness ends it after maxIdleEpochs.
- 2d: unbonding = `requestUnbond(shares)` then `completeUnbond()` once a close has passed, and only when not in drawdown (index >= hwm) or once safe mode is on. Review fix: a breach builds over several closes, so a one-close notice alone let the curator pull the bond just before it. A curator who wants out while losing stops managing; liveness turns safe mode on, and until then the bond can still be burned. A pending unbond counts against minBond at once (the vault goes inactive if it drops below), but the shares stay burnable until completed. One pending request at a time; a new request replaces it.
- 2d: a breach burns posted bond + pending fee bond; the curator's other (unlocked) shares are untouched. A liveness safe mode burns nothing, and the curator can still unbond afterwards.
- 2d: the breach check already ran before the fee-bond release since 2c (`r.breached` is computed first); the review was written against 2b.

## Known issues
- SIZE BUDGET: BridleHook has 1.4 KB left. 2b must put epoch close / NAV / index / fee math in BridleVault + TrackRecord (as the CLAUDE.md layout already says) and keep only small hooks (views, safe-mode flag) in BridleHook. Making MandateLib an external library saves only ~0.4 KB.
- Rebalance sandwich: someone can push the pool price inside the band, then trigger execution; the loss is bounded by oracleBandBps. Inherent to the design; the band is the mitigation.
- No L2 sequencer-uptime check on the Chainlink feed (check whether Unichain Sepolia has one in 3c).
- Rebalance gas (~687k for swap + 3->3) is from a warm-storage test; re-measure on the fork test (3c). Demo/web must add SWAP_RESERVE_GAS to swap gas estimates for in-swap execution.
- No reentrancy test (needs a malicious token). `nonReentrant` is on deposit and withdraw.
- Repo is public now (as CLAUDE.md says).
- Performance fee has no per-depositor equalization: whoever holds at close shares the fee, so a deposit just before close pays a little of it and a withdrawal just before skips it. Dust at 5-minute epochs; list in README limits (`shortcut:` comment in closeEpoch).
- Safe-mode unwind removes liquidity at the pool price. Someone who pushes the pool price within our liquidity just before a breaching close changes which tokens the vault ends up holding; it costs them the swap, and the vault keeps the fees.
- Demo (3c/4b), from the outside review: two vaults. One on the real Unichain Sepolia Chainlink ETH/USD feed, and one clearly labelled demo vault on MockAggregator for the breach scene (the real price can't be moved on camera). Set maxStaleness from the real feed's heartbeat, or closeEpoch reverts OracleStale with 5-minute epochs. The UI labels the index "gross of fees" (it's measured before the fee is minted).
- Demo (3c/4b): nobody arbitrages a testnet pool, so after any >1% ETH move the pool sits out of band and no rebalance or deposit can run. The demo script must swap the pool back to the oracle price; the curator keeps an intent queued to stay "present".
- SIZE BUDGET: BridleHook has 702 B left for 3a (amendments). Plan: amendments live in the vault and call one small vault-only setter on the hook.
- closeEpoch is permissionless, so whoever closes first picks the exact oracle reading inside the window after the epoch ends. The 3c Reactive watcher should close promptly.
- Fixed in 2d: anyone could deploy a vault naming any curator. Now such a vault takes no intents until that curator posts a bond, and it costs the curator nothing.

## Next
Milestone 3a, Amendments + capacity (branch `feat/phase-3a-amendments`, plan drafted in an earlier session):
Acceptance (CLAUDE.md phase 3): amendments (delay, exit before apply, immutable fields); capacity: cap = baseCap * min(1 + goodEpochs, maxMultiplier), good epoch = ratio >= 1.0, CapacityExceeded. Security: fee cap, safe-mode rules and in-kind withdrawal immutable; no lockups or exit fees. Events AmendmentProposed, AmendmentApplied.
- [ ] Vault: `proposeAmendment(Mandate)` (curator only): validateMandate; perfFeeBps can only go down; epochLength can't change (it numbers the epochs); amendmentDelay can only go up; not in safe mode; applies after the CURRENT amendmentDelay; replacing a proposal restarts the clock; AmendmentProposed
- [ ] Vault: `applyAmendment()` (permissionless, after the delay, not in safe mode) -> hook `setMandate` (vault-only, tiny: 702 B left); AmendmentApplied; pending mandate + applyAfter public for the web banner
- [ ] Exit before apply: withdrawals already work any time; test it during the window
- [ ] Capacity: constructor baseCap + maxMultiplier; goodEpochs counted in closeEpoch; deposit reverts CapacityExceeded above the cap (cap in shares)
- [ ] Tests for every revert, the delay boundary, the new mandate being enforced after apply, capacity growth and its ceiling
- [ ] forge build + forge test green; hook under 24 KB

