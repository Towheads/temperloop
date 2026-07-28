#!/usr/bin/env bash
# Tests for claude/status-line.sh's token_sum.sh resolution (temperloop#828,
# epic #810 "realized-session-context probe").
#
# WHY THIS SUITE EXISTS — the INSTALL SHAPE is the blind spot. The sibling
# suites (test_token_sum.sh, test_emit_session_context.sh) all invoke through
# real checkout paths, where a BASH_SOURCE-relative climb trivially resolves.
# The production status line does not run from a checkout path:
# workflows/scripts/install/links.sh symlinks `claude/*` PER FILE, so the
# installed status line is a FILE symlink living in the REAL directory
# ~/.claude. A bare `dirname "${BASH_SOURCE[0]}"` there yields ~/.claude and
# the "../workflows/scripts/lib" climb escapes to $HOME/workflows/scripts/lib
# — nonexistent — silently pinning the displayed "Tokens:" figure at 0 for
# every installed user while the recorded figure stayed correct. That is the
# exact inversion of this feature's contract (the displayed and recorded
# numbers "cannot drift apart"), and 47 green checks missed it because none
# of them invoked through a file symlink outside the repo.
#
# NOTE this is NOT the shape claude/hooks/*.sh have: hooks are installed as a
# whole-DIRECTORY symlink, so the OS resolves the symlinked dir before
# applying "..", and their identical-looking climb lands in the real
# checkout. Adding `cd -P` does not fix the file-symlink case either — the
# escape happens at the symlink, which -P never sees. Hence the explicit
# symlink-chain walk this suite pins.
#
# Coverage:
#   - direct-from-checkout invocation sums correctly (the baseline)
#   - REGRESSION: invocation through a per-file symlink in a NON-REPO dir
#     produces the SAME number, not 0
#   - TOKEN_SUM_LIB_DIR override wins over the relative climb
#   - a genuinely unreachable helper renders "Tokens: --", never "Tokens: 0"
#   - a genuine zero-token transcript still renders "Tokens: 0", so an
#     unknown and a real zero stay distinguishable
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
SCRIPT="$REPO/claude/status-line.sh"
[ -f "$SCRIPT" ] || { echo "FATAL: status-line.sh not found at $SCRIPT" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required for this test" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
check() { # <desc> <expected> <actual>
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    pass=$((pass + 1)); printf '  ✓ %s\n' "$desc"
  else
    fail=$((fail + 1)); printf '  ✗ %s\n     expected: %s\n     actual:   %s\n' "$desc" "$expected" "$actual"
  fi
}

# A synthetic transcript: 1000 + 2000 + 50000 + 700 = 53700 tokens -> "54k".
TRANSCRIPT="$TMP/transcript.jsonl"
jq -cn '{type:"assistant", message:{role:"assistant", usage:{
  input_tokens:1000, cache_creation_input_tokens:2000,
  cache_read_input_tokens:50000, output_tokens:700}}}' > "$TRANSCRIPT"
EXPECTED_TOKENS="54k"

# An empty-usage transcript: a GENUINE zero-token session.
ZERO_TRANSCRIPT="$TMP/zero.jsonl"
jq -cn '{type:"assistant", message:{role:"assistant", usage:{}}}' > "$ZERO_TRANSCRIPT"

stdin_for() { # <transcript-path>
  jq -cn --arg t "$1" '{cwd:"/tmp", model:{display_name:"TestModel"},
    transcript_path:$t,
    context_window:{remaining_percentage:80, context_window_size:200000}}'
}

# Run the status line and extract just the rendered "Tokens: X" value.
tokens_of() { # <script-path> <transcript-path> [env assignments via caller]
  local script="$1" transcript="$2"
  stdin_for "$transcript" \
    | HOME="$FAKE_HOME" bash "$script" 2>/dev/null \
    | sed -e 's/\x1b\[[0-9;]*m//g' -e 's/.*Tokens: //'
}

FAKE_HOME="$TMP/fakehome"
mkdir -p "$FAKE_HOME/.claude"

echo "status-line.sh token_sum resolution:"

# --- 1. Baseline: invoked directly from the checkout ------------------------
DIRECT=$(tokens_of "$SCRIPT" "$TRANSCRIPT")
check "direct from checkout: sums the transcript" "$EXPECTED_TOKENS" "$DIRECT"

# --- 2. THE REGRESSION: a PER-FILE symlink in a real, NON-REPO directory ----
# This mirrors links.sh's installed shape exactly: ~/.claude is a real dir,
# and status-line.sh inside it is a symlink pointing back at the checkout.
LINKED="$FAKE_HOME/.claude/status-line.sh"
ln -s "$SCRIPT" "$LINKED"
LINKED_OUT=$(tokens_of "$LINKED" "$TRANSCRIPT")
check "installed file symlink (non-repo dir): sums the transcript, not 0" \
  "$EXPECTED_TOKENS" "$LINKED_OUT"
check "installed file symlink: agrees with the direct invocation (no drift)" \
  "$DIRECT" "$LINKED_OUT"

# A two-hop symlink chain (a RELATIVE link to a link) must also resolve —
# the relative hop is what a naive `readlink` walk gets wrong.
mkdir -p "$FAKE_HOME/hop"
ln -s "$SCRIPT" "$FAKE_HOME/hop/status-line.sh"
ln -s "../hop/status-line.sh" "$FAKE_HOME/.claude/status-line-2hop.sh"
HOP_OUT=$(tokens_of "$FAKE_HOME/.claude/status-line-2hop.sh" "$TRANSCRIPT")
check "multi-hop relative symlink chain: still resolves" "$EXPECTED_TOKENS" "$HOP_OUT"

# --- 3. TOKEN_SUM_LIB_DIR override wins -------------------------------------
# Point it at the real lib from a copy that could never climb to it.
mkdir -p "$TMP/isolated/claude"
cp "$SCRIPT" "$TMP/isolated/claude/status-line.sh"
OVERRIDE_OUT=$(stdin_for "$TRANSCRIPT" \
  | HOME="$FAKE_HOME" TOKEN_SUM_LIB_DIR="$REPO/workflows/scripts/lib" \
    bash "$TMP/isolated/claude/status-line.sh" 2>/dev/null \
  | sed -e 's/\x1b\[[0-9;]*m//g' -e 's/.*Tokens: //')
check "TOKEN_SUM_LIB_DIR override: resolves where the relative climb cannot" \
  "$EXPECTED_TOKENS" "$OVERRIDE_OUT"

# --- 4. Unreachable helper renders "--", never a plausible "0" --------------
# Same isolated copy, no override: nothing to climb to, nothing to source.
UNREACHABLE=$(tokens_of "$TMP/isolated/claude/status-line.sh" "$TRANSCRIPT")
check "unreachable helper: renders '--' (announces itself), never '0'" \
  "--" "$UNREACHABLE"

# --- 5. A genuine zero still renders 0 --------------------------------------
# The '--' marker above is only useful if a REAL zero remains distinguishable.
REAL_ZERO=$(tokens_of "$SCRIPT" "$ZERO_TRANSCRIPT")
check "genuine zero-token transcript: still renders '0', distinct from '--'" \
  "0" "$REAL_ZERO"

echo
if [ "$fail" -gt 0 ]; then
  printf 'FAILED %d/%d\n' "$fail" "$((pass + fail))"; exit 1
fi
printf 'OK — all %d status-line token-resolution checks passed\n' "$pass"
