import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { parseBilling } from "../utils/grok.js";

const read = (f) => readFileSync(new URL(`./fixtures/${f}`, import.meta.url), "utf8");
const NOW = Date.parse("2026-10-10T20:00:00Z");

describe("grok parseBilling", () => {
  it("maps the credits response to a period window and products", () => {
    const s = parseBilling(read("grok-billing.json"), NOW);
    expect(s.ok).toBe(true);
    expect(s.snapshot.windows).toEqual([{
      id: "period",
      periodType: "weekly",
      percent: 63,
      start: Date.parse("2026-10-06T19:06:04.770890+00:00"),
      end: Date.parse("2026-10-13T19:06:04.770890+00:00")
    }]);
    expect(s.snapshot.products).toEqual([{ name: "GrokBuild", percent: 63 }]);
    expect(s.snapshot.provider).toBe("grok");
  });

  it("reads a monthly period and a missing period", () => {
    const monthly = JSON.stringify({ config: { creditUsagePercent: 5, currentPeriod: { type: "USAGE_PERIOD_TYPE_MONTHLY", start: "2026-10-01T00:00:00Z", end: "2026-11-01T00:00:00Z" } } });
    expect(parseBilling(monthly, NOW).snapshot.windows[0].periodType).toBe("monthly");
    const noPeriod = JSON.stringify({ config: { creditUsagePercent: 5 } });
    expect(parseBilling(noPeriod, NOW).snapshot.windows[0]).toMatchObject({ start: null, end: null, periodType: "weekly" });
  });

  it("refuses the legacy shape and garbage", () => {
    expect(parseBilling(read("grok-billing-legacy.json"), NOW)).toEqual({ ok: false, error: "grok-format" });
    expect(parseBilling("nope", NOW)).toEqual({ ok: false, error: "parse" });
  });
});
