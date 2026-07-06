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

# Keep the issue-touches emit (F#916/#919, capture.sh's own
# issue_touch_log_emit) off the REAL raw lake (ISSUE_TOUCHES_RAW_DIR_DEFAULT
# points at $HOME/dev/foundation/meta/data/raw — the actual checkout, not this
# worktree) for every case below that reaches a successful `gh issue create` —
# same rationale as test_claim.sh's CLAIMS_LOG_DIR override for claim.sh's
# sibling claims-log emit.
ISSUE_TOUCHES_LOG_DIR="$(mktemp -d "${TMPDIR:-/tmp}/capture-touches-XXXXXX")"
export ISSUE_TOUCHES_RAW_DIR="$ISSUE_TOUCHES_LOG_DIR"

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

# 6) invalid --repo value → refused, exit 2, no gh (F#808)
run 2 "Some title" --repo overlay
grep -q -- "--repo must be 'kernel' or 'ambiguous'" <<<"$out" \
  || fail "invalid --repo value not rejected (got: $out)"
echo "PASS: capture.sh rejects an invalid --repo value without filing an issue (F#808)"

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

# Issue-touches emit (F#916/#919): a successful capture appends one
# kind:"capture" JSONL record to ISSUE_TOUCHES_RAW_DIR/issue-touches-YYYY-MM.jsonl
# for the just-created issue (#999, per fixtures/fake_gh.sh's `issue create`
# stub) — the capture.sh half of the issue-touch stream (pr-open/merge are
# emitted separately by emit-issue-touch.sh from build.md).
touches_month="$(date -u +%Y-%m)"
touches_file="$ISSUE_TOUCHES_LOG_DIR/issue-touches-$touches_month.jsonl"
[ -f "$touches_file" ] || fail "capture.sh --rework: expected an issue-touches log file at $touches_file"
touch_rec="$(grep -F '"issue":999' "$touches_file" | tail -n1)"
[ -n "$touch_rec" ] || fail "capture.sh --rework: no issue-touches record found for issue 999\n$(cat "$touches_file")"
[ "$(printf '%s' "$touch_rec" | jq -r '.kind')" = "capture" ] \
  || fail "capture.sh --rework: issue-touches record kind must be 'capture'\n$touch_rec"
[ -n "$(printf '%s' "$touch_rec" | jq -r '.repo')" ] \
  || fail "capture.sh --rework: issue-touches record repo must be non-empty\n$touch_rec"
echo "PASS: capture.sh appends a kind:capture issue-touches record on a successful capture (F#916/#919)"

cleanup_rework
trap 'rm -rf "$BIN"' EXIT

echo "ALL capture.sh --rework tests passed"

# ---------------------------------------------------------------------------
# Work-class label substitution (#49): a --label naming a recognized work-class
# value (Operational/Foundational) SUBSTITUTES the default Operational label so
# the issue carries EXACTLY ONE work-class label (work-class-policy.md's
# mutually-exclusive binary) — it must NOT emit both. A non-work-class --label
# still APPENDS on top of the default Operational. Same full-flow fake_gh.sh
# harness as the --rework happy path above; we inspect the `gh issue create`
# line's --label flags.
# ---------------------------------------------------------------------------
WC_BIN="$(mktemp -d "${TMPDIR:-/tmp}/capture-wc-bin-XXXXXX")"
cp "$FIX/fake_gh.sh" "$WC_BIN/gh"; chmod +x "$WC_BIN/gh"
cleanup_wc() { rm -rf "$WC_BIN"; }
trap 'cleanup_wc; rm -rf "$BIN" "$ISSUE_TOUCHES_LOG_DIR"' EXIT

