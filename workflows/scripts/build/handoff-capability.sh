#!/usr/bin/env bash
#
# handoff-capability.sh — make a DROPPED orchestrator->engine hand-off key
# DETECTABLE, before the engine is invoked (temperloop#2018).
#
# THE SEAM THIS GUARDS. All three drivers — /build (build.md Step 3), /sweep
# (sweep.md Step 0.3 + Phase 2) and /fix (fix.md Step 0 item 3) — invoke the
# SAME engine by a hardcoded installed path (`$HOME/.claude/workflows/
# build-level.mjs`) and hand it a JSON `input` object. That hand-off is
# ADDITIVE by design: `build-level.mjs` falls back to an in-file default for
# any key it does not find, so a newly-wired key can never regress an
# un-migrated caller. That property is correct and this script does not
# change it — it adds DETECTION, not a gate.
#
# What the additive design costs is that the converse is silent too. A STALE
# installed engine — or a consuming repo's older VENDORED copy — simply
# ignores a key a current orchestrator passes, with no signal on either side.
# Observed: an installed copy 18 days behind carried zero `reviewerRoutingTsv`
# support, so following the driver spec literally dropped the key and fell
# back to the exact agent relay the run in flight was fixing.
#
# HOW IT DETECTS. `build-level.mjs` declares the top-level `input.*` keys it
# understands in a sentinel-delimited block (`HANDOFF-CAPABILITIES-BEGIN` …
# `HANDOFF-CAPABILITIES-END`; that file's own "hand-off capability
# declaration" comment owns the rationale). This script reads that block
# TEXTUALLY out of whatever engine file it is pointed at and set-differences
# it against the keys the caller says it is about to pass.
#
#   Textually, and deliberately: `build-level.mjs` cannot be imported outside
#   the Workflow runtime (its top-level `args` reference throws), and the
#   whole point is to work against an ARBITRARY engine file — a stale install,
#   a vendored copy in another repo — with no repo checkout to diff against
#   and no Node required. A freshness diff against "the repo copy" would have
#   solved only the stale-install half and would say nothing about whether the
#   drift MATTERS; this names the key.
#
# UNKNOWN IS ITS OWN OUTCOME — the load-bearing rule. An engine with no
# declaration (predating it, truncated, or not a build-level engine at all) is
# CAPABILITIES_INDETERMINATE. It is NEVER collapsed into "all keys supported":
# that collapse is precisely the typed-state failure this script exists to end,
# and it would read byte-identically to a clean pass. Same for an absent or
# unreadable engine file and for an empty declaration block.
#
# USAGE
#   handoff-capability.sh check <engine-path> <key>[,<key>…]
#       Stdout: ONE JSON line (the closed-outcome convention every script in
#       this directory uses — worktree.sh / pr.sh / ci-poll.sh). Stderr: the
#       human-readable degradation notice, on the DEGRADED and INDETERMINATE
#       outcomes only.
#
#         {"outcome":"CAPABILITIES_OK","engine":…,"declared":N,"passed":N,
#          "dropped":[],"notice":null,"remedy":null}
#         {"outcome":"CAPABILITIES_DEGRADED","engine":…,"declared":N,"passed":N,
#          "dropped":["reviewerRoutingTsv",…],"notice":"skipped — …",
#          "remedy":"…"}
#         {"outcome":"CAPABILITIES_INDETERMINATE","engine":…,"declared":null,
#          "passed":N,"dropped":null,"reason":"…","notice":"skipped — …",
#          "remedy":"…"}
#         {"outcome":"ERROR","error":…}   + non-zero exit
#
#       All three VERDICTS exit 0. Only ERROR (usage / missing jq) exits
#       non-zero — a degraded verdict must never abort a `set -e` driver,
#       because the drive is still correct to proceed: the dropped key falls
#       back, it does not crash.
#
#   handoff-capability.sh declared <engine-path>
#       The declared keys, one per line, sorted. Exit 0 with output, or exit 3
#       with an empty stdout and the reason on stderr when the declaration
#       cannot be read. This is the accessor temperloop#2024's hand-off key
#       REGISTRY lint is meant to read, so that registry is DERIVED from this
#       declaration rather than becoming a second hand-maintained list.
#
# THE NOTICE SHAPE. `notice` realizes `claude/message-schema.md` § Degradation
# notice in its mode-2 minimal form: one line, what was degraded (named keys —
# a generic "your engine is old" does not satisfy this), why, and a
# calibrated-trust clause. It carries NO remedy pointer, per that section's
# two-shapes rule; `remedy` is a SEPARATE field for the mode-6 durable form
# (a PR body, a parked record), where the remedy slot is unconditional.
#
# KNOWN BOUNDARY, stated rather than implied: TOP-LEVEL keys only. Nested
# per-item fields (`items[].activation`, `items[].dependsOn`) have the same
# drop-silently property and are NOT covered. Reporting what it covers, and
# no more, is the same discipline as the INDETERMINATE outcome above.

