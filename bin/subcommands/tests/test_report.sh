#!/usr/bin/env bash
#
# Tests for report.sh -- `temperloop report` (foundation #766, Epic E
# "before/after value proof"). Zero real network for the default path; a
# fake `gh` on PATH drives the --refresh case, mirroring the
# test_baseline_snapshot.sh convention.
#
# Covers:
#   1. two-record delta rendering (kernel tier) -- merged items/day,
#      time-to-merge, review latency, backlog age all show first->latest.
#   2. single-record repo -- "only one snapshot so far" note, no crash.
#   3. degraded record (metrics.available=false) -- graceful reason text,
#      exit 0, never a crash.
#   4. missing .temperloop/baseline.jsonl entirely -- exit 1, actionable msg.
#   5. overlay tier: missing report.d/, a passing drop-in (rendered
#      verbatim), a non-executable drop-in, a failing drop-in, a timing-out
#      drop-in -- each degrades to its own "skipped" line, never a hard
#      error.
#   6. tokens headline: a `tokens` drop-in with valid JSON drives the
#      tokens-vs-merged-items headline; invalid JSON falls back to the
#      kernel-tier headline. (6c, foundation#882) a by_model breakdown +
#      .temperloop/pricing.json renders a directional dollar line; each
#      missing/malformed/zero-overlap piece degrades to one legible line; a
#      by_model-less producer renders no dollar line (backward compat).
#   7. --refresh appends a real baseline record via a fake gh, then renders.
#   8. CLI hygiene: unknown arg is exit 2; -h is exit 0; a nonexistent --dir
#      is exit 1.
#   9. notice channel (temperloop#981): a present `notice` field renders on
#      its own line under a producer's heading; a `tokens` producer whose
#      stdout is leading non-JSON + JSON degrades to the kernel-tier headline
#      (jq's exit status is now checked, not just `-n "$parsed"`); a clean
#      single-JSON-object `tokens` producer still yields the tokens headline
#      (with notice rendering alongside it, undisturbed); bonus: trailing
#      non-JSON now degrades too, symmetric with the leading case.
#  10. cwd contract: a drop-in runs with cwd = the target repo.
#  11. tokens parse-failure notice (temperloop#988): a `tokens` producer that
#      exits 0 with stdout failing the single-JSON-object/numeric-
#      tokens_spent parse renders an explicit `skipped -- tokens: stdout did
#      not parse ...` line in the existing per-producer skipped-line channel,
#      under its own heading -- leading garbage, trailing garbage, and a
#      non-numeric tokens_spent alike; a producer that already self-declared
#      with its own `skipped -- ` line gets exactly one line, not two; a
#      conforming producer and a non-`tokens` producer get none; the
#      kernel-tier fallback and exit 0 are unchanged.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPORT="$HERE/../report.sh"

fail() { printf 'FAIL: %b\n' "$1" >&2; exit 1; }

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not on PATH"; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/report-test-XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@test \
       GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@test

mk_repo() {
  local dir="$1"
  mkdir -p "$dir"
  git -C "$dir" init -q -b main
  git -C "$dir" remote add origin "git@github.com:test-owner/test-repo.git"
}

# --- 1: two-record delta rendering ------------------------------------------
REPO1="$WORK/repo1"
mk_repo "$REPO1"
mkdir -p "$REPO1/.temperloop"
cat > "$REPO1/.temperloop/baseline.jsonl" <<'JSONL'
{"schema":1,"generated_at":"2026-06-01T00:00:00Z","lookback_days":90,"repo":{"gh_repo":"test-owner/test-repo"},"metrics":{"available":true,"reason":null,"pr_throughput":{"merged_count":9},"time_to_merge_hours":{"median":20.0,"sample_size":9},"review_latency_hours":{"median":4.0,"sample_size":8},"issue_backlog":{"open_count":10,"median_age_days":90.0}}}
{"schema":1,"generated_at":"2026-06-15T00:00:00Z","lookback_days":90,"repo":{"gh_repo":"test-owner/test-repo"},"metrics":{"available":true,"reason":null,"pr_throughput":{"merged_count":18},"time_to_merge_hours":{"median":10.0,"sample_size":18},"review_latency_hours":{"median":2.0,"sample_size":16},"issue_backlog":{"open_count":5,"median_age_days":60.0}}}
JSONL