wc_issue_create_line() {  # $1=label-arg... ; runs capture, echoes the issue create log line
  local wlog wcache
  wlog="$(mktemp "${TMPDIR:-/tmp}/capture-wc-log-XXXXXX")"
  wcache="$(mktemp -d "${TMPDIR:-/tmp}/capture-wc-cache-XXXXXX")"
  local rc=0 o
  o="$(PATH="$WC_BIN:$PATH" GH_LOG="$wlog" GH_FIXTURES="$FIX" \
       BOARD_CACHE_TTL=0 BOARD_CACHE_DIR="$wcache" \
       bash "$CAPTURE" "$@" 2>&1)" || rc=$?
  [ "$rc" -eq 0 ] || { rm -rf "$wcache"; fail "capture.sh [$*] exited $rc (out: $o)"; }
  grep '^gh issue create ' "$wlog" || true
  rm -f "$wlog"; rm -rf "$wcache"
}

# 1) --label Foundational SUBSTITUTES: one work-class label, and it's Foundational
line="$(wc_issue_create_line "New capability" --label Foundational)"
[ -n "$line" ] || fail "--label Foundational never reached gh issue create"
grep -q -- "--label Foundational" <<<"$line" \
  || fail "--label Foundational was not applied (line: $line)"
grep -q -- "--label Operational" <<<"$line" \
  && fail "#49: --label Foundational must NOT also apply Operational (line: $line)"
echo "PASS: capture.sh --label Foundational substitutes the work-class label (exactly one, no dual Operational) (#49)"

# 2) --label Operational (the default, passed explicitly) still yields exactly one
line="$(wc_issue_create_line "Explicit operational" --label Operational)"
[ "$(grep -o -- '--label Operational' <<<"$line" | wc -l | tr -d ' ')" = "1" ] \
  || fail "#49: --label Operational must yield exactly one Operational label (line: $line)"
echo "PASS: capture.sh --label Operational yields exactly one work-class label (no duplicate) (#49)"

# 3) a non-work-class --label still APPENDS on top of the default Operational
line="$(wc_issue_create_line "A bug" --label bug)"
grep -q -- "--label Operational" <<<"$line" \
  || fail "#49: a non-work-class --label must keep the default Operational (line: $line)"
grep -q -- "--label bug" <<<"$line" \
  || fail "#49: a non-work-class --label must still append (line: $line)"
echo "PASS: capture.sh --label bug still appends on top of the default Operational (#49)"

cleanup_wc
trap 'rm -rf "$BIN" "$ISSUE_TOUCHES_LOG_DIR"' EXIT

echo "ALL capture.sh work-class label substitution tests passed"

# ---------------------------------------------------------------------------
# --repo kernel / --repo ambiguous full-flow (F#808, Guard #3 of the
# kernel-vs-overlay routing rule): drives capture.sh as a real subprocess
# against a bespoke fake `gh` (the shared fixtures/fake_gh.sh is Projects-v2
# shaped and doesn't understand the issues-only backend's REST verbs —
# `gh api repos/<repo>/issues/<n>`, `gh issue edit --add-label`, `gh label
# create` — so this is a minimal issues-only-shaped stand-in, mirroring
# test_issues_backend.sh's in-process fakes but as a real PATH binary since
# capture.sh runs as a subprocess, not sourced).
#
# Board 7's REAL repo value lives only in lib/board.sh's board_repo() built-in
# case map (see that function's own comment + ISSUES-ONLY-BACKEND.md § "The
# temperloop tracker" for why: it's a sanctioned, denylist:allow'd
# exception, and this test file carries no such exception). So here we
# override board 7's `repo` to a placeholder via a scoped `boards.conf` — the
# SAME override mechanism a real consumer would use (test_boards_conf.sh § 7
# pins that this override path works) — proving the ROUTING logic
# (`--repo kernel`/`--repo ambiguous` -> board 7 -> board_repo(7) -> that
# repo) end-to-end without embedding the real org literal in a non-exempt
# test file.
#
# Proves acceptance criterion 2: the gh calls a `--repo kernel` capture makes
# hit board 7's registered repo (never a `gh project …` call — no Projects-v2
# board exists for it) and carry `fnd:` labels (fnd:status:backlog, both the
# `label create` that ensures it exists and the `issue edit --add-label` that
# applies it). And criterion 3: `--repo ambiguous` takes the SAME route but
# the issue body it files carries the documented ambiguity-default provenance
# note, and the arg-parsing case above (case 6) proves an invalid --repo value
# is refused before any gh call.
# ---------------------------------------------------------------------------
KERNEL_TEST_REPO="Acme/kernel-test"
KCONF_DIR="$(mktemp -d "${TMPDIR:-/tmp}/capture-kernel-conf-XXXXXX")"
cat > "$KCONF_DIR/boards.conf" <<EOF
board.7.repo=$KERNEL_TEST_REPO
EOF
export BOARDS_CONF_REPO_LOCAL="$KCONF_DIR/boards.conf"
export BOARDS_CONF_MACHINE="$KCONF_DIR/no-such-machine-conf"

