# Bridle: UHI11 Hookathon

Bridle is a Uniswap v4 hook for curated liquidity with enforceable mandates. Curators manage pooled LP capital only through EIP-712 signed rebalance intents; the hook enforces mandate limits, scores every epoch against simply holding (excess-return index), pays performance fees above the index high-water mark, burns the curator bond on a drawdown breach, and always lets depositors withdraw in kind.

- Naming: the product is Bridle; "mandate" stays as the word for the curator's terms (struct Mandate, MandateLib, MandateViolation, IMandate).
- Design doc (the why): https://claude.ai/artifact/XxJWbmAo5SGNGSsWhq9raP
- Deadline: Dec 3 2026, 11:59pm PT (Dec 4, 1:29pm IST)
- Target chain: Unichain Sepolia (1301). Uniswap v4, Chainlink Data Feeds and Reactive callbacks are all available there.

## How to work in this repo
- Work phase by phase (below). Finish a phase, run `forge test`, show results, then stop and wait before starting the next.
- Small commits with clear messages after each working step. Dated commits prove the code was written during the hookathon.
- Never weaken a security rule below to make a test pass. If a design point looks wrong, stop and say so.
- Prefer simple, readable code over clever gas tricks. Judges read it.
- Keep the hook's permissions to exactly the three listed.

## Repo layout (this folder is the repo root)
```
contracts/            Foundry project
  src/
    BridleHook.sol       BaseHook (OpenZeppelin uniswap-hooks); positions, intents, epochs, safe mode
    BridleVault.sol      ERC-20 shares per pool; deposit/withdraw in kind; HWM fee; bond; capacity
    libraries/MandateLib.sol   pure checks: intent vs mandate vs state
    libraries/OracleGuard.sol  Chainlink: staleness, decimals, price -> sqrtPriceX96/tick, band check
    TrackRecord.sol       per-curator epoch ledger + views (IMandate record schema)
    interfaces/IMandate.sol
    reactive/BridleWatcher.sol   Reactive contract (Lasna) + callback receiver logic
  test/  unit/  fuzz/  invariant/  fork/
  script/  Deploy.s.sol  Demo.s.sol
web/                   Next.js + wagmi + viem: leaderboard, vault page, curator console
agent/                 TS script: Claude-driven curator that proposes ranges and signs intents
README.md
```

## Hook permissions (only these three)
- beforeInitialize: bind pool -> registered vault + Chainlink feed; reject otherwise
- beforeAddLiquidity: revert always (v4 skips hook callbacks when the hook itself calls modifyLiquidity)
- beforeSwap: if a queued intent is executable -> cheap view checks (band, staleness, cooldown, deadline) -> try this.executeInternal() -> on failure keep the intent queued and let the swap continue; settle the hook's own deltas (ERC-6909 claims) before returning; return zero delta, no fee override

## Mandate terms
maxOracleDistanceTicks, maxTurnoverBpsPerEpoch, minWidthTicks, maxRanges, oracleBandBps, cooldown, maxDrawdownBps (on the index), perfFeeBps (<= 2000, immutable cap), epochLength, amendmentDelay, maxIdleEpochs.

## Key formulas
- Oracle price -> sqrtPriceX96: adjust Chainlink decimals and token decimals, respect currency0/currency1 order; tick = TickMath.getTickAtSqrtPrice
- Band: |poolPrice / oraclePrice - 1| <= oracleBandBps; feed updatedAt within maxStaleness. Required for rebalances AND deposits.
- Turnover of one rebalance = 1/2 * sum |w_new(r) - w_old(r)| over the union of ranges keyed by (tickLower, tickUpper); per-epoch turnover = running SUM of rebalance turnovers (A->B->A counts twice); must stay <= maxTurnoverBpsPerEpoch
- Ranges: every tickLower/tickUpper within maxOracleDistanceTicks of the oracle tick; width >= minWidthTicks; count <= maxRanges; weights sum to 10000; ticks aligned to tickSpacing
- NAV (token1 units) = value at the ORACLE sqrtPrice of: each position's amounts (LiquidityAmounts at oracle price) + uncollected fees + idle balances
- Work PER SHARE (deposits/withdrawals happen mid-epoch): at epoch start snapshot holdAmt0PerShare, holdAmt1PerShare; at close holdValuePerShare = value of those at the end oracle price
- Epoch ratio = navPerShareEnd / holdValuePerShareEnd; index_n = index_{n-1} * ratio (1e18 = 1.0)
- Fee: if index > hwm: gainFrac = (index - hwm) / index; f = perfFeeBps * gainFrac; mint feeShares = supply * f / (1 - f) to the curator, locked as bond for 1 epoch; hwm = index
- Breach: index < peakIndex * (1 - maxDrawdownBps) -> suspend curator, burn all bond shares, safe mode
- Capacity: cap = baseCap * min(1 + goodEpochs, maxMultiplier); good epoch = ratio >= 1.0