out1="$(bash "$REPORT" --dir "$REPO1")"
echo "$out1" | grep -q "Baseline records: 2" || fail "should report 2 baseline records"
echo "$out1" | grep -q "Merged items/day:" || fail "should render merged items/day row"
echo "$out1" | grep -q "0.1000/day -> 0.2000/day" || fail "merged items/day should go 9/90 -> 18/90"
echo "$out1" | grep -q "Median time-to-merge" || fail "should render time-to-merge row"
echo "$out1" | grep -q "20.0h -> 10.0h" || fail "time-to-merge should show 20.0h -> 10.0h"
echo "$out1" | grep -q "delta -10.00h" || fail "time-to-merge delta should be -10.00h"
echo "$out1" | grep -q "Review latency" || fail "should render review latency row"
echo "$out1" | grep -q "4.0h -> 2.0h" || fail "review latency should show 4.0h -> 2.0h"
echo "$out1" | grep -q "Issue backlog age" || fail "should render issue backlog age row"
echo "$out1" | grep -q "90.0d -> 60.0d" || fail "issue backlog age should show 90.0 -> 60.0"
echo "$out1" | grep -q "temperloop report: done" || fail "should print the completion line"

# --- 2: single-record repo --------------------------------------------------
REPO2="$WORK/repo2"
mk_repo "$REPO2"
mkdir -p "$REPO2/.temperloop"
cat > "$REPO2/.temperloop/baseline.jsonl" <<'JSONL'
{"schema":1,"generated_at":"2026-06-01T00:00:00Z","lookback_days":90,"repo":{"gh_repo":"test-owner/test-repo"},"metrics":{"available":true,"reason":null,"pr_throughput":{"merged_count":9},"time_to_merge_hours":{"median":20.0,"sample_size":9},"review_latency_hours":{"median":4.0,"sample_size":8},"issue_backlog":{"open_count":10,"median_age_days":90.0}}}
JSONL
out2="$(bash "$REPORT" --dir "$REPO2")"
echo "$out2" | grep -q "only one snapshot so far" || fail "single-record repo should note first==latest"

# --- 3: degraded record (metrics.available=false) ---------------------------
REPO3="$WORK/repo3"
mk_repo "$REPO3"
mkdir -p "$REPO3/.temperloop"
cat > "$REPO3/.temperloop/baseline.jsonl" <<'JSONL'
{"schema":1,"generated_at":"2026-06-01T00:00:00Z","lookback_days":90,"repo":{"gh_repo":null},"metrics":{"available":false,"reason":"skipped — gh not authenticated (or the auth check timed out)","pr_throughput":null,"time_to_merge_hours":null,"review_latency_hours":null,"issue_backlog":null}}
{"schema":1,"generated_at":"2026-06-15T00:00:00Z","lookback_days":90,"repo":{"gh_repo":"test-owner/test-repo"},"metrics":{"available":true,"reason":null,"pr_throughput":{"merged_count":18},"time_to_merge_hours":{"median":10.0,"sample_size":18},"review_latency_hours":{"median":2.0,"sample_size":16},"issue_backlog":{"open_count":5,"median_age_days":60.0}}}
JSONL
out3="$(bash "$REPORT" --dir "$REPO3")"
echo "$out3" | grep -q "unavailable for first record" || fail "degraded first record should render a graceful reason, not crash"
echo "$out3" | grep -q "gh not authenticated" || fail "degraded first record's reason text should surface"

# --- 4: missing .temperloop/baseline.jsonl entirely -------------------------
REPO4="$WORK/repo4"
mk_repo "$REPO4"
if bash "$REPORT" --dir "$REPO4" >/dev/null 2>/tmp/report-test-4.err; then
  fail "missing baseline.jsonl should exit non-zero"
fi
grep -q "no .temperloop/baseline.jsonl (or legacy .foundation/baseline.jsonl) found" /tmp/report-test-4.err || fail "missing-baseline error should be actionable"
rm -f /tmp/report-test-4.err

