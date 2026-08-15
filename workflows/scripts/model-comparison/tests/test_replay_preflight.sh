#!/usr/bin/env bash
#
# test_replay_preflight.sh — fixture suite for `replay.sh preflight`
# (temperloop#1256, epic #1225 "model comparison harness"): the per-
# comparison spend gate that prints eligible-N, a batch-cap-bounded cost
# estimate, and significance reachability (via stats.sh's own `mde`
# primitive) BEFORE any replay token is spent.
#
# Hermetic: no `gh` call, no network, no live model call — preflight reads an
# already-computed corpus JSONL file (a plain fixture on disk) rather than
# invoking `corpus` itself, and quota-gate.sh reads a fixture cache file via
# BUILD_QUOTA_CACHE. No mapfile / associative arrays / GNU-only flags (bash
# 3.2).
#
# Sections:
#   1-3   eligible-N counting (eligible + flagged-eligible, excluding
#         rejected), and the fail-closed floor is a REAL computed zero, not
#         a CANNOT_EVALUATE
#   4-6   REPLAY_PREFLIGHT_BATCH_CAP wiring (two distinct non-default
#         values), and planned_n never exceeds it
#   7-9   estimated_total_tokens = planned_replays_n *
#         REPLAY_PREFLIGHT_TOKENS_PER_REPLAY, where planned_replays_n is
#         planned_n * arms_n (temperloop#1379 — every record is replayed in
#         BOTH arms). REPLAY_PREFLIGHT_TOKENS_PER_REPLAY wiring, non-default
#         value. The two-arm factor itself is pinned end-to-end by the
#         sibling suite test_replay_preflight_two_arm.sh.
#   10-12 REPLAY_PREFLIGHT_CEILING_TOKENS: stop:true/ceiling_exceeded on an
#         over-budget batch, non-zero exit; MUTATION PROOF the ceiling check
#         is load-bearing
#   13-16 quota-gate.sh IS CONSULTED: pause -> stop, healthy -> proceed,
#         absent cache -> fail OPEN (never stops); MUTATION PROOF the gate
#         call is load-bearing
#   17-19 significance reachability: below MODEL_COMPARISON_MIN_SAMPLE_N,
#         at/above it, and genuinely CONSUMING stats.sh's own mde primitive
#         (byte-identical cross-check against a direct stats.sh call)
#   20-24 FAIL CLOSED: absent / unreadable(directory) / empty / malformed
#         corpus file, and an unreachable stats.sh primitive — all
#         CANNOT_EVALUATE, non-zero, never a silently-computed answer
#   25-26 no scheduled/cron/autonomous entry point exists, + mutation proof
#         the detector itself would catch one
#   27    hard constraint: a trailing flag with no value fails fast, bounded
#
# Usage: bash workflows/scripts/model-comparison/tests/test_replay_preflight.sh
#
# shellcheck disable=SC2016,SC1003

set -uo pipefail

# Physical derivation (`cd -P`) — dir-symlink-composition-safe (temperloop#1557).
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MC_DIR="$(cd -P "$HERE/.." && pwd)"
SCRIPTS_DIR="$(cd -P "$MC_DIR/.." && pwd)"
SUT="$MC_DIR/replay.sh"
STATS_SUT="$MC_DIR/stats.sh"
# Module-relative and physical, NOT `git rev-parse --show-toplevel`: in a
# dir-symlink composition (temperloop#1557) the module physically lives in a
# host repo's kernel/ SUBTREE, so rev-parse would return the HOST root — where
# the pipeline-* files this suite reads under $REPO_ROOT do not exist. In a
# plain kernel checkout or worktree the two derivations are identical.
REPO_ROOT="$(cd -P "$MC_DIR/../../.." && pwd)"

# shellcheck source=../../lib/portable-timeout.sh
. "$HERE/../../lib/portable-timeout.sh"

