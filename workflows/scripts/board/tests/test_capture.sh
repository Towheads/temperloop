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

# Hermetic conf env (temperloop#501): fixture tests must never resolve boards
# through the repo's or host's real boards.conf — a consumer's committed
# cutover flip (e.g. stageFind's board.3.backend=issues) or a driver host's
# machine-level conf would silently change canned-fixture resolution.
# (The --repo kernel section below re-exports its own fixture conf, then
# cleanup restores these hermetic defaults.)
export BOARDS_CONF_REPO_LOCAL=/dev/null
export BOARDS_CONF_MACHINE=/dev/null


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

# 4) a leading flag with no title → "title required", exit 2, no gh.
# (Post-#1227 a leading `--` arg is a flag, not the title, so `--board 4` with no
# title is a missing-title error rather than the "--"-prefixed-title refusal.)
run 2 --board 4
grep -q "a title is required" <<<"$out" \
  || fail "flags-only-no-title not rejected with the title-required error (got: $out)"
echo "PASS: capture.sh with flags but no title exits 2 (no junk issue) (#366/#1227)"

# 5) invalid --rework cause → refused, exit 2, no gh (F#730)
run 2 "Some title" --rework bogus
grep -q -- "--rework must be one of regression, spec-miss, flake" <<<"$out" \
  || fail "invalid --rework cause not rejected (got: $out)"
echo "PASS: capture.sh rejects an invalid --rework cause without filing an issue (F#730)"

# 6) --title alias is ACCEPTED as the title and proceeds past arg-parsing to the
# filing path (foundation#1227). The fail-on-call fake gh makes "reached gh" the
# proof that arg-parsing accepted the title rather than rejecting it in the
# preamble. (This is the one case that intentionally reaches gh.)
rm -f "$SENTINEL"
PATH="$BIN:$PATH" bash "$CAPTURE" --title "Alias title" --board 4 >/dev/null 2>&1 || true
[ -e "$SENTINEL" ] \
  || fail "6: --title should be accepted and proceed to the filing path (not rejected in arg-parsing)"
echo "PASS: capture.sh --title <t> is accepted as a positional-title alias (#1227)"

# 7) BOTH a positional title AND --title → exit 2, no gh (exactly one source).
run 2 "Positional" --title "Flag"
grep -q "EITHER positionally OR via --title, not both" <<<"$out" \
  || fail "7: passing both a positional title and --title should be rejected (got: $out)"
echo "PASS: capture.sh rejects both a positional title and --title (#1227)"

# 8) --title whose value starts with `--` (a misplaced flag) → refused, exit 2.
run 2 --title --board
grep -q "refusing a title that starts with '--'" <<<"$out" \
  || fail "8: a '--'-prefixed --title value should be refused (got: $out)"
echo "PASS: capture.sh refuses a '--'-prefixed --title value (#1227 keeps the junk-flag guard)"

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

# 4) --title alias: the flag VALUE flows through to `gh issue create` as the
# title (foundation#1227 — the whole point of the alias). Full-flow harness, so
# this proves value-passthrough, not merely that arg-parsing accepted the flag.
line="$(wc_issue_create_line --title "AliasTitle" --label bug)"
[ -n "$line" ] || fail "#1227: --title never reached gh issue create"
grep -q -- "--title AliasTitle" <<<"$line" \
  || fail "#1227: --title value did not flow to gh issue create as the title (line: $line)"
echo "PASS: capture.sh --title <t> flows the flag value through as the issue title (#1227)"

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
cleanup_kernel() { rm -rf "$KBIN" "$KLOG" "$KBODY" "$KCONF_DIR"; export BOARDS_CONF_REPO_LOCAL=/dev/null BOARDS_CONF_MACHINE=/dev/null; }
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

# ---------------------------------------------------------------------------
# board_capture_item / board_create_many race: never-resolves + resolves-late
# (foundation #1226). The original bug: `board_create_many` always returned 0
# even when an item never landed on the board, so capture.sh's caller-side
# "Captured -> Backlog" success line printed on the very next line after a
# loud "did not resolve in time" warning — a created-but-not-landed issue read
# as success in the run summary. Both cases below drive capture.sh as a real
# subprocess against a bespoke fake `gh` (same style as the --repo kernel fake
# above): the shared fixtures/fake_gh.sh PATH-binary form can't express a
# stateful "empty now, populated on a later call" item-list, which the
# resolves-late case needs. A fake `sleep` on PATH (ahead of the real one)
# keeps both cases fast despite board_capture_item's 3x2s poll and
# board_create_many's graduated backoff.
# ---------------------------------------------------------------------------