# --- 5: overlay tier ---------------------------------------------------------
REPO5="$WORK/repo5"
mk_repo "$REPO5"
mkdir -p "$REPO5/.temperloop"
cp "$REPO1/.temperloop/baseline.jsonl" "$REPO5/.temperloop/baseline.jsonl"

# 5a: no report.d/ at all
out5a="$(bash "$REPORT" --dir "$REPO5")"
echo "$out5a" | grep -q "skipped -- no .temperloop/report.d/ (or legacy .foundation/report.d/) directory" || fail "missing report.d/ should print a skip line"

# 5b-5d: passing / non-executable / failing drop-ins
mkdir -p "$REPO5/.temperloop/report.d"
cat > "$REPO5/.temperloop/report.d/hello" <<'EOF'
#!/usr/bin/env bash
echo "hello from a passing drop-in"
EOF
chmod +x "$REPO5/.temperloop/report.d/hello"

cat > "$REPO5/.temperloop/report.d/not-exec" <<'EOF'
#!/usr/bin/env bash
echo "should never run"
EOF
# deliberately not chmod +x

cat > "$REPO5/.temperloop/report.d/broken" <<'EOF'
#!/usr/bin/env bash
exit 3
EOF
chmod +x "$REPO5/.temperloop/report.d/broken"

out5b="$(bash "$REPORT" --dir "$REPO5")"
echo "$out5b" | grep -q "report.d/hello" || fail "a passing drop-in should render its own heading"
echo "$out5b" | grep -q "hello from a passing drop-in" || fail "a passing drop-in's stdout should render verbatim"
echo "$out5b" | grep -q "skipped -- not-exec: producer unavailable (not executable" || fail "a non-executable drop-in should skip legibly"
echo "$out5b" | grep -q "skipped -- broken: producer unavailable (exit 3)" || fail "a failing drop-in should skip legibly with its exit code"

# 5e: timing out
cat > "$REPO5/.temperloop/report.d/slow" <<'EOF'
#!/usr/bin/env bash
sleep 5
echo "too slow"
EOF
chmod +x "$REPO5/.temperloop/report.d/slow"
out5c="$(bash "$REPORT" --dir "$REPO5" --timeout 1)"
echo "$out5c" | grep -q "skipped -- slow: producer unavailable (timed out after 1s)" || fail "a hanging drop-in should time out and skip legibly"
rm -f "$REPO5/.temperloop/report.d/slow"

# --- 6: tokens headline ------------------------------------------------------
REPO6="$WORK/repo6"
mk_repo "$REPO6"
mkdir -p "$REPO6/.temperloop/report.d"
cp "$REPO1/.temperloop/baseline.jsonl" "$REPO6/.temperloop/baseline.jsonl"

cat > "$REPO6/.temperloop/report.d/tokens" <<'EOF'
#!/usr/bin/env bash
echo '{"tokens_spent": 3600}'
EOF
chmod +x "$REPO6/.temperloop/report.d/tokens"

out6a="$(bash "$REPORT" --dir "$REPO6")"
echo "$out6a" | grep -q "Tokens spent vs items merged" || fail "a valid tokens drop-in should drive the tokens headline"
echo "$out6a" | grep -q "3600 tokens / 18 merged item" || fail "tokens headline should cite the raw tokens_spent and latest merged_count"
echo "$out6a" | grep -q "200.0 tokens/item" || fail "tokens headline ratio should be 3600/18 = 200.0"

# 6b: invalid JSON -> falls back to kernel-tier headline
cat > "$REPO6/.temperloop/report.d/tokens" <<'EOF'
#!/usr/bin/env bash
echo "not json at all"
EOF
chmod +x "$REPO6/.temperloop/report.d/tokens"
out6b="$(bash "$REPORT" --dir "$REPO6")"
echo "$out6b" | grep -q "Kernel-tier headline" || fail "an invalid-JSON tokens drop-in should fall back to the kernel-tier headline"
echo "$out6b" | grep -qv "Tokens spent vs items merged" || true  # rendered section still present verbatim, only the HEADLINE falls back
echo "$out6b" | grep -q "Merged items/day: 0.1000 -> 0.2000/day" || fail "kernel-tier headline fallback should show the items/day figures"

