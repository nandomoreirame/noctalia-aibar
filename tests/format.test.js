import { describe, it, expect } from "vitest";
import { countdown, percentText, barText, minutesAgo, windowKey, errorMessage, moneyText, limitMessage, ago } from "../utils/format.js";

const M = 60000;

describe("format", () => {
  it("formats a countdown as d/h/m", () => {
    expect(countdown(72 * M, 0)).toBe("1h12m");
    expect(countdown(45 * M, 0)).toBe("45m");
    expect(countdown((3 * 24 * 60 + 4 * 60 + 30) * M, 0)).toBe("3d4h");
    expect(countdown(-5, 0)).toBe("0m");
    expect(countdown(null, 0)).toBe("");
  });
  it("rounds percent", () => {
    expect(percentText(47.4)).toBe("47%");
    expect(percentText(null)).toBe("—");
  });
  it("builds the bar text", () => {
    expect(barText({ percent: 47, end: 72 * M }, 0)).toBe("47% · 1h12m");
    expect(barText({ percent: 47, end: null }, 0)).toBe("47%");
    expect(barText(null, 0)).toBe("—");
  });
  it("counts minutes since a fetch", () => {
    expect(minutesAgo(0, 30 * 1000)).toBe(0);
    expect(minutesAgo(0, 5 * M + 1)).toBe(5);
  });
  it("maps a window to its i18n key", () => {
    expect(windowKey({ id: "session" })).toBe("window.session");
    expect(windowKey({ id: "weekly-opus" })).toBe("window.weekly-opus");
    expect(windowKey({ id: "period", periodType: "monthly" })).toBe("window.period-monthly");
    expect(windowKey({ id: "period", periodType: "weekly" })).toBe("window.period-weekly");
    expect(windowKey({ id: "period" })).toBe("window.period-weekly");
  });
  it("maps a request error to an i18n key and its vars", () => {
    expect(errorMessage(null, "claude", 0)).toBe(null);
    expect(errorMessage({ error: "" }, "claude", 0)).toBe(null);
    expect(errorMessage({ error: "auth" }, "claude", 0)).toEqual({ key: "error.claude-expired", vars: null });
    expect(errorMessage({ error: "auth" }, "grok", 0)).toEqual({ key: "error.grok-login", vars: null });
    expect(errorMessage({ error: "http", code: 503 }, "grok", 0)).toEqual({ key: "error.http", vars: { code: 503 } });
    expect(errorMessage({ error: "rate-limited", retryAt: 90 * 1000 }, "claude", 0)).toEqual({ key: "error.rate-limited", vars: { n: 2 } });
    expect(errorMessage({ error: "rate-limited", retryAt: 0 }, "claude", 5 * M)).toEqual({ key: "error.rate-limited", vars: { n: 0 } });
    expect(errorMessage({ error: "network" }, "claude", 0)).toEqual({ key: "error.network", vars: null });
  });
  it("formats extra usage money with two decimals and the given separator", () => {
    const extra = { used: 33.5, limit: 90, currency: "BRL" };
    expect(moneyText(extra, ",")).toBe("33,50 / 90,00 BRL");
    expect(moneyText(extra, ".")).toBe("33.50 / 90.00 BRL");
    expect(moneyText({ used: 0.1 + 0.2, limit: 5, currency: "" }, ".")).toBe("0.30 / 5.00");
    expect(moneyText({ used: 1, limit: 2, currency: "USD" })).toBe("1.00 / 2.00 USD");
    expect(moneyText(null, ",")).toBe("");
  });

  it("hides login errors while a limit is reached, but keeps the others", () => {
    for (const error of ["auth", "grok-login", "claude-expired", "claude-login"])
      expect(errorMessage({ error: error }, "grok", 0, true)).toBe(null);
    expect(errorMessage({ error: "network" }, "grok", 0, true)).toEqual({ key: "error.network", vars: null });
    expect(errorMessage({ error: "auth" }, "grok", 0, false)).toEqual({ key: "error.grok-login", vars: null });
  });

  it("tells how long ago a snapshot was fetched", () => {
    expect(ago(0, 5 * M)).toBe("5m");
    expect(ago(0, 125 * M)).toBe("2h5m");
    expect(ago(0, 3 * 1440 * M)).toBe("3d0h");
  });

  it("describes a reached limit with its reset countdown", () => {
    expect(limitMessage({ percent: 100, end: 72 * M }, 0)).toEqual({ key: "panel.limit-reached", vars: { t: "1h12m" } });
    expect(limitMessage(null, 0)).toBe(null);
  });
});
