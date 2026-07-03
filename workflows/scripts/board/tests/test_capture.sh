#!/usr/bin/env bash
#
# Arg-parsing tests for scripts/capture.sh (#366). Zero network: capture.sh has
# no source-guard (it runs `gh issue create` top-to-bottom), so we drive it as a
# SUBPROCESS with a fake `gh` on PATH that touches a sentinel + exits non-zero if
# ever called. The cases here all exit in the arg-parsing preamble BEFORE any gh
# call, so a green run proves no junk issue is filed.
#
# Regression target: `capture.sh --help` (no title) used to treat "--help" as the
# title and file a real issue to the default board (observed: created+deleted
# stageFind#689). -h/--help must print usage and exit 0; a missing title or a
# title that starts with `--` must exit 2 — all WITHOUT touching gh.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$HERE/.." && pwd)"
CAPTURE="$SCRIPTS_DIR/capture.sh"

fail() { printf 'FAIL: %b\n' "$1" >&2; exit 1; }

# Fake gh: if capture.sh ever reaches a real gh call in these cases, record it and
# fail loud (the whole point is that none of these cases should).
BIN="$(mktemp -d "${TMPDIR:-/tmp}/capture-bin-XXXXXX")"
SENTINEL="$BIN/gh-was-called"
cat > "$BIN/gh" <<EOF
#!/usr/bin/env bash
touch "$SENTINEL"
echo "FAKE GH CALLED: \$*" >&2
exit 1
EOF
chmod +x "$BIN/gh"

trap 'rm -rf "$BIN"' EXIT

run() {  # run <expected-exit> -- args...  ; sets $out, asserts exit code + no gh
  local want="$1"; shift
  rm -f "$SENTINEL"
  local rc=0
  out="$(PATH="$BIN:$PATH" bash "$CAPTURE" "$@" 2>&1)" || rc=$?
  [ "$rc" -eq "$want" ] || fail "expected exit $want for [$*], got $rc (out: $out)"
  [ ! -e "$SENTINEL" ] || fail "capture.sh reached gh for [$*] — would have filed a junk issue"
}

# 1) --help → usage on exit 0, no gh
run 0 --help
grep -q 'usage: capture.sh' <<<"$out" || fail "--help did not print usage (got: $out)"
echo "PASS: capture.sh --help prints usage and exits 0 without filing an issue (#366)"

# 2) -h → same
run 0 -h
grep -q 'usage: capture.sh' <<<"$out" || fail "-h did not print usage (got: $out)"
echo "PASS: capture.sh -h prints usage and exits 0 without filing an issue"

# 3) no args → usage on exit 2, no gh
run 2
grep -q 'usage: capture.sh' <<<"$out" || fail "no-arg run did not print usage (got: $out)"
echo "PASS: capture.sh with no title exits 2 with usage (no issue filed)"

# 4) a title that starts with `--` (misplaced flag) → refused, exit 2, no gh
run 2 --board 4
grep -q "refusing a title that starts with '--'" <<<"$out" \
  || fail "flag-as-title not refused (got: $out)"
echo "PASS: capture.sh refuses a '--'-prefixed title instead of filing it (#366)"

# 5) invalid --rework cause → refused, exit 2, no gh (F#730)
run 2 "Some title" --rework bogus
grep -q -- "--rework must be one of regression, spec-miss, flake" <<<"$out" \
  || fail "invalid --rework cause not rejected (got: $out)"
echo "PASS: capture.sh rejects an invalid --rework cause without filing an issue (F#730)"

echo "ALL capture.sh arg-parsing tests passed"

# ---------------------------------------------------------------------------
# --rework happy path (F#730): applies BOTH the `rework` and
# `rework-cause:<cause>` labels. Full-flow replay via the shared fake_gh.sh
# fixture (PATH-binary form) — issue_project_item.json already reports the new
# item as status "Ready" on org-project #4 (= logical board 3's project
# number), so board_capture_item's poll resolves on attempt 1 with zero extra
# gh calls beyond project view / field-list / api graphql.
# ---------------------------------------------------------------------------
FIX="$HERE/fixtures"
GH_LOG="$(mktemp "${TMPDIR:-/tmp}/capture-rework-log-XXXXXX")"
CACHE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/capture-rework-cache-XXXXXX")"
REWORK_BIN="$(mktemp -d "${TMPDIR:-/tmp}/capture-rework-bin-XXXXXX")"
cp "$FIX/fake_gh.sh" "$REWORK_BIN/gh"
chmod +x "$REWORK_BIN/gh"
cleanup_rework() { rm -rf "$GH_LOG" "$CACHE_DIR" "$REWORK_BIN"; }
trap 'cleanup_rework; rm -rf "$BIN"' EXIT

rc=0
out="$(
  PATH="$REWORK_BIN:$PATH" GH_LOG="$GH_LOG" GH_FIXTURES="$FIX" \
  BOARD_CACHE_TTL=0 BOARD_CACHE_DIR="$CACHE_DIR" \
  bash "$CAPTURE" "Rework: fix the thing" --rework regression 2>&1
)" || rc=$?
[ "$rc" -eq 0 ] || fail "capture.sh --rework regression exited $rc (out: $out)"

grep -Eq "^gh label create rework -R " "$GH_LOG" \
  || fail "capture.sh --rework did not create the 'rework' label (log: $(cat "$GH_LOG"))"
grep -Eq "^gh label create rework-cause:regression -R " "$GH_LOG" \
  || fail "capture.sh --rework did not create the 'rework-cause:regression' label (log: $(cat "$GH_LOG"))"

issue_create_line="$(grep '^gh issue create ' "$GH_LOG" || true)"
[ -n "$issue_create_line" ] || fail "capture.sh --rework never called gh issue create (log: $(cat "$GH_LOG"))"
grep -q -- "--label rework " <<<"$issue_create_line " \
  || fail "gh issue create was not passed --label rework (line: $issue_create_line)"
grep -q -- "--label rework-cause:regression" <<<"$issue_create_line" \
  || fail "gh issue create was not passed --label rework-cause:regression (line: $issue_create_line)"

echo "PASS: capture.sh --rework regression applies both the rework and rework-cause:regression labels (F#730)"

cleanup_rework
trap 'rm -rf "$BIN"' EXIT

echo "ALL capture.sh --rework tests passed"
