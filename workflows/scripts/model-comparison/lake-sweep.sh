#!/usr/bin/env bash
#
# lake-sweep.sh — remove FIXTURE residue from the attribution raw lake
# (temperloop#1747, epic #1225, ADR 0026).
#
# ── WHY THIS EXISTS ────────────────────────────────────────────────────────
# A stubbed replay emits a real attribution record, and before temperloop#1747
# a recorded run with no MODEL_USAGE_RAW_DIR wrote it into the repo's own
# production lake. Those records are indistinguishable from live spend to
# everything downstream, and three consumers read them as observed cost:
#
#   * `replay.sh preflight` prices a batch off them (temperloop#1657)
#   * `validate-model-usage-emit.sh` REJECTS them on MODEL-ENUM, taking
#     test_model_usage_emit.sh down with it — two gates red
#   * `test_replay_preflight.sh`'s verdict changes with the lake's contents
#     (temperloop#1642)
#
# replay.sh no longer writes them. This is the other half: getting the ones
# already on disk OUT, on a host that has been running the harness for months.
#
# ── WHAT COUNTS AS RESIDUE ─────────────────────────────────────────────────
# A record whose `model` matches REPLAY_PREFLIGHT_STUB_MODEL_PATTERNS — the
# SAME setting the pre-flight derive filter reads, deliberately, so "excluded
# from the basis" and "swept from the lake" can never mean two different sets.
#
# ── SAFETY ─────────────────────────────────────────────────────────────────
# DRY RUN BY DEFAULT. This deletes lines from an append-only telemetry stream,
# so `--apply` is required to write anything, and the original file is kept
# beside the new one as `<name>.pre-sweep-<n>.bak` rather than replaced in
# place. A line that does not parse as JSON is KEPT, never dropped: this
# script's job is removing fixture records, not tidying a corrupt file, and
# silently discarding an unparseable line would destroy evidence of a
# different problem.
#
# ── USAGE ──────────────────────────────────────────────────────────────────
#   lake-sweep.sh                       # dry run over the default lake
#   lake-sweep.sh --apply               # rewrite, keeping a .bak
#   lake-sweep.sh --lake-dir <path>     # a different lake
#   lake-sweep.sh --json                # machine-readable summary
#
# Exit 0 whether or not residue was found (a clean lake is not an error).
# Exit 1 only when the lake cannot be read or a rewrite fails.
set -uo pipefail

HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -P "$HERE/../../.." && pwd)"

BUILD_CONFIG="$REPO_ROOT/workflows/scripts/build/build.config.sh"
# shellcheck source=../build/build.config.sh
[ -f "$BUILD_CONFIG" ] && . "$BUILD_CONFIG"
: "${REPLAY_PREFLIGHT_STUB_MODEL_PATTERNS:=recorded-* stub-* *-stub-model *-stub}"

lake_dir="${MODEL_USAGE_RAW_DIR:-$REPO_ROOT/meta/data/raw}"
apply=0
as_json=0
while [ $# -gt 0 ]; do
  case "$1" in
    --apply) apply=1; shift ;;
    --json)  as_json=1; shift ;;
    --lake-dir)
      [ $# -ge 2 ] || { echo "lake-sweep.sh: --lake-dir requires a path" >&2; exit 1; }
      lake_dir="$2"; shift 2 ;;
    -h|--help)
      awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
      exit 0 ;;
    *) echo "lake-sweep.sh: unknown argument $1" >&2; exit 1 ;;
  esac
done

command -v jq >/dev/null 2>&1 || { echo "lake-sweep.sh: jq not found" >&2; exit 1; }
[ -d "$lake_dir" ] || { echo "lake-sweep.sh: no lake directory at $lake_dir" >&2; exit 1; }

# The same glob-safe split replay.sh uses: the values ARE globs, so an unquoted
# expansion would pathname-expand them against the cwd (temperloop#1657).
_pats=()
IFS=' ' read -r -a _pats <<<"${REPLAY_PREFLIGHT_STUB_MODEL_PATTERNS:-}"
pat_json="$(printf '%s\n' ${_pats[@]+"${_pats[@]}"} | jq -R -s 'split("\n") | map(select(length > 0))')"
[ -n "$pat_json" ] || pat_json='[]'

total_seen=0
total_residue=0
files_touched=0
report=""

for f in "$lake_dir"/model-usage-*.jsonl; do
  [ -f "$f" ] && [ -r "$f" ] || continue
  seen="$(wc -l <"$f" | tr -d ' ')"
  residue="$(jq -R --argjson pats "$pat_json" '
    def is_stub: . as $m
      | if $m == null then false
        else (($pats | map(. as $p | select($m | test("^" + ($p | gsub("\\."; "\\.") | gsub("\\*"; ".*")) + "$"))) | length) > 0)
        end;
    (fromjson? // null) as $r
    | if $r == null then empty
      elif (($r.model // null) | is_stub) then 1
      else empty end' <"$f" | wc -l | tr -d ' ')"
  total_seen=$((total_seen + seen))
  total_residue=$((total_residue + residue))
  [ "$residue" -gt 0 ] || continue
  report="$report$(printf '\n  %s: %s of %s record(s) are fixture residue' "$(basename "$f")" "$residue" "$seen")"
  [ "$apply" -eq 1 ] || continue

  # An UNPARSEABLE line is kept. See § SAFETY.
  tmp="$(mktemp "${TMPDIR:-/tmp}/lake-sweep.XXXXXX")" || exit 1
  jq -R --argjson pats "$pat_json" '
    def is_stub: . as $m
      | if $m == null then false
        else (($pats | map(. as $p | select($m | test("^" + ($p | gsub("\\."; "\\.") | gsub("\\*"; ".*")) + "$"))) | length) > 0)
        end;
    . as $line
    | (fromjson? // null) as $r
    | if $r == null then $line
      elif (($r.model // null) | is_stub) then empty
      else $line end' -r <"$f" >"$tmp" || { rm -f "$tmp"; echo "lake-sweep.sh: rewrite failed for $f" >&2; exit 1; }
  n=0
  while [ -e "$f.pre-sweep-$n.bak" ]; do n=$((n + 1)); done
  cp "$f" "$f.pre-sweep-$n.bak" || { rm -f "$tmp"; exit 1; }
  mv "$tmp" "$f" || { echo "lake-sweep.sh: could not replace $f" >&2; exit 1; }
  files_touched=$((files_touched + 1))
done

if [ "$as_json" -eq 1 ]; then
  jq -cn --arg dir "$lake_dir" --argjson seen "$total_seen" --argjson residue "$total_residue" \
    --argjson touched "$files_touched" --argjson applied "$apply" --argjson pats "$pat_json" \
    '{lake_dir:$dir, records_seen:$seen, fixture_residue_n:$residue,
      files_rewritten:$touched, applied:($applied == 1), patterns:$pats}'
  exit 0
fi

if [ "$total_residue" -eq 0 ]; then
  printf 'lake-sweep: clean — no fixture residue in %s (%s record(s) scanned)\n' "$lake_dir" "$total_seen"
  exit 0
fi
printf 'lake-sweep: %s fixture record(s) of %s in %s%s\n' "$total_residue" "$total_seen" "$lake_dir" "$report"
if [ "$apply" -eq 1 ]; then
  printf 'lake-sweep: rewrote %s file(s); the original of each is beside it as .pre-sweep-<n>.bak\n' "$files_touched"
else
  printf 'lake-sweep: DRY RUN — nothing written. Re-run with --apply to remove them.\n'
fi
exit 0