# --- 6c: dollar framing (foundation#882) -------------------------------------
# A tokens producer that also emits a by_model breakdown, combined with a
# user-supplied .temperloop/pricing.json, renders a directional dollar line.
REPO_D="$WORK/repoD"
mk_repo "$REPO_D"
mkdir -p "$REPO_D/.temperloop/report.d"
cp "$REPO1/.temperloop/baseline.jsonl" "$REPO_D/.temperloop/baseline.jsonl"
cat > "$REPO_D/.temperloop/report.d/tokens" <<'EOF'
#!/usr/bin/env bash
echo '{"tokens_spent": 3000000, "by_model": {"claude-opus-4-8": 1000000, "claude-sonnet-5": 2000000}}'
EOF
chmod +x "$REPO_D/.temperloop/report.d/tokens"

# 6c-i: all models priced -> ~$28.00 = (1M*18 + 2M*5)/1M, all covered.
echo '{"claude-opus-4-8": 18.00, "claude-sonnet-5": 5.00}' > "$REPO_D/.temperloop/pricing.json"
outDi="$(bash "$REPORT" --dir "$REPO_D")"
echo "$outDi" | grep -q 'Tokens spent vs items merged' || fail "dollar framing must keep the tokens headline"
echo "$outDi" | grep -q '~[$]28.00 directional' || fail "all-priced dollar total should be 28.00 (1M*18 + 2M*5 per Mtok)"
echo "$outDi" | grep -q '2 model(s) priced; all attributed tokens covered' || fail "all-priced line should report 2 covered, none excluded"

# 6c-ii: one model unpriced -> ~$18.00, sonnet excluded by name.
echo '{"claude-opus-4-8": 18.00}' > "$REPO_D/.temperloop/pricing.json"
outDii="$(bash "$REPORT" --dir "$REPO_D")"
echo "$outDii" | grep -q '~[$]18.00 directional' || fail "one-unpriced dollar total should exclude the unpriced model (18.00)"
echo "$outDii" | grep -q 'unpriced tokens excluded: claude-sonnet-5' || fail "the unpriced model should be named and excluded"

# 6c-iii: no pricing.json -> a legible 'add pricing.json' nudge, no dollar figure.
rm -f "$REPO_D/.temperloop/pricing.json"
outDiii="$(bash "$REPORT" --dir "$REPO_D")"
echo "$outDiii" | grep -q 'add .temperloop/pricing.json' || fail "by_model without a pricing table should nudge to add one"
if echo "$outDiii" | grep -q 'directional (priced from'; then fail "no dollar figure should render when the pricing table is absent"; fi

# 6c-iv: malformed (non-JSON) pricing.json -> a legible 'not a {model: $/Mtok}
# object' note, no crash, exit 0.
echo 'not json at all' > "$REPO_D/.temperloop/pricing.json"
outDiv="$(bash "$REPORT" --dir "$REPO_D")"
echo "$outDiv" | grep -qF '{model: $/Mtok} object' || fail "a malformed pricing.json should degrade to the object-shape note"

# 6c-iv-b: valid JSON but NOT an object (an array) -> same object-shape note,
# not a misleading 'no model matched' (would otherwise throw on indexing).
echo '[1, 2, 3]' > "$REPO_D/.temperloop/pricing.json"
outDivb="$(bash "$REPORT" --dir "$REPO_D")"
echo "$outDivb" | grep -qF '{model: $/Mtok} object' || fail "a non-object pricing.json should report the object-shape note, not a name-mismatch"
if echo "$outDivb" | grep -q 'no model in .temperloop/pricing.json matched'; then fail "a non-object pricing.json must not misreport as a name-mismatch"; fi

