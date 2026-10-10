import { describe, it, expect } from "vitest";
import { readFileSync, existsSync } from "node:fs";

const m = JSON.parse(readFileSync(new URL("../manifest.json", import.meta.url)));

describe("manifest", () => {
  it("points at existing entry files", () => {
    for (const f of Object.values(m.entryPoints)) expect(existsSync(new URL(`../${f}`, import.meta.url))).toBe(true);
  });
  it("declares every setting default", () => {
    expect(Object.keys(m.metadata.defaultSettings).sort()).toEqual(["barProvider", "claudeUserAgent", "notifyThreshold", "pollMinutes"]);
    expect(m.metadata.defaultSettings.barProvider).toBe("claude");
  });
});
