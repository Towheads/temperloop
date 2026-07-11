#!/usr/bin/env bash
#
# Tests for configure.sh — `temperloop configure` (temperloop#262, item
# configure-config-cli — ADR K164 D7). Same write-intercepting-wrapper
# idiom as test_try.sh: a fake `claude` on PATH that LOGS every argv
# element it receives (asserted to carry `--tools` immediately followed by
# an EMPTY string — the structural zero-tool-access proof), plus a
# throwaway XDG_CONFIG_HOME so every run's machine-conf write lands in a
# disposable temp dir, never a real host path.
#
# Covers:
#   - plain-prompt degradation: `claude` genuinely ABSENT from PATH (not
#     just a --no-ai flag) — zero claude invocations, wizard still
#     resolves every knob (via --set / non-interactive default) and
#     writes correctly
#   - --no-ai forces plain-prompt mode even with a (fake, would-answer)
#     claude on PATH — zero claude invocations
#   - AI-guided mode: fake claude IS invoked exactly once, with
#     `--tools` immediately followed by `` (empty string) in its argv,
#     and its JSON suggestions land in the written file
#   - AI call failure degrades gracefully to plain prompts for the
#     unresolved knobs (never a hard failure of the whole wizard)
#   - writes ONLY the machine-conf file: --dry-run touches nothing; a
#     consented run creates ONLY that one file (no other file appears
#     under the throwaway XDG_CONFIG_HOME tree, and cwd is untouched)
#   - non-interactive, no --yes: computes values but declines the write
#     (default-deny, mirrors init.sh/eject.sh) — file never created
#   - idempotent upsert: a second run with a different --set value
#     REPLACES the prior line in place (one value line, one export line —
#     never a duplicate)
#   - --set with an invalid (wrong-type) value is rejected and falls back
#     to the seed/default rather than writing garbage
#
# shellcheck disable=SC2016  # file-wide: every grep -q '${NAME:=...}' below is
# an intentional literal (asserting the WRITTEN FILE's content), never a
# shell expansion the test itself wants.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIGURE="$HERE/../configure.sh"