set -euo pipefail

command -v jq >/dev/null 2>&1 || {
  echo '{"outcome":"ERROR","error":"jq not found"}'
  exit 1
}

die() {
  jq -cn --arg error "$1" '{outcome:"ERROR", error:$error}'
  exit 1
}

usage() {
  die "usage: handoff-capability.sh check <engine-path> <key,key,...> | handoff-capability.sh declared <engine-path>"
}

# ---------------------------------------------------------------------------
# extract_declared <engine-path>
#
# Sets the globals EXTRACT_KEYS (declared keys, one per line, sorted and
# de-duplicated) on success, or EXTRACT_REASON on failure, and returns 0/1.
#
# It returns its result through GLOBALS and never through stdout, so callers
# never invoke it in a command substitution: a subshell would discard
# EXTRACT_REASON and the INDETERMINATE outcome would report an empty reason —
# a legibility hole in the very path whose whole job is to say WHY it could
# not tell. (That is not hypothetical: this function did exactly that until
# the test below pinned a non-empty reason.)
#
# Every failure arm is a REASON, never an empty success: an absent file, an
# unreadable file, a missing sentinel block, a truncated one, and an empty one
# are five distinct ways to be indeterminate and all five are reported.
# ---------------------------------------------------------------------------
EXTRACT_REASON=""
EXTRACT_KEYS=""
extract_declared() {
  local engine="$1" block="" rc=0 keys=""
  EXTRACT_REASON=""
  EXTRACT_KEYS=""

  if [ -z "$engine" ]; then
    EXTRACT_REASON="no engine path given"
    return 1
  fi
  if [ ! -e "$engine" ]; then
    EXTRACT_REASON="engine file does not exist: $engine"
    return 1
  fi
  if [ ! -f "$engine" ] || [ ! -r "$engine" ]; then
    EXTRACT_REASON="engine file is not a readable regular file: $engine"
    return 1
  fi

  # awk exits 10 when the BEGIN sentinel never appeared, 11 when it appeared
  # but the END sentinel did not (a truncated or mid-edit file). Both are
  # indeterminate, and they are distinguished because they mean different
  # things to a human: 10 = an engine older than the declaration (or not a
  # build-level engine); 11 = a damaged one.
  set +e
  block="$(awk '
    index($0, "HANDOFF-CAPABILITIES-BEGIN") { seen_begin = 1; inblock = 1; next }
    index($0, "HANDOFF-CAPABILITIES-END")   { if (inblock) { inblock = 0; seen_end = 1 } ; next }
    inblock { print }
    END {
      if (!seen_begin) { exit 10 }
      if (!seen_end)   { exit 11 }
    }
  ' "$engine")"
  rc=$?
  set -e

  case "$rc" in
    0) : ;;
    10)
      EXTRACT_REASON="no hand-off capability declaration found in $engine (an engine predating the declaration, or not a build-level engine)"
      return 1
      ;;
    11)
      EXTRACT_REASON="hand-off capability declaration in $engine is unterminated (truncated or mid-edit file)"
      return 1
      ;;
    *)
      EXTRACT_REASON="could not read the hand-off capability declaration in $engine (reader exited $rc)"
      return 1
      ;;
  esac

  keys="$(printf '%s\n' "$block" \
    | grep -oE "'[A-Za-z_][A-Za-z0-9_]*'" \
    | tr -d "'" \
    | sort -u || true)"

  if [ -z "$keys" ]; then
    EXTRACT_REASON="hand-off capability declaration in $engine is empty (declares no keys)"
    return 1
  fi

  EXTRACT_KEYS="$keys"
}