# --- never resolves: total failure -> non-zero exit, no false success line --
RACE_LOG="$(mktemp "${TMPDIR:-/tmp}/capture-race-log-XXXXXX")"
RACE_BIN="$(mktemp -d "${TMPDIR:-/tmp}/capture-race-bin-XXXXXX")"
RACE_CACHE="$(mktemp -d "${TMPDIR:-/tmp}/capture-race-cache-XXXXXX")"
export RACE_LOG
cat > "$RACE_BIN/gh" <<'RACEGH'
#!/usr/bin/env bash
# Minimal fake gh for the never-resolves race test: the added item NEVER
# indexes — every item-list and single-item graphql probe reports nothing —
# so both board_capture_item's own poll and its board_create_on_board
# fallback's index-lag retry exhaust with no card found.
set -euo pipefail
: "${RACE_LOG:?fake gh needs RACE_LOG}"
{ printf 'gh'; for a in "$@"; do printf ' %q' "$a"; done; printf '\n'; } >> "$RACE_LOG"
case "$1 $2" in
  "issue create")   printf 'https://github.com/ExampleOrg/example-repo/issues/902\n' ;;
  "label create")   : ;;
  "project view")   printf '{"id":"PVT_kwTESTPROJECT123","number":3,"title":"stageFind build","owner":{"login":"ExampleOrg"}}\n' ;;
  "project field-list")
    printf '{"fields":[{"id":"PVTSSF_status","name":"Status","type":"ProjectV2SingleSelectField","options":[{"id":"opt_backlog","name":"Backlog"}]}]}\n' ;;
  "project item-add")  : ;;
  "project item-edit") : ;;
  "project item-list") echo '{"items":[],"totalCount":0}' ;;
  "api graphql")
    printf '{"data":{"repository":{"issue":{"title":"Never lands","projectItems":{"nodes":[]}}}}}\n' ;;
  *) echo "fake gh: unhandled '$1 $2' (argv: $*)" >&2; exit 3 ;;
esac
RACEGH
chmod +x "$RACE_BIN/gh"
cat > "$RACE_BIN/sleep" <<'RACESLEEP'
#!/usr/bin/env bash
exit 0
RACESLEEP
chmod +x "$RACE_BIN/sleep"
cleanup_race() { rm -rf "$RACE_LOG" "$RACE_BIN" "$RACE_CACHE"; unset RACE_LOG; }
trap 'cleanup_race; rm -rf "$BIN" "$ISSUE_TOUCHES_LOG_DIR"' EXIT

rc=0
out="$(
  PATH="$RACE_BIN:$PATH" RACE_LOG="$RACE_LOG" \
  BOARD_CACHE_TTL=0 BOARD_CACHE_DIR="$RACE_CACHE" BOARD_BUDGET_GUARD_THRESHOLD=0 \
  BOARD_CREATE_INDEX_RETRIES=1 \
  bash "$CAPTURE" "Item that never lands" 2>&1
)" || rc=$?
[ "$rc" -ne 0 ] || fail "capture.sh must exit non-zero when the item never lands on the board (out: $out)"
if grep -Eq 'Captured .* -> board .* Backlog' <<<"$out"; then
  fail "capture.sh must NEVER print the Backlog success line for an item that never landed (out: $out)"
fi
grep -qi 'NOT land' <<<"$out" \
  || fail "capture.sh must print a distinct loud line naming the created-but-not-landed issue (out: $out)"
grep -q '#902' <<<"$out" \
  || fail "capture.sh's not-landed message must name the issue number (out: $out)"
echo "PASS: capture.sh exits non-zero and never prints a false Backlog success line when the board add races and the item never lands (F#1226)"

cleanup_race
trap 'rm -rf "$BIN" "$ISSUE_TOUCHES_LOG_DIR"' EXIT

