#!/usr/bin/env bash
#
# test_dispatch_rename.sh — pins the POST-WINDOW state of the foundation ->
# temperloop rename (foundation #893; windowed by temperloop#165, window
# closed in v0.19.0).
#
# Through the window this file asserted DISPATCH PARITY: kernel/bin/foundation
# was a thin shim that execed kernel/bin/temperloop, so both entrypoints
# behaved identically for every existing `foundation <sub>` caller. That
# parity is deliberately GONE. What is asserted now is the removal itself:
#
#   - `temperloop` is the sole working entrypoint and still dispatches.
#   - `foundation` is a tombstone: it refuses, legibly, on EVERY invocation
#     — non-zero exit, a message naming `temperloop` and the removal version
#     — and it NEVER forwards to a subcommand.
#
# The env seam that used to simulate the post-window state is gone with the
# window itself: the refusal below is the real, shipped behavior, exercised
# directly rather than staged.
#
# Zero network: help/version/unknown-subcommand all short-circuit before the
# claude/gh prereq check, so no fake binaries are needed for those; the final
# case drives a real installed subcommand (eject, a zero-write, zero-network
# dry-run) with a fake claude + gh on PATH (mirrors test_report_offer.sh's
# convention) to prove the shim refuses even a live subcommand dispatch.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HERE/../.."
TEMPERLOOP="$BIN_DIR/temperloop"
FOUNDATION="$BIN_DIR/foundation"

fail() { printf 'FAIL: %b\n' "$1" >&2; exit 1; }

[ -x "$TEMPERLOOP" ] || fail "kernel/bin/temperloop must exist and be executable (the sole entrypoint)"

# --- T0: the tombstone is still SHIPPED ----------------------------------
# Deliberately not deleted: a pre-v0.19.0 install left a
# ~/.local/bin/foundation symlink pointing here, and `temperloop update`
# moves the checkout underneath it. Deleting the file would turn that symlink
# into a dangling "no such file or directory" — an opaque failure exactly
# where the operator needs to be told the name changed.
[ -x "$FOUNDATION" ] || fail "kernel/bin/foundation must still exist and be executable (legible tombstone for an already-installed symlink)"

# It must NOT forward any more, and must stay small (a refusal, not a
# re-implementation and not a resurrected shim).
! grep -q 'exec .*temperloop' "$FOUNDATION" \
  || fail "kernel/bin/foundation must NOT exec temperloop any more (the compat window closed in v0.19.0)"
lines="$(wc -l < "$FOUNDATION" | tr -d ' ')"
[ "$lines" -le 30 ] || fail "kernel/bin/foundation should stay a bare refusal (got $lines lines)"
echo "PASS: kernel/bin/foundation ships as a non-forwarding tombstone ($lines lines)"

# --- T1: the tombstone refuses legibly, on every invocation shape ---------
# No env seam sets this up — this IS the shipped behavior now.
for args in "--version" "help" "eject" "not-a-real-subcommand"; do
  rc=0; out="$("$FOUNDATION" "$args" 2>&1)" || rc=$?
  [ "$rc" -ne 0 ] || fail "'foundation $args' must exit non-zero (got 0, output: $out)"
  case "$out" in *temperloop*) ;; *) fail "'foundation $args' refusal must name 'temperloop' (got: $out)" ;; esac
  case "$out" in *v0.19.0*) ;; *) fail "'foundation $args' refusal must name the removal version v0.19.0 (got: $out)" ;; esac
  # The through-the-window deprecation NOTE is gone: a refusal, not a warning.
  case "$out" in *NOTE*) fail "'foundation $args' must not print a deprecation NOTE any more (got: $out)" ;; *) ;; esac
done
echo "PASS: 'foundation <anything>' refuses legibly (non-zero, names temperloop + v0.19.0, no NOTE)"

# --- T2: the primary entrypoint is unaffected ----------------------------
out_t="$("$TEMPERLOOP" --version 2>&1)"
case "$out_t" in temperloop*) ;; *) fail "--version should self-identify as temperloop (got: $out_t)" ;; esac
echo "PASS: temperloop --version works ($out_t)"

out_t="$("$TEMPERLOOP" help 2>&1)"
case "$out_t" in *"temperloop —"*) ;; *) fail "help banner should self-identify as temperloop (got: $out_t)" ;; esac
echo "PASS: temperloop help works"

rc_t=0; out_t="$("$TEMPERLOOP" not-a-real-subcommand 2>&1)" || rc_t=$?
[ "$rc_t" -ne 0 ] || fail "temperloop must reject an unknown subcommand with a non-zero exit"
echo "PASS: temperloop rejects an unknown subcommand (exit $rc_t)"

# --- T3: the shim never reaches a real subcommand -------------------------
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH — T3 (live subcommand dispatch) skipped"; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/dispatch-rename-test-XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

FAKE_BIN="$WORK/bin"
mkdir -p "$FAKE_BIN"
cat > "$FAKE_BIN/claude" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$FAKE_BIN/gh" <<'EOF'
#!/usr/bin/env bash
if [ "$1" = "auth" ]; then exit 0; fi
echo "{}"
EOF
chmod +x "$FAKE_BIN/claude" "$FAKE_BIN/gh"

FIXTURE="$WORK/repo"
mkdir -p "$FIXTURE"
git -C "$FIXTURE" init -q
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@test \
       GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@test

# temperloop still dispatches 'eject' end-to-end...
rc_t=0; out_t="$(cd "$FIXTURE" && PATH="$FAKE_BIN:$PATH" "$TEMPERLOOP" eject 2>&1)" || rc_t=$?
case "$out_t" in *"temperloop eject"*) ;; *) fail "'temperloop eject' should reach the eject subcommand (got: $out_t)" ;; esac

# ...and the shim does not: it refuses BEFORE any subcommand runs, so none of
# eject's own output can appear.
rc_f=0; out_f="$(cd "$FIXTURE" && PATH="$FAKE_BIN:$PATH" "$FOUNDATION" eject 2>&1)" || rc_f=$?
[ "$rc_f" -ne 0 ] || fail "'foundation eject' must exit non-zero"
case "$out_f" in *"== temperloop eject =="*) fail "'foundation eject' must NOT reach the eject subcommand (got: $out_f)" ;; *) ;; esac
echo "PASS: 'temperloop eject' dispatches (exit $rc_t); 'foundation eject' refuses without dispatching (exit $rc_f)"