## Security rules (non-negotiable)
- Never use slot0 alone for any decision; always the Chainlink band + staleness check
- Deposits: band check + amount0Max, amount1Max, minShares; dead shares and minimum first deposit; revert on zero shares minted
- Withdrawals: in kind, pro rata on every position and idle balance; no price used; must work with curator suspended, oracle stale or safe mode on
- EIP-712 domain with chainId and hook address; per-curator nonce; deadline; ERC-1271 for contract curators; Range[] hashed as keccak of concatenated Range struct hashes
- Hook never requires hookData; intents live in storage
- Checks-effects-interactions; nonReentrant on vault entry points; hook functions only callable by PoolManager
- No lockups or exit fees ever; fee cap, safe-mode rules and in-kind withdrawal are immutable
- Validate hook address bits with Hooks.validateHookPermissions in the deploy script and a test

## Phases and acceptance
1. Skeleton (Nov 22-23): Foundry project from the v4 template with OpenZeppelin uniswap-hooks; hook address mining + permissions test; vault deposit/withdraw with dead shares + min first deposit + zero-shares revert; Mandate struct; MandateLib with a pass and a MandateViolation test per term; EIP-712 intent verification (nonce, deadline, chainId, ERC-1271) with tests.
2. Core (Nov 24-28): queueIntent; executeQueued via unlock; beforeSwap path; OracleGuard with a mock aggregator; epoch close, NAV, index, HWM fee, bond lock/burn, breach, safe mode; idle-epoch liveness. Unit tests for every revert and skip path, including low-gas swaps leaving the intent queued and the hook's deltas netting to zero.
3. Harden (Nov 29 - Dec 1): amendments (delay, exit before apply, immutable fields); capacity; invariant suite (below); fuzz MandateLib against a simple reference implementation; Reactive watcher + callback auth tests; deploy to Unichain Sepolia with the real Chainlink feed; fork test.
4. Ship (Dec 2-3): web (leaderboard, vault page with NAV vs hold chart + amendment banner, curator console with live pre-check), agent script, demo script with 3 curators (Steady, Agent, Reckless), README (integrations with file:line, invariants + runs, coverage, gas).

## Invariants (Foundry handler: deposit, withdraw, queue, execute, swap, closeEpoch, amend, warp, moveOracle)
1. Sum of share claims == hook holdings (rounding favours the vault)
2. Per-epoch turnover <= cap; every live position satisfies distance, width, count
3. Any holder can always withdraw in kind (curator suspended, oracle stale, safe mode)
4. Fee minted only when index > hwm; hwm non-decreasing
5. After a breach, each non-curator holder's claim per share >= before the burn

## Never cut
mandate checks, signed intents, Chainlink guard, track record, index HWM fee, bond burn, in-kind withdrawal, invariant tests.

## Cut order if behind
Brevis -> curator vote -> capacity -> Reactive watcher (keep permissionless calls) -> beforeSwap execution (keep executeQueued).

## Conventions
- Solidity 0.8.26+, Foundry, OpenZeppelin uniswap-hooks BaseHook, v4-core/v4-periphery; credit libraries and any workshop-derived code in the README
- Custom errors: MandateViolation(bytes32 term), IntentExpired, BadSignature, OracleStale, OutOfBand, NotCurator, CapacityExceeded
- Events for everything the frontend reads: IntentQueued, Rebalanced, IntentSkipped, EpochClosed, FeeMinted, Breach, SafeMode, AmendmentProposed, AmendmentApplied
- Testnet params: epochLength 5 min, amendmentDelay 10 min
- README must name prior art ERC-8192 ("Mandate Pattern" for ERC-4626 vaults) and state what Bridle adds: hook-native LP limits, execution inside swaps, scoring vs holding, index HWM, bond burn, exits before amendments
- Repo is public; the README lists only partner integrations that are actually built, with file paths

## Kickoff prompt for Claude Code
"Read CLAUDE.md. Set up the Foundry project under contracts/ from the Uniswap v4 template with OpenZeppelin uniswap-hooks, then do phase 1 only: hook skeleton (BridleHook) with the three permissions and address mining, vault deposit/withdraw with dead shares (BridleVault), Mandate struct, MandateLib checks, EIP-712 intent verification. Write unit tests for each mandate term (pass and MandateViolation cases) and for signature edge cases. Run forge test and show me results, then stop."