pass=0
total=0
ok() { pass=$((pass + 1)); echo "PASS: $1"; }
count() { total=$((total + 1)); }
fail() { echo "FAIL: $1" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-replay-preflight-XXXXXX")"
WORK="$(cd -P "$WORK" && pwd)"
trap 'chmod -R u+rwX "$WORK" 2>/dev/null; rm -rf "$WORK"' EXIT

# mutate_file <file> <old-literal-text> <new-literal-text> — exact, literal,
# single-occurrence replacement (see test_replay_isolation.sh's twin for the
# full rationale). Dies loudly if the old text is missing or not unique.
mutate_file() {
  local file="$1" old="$2" new="$3"
  MUT_OLD="$old" MUT_NEW="$new" perl -0777 -pi -e '
    my $o = $ENV{MUT_OLD};
    my $n = $ENV{MUT_NEW};
    my $count = () = /\Q$o\E/g;
    die "mutate_file: old text not found-or-not-unique (count=$count)\n" unless $count == 1;
    s/\Q$o\E/$n/;
  ' "$file"
}

# mk_mirror <dest> — a throwaway, symlink-backed mirror of workflows/scripts
# under <dest> (same helper as test_replay_score.sh's own, temperloop#1421),
# so a mutation proof can edit ONE real copy of replay.sh without ever
# writing into the checkout — in a vendoring overlay $SUT is a composed-tree
# SYMLINK into kernel/, and an in-place mutation (write-temp-then-rename-
# over-path) would replace the symlink with a forked regular file.
# Relative resolution (HERE/../build, HERE/stats.sh, etc.) all still work
# because the DIRECTORIES are real and only the leaves are links.
mk_mirror() {
  local d="$1" f b
  mkdir -p "$d/workflows/scripts/model-comparison"
  for f in "$SCRIPTS_DIR"/*; do
    b="$(basename "$f")"
    [ "$b" = "model-comparison" ] && continue
    ln -s "$f" "$d/workflows/scripts/$b"
  done
  for f in "$MC_DIR"/*; do
    ln -s "$f" "$d/workflows/scripts/model-comparison/$(basename "$f")"
  done
}

# unlink_and_copy <mirror-path> — swap one mirrored symlink for a real,
# editable copy of its target (same helper as test_replay_score.sh's own).
unlink_and_copy() {
  local p="$1" target
  target="$(cd -P "$(dirname "$p")" && pwd)/$(basename "$p")"
  local real; real="$(readlink "$target")"
  rm -f "$target"
  cp "$real" "$target"
  chmod u+w "$target"
}

# mk_corpus <file> <status>... — one JSON-lines record per status arg.
mk_corpus() {
  local file="$1"; shift
  : >"$file"
  local i=0 s
  for s in "$@"; do
    i=$((i + 1))
    jq -cn --argjson pr "$i" --arg st "$s" '{pr:$pr, status:$st}' >>"$file"
  done
}

# mk_quota_cache <file> <used-pct> [<resets-in-secs>] — a quota-gate.sh
# snapshot fixture; captured_at is "now" so the staleness guard never fires.
mk_quota_cache() {
  local file="$1" used="$2" resets_in="${3:-3600}"
  jq -cn --argjson u "$used" --argjson now "$(date +%s)" --argjson r "$resets_in" \
    '{captured_at:$now, five_hour:{used_percentage:$u, resets_at:($now+$r)}}' >"$file"
}

NOCACHE="$WORK/no-such-quota-cache.json"

# run_pf <env-assignments-string> -- <args...> — invoke preflight with the
# given env (a single string passed to `env`) plus a deterministic
# BUILD_QUOTA_CACHE pointing at a nonexistent file by default (fail-open,
# never stops the batch) unless the caller's env string overrides it.
# ...and a deterministically EMPTY attribution raw lake, so the per-replay
# figure is always the configured literal here (temperloop#1555). Without
# this the derivation would read the REAL checkout's meta/data/raw, and a
# developer host that has executed live replays would flip this whole suite
# into the derived arm — a suite that passes or fails depending on whose
# machine it runs on is not a measurement. The derivation itself is
# exercised in test_replay_preflight_derive.sh.
EMPTY_LAKE="$WORK/empty-lake"; mkdir -p "$EMPTY_LAKE"
run_pf() {
  env BUILD_QUOTA_CACHE="$NOCACHE" MODEL_USAGE_RAW_DIR="$EMPTY_LAKE" "$@"
}

# ═══════════════════════════════════════════════════════════════════════════
# SECTION A — eligible-N counting
# ═══════════════════════════════════════════════════════════════════════════

CORPUS_A="$WORK/corpus-a.jsonl"
mk_corpus "$CORPUS_A" eligible eligible flagged-eligible rejected rejected

# ---------------------------------------------------------------------------
# 1. eligible_n counts BOTH eligible and flagged-eligible, excluding
#    rejected (3 of 5 records here).
# ---------------------------------------------------------------------------
count
out="$(run_pf env REPLAY_PREFLIGHT_BATCH_CAP=100 REPLAY_PREFLIGHT_TOKENS_PER_REPLAY=10 \
  REPLAY_PREFLIGHT_CEILING_TOKENS=1000000 MODEL_COMPARISON_MIN_SAMPLE_N=1 \
  bash "$SUT" preflight --corpus-file "$CORPUS_A")"
[ "$(jq -r .outcome <<<"$out")" = "PREFLIGHT" ] || fail "1: expected PREFLIGHT, got: $out"
[ "$(jq -r .eligible_n <<<"$out")" = "3" ] || fail "1: expected eligible_n 3 (2 eligible + 1 flagged-eligible), got: $out"
ok "1 eligible_n counts eligible + flagged-eligible, excludes rejected"

# ---------------------------------------------------------------------------
# 2. A corpus with real records but ZERO eligible ones is a LEGITIMATE
#    computed zero (outcome PREFLIGHT), never CANNOT_EVALUATE — the fail-
#    closed floor is for input this command could not READ, not for a real
#    answer that happens to be zero.
# ---------------------------------------------------------------------------
count
CORPUS_ZERO="$WORK/corpus-zero.jsonl"
mk_corpus "$CORPUS_ZERO" rejected rejected
out="$(run_pf env REPLAY_PREFLIGHT_BATCH_CAP=100 REPLAY_PREFLIGHT_TOKENS_PER_REPLAY=10 \
  REPLAY_PREFLIGHT_CEILING_TOKENS=1000000 MODEL_COMPARISON_MIN_SAMPLE_N=1 \
  bash "$SUT" preflight --corpus-file "$CORPUS_ZERO")"
[ "$(jq -r .outcome <<<"$out")" = "PREFLIGHT" ] || fail "2: an all-rejected corpus should still PREFLIGHT (real zero), got: $out"
[ "$(jq -r .eligible_n <<<"$out")" = "0" ] || fail "2: expected eligible_n 0, got: $out"
[ "$(jq -r .significance_reachable <<<"$out")" = "false" ] || fail "2: eligible_n 0 must be unreachable: $out"
[ "$(jq -r .mde <<<"$out")" = "null" ] || fail "2: mde should be null when eligible_n is 0 (nothing to feed the primitive), got: $out"
ok "2 an all-rejected corpus (real eligible_n=0) is a computed PREFLIGHT result, not CANNOT_EVALUATE"

# ---------------------------------------------------------------------------
# 3. cost_basis is stated explicitly (cost-weighted-token-units, since
#    temperloop#1380 — the report producer's own unit string, not a raw
#    sum) — this module states no dollar figure
#    (docs/features/model-comparison.md's "stated cost basis"). The
#    preflight/report AGREEMENT itself is pinned in
#    test_replay_preflight_cost_unit.sh, which runs both surfaces; this
#    line only pins that the basis is stated at all.
# ---------------------------------------------------------------------------
count
[ "$(jq -r .cost_basis <<<"$out")" = "cost-weighted-token-units" ] || fail "3: expected cost_basis cost-weighted-token-units, got: $out"
ok "3 cost_basis is stated explicitly as cost-weighted-token-units (no dollar figure fabricated)"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION B — REPLAY_PREFLIGHT_BATCH_CAP wiring
# ═══════════════════════════════════════════════════════════════════════════

CORPUS_B="$WORK/corpus-b.jsonl"
mk_corpus "$CORPUS_B" eligible eligible eligible eligible eligible eligible eligible eligible eligible eligible

# ---------------------------------------------------------------------------
# 4-5. Two DISTINCT, non-default batch-cap values actually change planned_n
#      (proves the cap is READ from config, not hardcoded) — never pinned to
#      the shipped default (40).
# ---------------------------------------------------------------------------
count
out4="$(run_pf env REPLAY_PREFLIGHT_BATCH_CAP=3 REPLAY_PREFLIGHT_TOKENS_PER_REPLAY=10 \
  REPLAY_PREFLIGHT_CEILING_TOKENS=1000000 MODEL_COMPARISON_MIN_SAMPLE_N=1 \
  bash "$SUT" preflight --corpus-file "$CORPUS_B")"
[ "$(jq -r .eligible_n <<<"$out4")" = "10" ] || fail "4: expected eligible_n 10, got: $out4"
[ "$(jq -r .planned_n <<<"$out4")" = "3" ] || fail "4: batch cap 3 should cap planned_n to 3, got: $out4"
[ "$(jq -r .batch_cap_applied <<<"$out4")" = "true" ] || fail "4: batch_cap_applied should be true, got: $out4"
ok "4 REPLAY_PREFLIGHT_BATCH_CAP=3 caps planned_n to 3 (of 10 eligible)"

count
out5="$(run_pf env REPLAY_PREFLIGHT_BATCH_CAP=7 REPLAY_PREFLIGHT_TOKENS_PER_REPLAY=10 \
  REPLAY_PREFLIGHT_CEILING_TOKENS=1000000 MODEL_COMPARISON_MIN_SAMPLE_N=1 \
  bash "$SUT" preflight --corpus-file "$CORPUS_B")"
[ "$(jq -r .planned_n <<<"$out5")" = "7" ] || fail "5: batch cap 7 should cap planned_n to 7, got: $out5"
[ "$(jq -r .planned_n <<<"$out4")" != "$(jq -r .planned_n <<<"$out5")" ] || fail "5: two distinct cap values produced the SAME planned_n — not wired"
ok "5 a second, distinct batch-cap value (7) produces a DIFFERENT planned_n — genuinely wired, not hardcoded"

# ---------------------------------------------------------------------------
# 6. A cap larger than eligible_n does NOT pad planned_n up — planned_n
#    never exceeds the real eligible pool.
# ---------------------------------------------------------------------------
count
out6="$(run_pf env REPLAY_PREFLIGHT_BATCH_CAP=999 REPLAY_PREFLIGHT_TOKENS_PER_REPLAY=10 \
  REPLAY_PREFLIGHT_CEILING_TOKENS=1000000 MODEL_COMPARISON_MIN_SAMPLE_N=1 \
  bash "$SUT" preflight --corpus-file "$CORPUS_B")"
[ "$(jq -r .planned_n <<<"$out6")" = "10" ] || fail "6: planned_n should equal eligible_n (10) when the cap exceeds it, got: $out6"
[ "$(jq -r .batch_cap_applied <<<"$out6")" = "false" ] || fail "6: batch_cap_applied should be false when the cap doesn't bind, got: $out6"
ok "6 a batch cap above eligible_n does not bind (planned_n = eligible_n, batch_cap_applied=false)"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION C — REPLAY_PREFLIGHT_TOKENS_PER_REPLAY wiring + the cost formula
# ═══════════════════════════════════════════════════════════════════════════

# ---------------------------------------------------------------------------
# 7-9. estimated_total_tokens = planned_replays_n *
#      REPLAY_PREFLIGHT_TOKENS_PER_REPLAY — and planned_replays_n is
#      planned_n * arms_n, because every planned corpus record is replayed in
#      BOTH the baseline and the candidate arm (temperloop#1379). Two
#      distinct non-default per-replay estimates produce distinct totals over
#      the SAME planned_n (proves genuine multiplication by a config-read
#      value, not a hardcoded constant).
# ---------------------------------------------------------------------------
count
out7="$(run_pf env REPLAY_PREFLIGHT_BATCH_CAP=4 REPLAY_PREFLIGHT_TOKENS_PER_REPLAY=777 \
  REPLAY_PREFLIGHT_CEILING_TOKENS=1000000 MODEL_COMPARISON_MIN_SAMPLE_N=1 \
  bash "$SUT" preflight --corpus-file "$CORPUS_B")"
[ "$(jq -r .planned_n <<<"$out7")" = "4" ] || fail "7: expected planned_n 4, got: $out7"
[ "$(jq -r .planned_replays_n <<<"$out7")" = "8" ] || fail "7: expected planned_replays_n 8 (4 records x 2 arms), got: $out7"
[ "$(jq -r .estimated_total_tokens <<<"$out7")" = "6216" ] || fail "7: expected 4*2*777=6216, got: $out7"
[ "$(jq -r .estimated_cost <<<"$out7")" = "6216" ] || fail "7: estimated_cost should equal estimated_total_tokens under cost_basis=token_count, got: $out7"
ok "7 estimated_total_tokens = planned_replays_n * REPLAY_PREFLIGHT_TOKENS_PER_REPLAY (4 records x 2 arms x 777 = 6216)"

count
out8="$(run_pf env REPLAY_PREFLIGHT_BATCH_CAP=4 REPLAY_PREFLIGHT_TOKENS_PER_REPLAY=1234 \
  REPLAY_PREFLIGHT_CEILING_TOKENS=1000000 MODEL_COMPARISON_MIN_SAMPLE_N=1 \
  bash "$SUT" preflight --corpus-file "$CORPUS_B")"
[ "$(jq -r .estimated_total_tokens <<<"$out8")" = "9872" ] || fail "8: expected 4*2*1234=9872, got: $out8"
[ "$(jq -r .estimated_total_tokens <<<"$out7")" != "$(jq -r .estimated_total_tokens <<<"$out8")" ] \
  || fail "8: two distinct per-replay token estimates produced the SAME total — not wired"
ok "8 a second, distinct REPLAY_PREFLIGHT_TOKENS_PER_REPLAY value changes the total (not hardcoded)"

count
[ "$(jq -r .tokens_per_replay_estimate <<<"$out8")" = "1234" ] || fail "9: tokens_per_replay_estimate should echo the config value, got: $out8"
ok "9 tokens_per_replay_estimate echoes the configured per-replay figure"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION D — REPLAY_PREFLIGHT_CEILING_TOKENS: the ceiling actually STOPS a
# batch, with a mutation proof it is load-bearing.
# ═══════════════════════════════════════════════════════════════════════════

# ---------------------------------------------------------------------------
# 10. Under ceiling: stop:false, exit 0.
# ---------------------------------------------------------------------------
count
rc=0
out10="$(run_pf env REPLAY_PREFLIGHT_BATCH_CAP=10 REPLAY_PREFLIGHT_TOKENS_PER_REPLAY=100 \
  REPLAY_PREFLIGHT_CEILING_TOKENS=100000 MODEL_COMPARISON_MIN_SAMPLE_N=1 \
  bash "$SUT" preflight --corpus-file "$CORPUS_B")" || rc=$?
[ "$rc" -eq 0 ] || fail "10: expected exit 0 under ceiling, got rc=$rc: $out10"
[ "$(jq -r .ceiling_exceeded <<<"$out10")" = "false" ] || fail "10: expected ceiling_exceeded false: $out10"
[ "$(jq -r .stop <<<"$out10")" = "false" ] || fail "10: expected stop false: $out10"
ok "10 a batch under the ceiling proceeds (stop:false, exit 0)"

# ---------------------------------------------------------------------------
# 11. Over ceiling: a fixture batch that WOULD exceed the ceiling STOPS at
#     pre-flight — outcome still PREFLIGHT (fully reported, not swallowed),
#     but stop:true / ceiling_exceeded:true, and a NON-ZERO exit so any
#     caller orchestrating around this command sees "do not proceed".
# ---------------------------------------------------------------------------
count
rc=0
out11="$(run_pf env REPLAY_PREFLIGHT_BATCH_CAP=10 REPLAY_PREFLIGHT_TOKENS_PER_REPLAY=100 \
  REPLAY_PREFLIGHT_CEILING_TOKENS=50 MODEL_COMPARISON_MIN_SAMPLE_N=1 \
  bash "$SUT" preflight --corpus-file "$CORPUS_B")" || rc=$?
[ "$rc" -ne 0 ] || fail "11: expected non-zero exit when the ceiling is exceeded"
[ "$(jq -r .outcome <<<"$out11")" = "PREFLIGHT" ] || fail "11: outcome should still be PREFLIGHT (fully reported), got: $out11"
[ "$(jq -r .ceiling_exceeded <<<"$out11")" = "true" ] || fail "11: expected ceiling_exceeded true: $out11"
[ "$(jq -r .stop <<<"$out11")" = "true" ] || fail "11: expected stop true: $out11"
[ "$(jq -r .stop_reason <<<"$out11")" = "ceiling_exceeded" ] || fail "11: expected stop_reason ceiling_exceeded: $out11"
ok "11 a batch that would exceed the ceiling STOPS at pre-flight (stop:true, non-zero exit) — never partway through"

# --- mutation proof: the ceiling check never fires ------------------------
count
MIRROR_12="$WORK/mirror-12"
mk_mirror "$MIRROR_12"
SUT_12="$MIRROR_12/workflows/scripts/model-comparison/replay.sh"
unlink_and_copy "$SUT_12"
mutate_file "$SUT_12" \
  '  [ "$est_tokens" -gt "$REPLAY_PREFLIGHT_CEILING_TOKENS" ] && ceiling_exceeded=true' \
  '  [ "$est_tokens" -gt "$REPLAY_PREFLIGHT_CEILING_TOKENS" ] && ceiling_exceeded=false' \
  || fail "12m: mutation apply failed"
mut_rc=0
mut_out="$(run_pf env REPLAY_PREFLIGHT_BATCH_CAP=10 REPLAY_PREFLIGHT_TOKENS_PER_REPLAY=100 \
  REPLAY_PREFLIGHT_CEILING_TOKENS=50 MODEL_COMPARISON_MIN_SAMPLE_N=1 \
  bash "$SUT_12" preflight --corpus-file "$CORPUS_B")" || mut_rc=$?
rm -rf "$MIRROR_12"
[ "$mut_rc" -eq 0 ] || fail "12m: expected the mutated (disabled-ceiling) script to exit 0 despite being over budget, got rc=$mut_rc: $mut_out"
[ "$(jq -r .stop <<<"$mut_out")" = "false" ] || fail "12m: expected the mutated script to NOT stop an over-budget batch: $mut_out"
ok "12m MUTATION PROOF: disabling the ceiling comparison lets an over-budget batch proceed uncaught — mutation isolated to a \$WORK mirror copy, test 11 above (the real \$SUT) is unaffected"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION E — the quota-gate.sh consult (explicit scope, temperloop#1256)
# ═══════════════════════════════════════════════════════════════════════════

QUOTA_PAUSE="$WORK/quota-pause.json"
mk_quota_cache "$QUOTA_PAUSE" 95      # 5% remaining < default 10% pause threshold
QUOTA_HEALTHY="$WORK/quota-healthy.json"
mk_quota_cache "$QUOTA_HEALTHY" 20    # 80% remaining, well above pause threshold

# ---------------------------------------------------------------------------
# 13. quota-gate reports "pause" -> preflight STOPS (stop:true,
#     stop_reason:quota_paused, non-zero exit), even though the batch is
#     comfortably under the token ceiling.
# ---------------------------------------------------------------------------
count
rc=0
out13="$(env BUILD_QUOTA_CACHE="$QUOTA_PAUSE" REPLAY_PREFLIGHT_BATCH_CAP=10 \
  REPLAY_PREFLIGHT_TOKENS_PER_REPLAY=1 REPLAY_PREFLIGHT_CEILING_TOKENS=1000000 \
  MODEL_COMPARISON_MIN_SAMPLE_N=1 bash "$SUT" preflight --corpus-file "$CORPUS_B")" || rc=$?
[ "$rc" -ne 0 ] || fail "13: expected non-zero exit when quota-gate reports pause"
[ "$(jq -r .quota.action <<<"$out13")" = "pause" ] || fail "13: expected quota.action pause, got: $out13"
[ "$(jq -r .stop <<<"$out13")" = "true" ] || fail "13: expected stop true, got: $out13"
[ "$(jq -r .stop_reason <<<"$out13")" = "quota_paused" ] || fail "13: expected stop_reason quota_paused, got: $out13"
ok "13 quota-gate.sh reporting pause STOPS the batch even when well under the token ceiling"

# ---------------------------------------------------------------------------
# 14. quota-gate reports healthy remaining quota -> proceed (stop:false).
# ---------------------------------------------------------------------------
count
rc=0
out14="$(env BUILD_QUOTA_CACHE="$QUOTA_HEALTHY" REPLAY_PREFLIGHT_BATCH_CAP=10 \
  REPLAY_PREFLIGHT_TOKENS_PER_REPLAY=1 REPLAY_PREFLIGHT_CEILING_TOKENS=1000000 \
  MODEL_COMPARISON_MIN_SAMPLE_N=1 bash "$SUT" preflight --corpus-file "$CORPUS_B")" || rc=$?
[ "$rc" -eq 0 ] || fail "14: expected exit 0 on healthy quota, got rc=$rc: $out14"
[ "$(jq -r .quota.action <<<"$out14")" = "proceed" ] || fail "14: expected quota.action proceed, got: $out14"
[ "$(jq -r .stop <<<"$out14")" = "false" ] || fail "14: expected stop false, got: $out14"
ok "14 quota-gate.sh reporting healthy quota lets the batch proceed"

# ---------------------------------------------------------------------------
# 15. quota-gate.sh's own FAIL-OPEN contract is honored: an absent cache
#     (quota "unavailable") must NEVER stop a batch — a run must never stall
#     because the quota signal is absent (quota-gate.sh's own invariant).
# ---------------------------------------------------------------------------
count
rc=0
out15="$(run_pf env REPLAY_PREFLIGHT_BATCH_CAP=10 REPLAY_PREFLIGHT_TOKENS_PER_REPLAY=1 \
  REPLAY_PREFLIGHT_CEILING_TOKENS=1000000 MODEL_COMPARISON_MIN_SAMPLE_N=1 \
  bash "$SUT" preflight --corpus-file "$CORPUS_B")" || rc=$?
[ "$rc" -eq 0 ] || fail "15: expected exit 0 when quota is unavailable (fail open), got rc=$rc: $out15"
[ "$(jq -r .quota.action <<<"$out15")" = "unavailable" ] || fail "15: expected quota.action unavailable, got: $out15"
[ "$(jq -r .stop <<<"$out15")" = "false" ] || fail "15: an unavailable quota signal must never stop a batch (fail open): $out15"
ok "15 quota-gate.sh 'unavailable' (fail open) never stops a batch — only an explicit pause does"

# --- mutation proof: the quota-gate call is dropped (never consulted) -----
count
MIRROR_16="$WORK/mirror-16"
mk_mirror "$MIRROR_16"
SUT_16="$MIRROR_16/workflows/scripts/model-comparison/replay.sh"
unlink_and_copy "$SUT_16"
mutate_file "$SUT_16" \
  '  quota_json="$(bash "$QUOTA_GATE_SH" 2>/dev/null)"' \
  '  quota_json="{\"action\":\"proceed\"}"' \
  || fail "16m: mutation apply failed"
mut_rc=0
mut_out="$(env BUILD_QUOTA_CACHE="$QUOTA_PAUSE" REPLAY_PREFLIGHT_BATCH_CAP=10 \
  REPLAY_PREFLIGHT_TOKENS_PER_REPLAY=1 REPLAY_PREFLIGHT_CEILING_TOKENS=1000000 \
  MODEL_COMPARISON_MIN_SAMPLE_N=1 bash "$SUT_16" preflight --corpus-file "$CORPUS_B")" || mut_rc=$?
rm -rf "$MIRROR_16"
[ "$mut_rc" -eq 0 ] || fail "16m: expected the mutated (gate-bypassing) script to exit 0 despite a paused quota cache, got rc=$mut_rc: $mut_out"
[ "$(jq -r .stop <<<"$mut_out")" = "false" ] || fail "16m: expected the mutated script to NOT stop despite the quota-pause fixture: $mut_out"
ok "16m MUTATION PROOF: removing the quota-gate.sh call (hardcoding proceed) lets a quota-paused batch run uncaught — mutation isolated to a \$WORK mirror copy, test 13 above (the real \$SUT) is unaffected"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION F — significance reachability, genuinely consuming stats.sh's mde
# ═══════════════════════════════════════════════════════════════════════════

CORPUS_SMALL="$WORK/corpus-small.jsonl"
mk_corpus "$CORPUS_SMALL" eligible eligible eligible          # eligible_n=3
CORPUS_BIG="$WORK/corpus-big.jsonl"
mk_corpus "$CORPUS_BIG" eligible eligible eligible eligible eligible \
                        eligible eligible eligible eligible eligible \
                        eligible eligible                     # eligible_n=12

# ---------------------------------------------------------------------------
# 17. eligible_n BELOW MODEL_COMPARISON_MIN_SAMPLE_N -> significance
#     unreachable, with a stated reason — never silently omitted.
# ---------------------------------------------------------------------------
count
out17="$(run_pf env REPLAY_PREFLIGHT_BATCH_CAP=100 REPLAY_PREFLIGHT_TOKENS_PER_REPLAY=1 \
  REPLAY_PREFLIGHT_CEILING_TOKENS=1000000 REPLAY_PREFLIGHT_ASSUMED_STDDEV_TOKENS=500 \
  MODEL_COMPARISON_MIN_SAMPLE_N=20 \
  bash "$SUT" preflight --corpus-file "$CORPUS_SMALL")"
[ "$(jq -r .eligible_n <<<"$out17")" = "3" ] || fail "17: expected eligible_n 3, got: $out17"
[ "$(jq -r .significance_reachable <<<"$out17")" = "false" ] || fail "17: expected significance_reachable false (3 < 20): $out17"
[ -n "$(jq -r .reachable_reason <<<"$out17")" ] || fail "17: expected a non-empty reachable_reason: $out17"
[ "$(jq -r .mde <<<"$out17")" != "null" ] || fail "17: mde should still be disclosed (informative) even below the floor: $out17"
ok "17 eligible_n below MODEL_COMPARISON_MIN_SAMPLE_N -> significance_reachable:false with a stated reason (mde still disclosed)"

# ---------------------------------------------------------------------------
# 18. eligible_n AT/ABOVE MODEL_COMPARISON_MIN_SAMPLE_N -> reachable:true.
# ---------------------------------------------------------------------------
count
out18="$(run_pf env REPLAY_PREFLIGHT_BATCH_CAP=100 REPLAY_PREFLIGHT_TOKENS_PER_REPLAY=1 \
  REPLAY_PREFLIGHT_CEILING_TOKENS=1000000 REPLAY_PREFLIGHT_ASSUMED_STDDEV_TOKENS=500 \
  MODEL_COMPARISON_MIN_SAMPLE_N=12 \
  bash "$SUT" preflight --corpus-file "$CORPUS_BIG")"
[ "$(jq -r .eligible_n <<<"$out18")" = "12" ] || fail "18: expected eligible_n 12, got: $out18"
[ "$(jq -r .significance_reachable <<<"$out18")" = "true" ] || fail "18: expected significance_reachable true (12 >= 12): $out18"
ok "18 eligible_n at MODEL_COMPARISON_MIN_SAMPLE_N -> significance_reachable:true"

# ---------------------------------------------------------------------------
# 19. The disclosed .mde figure is BYTE-IDENTICAL to a DIRECT stats.sh mde
#     call at the same n/stddev — proving preflight genuinely CONSUMES the
#     primitive rather than computing a second, independent MDE.
# ---------------------------------------------------------------------------
count
direct_mde="$(bash "$STATS_SUT" mde --n 12 --stddev 500)"
embedded_mde="$(jq -c .mde <<<"$out18")"
direct_mde_c="$(jq -c . <<<"$direct_mde")"
[ "$embedded_mde" = "$direct_mde_c" ] || fail "19: preflight's embedded mde ($embedded_mde) does not byte-match a direct stats.sh mde call ($direct_mde_c) at the same n/stddev — suggests a second, independent computation"
ok "19 preflight's disclosed MDE is byte-identical to a direct stats.sh mde call — genuinely consumes the primitive, never re-derives it"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION G — FAIL CLOSED: absent / unreadable / empty / malformed input, and
# an unreachable stats.sh primitive
# ═══════════════════════════════════════════════════════════════════════════

# ---------------------------------------------------------------------------
# 20. Missing --corpus-file argument entirely.
# ---------------------------------------------------------------------------
count
rc=0
out20="$(run_pf bash "$SUT" preflight 2>"$WORK/pf-stderr.txt")" || rc=$?
[ "$rc" -ne 0 ] || fail "20: expected non-zero exit with no --corpus-file at all"
[ "$(jq -r .outcome <<<"$out20" 2>/dev/null)" = "CANNOT_EVALUATE" ] || fail "20: expected CANNOT_EVALUATE, got: $out20"
case "$(cat "$WORK/pf-stderr.txt")" in
  *"CANNOT EVALUATE"*) ;;
  *) fail "20: expected a distinct 'CANNOT EVALUATE' line on stderr, got: $(cat "$WORK/pf-stderr.txt")" ;;
esac
ok "20 FAIL CLOSED: no --corpus-file given -> CANNOT_EVALUATE, non-zero"

# ---------------------------------------------------------------------------
# 21. Nonexistent corpus-file path.
# ---------------------------------------------------------------------------
count
rc=0
out21="$(run_pf bash "$SUT" preflight --corpus-file "$WORK/does-not-exist.jsonl" 2>"$WORK/pf-stderr.txt")" || rc=$?
[ "$rc" -ne 0 ] || fail "21: expected non-zero exit for a nonexistent corpus file"
[ "$(jq -r .outcome <<<"$out21" 2>/dev/null)" = "CANNOT_EVALUATE" ] || fail "21: expected CANNOT_EVALUATE, got: $out21"
case "$out21" in *'"eligible_n"'*) fail "21: FAIL-OPEN — a computed eligible_n leaked out for input that was never read: $out21" ;; esac
case "$(cat "$WORK/pf-stderr.txt")" in
  *"CANNOT EVALUATE"*) ;;
  *) fail "21: expected a distinct 'CANNOT EVALUATE' line on stderr, got: $(cat "$WORK/pf-stderr.txt")" ;;
esac
ok "21 FAIL CLOSED: absent corpus file -> CANNOT_EVALUATE, non-zero, no computed eligible_n leaks out"

# ---------------------------------------------------------------------------
# 22. Unreadable corpus-file — a directory in place of a regular file (the
#     portable stand-in for a permission-denied file, robust under a
#     root-run test process where chmod 000 would not actually deny access).
# ---------------------------------------------------------------------------
count
mkdir -p "$WORK/a-directory"
rc=0
out22="$(run_pf bash "$SUT" preflight --corpus-file "$WORK/a-directory" 2>"$WORK/pf-stderr.txt")" || rc=$?
[ "$rc" -ne 0 ] || fail "22: expected non-zero exit when --corpus-file is a directory"
[ "$(jq -r .outcome <<<"$out22" 2>/dev/null)" = "CANNOT_EVALUATE" ] || fail "22: expected CANNOT_EVALUATE, got: $out22"
case "$(cat "$WORK/pf-stderr.txt")" in
  *"CANNOT EVALUATE"*) ;;
  *) fail "22: expected a distinct 'CANNOT EVALUATE' line on stderr, got: $(cat "$WORK/pf-stderr.txt")" ;;
esac
ok "22 FAIL CLOSED: --corpus-file is a directory (unreadable-as-a-file) -> CANNOT_EVALUATE, non-zero"

# ---------------------------------------------------------------------------
# 23. Empty corpus file (0 bytes, zero records).
# ---------------------------------------------------------------------------
count
EMPTY_FILE="$WORK/empty.jsonl"
: >"$EMPTY_FILE"
rc=0
out23="$(run_pf bash "$SUT" preflight --corpus-file "$EMPTY_FILE" 2>"$WORK/pf-stderr.txt")" || rc=$?
[ "$rc" -ne 0 ] || fail "23: expected non-zero exit for an empty corpus file"
[ "$(jq -r .outcome <<<"$out23" 2>/dev/null)" = "CANNOT_EVALUATE" ] || fail "23: expected CANNOT_EVALUATE, got: $out23"
case "$(cat "$WORK/pf-stderr.txt")" in
  *"CANNOT EVALUATE"*) ;;
  *) fail "23: expected a distinct 'CANNOT EVALUATE' line on stderr, got: $(cat "$WORK/pf-stderr.txt")" ;;
esac
ok "23 FAIL CLOSED: empty corpus file (0 records) -> CANNOT_EVALUATE, non-zero"

# ---------------------------------------------------------------------------
# 24. Malformed corpus file: one good record followed by an unparseable
#     line. The WHOLE file must CANNOT_EVALUATE — the good record's
#     eligible-N must NEVER leak out as if the bad line were silently
#     skipped (that would under-report eligible-N off input never fully
#     read, the exact fail-open shape this item guards against).
# ---------------------------------------------------------------------------
count
BAD_FILE="$WORK/malformed.jsonl"
{
  jq -cn '{pr:1, status:"eligible"}'
  printf 'THIS IS NOT JSON\n'
} >"$BAD_FILE"
rc=0
out24="$(run_pf bash "$SUT" preflight --corpus-file "$BAD_FILE" 2>"$WORK/pf-stderr.txt")" || rc=$?
[ "$rc" -ne 0 ] || fail "24: expected non-zero exit for a malformed corpus file"
[ "$(jq -r .outcome <<<"$out24" 2>/dev/null)" = "CANNOT_EVALUATE" ] || fail "24: expected CANNOT_EVALUATE, got: $out24"
case "$out24" in *'"eligible_n":1'*) fail "24: FAIL-OPEN — the good record's eligible_n leaked out despite a later malformed line: $out24" ;; esac
case "$(cat "$WORK/pf-stderr.txt")" in
  *"CANNOT EVALUATE"*) ;;
  *) fail "24: expected a distinct 'CANNOT EVALUATE' line on stderr, got: $(cat "$WORK/pf-stderr.txt")" ;;
esac
ok "24 FAIL CLOSED: a malformed line CANNOT_EVALUATEs the whole file — the good record's eligible_n never leaks out"

# ---------------------------------------------------------------------------
# 25. The stats.sh mde primitive itself is unreachable (STATS_SH points at a
#     nonexistent script) -> CANNOT_EVALUATE, non-zero — never a fabricated
#     mde/reachability figure for a primitive this command couldn't reach.
# ---------------------------------------------------------------------------
count
MIRROR_25="$WORK/mirror-25"
mk_mirror "$MIRROR_25"
SUT_25="$MIRROR_25/workflows/scripts/model-comparison/replay.sh"
unlink_and_copy "$SUT_25"
mutate_file "$SUT_25" \
  'STATS_SH="$HERE/stats.sh"' \
  'STATS_SH="$HERE/stats.sh.DOES-NOT-EXIST"' \
  || fail "25: mutation apply failed"
rc=0
out25="$(run_pf env REPLAY_PREFLIGHT_BATCH_CAP=100 REPLAY_PREFLIGHT_TOKENS_PER_REPLAY=1 \
  REPLAY_PREFLIGHT_CEILING_TOKENS=1000000 MODEL_COMPARISON_MIN_SAMPLE_N=1 \
  bash "$SUT_25" preflight --corpus-file "$CORPUS_A" 2>"$WORK/pf-stderr.txt")" || rc=$?
rm -rf "$MIRROR_25"
[ "$rc" -ne 0 ] || fail "25: expected non-zero exit when the stats.sh primitive is unreachable"
[ "$(jq -r .outcome <<<"$out25" 2>/dev/null)" = "CANNOT_EVALUATE" ] || fail "25: expected CANNOT_EVALUATE, got: $out25"
case "$(cat "$WORK/pf-stderr.txt")" in
  *"CANNOT EVALUATE"*) ;;
  *) fail "25: expected a distinct 'CANNOT EVALUATE' line on stderr, got: $(cat "$WORK/pf-stderr.txt")" ;;
esac
ok "25 FAIL CLOSED: the stats.sh mde primitive unreachable -> CANNOT_EVALUATE, non-zero (mutation isolated to a \$WORK mirror copy — test 19 above, run against the real \$SUT, is unaffected)"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION H — operator-initiated only: no scheduled/cron/autonomous entry
# point references replay.sh (docs/features/model-comparison.md "Inert by
# design", ADR 0027)
# ═══════════════════════════════════════════════════════════════════════════

SCHED_FILES="$REPO_ROOT/workflows/scripts/build/pipeline-cron.sh
$REPO_ROOT/workflows/scripts/build/pipeline-tick.sh
$REPO_ROOT/workflows/scripts/build/pipeline-drive.sh
$REPO_ROOT/workflows/scripts/build/pipeline-schedule-gate.sh"

# scan_for_autonomous_replay_wiring <file> — returns 0 (found) if the file
# references replay.sh / the model-comparison replay module / its own
# preflight settings; 1 (clean) otherwise. The one detector both the
# real-tree assertion (26) and the mutation proof (26m) share, so the two
# can never silently drift apart.
scan_for_autonomous_replay_wiring() {
  grep -Eq 'replay\.sh|model-comparison/replay|REPLAY_PREFLIGHT' "$1"
}

# ---------------------------------------------------------------------------
# 26. None of the pipeline's real autonomous/cron entry points reference
#     replay.sh today — replay batches stay operator-initiated only.
# ---------------------------------------------------------------------------
count
found=0
while IFS= read -r f; do
  [ -n "$f" ] || continue
  [ -f "$f" ] || fail "26: expected scheduled-entry-point file missing: $f"
  scan_for_autonomous_replay_wiring "$f" && found=1
done <<<"$SCHED_FILES"
[ "$found" -eq 0 ] || fail "26: a scheduled/cron/autonomous entry point references replay.sh — replay batches must stay operator-initiated only"
ok "26 no scheduled/cron/autonomous entry point (pipeline-cron/tick/drive/schedule-gate.sh) references replay.sh"

# --- mutation proof: the detector itself would catch a real wiring attempt
#     (exercised against a THROWAWAY COPY — this suite never edits the real
#     pipeline driver files, which is the whole point of the invariant it's
#     proving). ------------------------------------------------------------
count
SYNTH="$WORK/synthetic-pipeline-tick.sh"
cp "$REPO_ROOT/workflows/scripts/build/pipeline-tick.sh" "$SYNTH"
printf '\n# TEST-INJECTED: autonomously invoke replay.sh preflight on every tick\n' >>"$SYNTH"
scan_for_autonomous_replay_wiring "$SYNTH" \
  || fail "26m: MUTATION PROOF FAILED — the detector did not catch an injected replay.sh reference in a synthetic copy of pipeline-tick.sh"
ok "26m MUTATION PROOF: the same detector used in test 26 DOES catch an injected autonomous replay.sh reference (proven against a throwaway copy, never the real file)"

# ═══════════════════════════════════════════════════════════════════════════
# SECTION I — hard constraint: no shift-2-no-op infinite loop on a trailing
# flag with no value (fleet-wide #1342)
# ═══════════════════════════════════════════════════════════════════════════

# ---------------------------------------------------------------------------
# 27. A trailing --corpus-file with no value fails fast, bounded.
# ---------------------------------------------------------------------------
count
rc=0
run_with_timeout 5 bash "$SUT" preflight --corpus-file >/dev/null 2>&1 || rc=$?
[ "$rc" -ne 0 ] || fail "27: preflight --corpus-file (trailing, no value) should fail, got rc=0"
[ "$rc" -ne 137 ] || fail "27: preflight --corpus-file (trailing, no value) HUNG (timed out) instead of failing fast"
ok "27 a trailing --corpus-file with no value fails fast and bounded, never an infinite shift-2-no-op loop"

echo "---"
echo "$pass/$total tests passed"
[ "$pass" -eq "$total" ] || fail "only $pass of $total tests passed"