# 6c-v: a pricing table matching none of the by_model models -> 'no model matched'.
echo '{"some-other-model": 1.00}' > "$REPO_D/.temperloop/pricing.json"
outDv="$(bash "$REPORT" --dir "$REPO_D")"
echo "$outDv" | grep -q 'no model in .temperloop/pricing.json matched' || fail "a zero-overlap pricing table should report no match"

# 6c-vi: backward-compat -- a tokens producer WITHOUT by_model renders no
# dollar line at all, even when a pricing.json is present.
echo '{"claude-opus-4-8": 18.00}' > "$REPO_D/.temperloop/pricing.json"
cat > "$REPO_D/.temperloop/report.d/tokens" <<'EOF'
#!/usr/bin/env bash
echo '{"tokens_spent": 3000000}'
EOF
chmod +x "$REPO_D/.temperloop/report.d/tokens"
outDvi="$(bash "$REPORT" --dir "$REPO_D")"
echo "$outDvi" | grep -q 'Tokens spent vs items merged' || fail "a by_model-less tokens producer must still drive the tokens headline"
if echo "$outDvi" | grep -qE 'directional \(priced from|add .temperloop/pricing.json'; then
  fail "a tokens producer with no by_model must render no dollar line or nudge at all"
fi

# --- 7: --refresh appends via a fake gh, then renders -----------------------
REPO7="$WORK/repo7"
mk_repo "$REPO7"
mkdir -p "$REPO7/.temperloop"
cat > "$REPO7/.temperloop/baseline.jsonl" <<'JSONL'
{"schema":1,"generated_at":"2026-06-01T00:00:00Z","lookback_days":90,"repo":{"gh_repo":"test-owner/test-repo"},"metrics":{"available":true,"reason":null,"pr_throughput":{"merged_count":9},"time_to_merge_hours":{"median":20.0,"sample_size":9},"review_latency_hours":{"median":4.0,"sample_size":8},"issue_backlog":{"open_count":10,"median_age_days":90.0}}}
JSONL

BIN="$WORK/bin"
mkdir -p "$BIN"
cat > "$BIN/gh" <<'FAKE_GH_EOF'
#!/usr/bin/env bash
case "$1" in
  auth) exit 0 ;;
  pr)
    case "$2" in
      list) echo '[{"createdAt":"2026-06-20T00:00:00Z","mergedAt":"2026-06-21T00:00:00Z","reviews":[]}]'; exit 0 ;;
    esac
    ;;
  issue)
    case "$2" in
      list) echo '[{"createdAt":"2026-06-01T00:00:00Z"}]'; exit 0 ;;
    esac
    ;;
esac
exit 0
FAKE_GH_EOF
chmod +x "$BIN/gh"

lines_before="$(wc -l < "$REPO7/.temperloop/baseline.jsonl" | tr -d ' ')"
out7="$(cd "$REPO7" && PATH="$BIN:$PATH" bash "$REPORT" --dir "$REPO7" --refresh)"
lines_after="$(wc -l < "$REPO7/.temperloop/baseline.jsonl" | tr -d ' ')"
[ "$lines_after" -eq "$((lines_before + 1))" ] || fail "--refresh should append exactly one new baseline record"
echo "$out7" | grep -q "Refreshing baseline" || fail "--refresh should announce the refresh step"
echo "$out7" | grep -q "Baseline records: 2" || fail "--refresh's render step should see the freshly appended record"

# a default (no --refresh) run must NOT touch baseline.jsonl, even with no gh at all
lines_before2="$(wc -l < "$REPO7/.temperloop/baseline.jsonl" | tr -d ' ')"
bash "$REPORT" --dir "$REPO7" >/dev/null
lines_after2="$(wc -l < "$REPO7/.temperloop/baseline.jsonl" | tr -d ' ')"
[ "$lines_after2" -eq "$lines_before2" ] || fail "a default (non-refresh) run must never append to baseline.jsonl"

# --- 8: CLI hygiene ----------------------------------------------------------
if bash "$REPORT" --bogus-flag >/dev/null 2>&1; then
  fail "an unknown arg should be a usage error (exit 2)"
fi
bash "$REPORT" -h >/dev/null || fail "-h should exit 0"
if bash "$REPORT" --dir "$WORK/does-not-exist" >/dev/null 2>&1; then
  fail "a nonexistent --dir should exit non-zero"