KBIN="$(mktemp -d "${TMPDIR:-/tmp}/capture-kernel-bin-XXXXXX")"
KLOG="$(mktemp "${TMPDIR:-/tmp}/capture-kernel-log-XXXXXX")"
KBODY="$(mktemp "${TMPDIR:-/tmp}/capture-kernel-body-XXXXXX")"
export KLOG KBODY KERNEL_TEST_REPO
cleanup_kernel() { rm -rf "$KBIN" "$KLOG" "$KBODY" "$KCONF_DIR"; unset BOARDS_CONF_REPO_LOCAL BOARDS_CONF_MACHINE; }
trap 'cleanup_kernel; rm -rf "$BIN"' EXIT

# NB: a QUOTED heredoc delimiter ('FAKEGH') — this script's own comments
# contain backticks (e.g. "fake `gh`"), and an UNQUOTED heredoc treats those
# as command substitution AT GENERATION TIME, splicing the real `gh --help`
# output into the file and corrupting it. $KERNEL_TEST_REPO/$KLOG/$KBODY are
# read from the fake gh's OWN environment at RUNTIME instead (all exported
# above) — no heredoc substitution needed at all.
cat > "$KBIN/gh" <<'FAKEGH'
#!/usr/bin/env bash
# Minimal issues-only-backend fake `gh` for capture.sh's --repo kernel/
# ambiguous full-flow test. Logs every call (shell-quoted, one line) to
# $KLOG for the "which repo/label" assertions, and — for `issue create`
# only — ALSO writes the raw (unescaped) --body value to $KBODY separately:
# `%q` is observed to render an embedded newline (the multi-paragraph
# --repo ambiguous body) inconsistently across invocations (a real newline
# byte vs a literal `\n` escape, bash-version/locale dependent), which
# makes grep-the-%q-log fragile for multi-line body content. $KBODY
# sidesteps that — it's the exact string capture.sh passed, no shell-quoting
# round-trip. $KERNEL_TEST_REPO is board 7's boards.conf-overridden repo
# (set by the test, exported into this script's environment). Handles
# exactly the verbs the flow triggers:
#   issue create -R <repo> ...              -> prints a fake issue URL, dumps --body to $KBODY
#   api repos/<repo>/issues/<n>             -> a fresh, unstatused open issue
#   label create <name> -R <repo> ...       -> no-op (write, record only)
#   issue edit <n> -R <repo> --add-label .. -> no-op (write, record only)
# Anything else is unhandled -> fail loud so an unexpected call surfaces as a
# test failure rather than silently no-op-ing.
set -euo pipefail
: "${KERNEL_TEST_REPO:?fake gh needs KERNEL_TEST_REPO}"
{ printf 'gh'; for a in "$@"; do printf ' %q' "$a"; done; printf '\n'; } >> "$KLOG"
case "$1 $2" in
  "issue create")
    prev=""
    for a in "$@"; do
      [ "$prev" = "--body" ] && printf '%s' "$a" > "$KBODY"
      prev="$a"
    done
    printf 'https://github.com/%s/issues/501\n' "$KERNEL_TEST_REPO"
    ;;
  "api repos/$KERNEL_TEST_REPO/issues/501")
    printf '{"number":501,"title":"t","state":"open","labels":[]}\n' ;;
  "label create") : ;;
  "issue edit")   : ;;
  *) echo "fake gh: unhandled '$1 $2' (argv: $*)" >&2; exit 3 ;;
