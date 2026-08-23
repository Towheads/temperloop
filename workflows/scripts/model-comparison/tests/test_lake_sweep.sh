#!/usr/bin/env bash
#
# test_lake_sweep.sh — the PRODUCTION LAKE's integrity (temperloop#1747), in
# two halves that are the same defect from opposite ends:
#
#   WRITER  — a recorded/stub replay must not put fixture records into the
#             repo's own attribution lake in the first place. Covered
#             BEHAVIOURALLY in test_replay_score.sh section L, which drives a
#             real `replay.sh execute` with the lake unset; asserting it here
#             would only have been a grep over replay.sh's source, which is the
#             kind of test that passes while the behaviour is broken.
#   SWEEPER — residue already on disk must be removable, safely (this file)
#
# The script DELETES LINES from an append-only telemetry stream, so the
# properties worth defending are not "does it find residue" but the ones that
# bound the damage when it is wrong:
#
#   * a real record is never removed
#   * an unparseable line is never removed (that is evidence of a DIFFERENT
#     problem, and silently tidying it away destroys it)
#   * nothing is written without --apply
#   * the original survives every rewrite
#
# Plain mktemp-fixture style; nothing here touches the repo's own lake.
set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUT="$HERE/../lake-sweep.sh"

pass=0; total=0
ok()    { pass=$((pass + 1)); printf 'PASS: %s\n' "$1"; }
count() { total=$((total + 1)); }
fail()  { printf 'FAIL: %s\n' "$1" >&2; exit 1; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/test-lake-sweep.XXXXXX")" || exit 1
trap 'rm -rf "$WORK"' EXIT

LAKE="$WORK/lake"; mkdir -p "$LAKE"
F="$LAKE/model-usage-2026-08.jsonl"

rec() {  # rec <model> [seat]
  jq -cn --arg m "$1" --arg s "${2:-replay-candidate}" \
    '{schema_version:"1", ts:"2026-08-14T00:00:00Z", seat:$s, model:$m,
      provider:"anthropic", usage_source:"cli-envelope",
      tokens:{input:1,output:1,cache_read:0,cache_creation:0},
      weighted_units:6, duration_ms:1, outcome_ref:"pr:1"}'
}

mklake() {
  : >"$F"
  rec claude-opus-5            >>"$F"
  rec recorded-stub-model      >>"$F"
  rec claude-fable-5           >>"$F"
  rec recorded-stub-judge replay-judge >>"$F"
  rec unknown                  >>"$F"
  printf 'this line is not json at all\n' >>"$F"
}

sweep() { env MODEL_USAGE_RAW_DIR="$LAKE" bash "$SUT" "$@"; }

# ── 1. dry run finds residue and writes NOTHING ────────────────────────────
count
mklake
before="$(shasum -a 256 "$F" | awk '{print $1}')"
out="$(sweep --json)"
[ "$(jq -r '.fixture_residue_n' <<<"$out")" = "2" ] \
  || fail "1: expected 2 fixture records, got $(jq -r '.fixture_residue_n' <<<"$out")"
[ "$(jq -r '.applied' <<<"$out")" = "false" ] || fail "1: a bare run must not report applied"
[ "$(shasum -a 256 "$F" | awk '{print $1}')" = "$before" ] \
  || fail "1: the dry run MODIFIED the lake — it must write nothing without --apply"
ok "1 a dry run reports the residue and leaves the lake byte-identical"

# ── 2. --apply removes exactly the residue ─────────────────────────────────
count
sweep --apply >/dev/null
[ "$(wc -l <"$F" | tr -d ' ')" = "4" ] \
  || fail "2: expected 4 surviving lines, got $(wc -l <"$F"): $(cat "$F")"
grep -F 'recorded-stub-model' "$F" >/dev/null && fail "2: a fixture record survived the sweep"
grep -F 'recorded-stub-judge' "$F" >/dev/null && fail "2: a fixture judge record survived the sweep"
ok "2 --apply removes exactly the fixture records"

# ── 3. REAL records survive — including 'unknown' ──────────────────────────
# `unknown` is what the emitter writes when a live model could not be resolved
# (temperloop#1643). It is a REAL record about a REAL call and must never be
# swept: it is the honest-degradation case, not fixture output.
count
for m in claude-opus-5 claude-fable-5 unknown; do
  grep -F "\"$m\"" "$F" >/dev/null || fail "3: the real record for $m was removed"
done
ok "3 real records survive, including the 'unknown' honest-degradation record"

# ── 4. an unparseable line is KEPT ─────────────────────────────────────────
count
grep -F 'this line is not json at all' "$F" >/dev/null \
  || fail "4: the unparseable line was dropped — that is evidence of a different problem, not residue to tidy"
ok "4 an unparseable line survives the sweep rather than being silently discarded"

# ── 5. the original is preserved beside the rewrite ────────────────────────
count
[ -f "$F.pre-sweep-0.bak" ] || fail "5: no .pre-sweep-0.bak was left beside the rewritten file"
[ "$(wc -l <"$F.pre-sweep-0.bak" | tr -d ' ')" = "6" ] \
  || fail "5: the backup does not hold the original 6 lines"
ok "5 the pre-sweep original is kept beside the rewritten file"

# ── 6. a clean lake is not an error, and is a no-op ────────────────────────
count
clean_before="$(shasum -a 256 "$F" | awk '{print $1}')"
rc=0; sweep --apply >/dev/null || rc=$?
[ "$rc" -eq 0 ] || fail "6: sweeping an already-clean lake must exit 0, got $rc"
[ "$(shasum -a 256 "$F" | awk '{print $1}')" = "$clean_before" ] \
  || fail "6: sweeping a clean lake rewrote it anyway"
[ -f "$F.pre-sweep-1.bak" ] && fail "6: a clean lake must not accumulate backups"
ok "6 sweeping an already-clean lake is a no-op that exits 0 and leaves no new backup"

# ── 7. the patterns come from the SAME setting the derive filter reads ─────
# If these two ever diverge, "excluded from the pre-flight basis" and "swept
# from the lake" would silently mean different sets of records.
count
mklake
out="$(env MODEL_USAGE_RAW_DIR="$LAKE" REPLAY_PREFLIGHT_STUB_MODEL_PATTERNS="claude-opus-*" \
  bash "$SUT" --json)"
[ "$(jq -r '.fixture_residue_n' <<<"$out")" = "1" ] \
  || fail "7: the sweep does not honour REPLAY_PREFLIGHT_STUB_MODEL_PATTERNS, got $(jq -r '.fixture_residue_n' <<<"$out")"
[ "$(jq -r '.patterns | join(" ")' <<<"$out")" = "claude-opus-*" ] \
  || fail "7: the sweep must publish the patterns it actually used"
ok "7 the sweep reads REPLAY_PREFLIGHT_STUB_MODEL_PATTERNS — the same setting the pre-flight derive filter reads — and publishes it"

# ── 8. an absent lake is an ERROR, not a silent clean bill of health ───────
count
rc=0
env MODEL_USAGE_RAW_DIR="$WORK/no-such-lake" bash "$SUT" >/dev/null 2>&1 || rc=$?
[ "$rc" -eq 1 ] || fail "8: an absent lake must exit 1, got $rc"
ok "8 an absent lake directory is reported as an error, never as 'clean'"

printf '\ntest_lake_sweep.sh: %d/%d checks passed\n' "$pass" "$total"
[ "$pass" -eq "$total" ] || exit 1