# --- resolves late: the item indexes on a retry, not immediately -> still a
#     truthful success (regression guard against over-tightening the new
#     contract into treating a slow-but-eventual landing as a failure) -------
LATE_LOG="$(mktemp "${TMPDIR:-/tmp}/capture-late-log-XXXXXX")"
LATE_BIN="$(mktemp -d "${TMPDIR:-/tmp}/capture-late-bin-XXXXXX")"
LATE_CACHE="$(mktemp -d "${TMPDIR:-/tmp}/capture-late-cache-XXXXXX")"
LATE_COUNT="$(mktemp "${TMPDIR:-/tmp}/capture-late-count-XXXXXX")"
echo 0 > "$LATE_COUNT"
export LATE_LOG LATE_COUNT
cat > "$LATE_BIN/gh" <<'LATEGH'
#!/usr/bin/env bash
# Minimal fake gh for the resolves-late race test: auto-add never fires (the
# single-item graphql probe board_capture_item polls always reports nothing),
# forcing the board_create_on_board fallback; that fallback's item-list is
# EMPTY on its first call (mimicking un-indexed Projects-v2) and POPULATED
# from the second call on, so the item lands on the index-lag retry rather
# than immediately.
set -euo pipefail
: "${LATE_LOG:?fake gh needs LATE_LOG}" "${LATE_COUNT:?fake gh needs LATE_COUNT}"
{ printf 'gh'; for a in "$@"; do printf ' %q' "$a"; done; printf '\n'; } >> "$LATE_LOG"
case "$1 $2" in
  "issue create")   printf 'https://github.com/ExampleOrg/example-repo/issues/903\n' ;;
  "label create")   : ;;
  "project view")   printf '{"id":"PVT_kwTESTPROJECT123","number":3,"title":"stageFind build","owner":{"login":"ExampleOrg"}}\n' ;;
  "project field-list")
    printf '{"fields":[{"id":"PVTSSF_status","name":"Status","type":"ProjectV2SingleSelectField","options":[{"id":"opt_backlog","name":"Backlog"}]}]}\n' ;;
  "project item-add")  : ;;
  "project item-edit") : ;;
  "project item-list")
    c=$(($(cat "$LATE_COUNT") + 1)); echo "$c" > "$LATE_COUNT"
    if [ "$c" -lt 2 ]; then
      echo '{"items":[],"totalCount":0}'
    else
      echo '{"items":[{"id":"PVTI_item903","content":{"number":903,"title":"Resolves late","type":"Issue"}}],"totalCount":1}'
    fi
    ;;
  "api graphql")
    printf '{"data":{"repository":{"issue":{"title":"Resolves late","projectItems":{"nodes":[]}}}}}\n' ;;
  *) echo "fake gh: unhandled '$1 $2' (argv: $*)" >&2; exit 3 ;;
esac
LATEGH
chmod +x "$LATE_BIN/gh"
cat > "$LATE_BIN/sleep" <<'LATESLEEP'
#!/usr/bin/env bash
exit 0
LATESLEEP
chmod +x "$LATE_BIN/sleep"
cleanup_late() { rm -rf "$LATE_LOG" "$LATE_BIN" "$LATE_CACHE" "$LATE_COUNT"; unset LATE_LOG LATE_COUNT; }
trap 'cleanup_late; rm -rf "$BIN" "$ISSUE_TOUCHES_LOG_DIR"' EXIT

rc=0
out="$(
  PATH="$LATE_BIN:$PATH" LATE_LOG="$LATE_LOG" LATE_COUNT="$LATE_COUNT" \
  BOARD_CACHE_TTL=0 BOARD_CACHE_DIR="$LATE_CACHE" BOARD_BUDGET_GUARD_THRESHOLD=0 \
  bash "$CAPTURE" "Item that resolves late" 2>&1
)" || rc=$?
[ "$rc" -eq 0 ] || fail "capture.sh must still exit 0 when the item lands on a later index-lag retry (out: $out)"
grep -Eq 'Captured .* -> board 3 Backlog \(#903\)' <<<"$out" \
  || fail "capture.sh must print the truthful Backlog success line once the item lands late (out: $out)"
[ "$(grep -c '^gh project item-list' "$LATE_LOG")" -ge 2 ] \
  || fail "resolves-late: expected the item-list to be re-fetched at least once (log: $(cat "$LATE_LOG"))"
echo "PASS: capture.sh still reports truthful success when the board add lands on a later index-lag retry (F#1226)"

cleanup_late
trap 'rm -rf "$BIN" "$ISSUE_TOUCHES_LOG_DIR"' EXIT

echo "ALL capture.sh board-landing race tests passed (F#1226)"

