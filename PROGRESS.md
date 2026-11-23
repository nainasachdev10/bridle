# Bridle progress

Source of truth for status. Read at the start of every session. Workflow: see CLAUDE.md "## Workflow".

| Milestone | Dates | Branch | Status |
|---|---|---|---|
| 1 Skeleton | Nov 22-23 | feat/phase-1-skeleton | done, merged (PR #1) |
| 2a Execution path + oracle guard | Nov 24-25 | feat/phase-2a-execution | done, merged (PR #2) |
| 2b Epochs, NAV, index, HWM fee | Nov 26-27 | feat/phase-2b-epochs | done, merged (PR #3) |
| 2c Bond, breach, safe mode, liveness | Nov 28 | feat/phase-2c-breach | done, merged (PR #4) |
| 2d Curator-posted bond (added after an outside review) | Nov 23 | feat/phase-2d-bond | done, merged (PR #5) |
| 3a Amendments + capacity | Nov 29 | feat/phase-3a-amendments | done, merged (PR #6) |
| 3b Invariant suite + MandateLib fuzz | Nov 30 | feat/phase-3b-invariants | done, merged (PR #7) |
| 3c Unichain Sepolia deploy script + fork test | Dec 1 | feat/phase-3c-deploy | in progress (started Nov 23) |
| 3d Reactive watcher (cut order #4; needs Lasna REACT) | Dec 1 | feat/phase-3d-reactive | not started |
| 4a Web (leaderboard, vault page, curator console) | Dec 2 | feat/phase-4a-web | not started |
| 4b Agent, demo script, README | Dec 3 | feat/phase-4b-ship | not started |

## Current milestone: 3c Unichain Sepolia deploy script + fork test
Acceptance (CLAUDE.md phase 3 + security rules): deploy to Unichain Sepolia with the real Chainlink feed; validate hook address bits with Hooks.validateHookPermissions in the deploy script; fork test. Outside review: two kinds of vault (real feed; labelled demo feed for the breach scene), maxStaleness from the real feed's heartbeat.

Verified on chain 1301 (Nov 23):
- PoolManager `0x00b036b58a818b1bc34d502d3fe730db729e62ac` (developers.uniswap.org v4 deployments; 24,009 B of code)
- PoolSwapTest `0x9140a78c1a137c7ff1c151ec8231272af78a99a4`, CREATE2 factory `0x4e59b44847b379578588920cA78FbF26c0B4956C` present
- Chainlink ETH/USD `0xd9c93081210dFc33326B2af4C2c11848095E6a9a` (reference-data-directory feeds-ethereum-testnet-sepolia-unichain-1.json): 8 decimals, heartbeat 86,400 s, deviation 0.5%; description() = "ETH / USD", answer 1724.14, updated 105 min before the check

- [x] script/Deploy.s.sol: test tokens (mintable tWETH 18 / tUSDC 6), hook at a mined CREATE2 address (standard factory, so the address is the same in a broadcast and a fork) + Hooks.validateHookPermissions, owner-only DemoFeed, three vaults (Steady fee 3000/60 + Agent 500/10 on the real feed, Reckless 10000/200 on the demo feed with a 5% drawdown line), pools initialized at the oracle price
- [x] maxStaleness 25 h for the real feed (24 h heartbeat + margin); demo feed 1 h
- [x] Fork test (test/fork, runs only with UNICHAIN_SEPOLIA_RPC set): deploy against the real PoolManager + feed; hook price == Chainlink within 0.01%; deposit, bond, 3-range rebalance inside a real swap through Uniswap's PoolSwapTest, epoch close
- [ ] Broadcast: user runs the commands (keystore account, never a key in a file); addresses recorded here afterwards

Result: `forge test` 220 passed, 1 skipped (fork test without the RPC). With `UNICHAIN_SEPOLIA_RPC=https://sepolia.unichain.org`: 3/3 fork tests pass. Cold-storage gas on the fork: swap + first 3-range deployment in beforeSwap 576,240; closeEpoch with 3 positions 427,293. Simulated deploy (no broadcast): 24.3M gas, ~0.000024 ETH; hook address 0x5a2017AA16Cde9e88f5e8Ed0928FFBcff1eA6880 (fixed by CREATE2 mining).

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

- 3a: amendments live in the vault; the hook only gained a vault-only `setMandate`. Rules on top of validateMandate: perfFeeBps only down, maxDrawdownBps only down (a losing curator can't move the breach line away), epochLength fixed (it numbers the epochs and the turnover cap), amendmentDelay only up. The CURRENT delay applies, so lengthening the delay in a proposal doesn't help that proposal. Curator address is not part of the mandate, so the bond rules are unaffected.
- 3a review fix: oracleBandBps is capped at 5% (MandateLib.MAX_BAND_BPS) at creation and in amendments. Before, any band < 100% passed, so a curator could amend to a 99% band and sandwich their own rebalance (push the price, execute, swap back) against depositors who didn't exit in the window.
- 3a: size: `poolConfig()` (returned the whole nested struct) cost ~800 B of ABI-encoding code. Replaced by `curatorOf` and `mandateOf`; the feed is checked through `oracleSqrtPriceX96`.
- 3a: capacity is in shares (deposit reverts if totalSupply would pass it). An all-idle epoch scores exactly 1.0 and counts as good, so capacity also grows in safe mode; harmless, deposits are blocked there.

- 3b: the handler's moveOracle also arbitrages the pool to the new oracle price. Without it the first run showed 0 successful rebalances: the pool left the 1% band and everything stopped (the same testnet problem noted for the demo).
- 3b: breaches need a tighter line than the 10% test mandate in a 64-step random walk, so setUp amends maxDrawdownBps to 2% through proposeAmendment/applyAmendment.
- 3b: invariant 1 is checked in two parts: exact accounting (claims and liquidity) and rounding direction (per-share holdings never drop on a withdrawal). The first version only had the first part and missed a rounding-up mutation.

- 3c: test tokens are our own mintable tWETH/tUSDC (open faucet), not Unichain's WETH/USDC, so demo users and curators can get funds. The real vaults still price them with the real Chainlink ETH/USD feed.
- 3c: DemoFeed is owner-only (unlike the test MockAggregator), so only the deployer can move the demo vault's price for the breach scene. Its description says "not Chainlink".
- 3c: the Reckless (demo) vault uses a 5% drawdown line so the breach scene needs only a modest price move.

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
- 3b gaps: the invariant runs never reach idle-epoch liveness (needs 12+ epochs of no rebalance in 64 steps) and use a single pool; liveness and multi-pool isolation are covered by unit tests (SafeMode, Execution).
- SIZE BUDGET: BridleHook has 488 B left. 3c (Reactive callbacks) should live in a separate contract. Plan: amendments live in the vault and call one small vault-only setter on the hook.
- closeEpoch is permissionless, so whoever closes first picks the exact oracle reading inside the window after the epoch ends. The 3c Reactive watcher should close promptly.
- Fixed in 2d: anyone could deploy a vault naming any curator. Now such a vault takes no intents until that curator posts a bond, and it costs the curator nothing.

## Next
Milestone 3c, Reactive watcher + Unichain Sepolia deploy + fork test (branch `feat/phase-3c-deploy`): Deploy.s.sol (hook mining + Hooks.validateHookPermissions, vaults, pool init); two vaults (real Chainlink ETH/USD feed; labelled demo vault on MockAggregator); maxStaleness from the real feed's heartbeat; fork test against the deployed contracts (cold-storage gas for beforeSwap execution and closeEpoch); Reactive watcher that calls closeEpoch / executeQueued, with callback auth tests. Reactive is 4th in the cut order (keep permissionless calls).
