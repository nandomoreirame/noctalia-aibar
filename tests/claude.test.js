import { describe, it, expect } from "vitest";
import { readFileSync } from "node:fs";
import { parseUsage, WINDOW_MS } from "../utils/claude.js";

const fixture = readFileSync(new URL("./fixtures/claude-usage.json", import.meta.url), "utf8");
const NOW = Date.parse("2026-10-10T20:00:00Z");

describe("claude parseUsage", () => {
  it("maps the real response to session and weekly windows", () => {
    const s = parseUsage(fixture, "max", NOW);
    expect(s.ok).toBe(true);
    expect(s.snapshot.provider).toBe("claude");
    expect(s.snapshot.plan).toBe("max");
    expect(s.snapshot.windows.map((w) => w.id)).toEqual(["session", "weekly"]);
    const session = s.snapshot.windows[0];
    expect(session.percent).toBe(47);
    expect(session.end).toBe(Date.parse("2026-10-10T22:50:00.082044+00:00"));
    expect(session.start).toBe(session.end - WINDOW_MS.session);
    expect(s.snapshot.fetchedAt).toBe(NOW);
  });

  it("maps extra usage in major units", () => {
    const { extra } = parseUsage(fixture, "", NOW).snapshot;
    expect(extra).toEqual({ enabled: false, used: 33.5, limit: 90, percent: 37.22222222222222, currency: "BRL" });
  });

  it("adds model-scoped weekly windows only when present", () => {
    const body = JSON.stringify({
      five_hour: { utilization: 10, resets_at: "2026-10-10T22:00:00Z" },
      seven_day_opus: { utilization: 5, resets_at: "2026-10-15T00:00:00Z" },
      seven_day_sonnet: null
    });
    expect(parseUsage(body, "", NOW).snapshot.windows.map((w) => w.id)).toEqual(["session", "weekly-opus"]);
  });

  it("is an error when nothing usable comes back", () => {
    expect(parseUsage("{}", "", NOW)).toEqual({ ok: false, error: "parse" });
    expect(parseUsage("<html>", "", NOW)).toEqual({ ok: false, error: "parse" });
  });
});
