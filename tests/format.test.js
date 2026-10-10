import { describe, it, expect } from "vitest";
import { countdown, percentText, barText, minutesAgo } from "../utils/format.js";

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
});