fi

# --- 9: notice channel (temperloop#981) --------------------------------------
REPO9="$WORK/repo9"
mk_repo "$REPO9"
mkdir -p "$REPO9/.temperloop/report.d"
cp "$REPO1/.temperloop/baseline.jsonl" "$REPO9/.temperloop/baseline.jsonl"

# 9a: a plain (non-tokens) producer emitting a `notice` field renders it as
# its own line under its heading, alongside its normal verbatim stdout.
cat > "$REPO9/.temperloop/report.d/hello" <<'EOF'
#!/usr/bin/env bash
echo '{"notice": "first-run disclosure: this producer is new"}'
EOF
chmod +x "$REPO9/.temperloop/report.d/hello"
out9a="$(bash "$REPORT" --dir "$REPO9")"
echo "$out9a" | grep -q "report.d/hello" || fail "notice-emitting producer should still render its own heading"
echo "$out9a" | grep -q 'notice: first-run disclosure: this producer is new' || fail "a present notice field should render on its own line"

# 9b: a `tokens` producer whose stdout is leading non-JSON text ahead of the
# JSON blob must degrade to the kernel-tier headline -- one legible line --
# rather than crashing or silently misbehaving.
cat > "$REPO9/.temperloop/report.d/tokens" <<'EOF'
#!/usr/bin/env bash
echo "NOTICE: legacy pre-notice-channel producer text"
echo '{"tokens_spent": 4200}'
EOF
chmod +x "$REPO9/.temperloop/report.d/tokens"
out9b="$(bash "$REPORT" --dir "$REPO9")"
echo "$out9b" | grep -q "Kernel-tier headline" || fail "leading non-JSON tokens stdout should degrade to the kernel-tier headline"
echo "$out9b" | grep -q "temperloop report: done" || fail "leading non-JSON tokens producer must not crash the report"

# 9c: a clean, single-JSON-object tokens producer -- the designed shape,
# carrying `notice` alongside `tokens_spent` in the SAME object -- still
# yields the tokens headline; the notice channel must not interfere with the
# existing tokens_spent parse, and both render together.
cat > "$REPO9/.temperloop/report.d/tokens" <<'EOF'
#!/usr/bin/env bash
echo '{"tokens_spent": 4200, "notice": "directional spend, see report.contract.md"}'
EOF
chmod +x "$REPO9/.temperloop/report.d/tokens"
out9c="$(bash "$REPORT" --dir "$REPO9")"
echo "$out9c" | grep -q "Tokens spent vs items merged" || fail "a clean JSON tokens producer (with a notice alongside it) should still drive the tokens headline"
echo "$out9c" | grep -q "4200 tokens / 18 merged item" || fail "tokens headline should still cite the raw tokens_spent"
echo "$out9c" | grep -q 'notice: directional spend, see report.contract.md' || fail "the tokens producer's own notice should render alongside its headline-driving JSON"

# 9d (bonus regression guard): trailing non-JSON tokens stdout must ALSO
# degrade now -- before the jq-exit-status check this "accidentally" drove
# the headline off jq's partial output for the first valid document; now it
# is symmetric with the leading case in 9b.
cat > "$REPO9/.temperloop/report.d/tokens" <<'EOF'
#!/usr/bin/env bash
echo '{"tokens_spent": 4200}'
echo "trailing non-JSON garbage"
EOF
chmod +x "$REPO9/.temperloop/report.d/tokens"
out9d="$(bash "$REPORT" --dir "$REPO9")"
echo "$out9d" | grep -q "Kernel-tier headline" || fail "trailing non-JSON tokens stdout must also degrade to the kernel-tier headline (jq exit status now checked)"

# --- 11: tokens parse-failure notice (temperloop#988) ------------------------
# The fallback in 9b/9d above used to be entirely MUTE: a `tokens` producer
# present, executable, exit 0, but non-conforming stdout dropped to the
# kernel-tier headline with no line saying so. It now renders one line in the
# SAME per-producer skipped-line channel as the not-executable / non-zero /
# timeout cases, inside the producer's own block.
REPO11="$WORK/repo11-tokens-parse-notice"
mk_repo "$REPO11"
mkdir -p "$REPO11/.temperloop/report.d"
cp "$REPO1/.temperloop/baseline.jsonl" "$REPO11/.temperloop/baseline.jsonl"

