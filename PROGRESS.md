# Bridle progress

Source of truth for status. Read at the start of every session. Workflow: see CLAUDE.md "## Workflow".

| Milestone | Dates | Branch | Status |
|---|---|---|---|
| 1 Skeleton | Nov 22-23 | feat/phase-1-skeleton | done (Nov 22), awaiting merge |
| 2a Execution path + oracle guard | Nov 24-25 | feat/phase-2a-execution | not started |
| 2b Epochs, NAV, index, HWM fee | Nov 26-27 | feat/phase-2b-epochs | not started |
| 2c Bond, breach, safe mode, liveness | Nov 28 | feat/phase-2c-breach | not started |
| 3a Amendments + capacity | Nov 29 | feat/phase-3a-amendments | not started |
| 3b Invariant suite + MandateLib fuzz | Nov 30 | feat/phase-3b-invariants | not started |
| 3c Reactive watcher, Unichain Sepolia deploy, fork test | Dec 1 | feat/phase-3c-deploy | not started |
| 4a Web (leaderboard, vault page, curator console) | Dec 2 | feat/phase-4a-web | not started |
| 4b Agent, demo script, README | Dec 3 | feat/phase-4b-ship | not started |

## Current milestone: 1 Skeleton
Acceptance (CLAUDE.md): Foundry project from the v4 template with OpenZeppelin uniswap-hooks; hook address mining + permissions test; vault deposit/withdraw with dead shares + min first deposit + zero-shares revert; Mandate struct; MandateLib with a pass and a MandateViolation test per term; EIP-712 intent verification (nonce, deadline, chainId, ERC-1271) with tests.

- [x] contracts/ Foundry project, forge-std + OpenZeppelin/uniswap-hooks (template's pinned rev), template remappings
- [x] interfaces/IMandate.sol: Mandate, Range, RebalanceIntent structs, custom errors
- [x] libraries/MandateLib.sol: validateMandate (every term), checkRanges (distance, width, count, weights, spacing), turnover, cooldown, band, drawdown
- [x] IntentVerifier.sol: EIP-712 (chainId + hook address), per-curator nonce, deadline, ECDSA + ERC-1271, Range[] hashed as keccak of concatenated struct hashes
- [x] BridleHook.sol: exactly beforeInitialize / beforeAddLiquidity / beforeSwap; pool registration (vault + feed + curator + mandate)
- [x] BridleVault.sol: ERC-20 shares, in-kind deposit (amount0Max, amount1Max, minShares) and withdraw (amount0Min, amount1Min), dead shares, min first deposit, zero-shares revert, nonReentrant
- [x] Tests: hook mining + permissions, vault, MandateLib per term, signature edge cases
- [x] forge build + forge test green

Result: `forge test` 92 passed, 0 failed (MandateLib 44, IntentVerifier 19, BridleHook 11, BridleVault 18). Sizes: BridleHook 7,970 B, BridleVault 4,542 B runtime.

## Decisions
- Phase 1: solc pinned to 0.8.26 because v4-core PoolManager is `pragma =0.8.26`.
- Phase 1: `@openzeppelin/contracts` maps to uniswap-hooks' own OZ copy (newer than v4-core's; has ReentrancyGuardTransient). The template maps it to v4-core's copy.
- Phase 1: pool registration is permissionless. The BridleVault constructor calls `hook.registerPool(key, feed, curator, mandate)` and the caller becomes the vault. First registration per pool key wins. A squatter only blocks that exact key, and depositors choose the vault, not the key.
- Phase 1: first deposit mints sqrt(amount0 * amount1) shares, so both tokens are required. Minimum is 1e6 shares; 1,000 shares are burned to 0xdead. Later deposits are pro rata to holdings (no price used), with amounts rounded up and withdrawals rounded down.
- Phase 1: the vault tracks holdings internally (idle0/idle1), so donations don't move the share price.
- Phase 1: `withdraw` takes amount0Min/amount1Min. With positions (2a), removal amounts depend on pool price, so the user needs slippage bounds.
- Phase 1: band check in MandateLib reverts `MandateViolation("oracleBandBps")` (rebalances). `OutOfBand` is reserved for deposits in OracleGuard (2a). Both use `MandateLib.withinBand`.
- Phase 1: extra range checks beyond the listed terms: `tickSpacing`, `tickBounds`, `weights` (sum 10000, no zero weight), `duplicateRange`.
- Phase 1: turnover from no ranges follows the formula literally: first full deployment = 5,000 bps of the epoch budget. REVIEW: is that intended, or should idle count as a range (making it 10,000)?
- Phase 1: added error `BadNonce` (not in the CLAUDE.md list) to separate wrong nonce from bad signature.
- Phase 1: EIP-712 lives in `src/IntentVerifier.sol` (abstract, inherited by BridleHook; verifyingContract = hook). This file isn't in the CLAUDE.md layout.
- Phase 1: `MAX_RANGES_CAP = 10` bounds loop gas. ERC-20 pairs only (WETH, not native ETH).

## Known issues
- Deposits have no oracle band check yet (security rule). Lands with OracleGuard in 2a; marked `shortcut:` in BridleVault.
- Pool initialization price isn't checked against the oracle yet (2a).
- Intent verification isn't called from the hook yet: queueIntent, the `NotCurator` check and the `poolId` match land in 2a.
- The vault holds only idle balances. 2a must decide who custodies tokens (hook vs vault) for "share claims == hook holdings".
- No reentrancy test (needs a malicious token). `nonReentrant` is on deposit and withdraw.
- GitHub repo is private; CLAUDE.md says public.

## Next
Milestone 2a, Execution path + oracle guard (branch `feat/phase-2a-execution`): OracleGuard with a mock aggregator (staleness, decimals, price -> sqrtPriceX96/tick, band); deposit band check; queueIntent (curator + poolId + MandateLib checks); executeQueued via unlock (hook-owned positions, ERC-6909 settlement); beforeSwap try-execute with skip paths (low gas leaves the intent queued; deltas net to zero); withdraw across positions.
