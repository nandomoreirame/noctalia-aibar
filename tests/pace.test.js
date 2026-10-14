import { describe, it, expect } from "vitest";
import { pace, status, primaryWindow, exhausted, project } from "../utils/pace.js";

const H = 3600000;

describe("pace", () => {
  it("compares used percent with elapsed percent", () => {
    const w = { percent: 60, start: 0, end: 10 * H };
    expect(pace(w, 4 * H)).toEqual({ elapsed: 40, delta: 20 });
  });
  it("clamps elapsed to 0..100 and handles missing bounds", () => {
    expect(pace({ percent: 10, start: 0, end: H }, 2 * H).elapsed).toBe(100);
    expect(pace({ percent: 10, start: null, end: null }, H)).toEqual({ elapsed: null, delta: null });
  });
});

describe("status", () => {
  it("is critical from 90, ahead above 10 points, ok otherwise", () => {
    expect(status({ percent: 90, start: 0, end: 10 * H }, 9 * H)).toBe("critical");
    expect(status({ percent: 60, start: 0, end: 10 * H }, 4 * H)).toBe("ahead");
    expect(status({ percent: 45, start: 0, end: 10 * H }, 4 * H)).toBe("ok");
    expect(status({ percent: 45, start: null, end: null }, 0)).toBe("ok");
  });
});

describe("primaryWindow", () => {
  it("is session for Claude and period for Grok", () => {
    expect(primaryWindow({ windows: [{ id: "weekly" }, { id: "session" }] }).id).toBe("session");
    expect(primaryWindow({ windows: [{ id: "period" }] }).id).toBe("period");
    expect(primaryWindow(null)).toBeNull();
  });

  it("finds the exhausted window that resets last", () => {
    const week = { id: "weekly", percent: 100, start: 0, end: 50 * H };
    const session = { id: "session", percent: 100, start: 0, end: 2 * H };
    expect(exhausted({ windows: [session, week] }, H)).toBe(week);
    expect(exhausted({ windows: [session, { id: "weekly", percent: 99.4, end: 50 * H }] }, H)).toBe(session);
  });

  it("ignores windows that already reset or have no end", () => {
    expect(exhausted({ windows: [{ id: "session", percent: 100, end: H }] }, H)).toBe(null);
    expect(exhausted({ windows: [{ id: "period", percent: 100, end: null }] }, 0)).toBe(null);
    expect(exhausted(null, 0)).toBe(null);
  });
});

describe("project", () => {
  it("shows windows whose reset already passed as 0% without bounds", () => {
    const snap = { provider: "claude", windows: [
      { id: "session", percent: 80, start: 0, end: H },
      { id: "weekly", percent: 97, start: 0, end: 100 * H }
    ] };
    const out = project(snap, 2 * H);
    expect(out.windows[0]).toEqual({ id: "session", percent: 0, start: null, end: null });
    expect(out.windows[1]).toBe(snap.windows[1]);
    expect(snap.windows[0].percent).toBe(80);
  });

  it("returns the same snapshot when nothing reset, and passes junk through", () => {
    const snap = { windows: [{ id: "session", percent: 5, start: 0, end: H }] };
    expect(project(snap, 0)).toBe(snap);
    expect(project(null, 0)).toBe(null);
    expect(project({ windows: [{ id: "x", percent: 5, end: null }] }, H).windows[0].percent).toBe(5);
  });
});
