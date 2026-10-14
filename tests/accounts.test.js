import { describe, it, expect } from "vitest";
import { parseAccounts, sources, credPath, configPath, nextKey, resolveKey, accountOf, accountChange, cachedSnapshot, MAX_EXTRA } from "../utils/accounts.js";

describe("parseAccounts", () => {
  it("reads name=dir pairs separated by commas or newlines", () => {
    expect(parseAccounts("Trabalho=~/.claude-trabalho, Cliente X = /data/u/.claude-x\n")).toEqual([
      { key: "claude:trabalho", name: "Trabalho", dir: "~/.claude-trabalho" },
      { key: "claude:cliente-x", name: "Cliente X", dir: "/data/u/.claude-x" }
    ]);
  });

  it("drops a trailing slash from the dir", () => {
    expect(parseAccounts("A=~/.claude-a/")[0].dir).toBe("~/.claude-a");
  });

  it("ignores empty text and junk", () => {
    expect(parseAccounts("")).toEqual([]);
    expect(parseAccounts(undefined)).toEqual([]);
    expect(parseAccounts(42)).toEqual([]);
    expect(parseAccounts("no-equals, =~/.x, A=, A=relative/dir, !!!=~/.y")).toEqual([]);
  });

  it("rejects dirs that climb out with ..", () => {
    expect(parseAccounts("A=~/../etc, B=/data/u/../x")).toEqual([]);
  });

  it("skips the default dir and duplicate names", () => {
    expect(parseAccounts("A=~/.claude, B=~/.claude/, C=~/.c1, c=~/.c2").map(a => a.key)).toEqual(["claude:c"]);
  });

  it("keeps at most MAX_EXTRA accounts and caps the name length", () => {
    const text = Array.from({ length: MAX_EXTRA + 2 }, (_, i) => `N${i}=~/.c${i}`).join(",");
    expect(parseAccounts(text).length).toBe(MAX_EXTRA);
    expect(parseAccounts("A".repeat(40) + "=~/.c")[0].name.length).toBe(24);
  });
});

describe("sources", () => {
  it("lists the default Claude account, the extras, then Grok", () => {
    const list = sources(parseAccounts("Trabalho=~/.claude-trabalho"));
    expect(list).toEqual([
      { key: "claude", provider: "claude", name: "", dir: "", frozen: false },
      { key: "claude:trabalho", provider: "claude", name: "Trabalho", dir: "~/.claude-trabalho", frozen: true },
      { key: "grok", provider: "grok", name: "", dir: "", frozen: false }
    ]);
  });

  it("accepts a missing list", () => {
    expect(sources(null).map(s => s.key)).toEqual(["claude", "grok"]);
  });
});

describe("credPath", () => {
  it("expands ~ against HOME and appends the credentials file", () => {
    expect(credPath("~/.claude-x", "/data/u")).toBe("/data/u/.claude-x/.credentials.json");
    expect(credPath("/data/u/.claude-y", "/ignored")).toBe("/data/u/.claude-y/.credentials.json");
  });
});

describe("configPath", () => {
  // Claude Code keeps .claude.json in HOME by default and inside CLAUDE_CONFIG_DIR otherwise.
  it("points at the account's .claude.json", () => {
    expect(configPath("", "/data/u")).toBe("/data/u/.claude.json");
    expect(configPath("~/.claude-freeze", "/data/u")).toBe("/data/u/.claude-freeze/.claude.json");
  });
});

describe("accountOf", () => {
  it("reads the logged account id and email, nothing else", () => {
    const text = JSON.stringify({ oauthAccount: { accountUuid: "u1", emailAddress: "a@x.dev", organizationUuid: "o" }, other: 1 });
    expect(accountOf(text)).toEqual({ uuid: "u1", email: "a@x.dev" });
  });

  it("is null without a logged account", () => {
    expect(accountOf("")).toBe(null);
    expect(accountOf("{bad")).toBe(null);
    expect(accountOf("{}")).toBe(null);
    expect(accountOf(JSON.stringify({ oauthAccount: { emailAddress: "a@x.dev" } }))).toBe(null);
  });

  it("tolerates a missing email", () => {
    expect(accountOf(JSON.stringify({ oauthAccount: { accountUuid: "u1" } }))).toEqual({ uuid: "u1", email: "" });
  });
});

describe("accountChange", () => {
  it("adopts the first id, resets on a swap and ignores unreadable files", () => {
    expect(accountChange("", "u1")).toBe("adopt");
    expect(accountChange("u1", "u1")).toBe("none");
    expect(accountChange("u1", "u2")).toBe("reset");
    expect(accountChange("u1", "")).toBe("none");
  });
});

describe("cachedSnapshot", () => {
  const cache = { claude: { legacy: 1 }, grok: { g: 1 }, byAccount: { u1: { a: 1 } } };

  it("uses the account id when known", () => {
    expect(cachedSnapshot(cache, "claude", "u1")).toEqual({ a: 1 });
    expect(cachedSnapshot(cache, "claude:freeze", "u1")).toEqual({ a: 1 });
    expect(cachedSnapshot(cache, "claude", "u2")).toBe(null);
  });

  it("falls back to the per-provider entry only without an id", () => {
    expect(cachedSnapshot(cache, "claude", "")).toEqual({ legacy: 1 });
    expect(cachedSnapshot(cache, "grok", "")).toEqual({ g: 1 });
    expect(cachedSnapshot(cache, "claude:freeze", "")).toBe(null);
    expect(cachedSnapshot(null, "claude", "u1")).toBe(null);
  });
});

describe("nextKey and resolveKey", () => {
  const list = sources(parseAccounts("T=~/.claude-t"));

  it("cycles through every source", () => {
    expect(nextKey(list, "claude")).toBe("claude:t");
    expect(nextKey(list, "claude:t")).toBe("grok");
    expect(nextKey(list, "grok")).toBe("claude");
  });

  it("falls back to the first source for an unknown key", () => {
    expect(nextKey(list, "claude:gone")).toBe("claude");
    expect(resolveKey(list, "claude:gone")).toBe("claude");
    expect(resolveKey(list, "grok")).toBe("grok");
  });
});