# 11a: the acceptance shape -- one valid JSON object followed by trailing
# text. This is exactly the population temperloop#981 pulled into the
# falling-back set when it started checking jq's exit status.
cat > "$REPO11/.temperloop/report.d/tokens" <<'EOF'
#!/usr/bin/env bash
echo '{"tokens_spent": 4200}'
echo "...and a trailing human sentence the producer author forgot to drop"
EOF
chmod +x "$REPO11/.temperloop/report.d/tokens"
out11a="$(bash "$REPORT" --dir "$REPO11")"
echo "$out11a" | grep -q "skipped -- tokens: stdout did not parse as a single JSON object with a numeric tokens_spent field" \
  || fail "11a: a JSON-plus-trailing-text tokens producer must render the explicit parse-failure skipped line, not fall back silently"
echo "$out11a" | grep -q "Kernel-tier headline" \
  || fail "11a: the kernel-tier headline fallback itself must be unchanged"
bash "$REPORT" --dir "$REPO11" >/dev/null 2>&1 \
  || fail "11a: a non-conforming tokens producer must still exit 0 -- the notice is a degradation, never an error"
# The line belongs to the producer's own block, i.e. AFTER its heading.
head_line11="$(echo "$out11a" | grep -n -- '-- report.d/tokens --' | cut -d: -f1)"
skip_line11="$(echo "$out11a" | grep -n 'skipped -- tokens: stdout did not parse' | cut -d: -f1)"
[ -n "$head_line11" ] && [ -n "$skip_line11" ] && [ "$skip_line11" -gt "$head_line11" ] \
  || fail "11a: the parse-failure line must render under the producer's own '-- report.d/tokens --' heading (heading=$head_line11 skip=$skip_line11)"

# 11b: leading non-JSON text (the 9b shape) gets the same explicit line --
# leading and trailing garbage degrade identically, notice included.
cat > "$REPO11/.temperloop/report.d/tokens" <<'EOF'
#!/usr/bin/env bash
echo "NOTICE: legacy pre-notice-channel producer text"
echo '{"tokens_spent": 4200}'
EOF
chmod +x "$REPO11/.temperloop/report.d/tokens"
out11b="$(bash "$REPORT" --dir "$REPO11")"
echo "$out11b" | grep -q "skipped -- tokens: stdout did not parse" \
  || fail "11b: leading non-JSON tokens stdout must get the same parse-failure line as the trailing case"

# 11c: valid JSON, but no numeric tokens_spent -- still a headline the
# producer cannot drive, so still announced.
cat > "$REPO11/.temperloop/report.d/tokens" <<'EOF'
#!/usr/bin/env bash
echo '{"tokens_spent": "lots"}'
EOF
chmod +x "$REPO11/.temperloop/report.d/tokens"
out11c="$(bash "$REPORT" --dir "$REPO11")"
echo "$out11c" | grep -q "skipped -- tokens: stdout did not parse" \
  || fail "11c: a non-numeric tokens_spent must also announce the fallback"

# 11d: a producer that ALREADY self-declared via the skip channel (the shape
# the kernel's own shim prints when unresolvable or locally disabled) must
# NOT gain a second, redundant skip line under the same heading.
cat > "$REPO11/.temperloop/report.d/tokens" <<'EOF'
#!/usr/bin/env bash
echo "skipped -- tokens: producer unavailable"
EOF
chmod +x "$REPO11/.temperloop/report.d/tokens"
out11d="$(bash "$REPORT" --dir "$REPO11")"
n11d="$(echo "$out11d" | grep -c 'skipped -- tokens' || true)"
[ "$n11d" -eq 1 ] \
  || fail "11d: a self-declaring 'skipped -- tokens: producer unavailable' producer must render exactly one skip line, got $n11d"
