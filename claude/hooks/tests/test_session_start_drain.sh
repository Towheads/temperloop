#!/usr/bin/env bash
# Tests for claude/hooks/session-start-drain.sh's STUB WRITE TRANSPORT
# (temperloop#732 — the hook used to hand-roll a `curl -X PUT` against the
# Obsidian Local REST API; the write now goes through the knowledge_store
# seam's `ks_write`, so the drain works on a stranger's plain-files install
# with no Obsidian vault and no REST plugin anywhere).
#
# Every case builds a throwaway "fresh install" fixture tree —
#   <fixture>/claude/hooks/{session-start-drain.sh,eval-guard.sh}
#   <fixture>/workflows/scripts/lib/{knowledge_store.sh,knowledge_store_obsidian.sh}
# — mirroring the two-directories-up layout workflows/scripts/install/links.sh
# produces. Unlike test_lib_path_resolution.sh (which stubs the libs to prove
# WHICH lib dir was reached), this suite copies the REAL libs in, so the
# assertions are about the drain's observable outcome: where the document
# landed, and whether the local stub was removed.
#
# $HOME is a throwaway sandbox for every case, and KNOWLEDGE_STORE_ROOT is
# pinned into the temp tree — no network, no Obsidian, no operator vault.
#
# Covers:
#   1. plain-files backend: a stub under $HOME/dev/<proj>/.mind/ is written to
#      <root>/Sessions/_inbox/<filename>.md verbatim and the stub is deleted.
#   2. The session-id additionalContext JSON is still emitted on stdout.
#   3. Store-root exclusion: a .mind/ stub sitting INSIDE the store root is
#      pruned from the search and never drained back into the store.
#   4. A failing write leaves the stub in place and logs the failure (never a
#      silent delete).
#   5. Structural regression guard: the hook issues no raw curl request and
#      names no Obsidian REST endpoint of its own.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS_DIR="$(cd "$HERE/.." && pwd)"
REPO_ROOT="$(cd "$HOOKS_DIR/../.." && pwd)"
LIB_SRC="$REPO_ROOT/workflows/scripts/lib"
HOOK_SRC="$HOOKS_DIR/session-start-drain.sh"
command -v jq >/dev/null 2>&1 || { echo "FATAL: jq required for this test" >&2; exit 1; }

TMP="$(mktemp -d "${TMPDIR:-/tmp}/test-session-start-drain-XXXXXX")"
trap 'rm -rf "$TMP"' EXIT

pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  \xe2\x9c\x93 %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  \xe2\x9c\x97 %s\n' "$1"; }

STUB_NAME="2026-01-02-030405-demo-abcd1234.md"
STUB_BODY=$'# session stub\n\nfirst user line: drain me\n'

# make_fixture <dir> — fresh-install-shaped fixture carrying the REAL hook and
# the REAL knowledge_store libs.
make_fixture() {
  local dir="$1"
  mkdir -p "$dir/claude/hooks" "$dir/workflows/scripts/lib"
  cp "$HOOK_SRC" "$HOOKS_DIR/eval-guard.sh" "$dir/claude/hooks/"
  cp "$LIB_SRC/knowledge_store.sh" "$LIB_SRC/knowledge_store_obsidian.sh" \
     "$dir/workflows/scripts/lib/"
  chmod +x "$dir/claude/hooks/"*.sh
}

# run_hook <fixture-dir> <sandbox-home> <store-root> -> stdout on fd1
run_hook() {
  local dir="$1" home="$2" root="$3"
  printf '{"session_id":"deadbeef-1111-2222-3333-444455556666"}' \
    | env HOME="$home" \
          XDG_STATE_HOME="$home/.state" \
          XDG_CONFIG_HOME="$home/.config" \
          XDG_DATA_HOME="$home/.data" \
          KS_LIB_DIR= \
          KNOWLEDGE_STORE_ROOT="$root" \
      bash "$dir/claude/hooks/session-start-drain.sh" 2>"$TMP/stderr.last"
}

# ---------------------------------------------------------------------------
# 1 & 2. plain-files drain: document written under the store root, stub gone,
#        session-id still emitted.
# ---------------------------------------------------------------------------
FIX1="$TMP/fixture1"; make_fixture "$FIX1"
HOME1="$TMP/home1"; ROOT1="$TMP/store1"
mkdir -p "$HOME1/dev/demo/.mind"
printf '%s' "$STUB_BODY" > "$TMP/expected-stub"
cp "$TMP/expected-stub" "$HOME1/dev/demo/.mind/$STUB_NAME"

OUT1="$(run_hook "$FIX1" "$HOME1" "$ROOT1")"; rc=$?
DEST1="$ROOT1/Sessions/_inbox/$STUB_NAME"