# ---------------------------------------------------------------------------
# Batch-budget fixes (foundation #1225): capture.sh drives board_add_to_board /
# board_create_many (both in lib/board.sh), which capture.sh itself doesn't
# touch — these two tests drive the fix through the real capture.sh entrypoint,
# as real subprocesses, to prove the observable behavior end to end.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# 1) Cache-patch call-counting: N SERIAL capture.sh invocations that all fall
#    through to the board_create_many fallback (auto-add never fires) must
#    share <=1 LIVE whole-board `item-list` fetch within one BOARD_CACHE_TTL
#    window, not pay one per invocation (the O(N) mechanism #1225 reported: 9
#    serial captures drained the shared GraphQL budget). A stateful fake `gh`
#    on PATH: `project item-add` records the added issue number into a shared
#    state file and echoes back `{"id":"PVTI_<num>"}` (the real gh behavior
#    board_add_to_board now reads to splice the cache — see
#    _board_cache_patch_add in lib/board.sh); `project item-list` counts its
#    own live calls and replies with every issue added so far. `api graphql`
#    (board_capture_item's own auto-add poll) always reports the issue absent,
#    so EVERY invocation takes the board_create_many fallback — the worst case.
#
# Mechanism under test: invocation 1 has no warm cache yet, so its
# board_add_to_board falls back to a bust and board_resolve pays the ONE live
# item-list fetch (unavoidable — nothing to share yet). Invocations 2..N each
# splice their new item straight into the now-warm cache (_board_cache_patch_add)
# instead of busting it, so their board_resolve is a cache HIT — zero further
# item-list calls. Total across all N: exactly 1.
# ---------------------------------------------------------------------------
BURST_BIN="$(mktemp -d "${TMPDIR:-/tmp}/capture-burst-bin-XXXXXX")"
BURST_CACHE="$(mktemp -d "${TMPDIR:-/tmp}/capture-burst-cache-XXXXXX")"
BURST_LOG="$(mktemp "${TMPDIR:-/tmp}/capture-burst-log-XXXXXX")"
BURST_STATE="$(mktemp "${TMPDIR:-/tmp}/capture-burst-state-XXXXXX")"
BURST_ITEMLIST_CALLS="$(mktemp "${TMPDIR:-/tmp}/capture-burst-calls-XXXXXX")"
BURST_ISSUE_COUNTER="$(mktemp "${TMPDIR:-/tmp}/capture-burst-counter-XXXXXX")"
: > "$BURST_STATE"
: > "$BURST_ITEMLIST_CALLS"
echo 800 > "$BURST_ISSUE_COUNTER"
export BURST_LOG BURST_STATE BURST_ITEMLIST_CALLS BURST_ISSUE_COUNTER
cat > "$BURST_BIN/gh" <<'BURSTGH'
#!/usr/bin/env bash
# Stateful fake gh for the serial-capture cache-patch test (foundation #1225).
# See the test's own header comment (test_capture.sh) for the full mechanism.
set -euo pipefail
: "${BURST_LOG:?}" "${BURST_STATE:?}" "${BURST_ITEMLIST_CALLS:?}" "${BURST_ISSUE_COUNTER:?}"
{ printf 'gh'; for a in "$@"; do printf ' %q' "$a"; done; printf '\n'; } >> "$BURST_LOG"
case "$1 $2" in
  "issue create")
    n=$(($(cat "$BURST_ISSUE_COUNTER") + 1)); echo "$n" > "$BURST_ISSUE_COUNTER"
    printf 'https://github.com/ExampleOrg/example-repo/issues/%s\n' "$n"
    ;;
  "label create")   : ;;
  "project view")   printf '{"id":"PVT_kwTESTPROJECT123","number":3,"title":"stageFind build","owner":{"login":"ExampleOrg"}}\n' ;;
  "project field-list")
    printf '{"fields":[{"id":"PVTSSF_status","name":"Status","type":"ProjectV2SingleSelectField","options":[{"id":"opt_backlog","name":"Backlog"}]}]}\n' ;;
  "project item-add")
    # Extract the issue number off the trailing --url path segment, record it
    # (idempotent), and echo back the real gh shape board_add_to_board reads.
    url=""; prev=""
    for a in "$@"; do [ "$prev" = "--url" ] && url="$a"; prev="$a"; done
    num="${url##*/}"
    grep -qx "$num" "$BURST_STATE" 2>/dev/null || echo "$num" >> "$BURST_STATE"
    printf '{"id":"PVTI_item%s"}\n' "$num"
    ;;
  "project item-edit") : ;;
  "project item-list")
    echo x >> "$BURST_ITEMLIST_CALLS"
    items="[]"
    if [ -s "$BURST_STATE" ]; then
      items="$(jq -sR '[split("\n")[] | select(length>0) | {id: ("PVTI_item" + .), content: {number: (.|tonumber), title: "Burst item", type: "Issue"}}]' "$BURST_STATE")"
    fi
    jq -n --argjson items "$items" '{items: $items, totalCount: ($items|length)}'
    ;;
  "api graphql")
    # board_capture_item's auto-add poll: always report the issue absent, so
    # every invocation takes the board_create_many fallback (the worst case).
    printf '{"data":{"repository":{"issue":{"title":"Burst item","projectItems":{"nodes":[]}}}}}\n'
    ;;
  *) echo "fake gh: unhandled '$1 $2' (argv: $*)" >&2; exit 3 ;;