echo "$out11d" | grep -q "Kernel-tier headline" \
  || fail "11d: a self-declared skip must still fall back to the kernel-tier headline"

# 11e: the happy path stays clean -- a conforming producer renders NO
# parse-failure line at all.
cat > "$REPO11/.temperloop/report.d/tokens" <<'EOF'
#!/usr/bin/env bash
echo '{"tokens_spent": 3600}'
EOF
chmod +x "$REPO11/.temperloop/report.d/tokens"
out11e="$(bash "$REPORT" --dir "$REPO11")"
echo "$out11e" | grep -q "Tokens spent vs items merged" \
  || fail "11e: a conforming tokens producer must still drive the tokens headline"
if echo "$out11e" | grep -q "skipped -- tokens"; then
  fail "11e: a conforming tokens producer must render no skipped line at all"
fi

# 11f: the rule is scoped to the producer named exactly `tokens` -- a
# differently-named producer with unparseable stdout is unconstrained plain
# text and must never gain a parse-failure line.
cat > "$REPO11/.temperloop/report.d/plain" <<'EOF'
#!/usr/bin/env bash
echo "just some prose, not JSON at all"
EOF
chmod +x "$REPO11/.temperloop/report.d/plain"
out11f="$(bash "$REPORT" --dir "$REPO11")"
if echo "$out11f" | grep -q "skipped -- plain"; then
  fail "11f: a non-tokens producer's plain-text stdout is contractually fine and must never be announced as a parse failure"
fi
echo "OK 11: tokens parse failure announces itself through the per-producer skipped-line channel (temperloop#988)"

# --- 10: CWD CONTRACT (temperloop#983 review, BLOCKING finding 2) -----------
# report.contract.md's "Overlay drop-in contract" documents a drop-in as
# invoked with "cwd = the target repo" -- but before this fix report.sh
# never actually `cd`'d before running one, so a producer ran with WHATEVER
# cwd this process itself inherited, not $repo_root. That silently breaks
# any producer that derives something from its own cwd (the kernel-side
# `tokens` producer's repo-scoping, temperloop#983, is exactly such a
# consumer) whenever `temperloop report --dir X` is invoked from somewhere
# OTHER than X. Proven with a probe producer that reports its own resolved
# cwd via `pwd -P`, invoked from a THIRD location that is neither the
# fixture repo nor this test's own execution directory.
REPO10="$WORK/repo10-cwd-contract"
mk_repo "$REPO10"
mkdir -p "$REPO10/.temperloop/report.d"
cat > "$REPO10/.temperloop/baseline.jsonl" <<'JSONL'
{"schema":1,"generated_at":"2026-06-01T00:00:00Z","lookback_days":90,"repo":{"gh_repo":"test-owner/test-repo"},"metrics":{"available":true,"reason":null,"pr_throughput":{"merged_count":1},"time_to_merge_hours":{"median":1.0,"sample_size":1},"review_latency_hours":{"median":1.0,"sample_size":1},"issue_backlog":{"open_count":1,"median_age_days":1.0}}}
JSONL
cat > "$REPO10/.temperloop/report.d/cwd-probe" <<'EOF'
#!/usr/bin/env bash
printf '{"notice": "cwd=%s"}\n' "$(pwd -P)"
EOF
chmod +x "$REPO10/.temperloop/report.d/cwd-probe"

THIRD_LOCATION="$WORK/third-location-unrelated"
mkdir -p "$THIRD_LOCATION"
REAL_REPO10="$(cd "$REPO10" && pwd -P)"
out10="$(cd "$THIRD_LOCATION" && bash "$REPORT" --dir "$REPO10")"
echo "$out10" | grep -qF "notice: cwd=$REAL_REPO10" \
  || fail "report.sh must cd to the target repo before running a drop-in producer (report.contract.md: cwd = the target repo) -- expected notice: cwd=$REAL_REPO10, got: $(echo "$out10" | grep 'notice: cwd=')"
echo "OK 10: report.sh cd's to \$repo_root before invoking a drop-in producer, even when --dir differs from this process's own cwd"

echo "OK: test_report.sh"
