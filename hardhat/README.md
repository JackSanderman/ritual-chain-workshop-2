# DriftGuard Hardhat Package

This package contains the Solidity market, local mocks, and CLI scripts for a
three-outcome drift market on Ritual Chain.

## Commands

```bash
pnpm install
pnpm exec hardhat build
pnpm exec tsc --noEmit
pnpm exec hardhat test solidity
```

Solidity tests run entirely against local mocks. `vm.etch` places mocks at the canonical
Ritual Scheduler, RitualWallet, registry, HTTP, and jq addresses, so the suite does not
need live funds or a deployer key.

## Market Parameters

`NewMarket` contains a question, public JSON URL, jq path, reference value, tolerance in
basis points, betting duration, and resolution delay. The contract schedules three
resolution attempts and treats oracle failures as retryable failures, not as a market
answer.
