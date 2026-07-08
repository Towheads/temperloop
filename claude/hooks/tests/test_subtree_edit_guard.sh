#!/usr/bin/env bash
# Tests for subtree-edit-guard.sh — Guard #1 of the kernel-routing rule
# (foundation #806, epic #763).
#
# Synthetic fixture repo (mktemp, zero network): a git-inited checkout
# carrying a .kernel-pin at its root, a physical kernel/ subtree dir, and a
# compat symlink presenting a kernel file at its pre-split path — the exact
# shape a real post-cutover foundation checkout has. Covers:
#   - direct kernel/... path (existing + new-nested-file)                -> ask
#   - pre-split compat symlink resolving into kernel/ (file- and dir-level) -> ask
#   - non-kernel overlay path                                            -> silent
#   - a repo with NO .kernel-pin (not vendored)                          -> silent (inert)
#   - KERNEL_EDIT_ACK=1 bypass                                           -> silent + stderr note
#   - .build-guard marker bypass                                        -> silent + stderr note
#   - EVAL_RUN set                                                       -> silent
#   - fail-open: malformed input, missing jq                            -> exit 0, no output
set -uo pipefail

HERE=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
HOOK="$HERE/../subtree-edit-guard.sh"
[ -f "$HOOK" ] || { echo "FATAL: hook not found at $HOOK" >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required for this test" >&2; exit 1; }

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
check() { # <desc> <expected: ask|silent> <actual-stdout>
  local desc="$1" want="$2" out="$3" got
  if printf '%s' "$out" | grep -q '"permissionDecision":"ask"'; then got=ask; else got=silent; fi
  if [ "$got" = "$want" ]; then
    pass=$((pass + 1)); printf '  ✓ %s\n' "$desc"
  else
    fail=$((fail + 1)); printf '  ✗ %s (want=%s got=%s)\n     out=%s\n' "$desc" "$want" "$got" "$out"
  fi
}

# run_hook <cwd> <tool> <file_path> [env-assignments...]
# env-assignments: space-separated NAME=VALUE pairs exported for this call only.
run_hook() {
  local cwd="$1" tool="$2" fp="$3"; shift 3
  local json
  json=$(jq -cn --arg t "$tool" --arg fp "$fp" --arg cwd "$cwd" \
    '{tool_name:$t, tool_input:{file_path:$fp}, cwd:$cwd}')
  ( cd "$cwd" && env "$@" bash "$HOOK" <<<"$json" )
}

# --- Build the fixture: a post-cutover-shaped repo ------------------------
REPO="$TMP/repo"
mkdir -p "$REPO"
git init -q --initial-branch=main "$REPO"
echo "pin" >"$REPO/.kernel-pin"
mkdir -p "$REPO/kernel/claude/hooks" "$REPO/claude/hooks" "$REPO/overlay-only"
echo "vendored" >"$REPO/kernel/claude/hooks/board-adapter-guard.sh"
ln -s ../../kernel/claude/hooks/board-adapter-guard.sh "$REPO/claude/hooks/board-adapter-guard.sh"
# Directory-level compat symlink (mirrors claude/agents -> ../kernel/claude/agents).
ln -s kernel/claude/hooks "$REPO/hooks-dirlink"
# The EXACT foundation#1070 / issue #130 shape: a build-scripts dir presented at
# its pre-split path via an UP-AND-BACK relative dir symlink
# (workflows/scripts/build -> ../../kernel/workflows/scripts/build). The raw
# target string carries no `kernel/` component, so a pre-fix raw-string matcher
# stayed silent and let the kernel edit through; only the realpath-resolved
# path lands under kernel/.
mkdir -p "$REPO/kernel/workflows/scripts/build" "$REPO/workflows/scripts"
echo "cron" >"$REPO/kernel/workflows/scripts/build/funnel-cron.sh"
ln -s ../../kernel/workflows/scripts/build "$REPO/workflows/scripts/build"
echo "overlay" >"$REPO/overlay-only/real.txt"
echo "readme" >"$REPO/README.md"
git -C "$REPO" add -A
git -C "$REPO" commit -qm init

# A sibling repo with NO .kernel-pin — must be fully inert.
PLAIN="$TMP/plain"
mkdir -p "$PLAIN"
git init -q --initial-branch=main "$PLAIN"
git -C "$PLAIN" commit -q --allow-empty -m init

REPO_RP="$(cd "$REPO" && pwd -P)"

# --- direct kernel/... path (existing file) -> ask -------------------------
out="$(run_hook "$REPO" Edit "kernel/claude/hooks/board-adapter-guard.sh")"
check "direct kernel/ path (existing file) -> ask" ask "$out"
grep -q "$REPO_RP/kernel/claude/hooks/board-adapter-guard.sh" <<<"$out" \
  || { fail=$((fail + 1)); printf '  ✗ ask reason does not name the resolved path\n'; }

# --- direct kernel/... path (new file, existing parent dir) -> ask --------
out="$(run_hook "$REPO" Write "kernel/claude/hooks/new-file.sh")"
check "direct kernel/ path (new file) -> ask" ask "$out"

# --- direct kernel/... path (new file under a not-yet-existing nested dir) -> ask
out="$(run_hook "$REPO" Write "kernel/claude/hooks/nested/new/deep.sh")"
check "direct kernel/ path (new nested dirs) -> ask" ask "$out"

# --- pre-split compat symlink, FILE-level -> ask ---------------------------
out="$(run_hook "$REPO" Edit "claude/hooks/board-adapter-guard.sh")"
check "compat symlink (file-level) resolving into kernel/ -> ask" ask "$out"
grep -q "$REPO_RP/kernel/claude/hooks/board-adapter-guard.sh" <<<"$out" \
  || { fail=$((fail + 1)); printf '  ✗ ask reason does not name the RESOLVED (not symlink) path\n'; }

# --- pre-split compat symlink, DIRECTORY-level, new file inside -> ask ----
out="$(run_hook "$REPO" Write "hooks-dirlink/another-new.sh")"
check "compat symlink (dir-level) resolving into kernel/ -> ask" ask "$out"

# --- REGRESSION (issue #130 / foundation#1070): build-script edited through the
# `workflows/scripts/build -> ../../kernel/workflows/scripts/build` alias -> ask.
# This is the failure the issue describes: the RAW input path has no `kernel/`
# component, so a raw-string matcher (the pre-fix behavior) would NOT have fired
# and the kernel edit slipped through. The guard resolves the realpath BEFORE
# matching, so it must ask. The `case` below asserts the load-bearing property
# — that the input path genuinely lacks `kernel/`, i.e. only resolution trips it.
alias_target="workflows/scripts/build/funnel-cron.sh"
case "$alias_target" in
  *kernel/*) echo "FATAL: #130 fixture path unexpectedly contains kernel/ — assertion void" >&2; exit 1 ;;
esac
out="$(run_hook "$REPO" Edit "$alias_target")"
check "build-dir alias (../../kernel up-and-back), raw path has no 'kernel/' -> ask [#130]" ask "$out"
grep -q "$REPO_RP/kernel/workflows/scripts/build/funnel-cron.sh" <<<"$out" \
  || { fail=$((fail + 1)); printf '  ✗ #130: ask reason does not name the RESOLVED kernel path\n'; }

# --- MultiEdit shape (edits[].file_path) -> ask ----------------------------
json=$(jq -cn --arg cwd "$REPO" \
  '{tool_name:"MultiEdit", tool_input:{edits:[{file_path:"kernel/claude/hooks/board-adapter-guard.sh"}]}, cwd:$cwd}')
out="$(cd "$REPO" && bash "$HOOK" <<<"$json")"
check "MultiEdit edits[].file_path into kernel/ -> ask" ask "$out"

# --- non-kernel overlay path -> silent -------------------------------------
out="$(run_hook "$REPO" Edit "overlay-only/real.txt")"
check "non-kernel overlay path -> silent" silent "$out"

out="$(run_hook "$REPO" Write "brand-new-overlay-file.txt")"
check "new overlay file (non-kernel) -> silent" silent "$out"

# --- repo with no .kernel-pin -> fully inert --------------------------------
out="$(run_hook "$PLAIN" Write "kernel/whatever.sh")"
check "no .kernel-pin at repo root -> inert/silent" silent "$out"

# --- KERNEL_EDIT_ACK=1 bypass -> silent, but a stderr note is logged -------
err="$TMP/stderr-ack.txt"
out="$( ( cd "$REPO" && KERNEL_EDIT_ACK=1 bash "$HOOK" \
    <<<"$(jq -cn --arg cwd "$REPO" '{tool_name:"Edit", tool_input:{file_path:"kernel/claude/hooks/board-adapter-guard.sh"}, cwd:$cwd}')" \
    2>"$err" ) )"
check "KERNEL_EDIT_ACK=1 bypasses the ask -> silent" silent "$out"
grep -qi "bypass" "$err" || { fail=$((fail + 1)); printf '  ✗ KERNEL_EDIT_ACK bypass produced no stderr note (stderr: %s)\n' "$(cat "$err")"; }
echo "PASS: KERNEL_EDIT_ACK=1 bypasses silently and logs a stderr note"

# --- .build-guard marker bypass -> silent, but a stderr note is logged ----
touch "$REPO/.build-guard"
err2="$TMP/stderr-marker.txt"
out="$( ( cd "$REPO" && bash "$HOOK" \
    <<<"$(jq -cn --arg cwd "$REPO" '{tool_name:"Edit", tool_input:{file_path:"kernel/claude/hooks/board-adapter-guard.sh"}, cwd:$cwd}')" \
    2>"$err2" ) )"
check ".build-guard marker bypasses the ask -> silent" silent "$out"
grep -qi "bypass" "$err2" || { fail=$((fail + 1)); printf '  ✗ .build-guard bypass produced no stderr note (stderr: %s)\n' "$(cat "$err2")"; }
echo "PASS: .build-guard marker bypasses silently and logs a stderr note"
rm -f "$REPO/.build-guard"

# --- EVAL_RUN suppresses the ask (even with no bypass) ----------------------
out="$(run_hook "$REPO" Edit "kernel/claude/hooks/board-adapter-guard.sh" EVAL_RUN=1)"
check "EVAL_RUN=1 suppresses the ask -> silent" silent "$out"

# --- non Edit/Write/MultiEdit tool -> silent --------------------------------
out="$(run_hook "$REPO" Bash "kernel/claude/hooks/board-adapter-guard.sh")"
check "non-Edit/Write/MultiEdit tool_name -> silent" silent "$out"

# --- fail-open: malformed input ---------------------------------------------
out="$(cd "$REPO" && printf 'not json' | bash "$HOOK")"
rc=$?
[ "$rc" -eq 0 ] || { fail=$((fail + 1)); printf '  ✗ malformed input: exit=%s (want 0)\n' "$rc"; }
[ -z "$out" ] || { fail=$((fail + 1)); printf '  ✗ malformed input produced output: %s\n' "$out"; }
echo "PASS: malformed input fails open (exit 0, no output)"

# --- fail-open: jq missing ---------------------------------------------------
# BASH_BIN is invoked by its absolute path (found via the test's own normal
# PATH) so ONLY the hook's internal `command -v jq` sees the jq-less PATH,
# not the lookup of bash itself.
BASH_BIN="$(command -v bash)"
NOJQ_BIN="$TMP/nojq-bin"
mkdir -p "$NOJQ_BIN"
for b in cat git dirname basename readlink mkdir date; do
  bp="$(command -v "$b")"
  [ -n "$bp" ] && ln -sf "$bp" "$NOJQ_BIN/$b"
done
json=$(jq -cn --arg cwd "$REPO" '{tool_name:"Edit", tool_input:{file_path:"kernel/claude/hooks/board-adapter-guard.sh"}, cwd:$cwd}')
out="$(cd "$REPO" && printf '%s' "$json" | PATH="$NOJQ_BIN" "$BASH_BIN" "$HOOK")"
rc=$?
[ "$rc" -eq 0 ] || { fail=$((fail + 1)); printf '  ✗ jq-missing: exit=%s (want 0)\n' "$rc"; }
[ -z "$out" ] || { fail=$((fail + 1)); printf '  ✗ jq-missing produced output: %s\n' "$out"; }
echo "PASS: jq missing fails open (exit 0, no output)"

echo
if [ "$fail" -gt 0 ]; then
  printf 'FAILED %d/%d\n' "$fail" "$((pass + fail))"; exit 1
fi
printf 'OK — all %d subtree-edit-guard checks passed\n' "$pass"