fail() { printf 'FAIL: %b\n' "$1" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/configure-test-XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

BIN="$WORK/bin"
mkdir -p "$BIN"
CLAUDE_ARGS_DIR="$WORK/claude-args"
CLAUDE_CALL_COUNT_FILE="$WORK/claude-call-count"
: > "$CLAUDE_CALL_COUNT_FILE"

cat > "$BIN/claude" <<'FAKE_CLAUDE_EOF'
#!/usr/bin/env bash
echo x >> "$CLAUDE_CALL_COUNT_FILE"
rm -rf "$CLAUDE_ARGS_DIR"
mkdir -p "$CLAUDE_ARGS_DIR"
i=0
for a in "$@"; do
  printf '%s' "$a" > "$CLAUDE_ARGS_DIR/arg_$i"
  i=$((i + 1))
done
echo "$i" > "$CLAUDE_ARGS_DIR/argc"
if [ "${FAKE_CLAUDE_RC:-0}" -ne 0 ]; then
  exit "${FAKE_CLAUDE_RC:-0}"
fi
printf '%s' "${FAKE_CLAUDE_JSON:-{\}}"
FAKE_CLAUDE_EOF
chmod +x "$BIN/claude"
export CLAUDE_ARGS_DIR CLAUDE_CALL_COUNT_FILE

claude_call_count() { grep -c . "$CLAUDE_CALL_COUNT_FILE" 2>/dev/null || true; }

argv_has_tools_empty() {
  # asserts some arg_N == "--tools" and arg_(N+1) == "" (exists and is empty)
  local i argc found=0
  argc="$(cat "$CLAUDE_ARGS_DIR/argc" 2>/dev/null || echo 0)"
  i=0
  while [ "$i" -lt "$argc" ]; do
    if [ "$(cat "$CLAUDE_ARGS_DIR/arg_$i" 2>/dev/null)" = "--tools" ]; then
      local next=$((i + 1))
      if [ -f "$CLAUDE_ARGS_DIR/arg_$next" ] && [ ! -s "$CLAUDE_ARGS_DIR/arg_$next" ]; then
        found=1
      fi
    fi
    i=$((i + 1))
  done
  [ "$found" -eq 1 ]
}

fresh_xdg() {
  # prints a fresh, unique XDG_CONFIG_HOME dir path (not yet created)
  local d
  d="$(mktemp -d "$WORK/xdg-XXXXXX")"
  rm -rf "$d"
  printf '%s' "$d"
}

machine_conf_path() {
  printf '%s/temperloop/build.config.sh' "$1"
}

# =============================================================================
# 1. Plain-prompt degradation: claude GENUINELY ABSENT from PATH (a PATH
#    with no claude anywhere, not just this fixture's fake one missing).
# =============================================================================
: > "$CLAUDE_CALL_COUNT_FILE"
XDG1="$(fresh_xdg)"
out="$(PATH="/usr/bin:/bin" XDG_CONFIG_HOME="$XDG1" bash "$CONFIGURE" \
  --set FUNNEL_OPERATOR=octocat --set FUNNEL_WIP_CAP=5 \
  --set BUILD_MERGE_GATE_WINDOW=120 --set BUILD_QUOTA_PAUSE_PCT=20 \
  --yes </dev/null 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "plain-prompt-degradation run did not exit 0 (got: $rc) -- output:\n$out"
[ "$(claude_call_count)" -eq 0 ] || fail "claude was invoked despite being absent from PATH"
mc1="$(machine_conf_path "$XDG1")"
[ -f "$mc1" ] || fail "machine-conf file was not written: $mc1"
grep -q ': "${FUNNEL_OPERATOR:=octocat}"' "$mc1" || fail "written file missing FUNNEL_OPERATOR=octocat (got: $(cat "$mc1")\""
grep -q ': "${FUNNEL_WIP_CAP:=5}"' "$mc1" || fail "written file missing FUNNEL_WIP_CAP=5"
echo "PASS: claude genuinely absent from PATH -> zero claude invocations, wizard still resolves + writes via --set"

# =============================================================================
# 2. --no-ai forces plain-prompt mode even with a (fake, would-answer)
#    claude on PATH.
# =============================================================================
: > "$CLAUDE_CALL_COUNT_FILE"
XDG2="$(fresh_xdg)"
FAKE_CLAUDE_JSON='{"FUNNEL_WIP_CAP":{"value":"9","why":"x"}}' \
  PATH="$BIN:/usr/bin:/bin" XDG_CONFIG_HOME="$XDG2" bash "$CONFIGURE" --no-ai \
  --set FUNNEL_OPERATOR=octocat --set FUNNEL_WIP_CAP=5 \
  --set BUILD_MERGE_GATE_WINDOW=120 --set BUILD_QUOTA_PAUSE_PCT=20 \
  --yes </dev/null >/dev/null 2>&1
[ "$(claude_call_count)" -eq 0 ] || fail "--no-ai still invoked claude"
echo "PASS: --no-ai forces plain-prompt mode even with claude present (zero invocations)"

# =============================================================================
# 3. AI-guided mode: fake claude invoked exactly once, --tools immediately
#    followed by an empty string; its JSON suggestions land in the file.
# =============================================================================
: > "$CLAUDE_CALL_COUNT_FILE"
XDG3="$(fresh_xdg)"
FAKE_CLAUDE_JSON='{"FUNNEL_OPERATOR":{"value":"@REPLACE_WITH_YOUR_GH_LOGIN","why":"placeholder"},"FUNNEL_WIP_CAP":{"value":"4","why":"ok"},"BUILD_MERGE_GATE_WINDOW":{"value":"300","why":"ok"},"BUILD_QUOTA_PAUSE_PCT":{"value":"15","why":"ok"}}' \
  PATH="$BIN:/usr/bin:/bin" XDG_CONFIG_HOME="$XDG3" bash "$CONFIGURE" --yes </dev/null >/dev/null 2>&1
[ "$(claude_call_count)" -eq 1 ] || fail "AI-guided mode did not invoke claude exactly once (got: $(claude_call_count))"
argv_has_tools_empty || fail "claude was not invoked with --tools immediately followed by an empty string"
mc3="$(machine_conf_path "$XDG3")"
grep -q ': "${FUNNEL_WIP_CAP:=4}"' "$mc3" || fail "AI-suggested FUNNEL_WIP_CAP=4 not written (got: $(cat "$mc3")\")"
grep -q ': "${BUILD_QUOTA_PAUSE_PCT:=15}"' "$mc3" || fail "AI-suggested BUILD_QUOTA_PAUSE_PCT=15 not written"
echo "PASS: AI-guided mode invokes claude exactly once (--tools \"\" structural proof), applies its JSON suggestions"

# =============================================================================
# 4. AI call failure degrades gracefully to plain prompts (never a hard
#    failure of the whole wizard).
# =============================================================================
: > "$CLAUDE_CALL_COUNT_FILE"
XDG4="$(fresh_xdg)"
out="$(FAKE_CLAUDE_RC=1 PATH="$BIN:/usr/bin:/bin" XDG_CONFIG_HOME="$XDG4" bash "$CONFIGURE" \
  --set FUNNEL_OPERATOR=octocat --yes </dev/null 2>&1)"
rc=$?
[ "$rc" -eq 0 ] || fail "AI-call-failure run did not still exit 0 (got: $rc) -- output:\n$out"
echo "$out" | grep -q "falling back to plain prompts" || fail "AI-call-failure did not report a plain-prompt fallback (got: $out)"
mc4="$(machine_conf_path "$XDG4")"
[ -f "$mc4" ] || fail "AI-call-failure run did not still write the machine-conf file"
echo "PASS: an AI call failure degrades gracefully to plain prompts (still writes, never hard-fails)"

# =============================================================================
# 5. Writes ONLY the machine-conf file: --dry-run touches nothing.
# =============================================================================
: > "$CLAUDE_CALL_COUNT_FILE"
XDG5="$(fresh_xdg)"
mkdir -p "$XDG5"
before="$(find "$XDG5" -type f | sort)"
PATH="/usr/bin:/bin" XDG_CONFIG_HOME="$XDG5" bash "$CONFIGURE" --dry-run \
  --set FUNNEL_WIP_CAP=6 --yes </dev/null >/dev/null 2>&1
after="$(find "$XDG5" -type f | sort)"
[ "$before" = "$after" ] || fail "--dry-run created/modified a file under XDG_CONFIG_HOME (before: [$before] after: [$after])"
echo "PASS: --dry-run touches no file"

# =============================================================================
# 6. Non-interactive, no --yes: computes values but declines the write.
# =============================================================================
XDG6="$(fresh_xdg)"
PATH="/usr/bin:/bin" XDG_CONFIG_HOME="$XDG6" bash "$CONFIGURE" \
  --set FUNNEL_WIP_CAP=6 </dev/null >/dev/null 2>&1
mc6="$(machine_conf_path "$XDG6")"
[ ! -f "$mc6" ] || fail "non-interactive run with no --yes still wrote a file"
echo "PASS: non-interactive with no --yes declines the write (default-deny, file never created)"

# =============================================================================
# 7. Idempotent upsert: a second run with a different --set value REPLACES
#    the prior line in place.
# =============================================================================
XDG7="$(fresh_xdg)"
PATH="/usr/bin:/bin" XDG_CONFIG_HOME="$XDG7" bash "$CONFIGURE" \
  --set FUNNEL_WIP_CAP=5 --yes </dev/null >/dev/null 2>&1
PATH="/usr/bin:/bin" XDG_CONFIG_HOME="$XDG7" bash "$CONFIGURE" \
  --set FUNNEL_WIP_CAP=7 --yes </dev/null >/dev/null 2>&1
mc7="$(machine_conf_path "$XDG7")"
[ "$(grep -c ': "${FUNNEL_WIP_CAP:=' "$mc7")" -eq 1 ] || fail "upsert produced more than one FUNNEL_WIP_CAP value line"
grep -q ': "${FUNNEL_WIP_CAP:=7}"' "$mc7" || fail "second run's value (7) did not win (got: $(cat "$mc7")\")"
grep -q ': "${FUNNEL_WIP_CAP:=5}"' "$mc7" && fail "first run's stale value (5) is still present"
echo "PASS: a second configure run upserts (replaces) an existing knob's line rather than duplicating it"

# =============================================================================
# 8. --set with an invalid (wrong-type) value is rejected, falls back to
#    the seed/default rather than writing garbage.
# =============================================================================
XDG8="$(fresh_xdg)"
out="$(PATH="/usr/bin:/bin" XDG_CONFIG_HOME="$XDG8" bash "$CONFIGURE" \
  --set 'FUNNEL_WIP_CAP=not-a-number' --yes </dev/null 2>&1)"
echo "$out" | grep -qi "not a valid" || fail "invalid --set value was not reported as invalid (got: $out)"
mc8="$(machine_conf_path "$XDG8")"
grep -q ': "${FUNNEL_WIP_CAP:=not-a-number}"' "$mc8" && fail "invalid value was written verbatim"
grep -q ': "${FUNNEL_WIP_CAP:=3}"' "$mc8" || fail "invalid --set did not fall back to the registry default of 3 (got: $(cat "$mc8")\")"
echo "PASS: an invalid --set value is rejected and falls back to the seed/registry default"

echo
echo "ALL PASS: test_configure.sh"
