# DriftGuard

DriftGuard is a self-resolving prediction market for relative movement. Instead of
asking a plain yes/no threshold question, each market starts from a fixed reference
value and a tolerance measured in basis points. The final reading is classified as
`DownDrift`, `Stable`, or `UpDrift`.

Ritual's Scheduler books three resolution attempts when the market is created. Each
attempt performs one HTTP precompile call (`0x0801`) and then a synchronous jq
extraction (`0x0803`). A successful read calculates:

```text
driftBps = (observed - referenceValue) * 10000 / referenceValue
```

If the drift is below `-toleranceBps`, `DownDrift` wins. If it is above
`+toleranceBps`, `UpDrift` wins. Everything inside the tolerance window resolves as
`Stable`.

## Resolution Flow

```text
createMarket
   └─ Scheduler: 3 attempts, 180 blocks apart
          └─ pick HTTP executor -> fetch dataUrl -> jq jsonPath -> classify drift

negative drift past tolerance ───► DownDrift
inside tolerance window ─────────► Stable
positive drift past tolerance ───► UpDrift
all attempts fail ───────────────► Invalid / refunds
winning side empty ──────────────► Invalid / refunds
```

## Behavior

- `referenceValue` must be non-zero.
- `toleranceBps` is capped at 5,000 bps.
- Failed HTTP and jq reads spend retry budget instead of becoming an outcome.
- A successful attempt cancels the remaining scheduled executions.
- Payouts are pull-based and proportional across the three pools.
- Invalid markets refund all original stakes.
- No executor is hardcoded; the contract asks `TEEServiceRegistry` at resolution time.

## Verify Locally

```bash
cd hardhat
pnpm install
pnpm exec hardhat build
pnpm exec tsc --noEmit
pnpm exec hardhat test solidity
```

## Files

| Path | Purpose |
|---|---|
| `hardhat/contracts/RitualPredict.sol` | Drift-based market contract |
| `hardhat/contracts/DriftGuard.t.sol` | Solidity tests with local Ritual mocks |
| `hardhat/contracts/ritual/RitualChain.sol` | Ritual system addresses and interfaces |
| `DRIFT_SPEC.md` | Settlement and accounting rules |
| `LOCAL_RUN.md` | Build and debugging record |

## Deployment Status

This fork intentionally has no frontend and no GitHub Pages site. The account folder
contained a GitHub token but no Ritual deployer private key, so the work was verified
locally and no contract address or transaction hash is claimed.

Official workshop parent: <https://github.com/cozfuttu/ritual-chain-workshop-2>.