esac
BURSTGH
chmod +x "$BURST_BIN/gh"
cat > "$BURST_BIN/sleep" <<'BURSTSLEEP'
#!/usr/bin/env bash
exit 0
BURSTSLEEP
chmod +x "$BURST_BIN/sleep"
cleanup_burst() { rm -rf "$BURST_BIN" "$BURST_CACHE" "$BURST_LOG" "$BURST_STATE" "$BURST_ITEMLIST_CALLS" "$BURST_ISSUE_COUNTER"; unset BURST_LOG BURST_STATE BURST_ITEMLIST_CALLS BURST_ISSUE_COUNTER; }
trap 'cleanup_burst; rm -rf "$BIN" "$ISSUE_TOUCHES_LOG_DIR"' EXIT

for i in 1 2 3; do
  rc=0
  out="$(
    PATH="$BURST_BIN:$PATH" \
    BOARD_CACHE_TTL=300 BOARD_CACHE_DIR="$BURST_CACHE" BOARD_BUDGET_GUARD_THRESHOLD=0 \
    bash "$CAPTURE" "Burst item $i" 2>&1
  )" || rc=$?
  [ "$rc" -eq 0 ] || fail "burst capture #$i exited $rc (out: $out)"
  grep -Eq 'Captured .* -> board 3 Backlog' <<<"$out" \
    || fail "burst capture #$i did not report landing on the board (out: $out)"
done

itemlist_calls="$(wc -l < "$BURST_ITEMLIST_CALLS" | tr -d ' ')"
[ "$itemlist_calls" -eq 1 ] \
  || fail "3 serial captures within BOARD_CACHE_TTL should share exactly 1 live item-list fetch (cache-patch, not bust — foundation #1225), got $itemlist_calls (log: $(cat "$BURST_LOG"))"
[ "$(wc -l < "$BURST_STATE" | tr -d ' ')" -eq 3 ] \
  || fail "expected all 3 burst issues to have been item-added (state: $(cat "$BURST_STATE"))"
echo "PASS: 3 serial capture.sh invocations within one BOARD_CACHE_TTL window share exactly 1 live whole-board item-list fetch — board_add_to_board patches the cache instead of busting it (foundation #1225)"

cleanup_burst
trap 'rm -rf "$BIN" "$ISSUE_TOUCHES_LOG_DIR"' EXIT

