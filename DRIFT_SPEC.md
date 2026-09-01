# DriftGuard Specification

## Valid Signal

A resolution attempt is usable only when:

1. `TEEServiceRegistry` returns an HTTP-capable executor;
2. the HTTP precompile succeeds and returns a settled async envelope;
3. the HTTP status is 2xx and the executor error string is empty;
4. jq extracts a `uint256` from the configured JSON path.

Failures do not vote. They consume one scheduled attempt. After the third failed
attempt, the market becomes invalid and all stakes are refundable.

## Drift Rule

The market stores a non-zero `referenceValue` and a `toleranceBps` cap. Settlement uses
integer basis points:

```text
positive drift = (observed - referenceValue) * 10000 / referenceValue
negative drift = -((referenceValue - observed) * 10000 / referenceValue)
```

| Drift | Result |
|---|---|
| `< -toleranceBps` | `DownDrift` |
| `>= -toleranceBps` and `<= toleranceBps` | `Stable` |
| `> toleranceBps` | `UpDrift` |

The tolerance edges are stable by design.

## Accounting

- Bets are split into three independent pools.
- A resolved winner claims `stake * totalPool / winningPool`.
- Invalid markets refund original stake across all three sides.
- If the winning pool is empty, the market is invalidated to avoid trapped funds.
- Claim state is written before transfers.
