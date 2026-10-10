import { describe, it, expect } from "vitest";
import { crossings } from "../utils/notify.js";

const snap = (p, end = 1000) => ({ provider: "claude", windows: [{ id: "session", percent: p, end }] });

describe("crossings", () => {
  it("fires once when a window crosses the threshold upward", () => {
    const a = crossings(snap(98), {}, 97);
    expect(a.fire).toEqual([{ provider: "claude", id: "session", percent: 98, end: 1000 }]);
    const b = crossings(snap(99), a.armed, 97);
    expect(b.fire).toEqual([]);
  });
  it("re-arms after dropping below or after a reset", () => {
    const a = crossings(snap(98), {}, 97);
    expect(crossings(snap(98), crossings(snap(10), a.armed, 97).armed, 97).fire.length).toBe(1);
    expect(crossings(snap(98, 2000), a.armed, 97).fire.length).toBe(1);
  });
  it("is off at threshold 0", () => {
    expect(crossings(snap(100), {}, 0).fire).toEqual([]);
  });
});
