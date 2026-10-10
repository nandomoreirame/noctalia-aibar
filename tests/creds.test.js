import { describe, it, expect } from "vitest";
import { claudeToken, grokKey } from "../utils/creds.js";

const NOW = 1_800_000_000_000;

describe("claudeToken", () => {
  const file = (o) => JSON.stringify({ claudeAiOauth: o });
  it("returns the token and plan when not expired", () => {
    expect(claudeToken(file({ accessToken: "AT", expiresAt: NOW + 3_600_000, subscriptionType: "max" }), NOW))
      .toEqual({ ok: true, token: "AT", plan: "max" });
  });
  it("treats a token expiring within a minute as expired", () => {
    expect(claudeToken(file({ accessToken: "AT", expiresAt: NOW + 30_000 }), NOW)).toEqual({ ok: false, error: "claude-expired" });
  });
  it("reports login for missing or malformed files", () => {
    expect(claudeToken("", NOW)).toEqual({ ok: false, error: "claude-login" });
    expect(claudeToken("{not json", NOW)).toEqual({ ok: false, error: "claude-login" });
    expect(claudeToken(file({ expiresAt: NOW + 3_600_000 }), NOW)).toEqual({ ok: false, error: "claude-login" });
  });
});

describe("grokKey", () => {
  it("takes the first entry with a key", () => {
    const f = JSON.stringify({ a: { email: "x" }, "https://auth.x.ai": { key: "  K1  " }, b: { key: "K2" } });
    expect(grokKey(f)).toEqual({ ok: true, key: "K1" });
  });
  it("reports login when there is no key", () => {
    expect(grokKey("")).toEqual({ ok: false, error: "grok-login" });
    expect(grokKey(JSON.stringify({ a: { key: "" } }))).toEqual({ ok: false, error: "grok-login" });
    expect(grokKey("[]")).toEqual({ ok: false, error: "grok-login" });
  });
});
