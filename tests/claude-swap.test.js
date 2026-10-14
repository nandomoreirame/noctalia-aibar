import { describe, it, expect, beforeEach } from "vitest";
import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, writeFileSync, readFileSync, chmodSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const SCRIPT = new URL("../scripts/claude-swap", import.meta.url).pathname;

let home;
let fakeBin;

const cred = (t) => JSON.stringify({ claudeAiOauth: { accessToken: t, refreshToken: "r-" + t, expiresAt: 1 } });
const account = (uuid) => ({ accountUuid: uuid, emailAddress: uuid + "@x.dev" });
const read = (p) => JSON.parse(readFileSync(join(home, p), "utf8"));

// pgrep stub: exit 1 = no claude running, 0 = running.
function stubPgrep(running) {
  writeFileSync(join(fakeBin, "pgrep"), `#!/bin/sh\nexit ${running ? 0 : 1}\n`);
  chmodSync(join(fakeBin, "pgrep"), 0o755);
}

function run(...args) {
  return spawnSync("bash", [SCRIPT, ...args], {
    env: { HOME: home, PATH: `${fakeBin}:/usr/bin:/bin` },
    encoding: "utf8"
  });
}

beforeEach(() => {
  home = mkdtempSync(join(tmpdir(), "swap-"));
  fakeBin = join(home, "bin");
  mkdirSync(fakeBin);
  mkdirSync(join(home, ".claude"));
  mkdirSync(join(home, ".claude-freeze"));
  writeFileSync(join(home, ".claude/.credentials.json"), cred("A"), { mode: 0o600 });
  writeFileSync(join(home, ".claude-freeze/.credentials.json"), cred("B"), { mode: 0o600 });
  writeFileSync(join(home, ".claude.json"), JSON.stringify({ oauthAccount: account("a"), mcpServers: { m: 1 } }));
  writeFileSync(join(home, ".claude-freeze/.claude.json"), JSON.stringify({ oauthAccount: account("b") }));
  stubPgrep(false);
});

describe("claude-swap", () => {
  it("swaps logins and accounts, keeping the rest of .claude.json", () => {
    const r = run();
    expect(r.status).toBe(0);
    expect(read(".claude/.credentials.json").claudeAiOauth.accessToken).toBe("B");
    expect(read(".claude-freeze/.credentials.json").claudeAiOauth.accessToken).toBe("A");
    expect(read(".claude.json")).toEqual({ oauthAccount: account("b"), mcpServers: { m: 1 } });
    expect(read(".claude-freeze/.claude.json")).toEqual({ oauthAccount: account("a") });
    expect(r.stdout).toContain("b@x.dev");
    expect(r.stdout).not.toContain("r-A");
  });

  it("swaps back to the original state", () => {
    run();
    expect(run().status).toBe(0);
    expect(read(".claude/.credentials.json").claudeAiOauth.accessToken).toBe("A");
    expect(read(".claude.json").oauthAccount.accountUuid).toBe("a");
  });

  it("keeps the credential files private", () => {
    run();
    expect(statSync(join(home, ".claude/.credentials.json")).mode & 0o777).toBe(0o600);
    expect(statSync(join(home, ".claude-freeze/.credentials.json")).mode & 0o777).toBe(0o600);
    expect(statSync(join(home, ".claude-freeze/.claude.json")).mode & 0o777).toBe(0o600);
  });

  it("refuses while claude is running and changes nothing", () => {
    stubPgrep(true);
    const r = run();
    expect(r.status).not.toBe(0);
    expect(r.stderr).toMatch(/claude/);
    expect(read(".claude/.credentials.json").claudeAiOauth.accessToken).toBe("A");
    expect(read(".claude.json").oauthAccount.accountUuid).toBe("a");
  });

  it("refuses when the frozen account is incomplete", () => {
    writeFileSync(join(home, ".claude-freeze/.claude.json"), "{}");
    const r = run();
    expect(r.status).not.toBe(0);
    expect(read(".claude/.credentials.json").claudeAiOauth.accessToken).toBe("A");
  });

  it("prints both accounts with status and changes nothing", () => {
    const r = run("status");
    expect(r.status).toBe(0);
    expect(r.stdout).toContain("a@x.dev");
    expect(r.stdout).toContain("b@x.dev");
    expect(read(".claude/.credentials.json").claudeAiOauth.accessToken).toBe("A");
  });

  it("freezes the current login into an empty freeze dir with init", () => {
    const empty = mkdtempSync(join(tmpdir(), "swap-"));
    mkdirSync(join(empty, ".claude"));
    writeFileSync(join(empty, ".claude/.credentials.json"), cred("A"), { mode: 0o600 });
    writeFileSync(join(empty, ".claude.json"), JSON.stringify({ oauthAccount: account("a"), x: 1 }));
    home = empty;
    mkdirSync((fakeBin = join(home, "bin")));
    stubPgrep(false);
    const r = run("init");
    expect(r.status).toBe(0);
    expect(read(".claude-freeze/.credentials.json").claudeAiOauth.accessToken).toBe("A");
    expect(read(".claude-freeze/.claude.json")).toEqual({ oauthAccount: account("a") });
    expect(() => read(".claude/.credentials.json")).toThrow();
    expect(read(".claude.json")).toEqual({ x: 1 });
    expect(statSync(join(home, ".claude-freeze")).mode & 0o777).toBe(0o700);
  });
});
