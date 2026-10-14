#!/usr/bin/env bash
# scripts/claude-swap in a throwaway HOME with a fake pgrep (exit 1 = no claude running).
set -eo pipefail

SCRIPT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/claude-swap"
passed=0
failed=0

cred() { printf '{"claudeAiOauth":{"accessToken":"%s","refreshToken":"r-%s","expiresAt":1}}' "$1" "$1"; }
account() { printf '{"accountUuid":"%s","emailAddress":"%s@x.dev"}' "$1" "$1"; }

stub_pgrep() {
  printf '#!/bin/sh\nexit %s\n' "$1" >"$H/bin/pgrep"
  chmod +x "$H/bin/pgrep"
}

setup() {
  H="$(mktemp -d)"
  mkdir -p "$H/bin" "$H/.claude" "$H/.claude-freeze"
  (umask 077; cred A >"$H/.claude/.credentials.json"; cred B >"$H/.claude-freeze/.credentials.json")
  printf '{"oauthAccount":%s,"mcpServers":{"m":1}}' "$(account a)" >"$H/.claude.json"
  printf '{"oauthAccount":%s}' "$(account b)" >"$H/.claude-freeze/.claude.json"
  stub_pgrep 1
}

run_swap() {
  env -i HOME="$H" PATH="$H/bin:/usr/bin:/bin" timeout 20 bash "$SCRIPT" "$@" >"$H/out" 2>"$H/err"
}

field() { jq -c "$2" "$H/$1"; }
mode() { stat -c %a "$H/$1"; }

check() {
  local name="$1"
  shift
  if "$@"; then
    passed=$((passed + 1))
    echo "  ok $name"
  else
    failed=$((failed + 1))
    echo "  FAIL $name"
  fi
  [[ -n "$H" ]] && rm -rf "$H"
  H=""
}

t_swap() {
  setup
  run_swap || return 1
  [[ $(field .claude/.credentials.json .claudeAiOauth.accessToken) == '"B"' ]] &&
    [[ $(field .claude-freeze/.credentials.json .claudeAiOauth.accessToken) == '"A"' ]] &&
    [[ $(field .claude.json .) == '{"oauthAccount":{"accountUuid":"b","emailAddress":"b@x.dev"},"mcpServers":{"m":1}}' ]] &&
    [[ $(field .claude-freeze/.claude.json .) == '{"oauthAccount":{"accountUuid":"a","emailAddress":"a@x.dev"}}' ]] &&
    grep -q 'b@x.dev' "$H/out" && ! grep -q 'r-A' "$H/out"
}

t_swap_back() {
  setup
  run_swap && run_swap || return 1
  [[ $(field .claude/.credentials.json .claudeAiOauth.accessToken) == '"A"' ]] &&
    [[ $(field .claude.json .oauthAccount.accountUuid) == '"a"' ]]
}

t_private() {
  setup
  run_swap || return 1
  [[ $(mode .claude/.credentials.json) == 600 ]] &&
    [[ $(mode .claude-freeze/.credentials.json) == 600 ]] &&
    [[ $(mode .claude-freeze/.claude.json) == 600 ]]
}

t_running() {
  setup
  stub_pgrep 0
  run_swap && return 1
  grep -q claude "$H/err" &&
    [[ $(field .claude/.credentials.json .claudeAiOauth.accessToken) == '"A"' ]] &&
    [[ $(field .claude.json .oauthAccount.accountUuid) == '"a"' ]]
}

t_incomplete() {
  setup
  echo '{}' >"$H/.claude-freeze/.claude.json"
  run_swap && return 1
  [[ $(field .claude/.credentials.json .claudeAiOauth.accessToken) == '"A"' ]]
}

t_status() {
  setup
  run_swap status || return 1
  grep -q 'a@x.dev' "$H/out" && grep -q 'b@x.dev' "$H/out" &&
    [[ $(field .claude/.credentials.json .claudeAiOauth.accessToken) == '"A"' ]]
}

t_init() {
  H="$(mktemp -d)"
  mkdir -p "$H/bin" "$H/.claude"
  (umask 077; cred A >"$H/.claude/.credentials.json")
  printf '{"oauthAccount":%s,"x":1}' "$(account a)" >"$H/.claude.json"
  stub_pgrep 1
  run_swap init || return 1
  [[ $(field .claude-freeze/.credentials.json .claudeAiOauth.accessToken) == '"A"' ]] &&
    [[ $(field .claude-freeze/.claude.json .) == '{"oauthAccount":{"accountUuid":"a","emailAddress":"a@x.dev"}}' ]] &&
    [[ ! -e "$H/.claude/.credentials.json" ]] &&
    [[ $(field .claude.json .) == '{"x":1}' ]] &&
    [[ $(mode .claude-freeze) == 700 ]]
}

echo "claude-swap"
check "swaps logins and accounts, keeping the rest of .claude.json" t_swap
check "swaps back to the original state" t_swap_back
check "keeps the credential files private" t_private
check "refuses while claude is running and changes nothing" t_running
check "refuses when the frozen account is incomplete" t_incomplete
check "prints both accounts with status and changes nothing" t_status
check "freezes the current login into an empty freeze dir with init" t_init
echo "claude-swap: $passed passed, $failed failed"
((failed == 0))