# normalize_keys <comma-and/or-whitespace-separated list> — one key per line,
# sorted, de-duplicated, blanks dropped.
normalize_keys() {
  # Two passes rather than one multi-class `tr`: BSD and GNU tr disagree about
  # padding a shorter string2, and this runs on macOS (see the kernel's
  # "check the platform's dialect" rule).
  printf '%s' "$1" \
    | tr ',' '\n' \
    | tr -s '[:space:]' '\n' \
    | grep -E '^[A-Za-z_][A-Za-z0-9_]*$' \
    | sort -u || true
}

# join_commas — stdin lines -> "a, b, c". Not `paste -sd', '`: BSD paste reads
# -d as a CYCLED delimiter list, so a two-character ', ' would alternate the
# comma and the space between successive pairs.
join_commas() {
  awk 'NR == 1 { printf "%s", $0; next } { printf ", %s", $0 }'
}

cmd_declared() {
  local engine="${1:-}"
  [ -n "$engine" ] || usage
  if ! extract_declared "$engine"; then
    printf '%s\n' "$EXTRACT_REASON" >&2
    return 3
  fi
  printf '%s\n' "$EXTRACT_KEYS"
}

cmd_check() {
  local engine="${1:-}" keycsv="${2:-}"
  [ -n "$engine" ] || usage
  [ -n "$keycsv" ] || usage

  local passed passed_n
  passed="$(normalize_keys "$keycsv")"
  passed_n="$(printf '%s\n' "$passed" | grep -c . || true)"
  if [ "$passed_n" -eq 0 ]; then
    die "no valid hand-off keys parsed from: $keycsv"
  fi

  local declared notice remedy
  if ! extract_declared "$engine"; then
    notice="skipped — the hand-off capability of $engine could not be determined (${EXTRACT_REASON}); every one of the $passed_n keys this drive passes is UNVERIFIED, not confirmed supported, so treat anything they arm as unproven this run."
    remedy="Redeploy the engine from a checkout that carries the declaration (\`make install\`), or point the driver at one that does; then re-run this probe."
    jq -cn \
      --arg engine "$engine" \
      --argjson passed "$passed_n" \
      --arg reason "$EXTRACT_REASON" \
      --arg notice "$notice" \
      --arg remedy "$remedy" \
      '{outcome:"CAPABILITIES_INDETERMINATE", engine:$engine, declared:null,
        passed:$passed, dropped:null, reason:$reason, notice:$notice, remedy:$remedy}'
    printf '%s\n' "$notice" >&2
    return 0
  fi

  declared="$EXTRACT_KEYS"

  local declared_n dropped dropped_n dropped_list
  declared_n="$(printf '%s\n' "$declared" | grep -c . || true)"
  dropped="$(comm -23 <(printf '%s\n' "$passed") <(printf '%s\n' "$declared") || true)"
  dropped_n="$(printf '%s\n' "$dropped" | grep -c . || true)"

  if [ "$dropped_n" -eq 0 ]; then
    jq -cn \
      --arg engine "$engine" \
      --argjson declared "$declared_n" \
      --argjson passed "$passed_n" \
      '{outcome:"CAPABILITIES_OK", engine:$engine, declared:$declared,
        passed:$passed, dropped:[], notice:null, remedy:null}'
    return 0
  fi

  dropped_list="$(printf '%s\n' "$dropped" | grep . | join_commas)"
  notice="skipped — hand-off key(s) ${dropped_list} are not understood by ${engine} (it declares ${declared_n} keys; this drive passes ${passed_n}); they will be silently dropped and the engine falls back, so whatever they arm did NOT run this drive."
  remedy="Redeploy the engine from a checkout whose declaration carries ${dropped_list} (\`make install\`), or stop passing the key until it does."
  jq -cn \
    --arg engine "$engine" \
    --argjson declared "$declared_n" \
    --argjson passed "$passed_n" \
    --arg dropped "$dropped" \
    --arg notice "$notice" \
    --arg remedy "$remedy" \
    '{outcome:"CAPABILITIES_DEGRADED", engine:$engine, declared:$declared,
      passed:$passed,
      dropped:($dropped | split("\n") | map(select(length > 0))),
      notice:$notice, remedy:$remedy}'
  printf '%s\n' "$notice" >&2
  return 0
}

case "${1:-}" in
  check)    shift; cmd_check "$@" ;;
  declared) shift; cmd_declared "$@" ;;
  ""|-h|--help|help) usage ;;
  *) die "unknown subcommand: $1 (expected: check | declared)" ;;
esac
