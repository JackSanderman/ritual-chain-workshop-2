/** MarketState enum, matching RitualPredict.MarketState. */
export const MARKET_STATE = ["Open", "Closed", "Resolving", "Resolved", "Invalid"] as const;

/** Outcome enum, matching RitualPredict.Outcome. */
export const OUTCOME = ["Unresolved", "DownDrift", "Stable", "UpDrift"] as const;

/** Small CLI preset for a public JSON metric drift market. */
export const DEMO_MARKET = {
  question: "Will the usage metric move more than 5 percent from its reference?",
  dataUrl: "https://example.com/metric.json",
  jsonPath: ".metric",
  referenceValue: 1000,
  toleranceBps: 500,
  bettingSeconds: 180,
  resolveDelaySeconds: 60,
} as const;
