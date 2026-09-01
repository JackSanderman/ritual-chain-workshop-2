/**
 * Print live status for every market — the fastest way to see whether the Scheduler
 * has woken the contract yet.
 *
 *   PREDICT_ADDRESS=0x... npx hardhat run scripts/status.ts
 */
import { formatEther } from "viem";
import { MARKET_STATE, OUTCOME } from "./market-presets.ts";
import { RITUAL, connectRitual, ritual } from "./ritual.ts";

const SCHEDULER_CALL_STATE = ["SCHEDULED", "EXECUTING", "COMPLETED", "CANCELLED", "EXPIRED"] as const;

const SCHEDULER_ABI = [
  {
    type: "function",
    name: "getCallState",
    stateMutability: "view",
    inputs: [{ name: "callId", type: "uint256" }],
    outputs: [{ name: "state", type: "uint8" }],
  },
] as const;

const address = process.env.PREDICT_ADDRESS;
if (!address) throw new Error("Set PREDICT_ADDRESS to the deployed RitualPredict address.");

const { connection, publicClient, viem } = await connectRitual();
const predict = await viem.getContractAt("RitualPredict", address as `0x${string}`);

const [currentBlock, blockTimeMs, executionBalance, count, maxAttempts] = await Promise.all([
  publicClient.getBlockNumber(),
  predict.read.blockTimeMs(),
  predict.read.executionBalance(),
  predict.read.marketCount(),
  predict.read.MAX_ATTEMPTS(),
]);

console.log(`Contract:          ${address}`);
console.log(`Current block:     ${currentBlock}`);
console.log(`Execution balance: ${ritual(executionBalance)}`);
console.log(`Markets:           ${count}`);

const secondsUntil = (target: bigint) =>
  target <= currentBlock ? "now" : `${(Number(target - currentBlock) * Number(blockTimeMs)) / 1000}s`;

for (const market of await predict.read.getMarkets()) {
  const pool = market.totalDown + market.totalStable + market.totalUp;
  const pct = (value: bigint) => (pool === 0n ? 0 : Number((value * 10000n) / pool) / 100);

  console.log("");
  console.log(`#${market.id} ${market.question}`);
  console.log(`  state        ${MARKET_STATE[market.state]}   outcome ${OUTCOME[market.outcome]}`);
  console.log(`  rule         reference ${market.referenceValue}, tolerance +/-${market.toleranceBps} bps`);
  console.log(`  source       ${market.dataUrl}  (jq ${market.jsonPath})`);
  console.log(
    `  pool         ${formatEther(pool)} RITUAL — down ${pct(market.totalDown).toFixed(1)}% / stable ${pct(
      market.totalStable,
    ).toFixed(1)}% / up ${pct(market.totalUp).toFixed(1)}%`,
  );
  console.log(`  closes       block ${market.closeBlock} (${secondsUntil(market.closeBlock)})`);
  console.log(`  resolves     block ${market.resolveBlock} (${secondsUntil(market.resolveBlock)})`);
  console.log(`  attempts     ${market.attempts}/${maxAttempts}`);

  if (market.observedValue !== 0n) {
    console.log(`  observed     ${market.observedValue} (${market.driftBps} bps drift)`);
  }
  if (market.invalidReason !== "") console.log(`  invalid      ${market.invalidReason}`);

  if (market.scheduleId !== 0n) {
    const state = await publicClient.readContract({
      address: RITUAL.scheduler,
      abi: SCHEDULER_ABI,
      functionName: "getCallState",
      args: [market.scheduleId],
    });
    console.log(`  schedule     id ${market.scheduleId} — ${SCHEDULER_CALL_STATE[state] ?? state}`);
  }
}

await connection.close();