esac
FAKEGH
chmod +x "$KBIN/gh"

# --- --repo kernel: routes to board 7's registered repo, issues-only -------
: > "$KLOG"; : > "$KBODY"
rc=0
out="$(PATH="$KBIN:$PATH" bash "$CAPTURE" "Board adapter caching bug" --repo kernel 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || fail "capture.sh --repo kernel exited $rc (out: $out)"
grep -qa '^gh issue create ' "$KLOG" || fail "--repo kernel never called gh issue create (log: $(cat "$KLOG")))"
grep -qa -- "-R $KERNEL_TEST_REPO" "$KLOG" \
  || fail "--repo kernel's gh issue create did not target board 7's registered repo (log: $(cat "$KLOG"))"
grep -qa '^gh project' "$KLOG" && fail "--repo kernel must NEVER call gh project (issues-only backend, no Projects board)"
grep -qa -- "gh label create fnd:status:backlog -R $KERNEL_TEST_REPO" "$KLOG" \
  || fail "--repo kernel did not ensure the fnd:status:backlog label exists (log: $(cat "$KLOG"))"
grep -qa -- "gh issue edit 501 -R $KERNEL_TEST_REPO --add-label fnd:status:backlog" "$KLOG" \
  || fail "--repo kernel did not apply the fnd:status:backlog label (log: $(cat "$KLOG"))"
grep -qa 'board 7 Backlog (#501)' <<<"$out" || fail "--repo kernel did not report landing on board 7 Backlog (out: $out)"
echo "PASS: capture.sh --repo kernel files to the kernel issues-only tracker with fnd: labels, no Projects-v2 call (F#808)"

# --- --repo ambiguous: SAME route, but the body carries the default's provenance
: > "$KLOG"; : > "$KBODY"
rc=0
out="$(PATH="$KBIN:$PATH" bash "$CAPTURE" "Not sure if kernel or overlay" --repo ambiguous 2>&1)" || rc=$?
[ "$rc" -eq 0 ] || fail "capture.sh --repo ambiguous exited $rc (out: $out)"
grep -qa '^gh issue create ' "$KLOG" || fail "--repo ambiguous never called gh issue create (log: $(cat "$KLOG"))"
grep -qa -- "-R $KERNEL_TEST_REPO" "$KLOG" \
  || fail "--repo ambiguous's gh issue create did not target board 7's registered repo (log: $(cat "$KLOG"))"
# $KBODY holds the exact, unescaped --body value the fake gh received (see the
# fake gh's own comment above on why this sidesteps %q's inconsistent
# newline rendering for a multi-paragraph body).
grep -q -- 'kernel-vs-overlay routing rule' "$KBODY" \
  || fail "--repo ambiguous's issue body did not carry the documented ambiguity-default provenance note (body: $(cat "$KBODY"))"
grep -q -- 'Ambiguous foundation-domain captures default to kernel' "$KBODY" \
  || fail "--repo ambiguous's issue body did not cite the routing rule's ambiguity clause verbatim (body: $(cat "$KBODY"))"
grep -qa 'board 7 Backlog' <<<"$out" || fail "--repo ambiguous did not report landing on board 7 Backlog (out: $out)"
echo "PASS: capture.sh --repo ambiguous defaults to the kernel tracker and records the ambiguity-default provenance in the issue body (F#808)"

cleanup_kernel
trap 'rm -rf "$BIN" "$ISSUE_TOUCHES_LOG_DIR"' EXIT

echo "ALL capture.sh --repo kernel/ambiguous tests passed"
