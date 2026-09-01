/**
 * Create the preset drift market: betting open ~3 minutes, automatic resolution
 * ~1 minute later.
 *
 *   PREDICT_ADDRESS=0x... DATA_URL=https://example.com/metric.json \
 *     npx hardhat run scripts/create-demo-market.ts
 *
 * Optional: QUESTION, JSON_PATH, REFERENCE_VALUE, TOLERANCE_BPS, BETTING_SECONDS,
 *           RESOLVE_DELAY_SECONDS
 */
import { DEMO_MARKET } from "./market-presets.ts";
import { connectRitual, explorerTx } from "./ritual.ts";

const address = process.env.PREDICT_ADDRESS;
if (!address) throw new Error("Set PREDICT_ADDRESS to the deployed RitualPredict address.");

const dataUrl = process.env.DATA_URL ?? DEMO_MARKET.dataUrl;
if (!dataUrl.startsWith("https://") && !dataUrl.startsWith("http://")) {
  throw new Error("DATA_URL must be an http(s) URL reachable from the public internet.");
}
if (dataUrl.includes("localhost") || dataUrl.includes("127.0.0.1")) {
  throw new Error(
    "The data URL is fetched by a TEE executor in the cloud, so localhost will never resolve.",
  );
}

const params = {
  question: process.env.QUESTION ?? DEMO_MARKET.question,
  dataUrl,
  jsonPath: process.env.JSON_PATH ?? DEMO_MARKET.jsonPath,
  referenceValue: BigInt(process.env.REFERENCE_VALUE ?? DEMO_MARKET.referenceValue),
  toleranceBps: Number(process.env.TOLERANCE_BPS ?? DEMO_MARKET.toleranceBps),
  bettingSeconds: BigInt(process.env.BETTING_SECONDS ?? DEMO_MARKET.bettingSeconds),
  resolveDelaySeconds: BigInt(process.env.RESOLVE_DELAY_SECONDS ?? DEMO_MARKET.resolveDelaySeconds),
} as const;

const { connection, publicClient, viem } = await connectRitual();
const predict = await viem.getContractAt("RitualPredict", address as `0x${string}`);

const executionBalance = await predict.read.executionBalance();
if (executionBalance === 0n) {
  console.warn(
    "! Execution balance is 0 — the scheduled resolution will be skipped.\n" +
      "  Run: PREDICT_ADDRESS=... npx hardhat run scripts/fund.ts",
  );
}

console.log(`Question:   ${params.question}`);
console.log(`Rule:       drift from ${params.referenceValue} with +/-${params.toleranceBps} bps tolerance`);
console.log(`Source:     ${params.dataUrl}  (jq: ${params.jsonPath})`);
console.log(`Betting:    ${params.bettingSeconds}s, then resolve after ${params.resolveDelaySeconds}s`);
console.log("");

const hash = await predict.write.createMarket([params]);
const receipt = await publicClient.waitForTransactionReceipt({ hash });

const marketId = await predict.read.marketCount();
const market = await predict.read.getMarket([marketId]);

console.log(`Created market #${marketId} in block ${receipt.blockNumber}`);
console.log(`Betting closes at block ${market.closeBlock}`);
console.log(`Scheduler fires at block ${market.resolveBlock} (schedule id ${market.scheduleId})`);
console.log(`${explorerTx(hash)}`);

await connection.close();
