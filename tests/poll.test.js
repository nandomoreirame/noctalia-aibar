import { describe, it, expect } from "vitest";
import { createState, canRequest, begin, succeed, fail, BACKOFF_MS, REQUEST_TIMEOUT_MS } from "../utils/poll.js";

const SNAP = { provider: "claude", windows: [{ id: "session", percent: 1 }] };

describe("poll", () => {
  it("allows one request at a time", () => {
    const s = begin(createState(), 0);
    expect(canRequest(s, 0)).toBe(false);
    expect(canRequest(succeed(s, SNAP), 0)).toBe(true);
  });

  it("keeps the last snapshot as stale on failure", () => {
    const ok = succeed(begin(createState(), 0), SNAP);
    const bad = fail(begin(ok, 1), "network", 0, 1);
    expect(bad).toMatchObject({ snapshot: SNAP, stale: true, error: "network", inFlight: false });
  });

  it("maps HTTP status codes to error kinds", () => {
    expect(fail(createState(), "http", 401, 0).error).toBe("auth");
    expect(fail(createState(), "http", 403, 0).error).toBe("auth");
    expect(fail(createState(), "http", 500, 0)).toMatchObject({ error: "http", code: 500 });
  });

  it("backs off for five minutes after a 429", () => {
    const s = fail(createState(), "http", 429, 1000);
    expect(s.error).toBe("rate-limited");
    expect(canRequest(s, 1000 + BACKOFF_MS - 1)).toBe(false);
    expect(canRequest(s, 1000 + BACKOFF_MS)).toBe(true);
  });

  it("clears the error and backoff on success", () => {
    const s = succeed(begin(fail(createState(), "http", 429, 0), BACKOFF_MS), SNAP);
    expect(s).toMatchObject({ error: "", stale: false, retryAt: 0, snapshot: SNAP });
  });

  it("keeps auth errors from credential reads", () => {
    expect(fail(createState(), "claude-expired", 0, 0)).toMatchObject({ error: "claude-expired", stale: false });
  });

  // QML XMLHttpRequest ignores xhr.timeout, so a request cut by suspend never finishes.
  it("frees a request that never answers", () => {
    const s = begin(createState(), 1000);
    expect(canRequest(s, 1000 + REQUEST_TIMEOUT_MS - 1)).toBe(false);
    expect(canRequest(s, 1000 + REQUEST_TIMEOUT_MS)).toBe(true);
  });

  it("still honors the 429 backoff while freeing a hung request", () => {
    const s = begin(fail(createState(), "http", 429, 0), 0);
    expect(canRequest(s, REQUEST_TIMEOUT_MS)).toBe(false);
    expect(canRequest(s, BACKOFF_MS)).toBe(true);
  });
});