if [ "$rc" -eq 0 ] && [ -f "$DEST1" ] \
   && cmp -s "$DEST1" "$TMP/expected-stub" \
   && [ ! -e "$HOME1/dev/demo/.mind/$STUB_NAME" ]; then
  ok "plain-files backend: stub written to <root>/Sessions/_inbox/ verbatim and the local stub removed"
else
  bad "plain-files drain failed (rc=$rc, dest-exists=$([ -f "$DEST1" ] && echo yes || echo no), content-match=$(cmp -s "$DEST1" "$TMP/expected-stub" && echo yes || echo no), stub-exists=$([ -e "$HOME1/dev/demo/.mind/$STUB_NAME" ] && echo yes || echo no))"
fi

if printf '%s' "$OUT1" | jq -e '.hookSpecificOutput.additionalContext == "<session-id>deadbeef</session-id>"' >/dev/null 2>&1; then
  ok "session-id additionalContext JSON still emitted on stdout (unchanged by the transport swap)"
else
  bad "session-id additionalContext missing or malformed: $OUT1"
fi

# ---------------------------------------------------------------------------
# 3. Store-root exclusion: a .mind/ stub inside the store root is pruned.
# ---------------------------------------------------------------------------
FIX2="$TMP/fixture2"; make_fixture "$FIX2"
HOME2="$TMP/home2"; ROOT2="$HOME2/dev/store-vault"
mkdir -p "$ROOT2/.mind" "$HOME2/dev/demo/.mind"
printf 'inside the store\n' > "$ROOT2/.mind/inside.md"
printf '%s' "$STUB_BODY" > "$HOME2/dev/demo/.mind/$STUB_NAME"

run_hook "$FIX2" "$HOME2" "$ROOT2" >/dev/null; rc=$?

if [ "$rc" -eq 0 ] && [ -f "$ROOT2/.mind/inside.md" ] \
   && [ ! -e "$ROOT2/Sessions/_inbox/inside.md" ] \
   && [ -f "$ROOT2/Sessions/_inbox/$STUB_NAME" ]; then
  ok "store root is pruned from the stub search — a .mind/ file inside the store is not drained into it"
else
  bad "store-root prune failed (rc=$rc, inside-kept=$([ -f "$ROOT2/.mind/inside.md" ] && echo yes || echo no), inside-drained=$([ -e "$ROOT2/Sessions/_inbox/inside.md" ] && echo yes || echo no), outside-drained=$([ -f "$ROOT2/Sessions/_inbox/$STUB_NAME" ] && echo yes || echo no))"
fi

# ---------------------------------------------------------------------------
# 4. Failing write: stub survives, failure is logged, hook still exits 0.
# ---------------------------------------------------------------------------
FIX3="$TMP/fixture3"; make_fixture "$FIX3"
HOME3="$TMP/home3"
mkdir -p "$HOME3/dev/demo/.mind"
printf '%s' "$STUB_BODY" > "$HOME3/dev/demo/.mind/$STUB_NAME"
# A store root whose PARENT is a regular file: mkdir -p can never succeed, so
# the plain-files write returns non-zero without any network involvement.
printf 'not a directory\n' > "$TMP/blocker"
ROOT3="$TMP/blocker/store"

run_hook "$FIX3" "$HOME3" "$ROOT3" >/dev/null; rc=$?
LOG3="$HOME3/.state/foundation/session-start-drain.log"

if [ "$rc" -eq 0 ] && [ -f "$HOME3/dev/demo/.mind/$STUB_NAME" ] \
   && grep -q "FAILED \[ks_write rc=" "$LOG3" 2>/dev/null; then
  ok "a failing ks_write leaves the stub in place, logs FAILED with the rc, and never blocks session start"
else
  bad "failure path wrong (rc=$rc, stub-kept=$([ -f "$HOME3/dev/demo/.mind/$STUB_NAME" ] && echo yes || echo no), log=$(cat "$LOG3" 2>/dev/null))"
fi

# ---------------------------------------------------------------------------
# 5. Structural guard: no raw curl / REST endpoint left in the hook itself.
# ---------------------------------------------------------------------------
if ! grep -qE '^[^#]*\bcurl\b' "$HOOK_SRC" \
   && ! grep -qE '^[^#]*/vault/' "$HOOK_SRC"; then
  ok "hook carries no raw curl call and no Obsidian /vault/ endpoint of its own"
else
  bad "hook still contains a raw curl / REST endpoint: $(grep -nE '^[^#]*(\bcurl\b|/vault/)' "$HOOK_SRC")"
fi

echo
echo "test_session_start_drain.sh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
