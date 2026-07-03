#!/usr/bin/env bash
#
# test_dispatch_rename.sh — proves the foundation -> temperloop rename
# (foundation #893, "chore(kernel): rename to TemperLoop everywhere the
# name lives") didn't break dispatch: kernel/bin/temperloop is the primary
# entrypoint, and kernel/bin/foundation is a thin compat shim that execs it
# — so BOTH paths dispatch identically for every existing `foundation <sub>`
# caller. Zero network: help/version/unknown-subcommand all short-circuit
# before the claude/gh prereq check, so no fake binaries are needed for
# those; the final case drives a real installed subcommand (eject, which is
# a zero-write, zero-network dry-run) through both entrypoints with a fake
# claude + gh on PATH (mirrors test_report_offer.sh's convention) to prove
# parity all the way through a live subcommand dispatch too.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$HERE/../.."
TEMPERLOOP="$BIN_DIR/temperloop"
FOUNDATION="$BIN_DIR/foundation"

fail() { printf 'FAIL: %b\n' "$1" >&2; exit 1; }

[ -x "$TEMPERLOOP" ] || fail "kernel/bin/temperloop must exist and be executable (primary entrypoint)"
[ -x "$FOUNDATION" ] || fail "kernel/bin/foundation must exist and be executable (compat shim)"

# The shim must be short (a thin exec, not a re-implementation) and must
# actually exec temperloop rather than duplicate its logic.
grep -q 'exec .*temperloop' "$FOUNDATION" || fail "kernel/bin/foundation must exec temperloop"
lines="$(wc -l < "$FOUNDATION" | tr -d ' ')"
[ "$lines" -le 25 ] || fail "kernel/bin/foundation should stay a thin shim (got $lines lines)"

# --- T1: --version identical --------------------------------------------
out_t="$("$TEMPERLOOP" --version 2>&1)"
out_f="$("$FOUNDATION" --version 2>&1)"
[ "$out_t" = "$out_f" ] || fail "--version diverged: temperloop='$out_t' foundation='$out_f'"
case "$out_t" in temperloop*) ;; *) fail "--version should self-identify as temperloop (got: $out_t)" ;; esac
echo "PASS: --version identical via both entrypoints ($out_t)"

# --- T2: help identical ---------------------------------------------------
out_t="$("$TEMPERLOOP" help 2>&1)"
out_f="$("$FOUNDATION" help 2>&1)"
[ "$out_t" = "$out_f" ] || fail "help output diverged between temperloop and foundation"
case "$out_t" in *"temperloop —"*) ;; *) fail "help banner should self-identify as temperloop (got: $out_t)" ;; esac
echo "PASS: help identical via both entrypoints"

# --- T3: unknown subcommand identical (dispatch error path) ---------------
rc_t=0; out_t="$("$TEMPERLOOP" not-a-real-subcommand 2>&1)" || rc_t=$?
rc_f=0; out_f="$("$FOUNDATION" not-a-real-subcommand 2>&1)" || rc_f=$?
[ "$out_t" = "$out_f" ] || fail "unknown-subcommand output diverged"
[ "$rc_t" = "$rc_f" ] || fail "unknown-subcommand exit code diverged ($rc_t vs $rc_f)"
echo "PASS: unknown-subcommand error identical via both entrypoints (exit $rc_t)"

# --- T4: a real installed subcommand dispatches identically end-to-end ----
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH — T4 (live subcommand dispatch) skipped"; exit 0; }

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

rc_t=0; out_t="$(cd "$FIXTURE" && PATH="$FAKE_BIN:$PATH" "$TEMPERLOOP" eject 2>&1)" || rc_t=$?
rc_f=0; out_f="$(cd "$FIXTURE" && PATH="$FAKE_BIN:$PATH" "$FOUNDATION" eject 2>&1)" || rc_f=$?
[ "$out_t" = "$out_f" ] || fail "'eject' dispatch diverged between temperloop and foundation (t='$out_t' f='$out_f')"
[ "$rc_t" = "$rc_f" ] || fail "'eject' exit code diverged ($rc_t vs $rc_f)"
echo "PASS: live subcommand ('eject') dispatches identically via both entrypoints (exit $rc_t)"