# ---------------------------------------------------------------------------
# 2) Budget-guard abort: board_create_many's index-wait retry loop must
#    pre-flight the SAME GraphQL budget guard used by board_resolve
#    (_board_budget_guard), but DEFAULTING TO ABORT (not the general guard's
#    warn-only default) so a near-empty budget stops the retry loop loud
#    instead of continuing to drain it. The item here NEVER indexes (item-list
#    always empty, auto-add's graphql probe always empty), forcing the
#    fallback's retry loop to actually iterate; `api rate_limit` reports a
#    budget under the default threshold (200) with BOARD_BUDGET_GUARD left
#    UNSET (proving the abort is the retry loop's own default, not something
#    the caller had to opt into). BOARD_CREATE_INDEX_RETRIES is set higher
#    than 1 so a passing item-list count proves the GUARD cut the loop short,
#    not that the retry budget merely ran out.
# ---------------------------------------------------------------------------
GUARD_LOG="$(mktemp "${TMPDIR:-/tmp}/capture-guard-log-XXXXXX")"
GUARD_BIN="$(mktemp -d "${TMPDIR:-/tmp}/capture-guard-bin-XXXXXX")"
GUARD_CACHE="$(mktemp -d "${TMPDIR:-/tmp}/capture-guard-cache-XXXXXX")"
GUARD_ITEMLIST_CALLS="$(mktemp "${TMPDIR:-/tmp}/capture-guard-calls-XXXXXX")"
: > "$GUARD_ITEMLIST_CALLS"
export GUARD_LOG GUARD_ITEMLIST_CALLS
cat > "$GUARD_BIN/gh" <<'GUARDGH'
#!/usr/bin/env bash
# Fake gh for the budget-guard-abort test: the item NEVER indexes (item-list
# always empty, auto-add's graphql probe always empty), and the GraphQL
# budget is reported low — proving board_create_many's retry loop aborts
# rather than exhausting its full retry budget against a near-empty bucket.
set -euo pipefail
: "${GUARD_LOG:?}" "${GUARD_ITEMLIST_CALLS:?}"
{ printf 'gh'; for a in "$@"; do printf ' %q' "$a"; done; printf '\n'; } >> "$GUARD_LOG"
case "$1 $2" in
  "issue create")   printf 'https://github.com/ExampleOrg/example-repo/issues/904\n' ;;
  "label create")   : ;;
  "project view")   printf '{"id":"PVT_kwTESTPROJECT123","number":3,"title":"stageFind build","owner":{"login":"ExampleOrg"}}\n' ;;
  "project field-list")
    printf '{"fields":[{"id":"PVTSSF_status","name":"Status","type":"ProjectV2SingleSelectField","options":[{"id":"opt_backlog","name":"Backlog"}]}]}\n' ;;
  "project item-add")  printf '{"id":"PVTI_item904"}\n' ;;
  "project item-edit") : ;;
  "project item-list")
    echo x >> "$GUARD_ITEMLIST_CALLS"
    echo '{"items":[],"totalCount":0}'
    ;;
  "api graphql")
    printf '{"data":{"repository":{"issue":{"title":"Budget-guarded item","projectItems":{"nodes":[]}}}}}\n' ;;
  "api rate_limit")
    # Under the default BOARD_BUDGET_GUARD_THRESHOLD (200): a near-empty budget.
    printf '%s\n%s\n' 40 "$(( $(date +%s) + 600 ))"
    ;;
  *) echo "fake gh: unhandled '$1 $2' (argv: $*)" >&2; exit 3 ;;
esac
GUARDGH
chmod +x "$GUARD_BIN/gh"
cat > "$GUARD_BIN/sleep" <<'GUARDSLEEP'
#!/usr/bin/env bash
exit 0
GUARDSLEEP
chmod +x "$GUARD_BIN/sleep"
cleanup_guard() { rm -rf "$GUARD_BIN" "$GUARD_CACHE" "$GUARD_LOG" "$GUARD_ITEMLIST_CALLS"; unset GUARD_LOG GUARD_ITEMLIST_CALLS; }
trap 'cleanup_guard; rm -rf "$BIN" "$ISSUE_TOUCHES_LOG_DIR"' EXIT

rc=0
out="$(
  PATH="$GUARD_BIN:$PATH" \
  BOARD_CACHE_TTL=0 BOARD_CACHE_DIR="$GUARD_CACHE" BOARD_CREATE_INDEX_RETRIES=3 \
  bash "$CAPTURE" "Item under a drained budget" 2>&1
)" || rc=$?
[ "$rc" -ne 0 ] || fail "capture.sh must exit non-zero when board_create_many's retry loop budget-aborts (out: $out)"
grep -qi 'NOT land' <<<"$out" \
  || fail "capture.sh must still print the loud not-landed message on a budget-abort (out: $out)"
grep -q '#904' <<<"$out" \
  || fail "capture.sh's not-landed message must name the issue number (out: $out)"
grep -qi 'aborting index-wait retry' <<<"$out" \
  || fail "board_create_many must name the budget-abort explicitly (out: $out)"
guard_calls="$(wc -l < "$GUARD_ITEMLIST_CALLS" | tr -d ' ')"
[ "$guard_calls" -eq 1 ] \
  || fail "the retry loop must abort on its FIRST budget check (only the base board_resolve item-list call, 1 total), not exhaust BOARD_CREATE_INDEX_RETRIES=3 — got $guard_calls item-list calls (log: $(cat "$GUARD_LOG"))"
echo "PASS: board_create_many's index-wait retry loop pre-flight budget-guards each re-list and ABORTS BY DEFAULT (not board_resolve's warn-only default) on a near-empty GraphQL budget, propagating through the same truthful-failure contract as an index-timeout (foundation #1225)"

cleanup_guard
trap 'rm -rf "$BIN" "$ISSUE_TOUCHES_LOG_DIR"' EXIT

echo "ALL capture.sh batch-budget tests passed (F#1225)"
