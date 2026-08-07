#!/usr/bin/env bash
#
# declared-expiry-check.sh — finds standing rules whose own stated end
# condition has already passed (temperloop#831, epic #810 P10, "session-start
# context budget" — Phase A: measurement only, no cap, no CI gate).
#
# ── What this is ────────────────────────────────────────────────────────────
# claude/citation-schema.md's marker grammar (temperloop#719) lets a standing
# rule's citation marker optionally declare an EXPIRY — an absolute date, or a
# named retirement issue (see that file's § Declaring an expiry) — appended as
# `expires:<expiry>` on the same marker. This script resolves every declared
# expiry over an in-scope surface and reports which ones have PASSED: a date
# on or before today, or a referenced issue that is now CLOSED.
#
# ── REPORTS COVERAGE, NOT PRECISION (the acceptance's own framing) ─────────
# A date either has passed or it has not, and an issue either is closed or it
# is not — resolution, within what this script can see, is essentially exact.
# Its VALUE is bounded entirely by ADOPTION: most standing rules today declare
# no expiry at all, whether or not they read as temporary in prose. So this
# script reports two numbers, not one: how many in-scope rules DECLARE an
# expiry, and how many read as temporary in prose (a best-effort keyword
# heuristic — never a semantic reader) yet declare nothing. Neither number is
# a verdict on any individual rule's quality; both are coverage signal.
#
# ── STATED LIMIT (never papered over) ───────────────────────────────────────
# An UNDECLARED temporary rule that also carries no recognizable temporal
# language (no "temporary", "until", "phase N", etc. near the marker) is
# INVISIBLE to this script BY CONSTRUCTION — there is no code path here that
# could ever find it. The "reads as temporary" bucket only catches prose that
# happens to use one of a small, fixed set of keywords; it is a lower bound on
# unadopted temporariness, never a complete count.
#
# ── PRE-REGISTERED ADOPTION THRESHOLD (recorded BEFORE any measurement ran,
#    per this item's own acceptance ordering — the epic's stated reason this
#    ordering is load-bearing: three prior attempts in this same epic enforced
#    against a metric before establishing that the metric tracked the cost) ──
# Gating (a future Phase-B CI check that would fail a build over an expired,
# undeclared-renewal rule) is judged WARRANTED once measured adoption — the
# share of in-scope standing rules that declare an expiry, against the
# denominator of (declared + reads-as-temporary-but-undeclared) — reaches
# DECLARED_EXPIRY_ADOPTION_THRESHOLD_PCT (workflows/scripts/config/
# setting-registry.tsv; named here, never valued in prose, per this kernel's
# own "prose names a setting, never states its value" convention). This
# threshold was fixed before this script was ever run against the real tree —
# changing it after seeing a real coverage number would repeat exactly the
# metric error this epic exists to correct.
#
# ── SURFACE definition (a deliberate synthesis of two source-of-truth files,
#    documented here since neither file alone answers "what does THIS script
#    scan") ───────────────────────────────────────────────────────────────
# "Standing rule" is citation-schema.md's own mechanical definition: a row in
# workflows/scripts/config/citation-registry.tsv (row-id, file). "The
# always-loaded surface" is workflows/scripts/config/contributor-manifest.tsv
# (temperloop#827) — the tracked registry of files/fields Claude Code
# auto-loads at session start. This script's IN-SCOPE rule set is the
# INTERSECTION: every citation-registry.tsv row whose FILE also appears as a
# path in contributor-manifest.tsv (scanned by that file's FULL content, not
# only the manifest's byte-measurement `unit` — the manifest names WHICH
# FILES are in scope; the byte-measurement unit is a separate, narrower
# concern of count-prose.sh's own budget report).
#
# A DIRECT, STATED CONSEQUENCE: claude/CLAUDE.kernel.md — the single largest
# citation-registry.tsv file by row count (the K.* rows) — is explicitly
# EXCLUDED from contributor-manifest.tsv (that file's own header: "TIER-1's
# concern, never auto-loaded verbatim in a kernel-only checkout"), so K.*
# rules are OUT OF SCOPE for this script's coverage measurement. This is not
# a bug to silently work around — it is reported explicitly in every run's
# output (the "excluded from this run's surface" line) so a reader is never
# left assuming 100% of standing rules were considered.
#
# ── Two expiry forms (claude/citation-schema.md § Declaring an expiry) ──────
#   date-expiry   expires:YYYY-MM-DD           resolves 100% OFFLINE (a plain
#                 lexical string comparison against two ISO-8601 dates is
#                 correct with no date arithmetic — no `date -d`, no BSD/GNU
#                 dialect concern).
#   issue-expiry  expires:#N | expires:owner/repo#N   resolves via `gh issue
#                 view`. DEGRADES LEGIBLY when gh is unavailable (network
#                 down, unauthenticated, not installed): the rule is reported
#                 in an explicit UNRESOLVED bucket, never silently dropped and
#                 never a hard script failure.
#
# ── Never a gate ─────────────────────────────────────────────────────────────
# This script's own findings NEVER fail its exit code — Phase A ships no cap
# and nothing here can turn a contributor's PR red (this is a report, exactly
# like the sibling workflows/scripts/count-prose.sh). It exits non-zero only
# if it cannot produce a report AT ALL (its own two required registry/
# manifest files are missing — a broken checkout, not a content finding).
#
# Usage:
#   workflows/scripts/declared-expiry-check.sh [--dry-run --fixture <dir>]
#
#   --dry-run --fixture <dir>   Offline fixture mode for issue-form
#                                resolution and repo auto-detection (fixture-
#                                driven tests; see this file's own test suite
#                                for the exact fixture shapes):
#                                  $FIXTURE/issue-<owner>-<repo>-<n>.json
#                                      {"state":"OPEN"|"CLOSED"}
#                                  $FIXTURE/repo.json
#                                      {"nameWithOwner":"owner/repo"} — used
#                                      only to resolve a BARE `#N` reference
#                                      when DECLARED_EXPIRY_REPO is unset.
#                                A referenced issue with no fixture file present
#                                is the DELIBERATE "gh would return nothing"
#                                case, reported UNRESOLVED like a real offline
#                                run — never a test-harness special case.
#
# Env overrides (fixture-driven tests; same "setting:exempt" class as this
# repo's other scan-root/file-path test seams — not operator-facing
# config-precedence defaults):
#   DECLARED_EXPIRY_SCAN_ROOT      repo root the manifest/registry paths
#                                  resolve against (default: this repo).
#   CITATION_REGISTRY_FILE         path to citation-registry.tsv (default:
#                                  the tracked sibling under
#                                  workflows/scripts/config/).
#   CONTRIBUTOR_MANIFEST_TSV       path to contributor-manifest.tsv (default:
#                                  ditto).
#   DECLARED_EXPIRY_REPO           "owner/repo" to resolve a bare `#N` issue
#                                  reference against, bypassing the
#                                  `gh repo view` auto-detect call entirely.
#   DECLARED_EXPIRY_TODAY          override "today" as a YYYY-MM-DD string
#                                  (default: `date -u +%Y-%m-%d`) — the ONE
#                                  seam a deterministic date-form fixture
#                                  needs; the real code path never calls
#                                  `date -d`/arithmetic of any kind.
#
# Kept bash-3.2-portable (no associative arrays, no mapfile) — same
# discipline as every other workflows/scripts/config/*.sh and
# workflows/scripts/*.sh checker in this family.

set -uo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# This script lives at workflows/scripts/declared-expiry-check.sh — the same
# directory as count-prose.sh and validate-prose-budget.sh — so REPO_ROOT is
# TWO levels up from SCRIPT_DIR, matching those scripts' own resolution.
REPO_ROOT_DEFAULT="$(cd "$SCRIPT_DIR/../.." && pwd)"

: "${DECLARED_EXPIRY_SCAN_ROOT:=$REPO_ROOT_DEFAULT}"  # setting:exempt — fixture/scan-root override, same class as COUNT_PROSE_ROOT
: "${CITATION_REGISTRY_FILE:=$SCRIPT_DIR/config/citation-registry.tsv}"  # setting:exempt — fixture seam, same class as validate-prose-budget.sh's own CITATION_REGISTRY_FILE
: "${CONTRIBUTOR_MANIFEST_TSV:=$SCRIPT_DIR/config/contributor-manifest.tsv}"  # setting:exempt — fixture seam, same class as count-prose.sh's own CONTRIBUTOR_MANIFEST_TSV
: "${DECLARED_EXPIRY_REPO:=}"  # setting:exempt — explicit owner/repo override, bypasses the gh repo-view auto-detect
: "${DECLARED_EXPIRY_TODAY:=}"  # setting:exempt — deterministic "today" override for date-form fixtures

# Attribution for the gh call-logger shim (F#988), same convention every
# gh-calling build-machinery entry point already uses.
export GH_CALL_CONTEXT="${GH_CALL_CONTEXT:-declared-expiry-check}"

# ── PRE-REGISTERED ADOPTION THRESHOLD (see header above for the ordering
#    rationale). Registered in workflows/scripts/config/setting-registry.tsv;
#    this IS that row's own owning-script literal. ──────────────────────────
: "${DECLARED_EXPIRY_ADOPTION_THRESHOLD_PCT:=50}"

DRY_RUN=0
FIXTURE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run) DRY_RUN=1; shift ;;
    --fixture) FIXTURE="${2:?--fixture needs a dir}"; shift 2 ;;
    -h|--help)
      sed -n '1,/^set -uo pipefail/p' "$0" | grep '^#' | sed 's/^# \{0,1\}//'
      exit 0
      ;;
    *)
      echo "declared-expiry-check: unrecognized argument: $1" >&2
      exit 2
      ;;
  esac
done
if [ "$DRY_RUN" -eq 1 ] && [ -z "$FIXTURE" ]; then
  echo "declared-expiry-check: --dry-run requires --fixture <dir>" >&2
  exit 2
fi

# ── Required inputs: degrade to a clean skip, never a build failure. This
#    script's OWN findings never gate a build (Phase A); a totally absent
#    input file means "cannot produce a report", reported plainly, exit 0. ──
if [ ! -f "$CITATION_REGISTRY_FILE" ]; then
  echo "declared-expiry-check: citation registry not found at $CITATION_REGISTRY_FILE — skipping (report-only tool; never fails a build)" >&2
  exit 0
fi
if [ ! -f "$CONTRIBUTOR_MANIFEST_TSV" ]; then
  echo "declared-expiry-check: contributor manifest not found at $CONTRIBUTOR_MANIFEST_TSV — skipping (report-only tool; never fails a build)" >&2
  exit 0
fi

today="${DECLARED_EXPIRY_TODAY:-$(date -u +%Y-%m-%d)}"  # setting:exempt — deterministic "today" test seam (DECLARED_EXPIRY_TODAY), already registered above; this is a second read of the same env var, not a second setting

# --- load contributor-manifest.tsv's path column (column 1 only) ----------
manifest_paths=()
while IFS=$'\t' read -r m_path _rest || [ -n "${m_path:-}" ]; do
  [ -z "${m_path:-}" ] && continue
  case "$m_path" in \#*) continue ;; esac
  m_path="${m_path%$'\r'}"
  manifest_paths+=("$m_path")
done <"$CONTRIBUTOR_MANIFEST_TSV"

_de_in_manifest() {
  local p
  for p in "${manifest_paths[@]:-}"; do
    [ -n "$p" ] && [ "$p" = "$1" ] && return 0
  done
  return 1
}

# --- load citation-registry.tsv rows: row-id, file -------------------------
reg_ids=()
reg_files=()
while IFS=$'\t' read -r r_id r_file || [ -n "${r_id:-}" ]; do
  [ -z "${r_id:-}" ] && continue
  case "$r_id" in \#*) continue ;; esac
  r_id="${r_id%$'\r'}"
  r_file="${r_file%$'\r'}"
  [ -z "$r_file" ] && continue
  reg_ids+=("$r_id")
  reg_files+=("$r_file")
done <"$CITATION_REGISTRY_FILE"

total_registered="${#reg_ids[@]}"
if [ "$total_registered" -eq 0 ]; then
  echo "declared-expiry-check: zero rows parsed from $CITATION_REGISTRY_FILE — skipping (report-only tool; never fails a build)" >&2
  exit 0
fi

# --- partition into in-scope (file is a manifest row) vs out-of-scope ------
scope_ids=()
scope_files=()
excluded_files_seen=()
i=0
while [ "$i" -lt "$total_registered" ]; do
  f="${reg_files[$i]}"
  if _de_in_manifest "$f"; then
    scope_ids+=("${reg_ids[$i]}")
    scope_files+=("$f")
  else
    already=0
    for ex in "${excluded_files_seen[@]:-}"; do
      [ "$ex" = "$f" ] && already=1 && break
    done
    [ "$already" -eq 0 ] && excluded_files_seen+=("$f")
  fi
  i=$((i + 1))
done
in_scope_count="${#scope_ids[@]}"

# ── marker line lookup: the FIRST line in <root>/<file> carrying the
#    literal `<!-- cite: <row-id> ` prefix. The citation gate
#    (validate-prose-budget.sh) already guarantees every registered marker
#    appears exactly once outside a fenced code block; this script does its
#    own independent, minimal lookup rather than sharing state with that
#    gate (a lint and the report it feeds should not share one point of
#    failure — same rationale check-contributor-manifest.sh's own header
#    states for its independent frontmatter extraction). --------------------
_de_marker_line() {
  local root="$1" file="$2" rowid="$3" path
  path="$root/$file"
  [ -f "$path" ] || return 1
  grep -m1 -F -- "<!-- cite: $rowid " "$path" || return 1
}

# _de_parse_expires <marker-line> -> prints the raw expires: value (may be
# empty if absent).
_de_parse_expires() {
  printf '%s' "$1" | grep -oE 'expires:[^[:space:]]+' | head -1 | sed 's/^expires://'
}

# _de_is_date <value> -> rc 0 if it looks like YYYY-MM-DD.
_de_is_date() {
  case "$1" in
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]) return 0 ;;
    *) return 1 ;;
  esac
}

# --- gh access: the ONE live-gh seam (tests override via --dry-run/fixture
#     for the deterministic paths, and via a PATH-shadowing fake `gh` binary
#     for the genuine offline-degrade path — see this file's test suite). --
_de_gh_repo_nwo() {
  # -> stdout "owner/repo", rc 1 if it cannot be resolved.
  local val
  if [ "$DRY_RUN" -eq 1 ]; then
    if [ -f "$FIXTURE/repo.json" ]; then
      val="$(jq -r '.nameWithOwner // empty' "$FIXTURE/repo.json" 2>/dev/null)"
      [ -n "$val" ] || return 1
      printf '%s' "$val"
      return 0
    fi
    return 1
  fi
  val="$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null)" || return 1
  [ -n "$val" ] || return 1
  printf '%s' "$val"
}

# _de_gh_issue_state <owner/repo> <number> -> prints OPEN|CLOSED, rc 1 if
# unresolvable (network/auth/gh-missing, or dry-run fixture absent).
_de_gh_issue_state() {
  local repo="$1" number="$2" f state
  if [ "$DRY_RUN" -eq 1 ]; then
    f="$FIXTURE/issue-$(printf '%s' "$repo" | tr '/' '-')-$number.json"
    [ -f "$f" ] || return 1
    state="$(jq -r '.state // empty' "$f" 2>/dev/null)"
    [ -n "$state" ] || return 1
    printf '%s' "$state"
    return 0
  fi
  state="$(gh issue view "$number" -R "$repo" --json state -q .state 2>/dev/null)" || return 1
  [ -n "$state" ] || return 1
  printf '%s' "$state"
}

# _de_parse_issue_ref <value> -> stdout "owner<TAB>repo<TAB>number", or just
# "<TAB><TAB>number" when the value is a bare `#N` (repo resolved by the
# caller). rc 1 if it does not parse as an issue reference at all.
_de_parse_issue_ref() {
  local v="$1"
  case "$v" in
    */*#[0-9]*)
      local ownerrepo="${v%%#*}" number="${v##*#}"
      case "$number" in *[!0-9]*|'') return 1 ;; esac
      printf '%s\t%s' "$ownerrepo" "$number"
      return 0
      ;;
    '#'[0-9]*)
      local number="${v#\#}"
      case "$number" in *[!0-9]*|'') return 1 ;; esac
      printf '\t%s' "$number"
      return 0
      ;;
    *) return 1 ;;
  esac
}

_de_repo_resolved=0
_de_repo_nwo=""
_de_resolve_default_repo() {
  [ "$_de_repo_resolved" -eq 1 ] && { [ -n "$_de_repo_nwo" ]; return $?; }
  _de_repo_resolved=1
  if [ -n "$DECLARED_EXPIRY_REPO" ]; then
    _de_repo_nwo="$DECLARED_EXPIRY_REPO"
    return 0
  fi
  _de_repo_nwo="$(_de_gh_repo_nwo)" || { _de_repo_nwo=""; return 1; }
  [ -n "$_de_repo_nwo" ]
}

# heuristic "reads as temporary in prose" keyword set — a deliberately small,
# fixed, documented list (never a semantic reader; see header § STATED LIMIT).
_de_reads_temporary() {
  printf '%s' "$1" | grep -qiE 'temporary|deprecated|sunset|removed at|to be removed|timeboxed|phase [0-9]|for now|until [a-z0-9#]'
}

# ── Walk the in-scope set, classify each row ────────────────────────────────
expired_lines=()
unresolved_lines=()
declared_ok_lines=()
temporary_undeclared_lines=()
declared_count=0

i=0
while [ "$i" -lt "$in_scope_count" ]; do
  rid="${scope_ids[$i]}"
  rfile="${scope_files[$i]}"
  i=$((i + 1))

  mline="$(_de_marker_line "$DECLARED_EXPIRY_SCAN_ROOT" "$rfile" "$rid")" || {
    echo "declared-expiry-check: NOTE: $rid ($rfile) is in scope but its marker line could not be located — skipping this row (the citation gate, run separately, is the authority on marker presence)" >&2
    continue
  }
  prose_before_marker="${mline%%<!--*}"

  expires_val="$(_de_parse_expires "$mline")"
  if [ -z "$expires_val" ]; then
    if _de_reads_temporary "$prose_before_marker"; then
      temporary_undeclared_lines+=("$rid	$rfile	(reads as temporary in prose, declares no expiry)")
    fi
    continue
  fi

  declared_count=$((declared_count + 1))

  if _de_is_date "$expires_val"; then
    if [ "$expires_val" \< "$today" ] || [ "$expires_val" = "$today" ]; then
      expired_lines+=("$rid	$rfile	date $expires_val has passed (today: $today)")
    else
      declared_ok_lines+=("$rid	$rfile	expires:$expires_val (not yet passed)")
    fi
    continue
  fi

  parsed_ref="$(_de_parse_issue_ref "$expires_val")"; parse_rc=$?
  if [ "$parse_rc" -ne 0 ]; then
    unresolved_lines+=("$rid	$rfile	expires:$expires_val does not parse as a date or an issue reference — cannot resolve")
    continue
  fi
  ref_owner_repo="${parsed_ref%%$'\t'*}"
  ref_number="${parsed_ref##*$'\t'}"
  if [ -z "$ref_owner_repo" ]; then
    if ! _de_resolve_default_repo; then
      unresolved_lines+=("$rid	$rfile	expires:$expires_val — bare issue ref, and the default repo could not be resolved (gh unavailable, or --dry-run with no fixture repo.json) — cannot resolve")
      continue
    fi
    ref_owner_repo="$_de_repo_nwo"
  fi

  state="$(_de_gh_issue_state "$ref_owner_repo" "$ref_number")" || {
    unresolved_lines+=("$rid	$rfile	expires:$expires_val — could not resolve $ref_owner_repo#$ref_number (gh unavailable/offline) — never silently dropped")
    continue
  }
  if [ "$state" = "CLOSED" ]; then
    expired_lines+=("$rid	$rfile	$ref_owner_repo#$ref_number is CLOSED")
  else
    declared_ok_lines+=("$rid	$rfile	expires:$expires_val ($ref_owner_repo#$ref_number is still $state)")
  fi
done

# ── Report ───────────────────────────────────────────────────────────────
echo "DECLARED-EXPIRY CHECK (temperloop#831, epic #810 P10) — report only; findings here never fail a build."
echo
echo "SURFACE: $in_scope_count in-scope standing rule(s) — citation-registry.tsv rows whose file is also a contributor-manifest.tsv row (today: $today)."
if [ "${#excluded_files_seen[@]}" -gt 0 ]; then
  echo "  Excluded from this run's surface (registered, but their file is not part of the always-loaded contributor-manifest surface): ${excluded_files_seen[*]}"
fi
echo

echo "EXPIRED (declared end condition has passed):"
if [ "${#expired_lines[@]}" -eq 0 ]; then
  echo "  none"
else
  for l in "${expired_lines[@]}"; do
    printf '  %s\n' "$l" | tr '\t' ' '
  done
fi
echo

echo "UNRESOLVED (issue-form expiry could not be checked — never silently dropped):"
if [ "${#unresolved_lines[@]}" -eq 0 ]; then
  echo "  none"
else
  for l in "${unresolved_lines[@]}"; do
    printf '  %s\n' "$l" | tr '\t' ' '
  done
fi
echo

echo "DECLARED, not yet expired:"
if [ "${#declared_ok_lines[@]}" -eq 0 ]; then
  echo "  none"
else
  for l in "${declared_ok_lines[@]}"; do
    printf '  %s\n' "$l" | tr '\t' ' '
  done
fi
echo

echo "READS AS TEMPORARY IN PROSE, DECLARES NO EXPIRY (best-effort keyword heuristic, never a semantic reader):"
if [ "${#temporary_undeclared_lines[@]}" -eq 0 ]; then
  echo "  none"
else
  for l in "${temporary_undeclared_lines[@]}"; do
    printf '  %s\n' "$l" | tr '\t' ' '
  done
fi
echo

undeclared_temporary_count="${#temporary_undeclared_lines[@]}"
denom=$((declared_count + undeclared_temporary_count))

echo "COVERAGE (adoption, not precision):"
if [ "$in_scope_count" -gt 0 ]; then
  scale=100
  pct_of_surface_scaled=$((declared_count * scale * scale / in_scope_count))
  printf '  %d of %d in-scope standing rule(s) declare an expiry (%d.%02d%% of the in-scope surface).\n' \
    "$declared_count" "$in_scope_count" "$((pct_of_surface_scaled / scale))" "$((pct_of_surface_scaled % scale))"
else
  echo "  0 in-scope standing rules — nothing to measure."
fi
echo "  $undeclared_temporary_count additional rule(s) read as temporary in prose but declare no expiry."

if [ "$denom" -gt 0 ]; then
  scale=100
  adoption_pct_scaled=$((declared_count * scale * scale / denom))
  adoption_pct_int=$((adoption_pct_scaled / scale))
  adoption_pct_frac=$((adoption_pct_scaled % scale))
  printf '  Adoption denominator (declared + reads-as-temporary-but-undeclared): %d. Adoption rate against that denominator: %d.%02d%%.\n' \
    "$denom" "$adoption_pct_int" "$adoption_pct_frac"
  echo
  echo "PRE-REGISTERED ADOPTION THRESHOLD: gating is warranted at >= ${DECLARED_EXPIRY_ADOPTION_THRESHOLD_PCT}% adoption (DECLARED_EXPIRY_ADOPTION_THRESHOLD_PCT, registered in workflows/scripts/config/setting-registry.tsv; fixed before this run's measurement — see this script's own header)."
  if [ "$adoption_pct_int" -ge "$DECLARED_EXPIRY_ADOPTION_THRESHOLD_PCT" ]; then
    echo "GO/NO-GO: GO — measured adoption ($adoption_pct_int.$(printf '%02d' "$adoption_pct_frac")%) meets or exceeds the pre-registered threshold (${DECLARED_EXPIRY_ADOPTION_THRESHOLD_PCT}%). A Phase-B expiry gate would have real signal to act on."
  else
    echo "GO/NO-GO: NO-GO — measured adoption ($adoption_pct_int.$(printf '%02d' "$adoption_pct_frac")%) is below the pre-registered threshold (${DECLARED_EXPIRY_ADOPTION_THRESHOLD_PCT}%). A Phase-B expiry gate is not yet warranted; this remains a report-only tool."
  fi
else
  echo
  echo "PRE-REGISTERED ADOPTION THRESHOLD: gating is warranted at >= ${DECLARED_EXPIRY_ADOPTION_THRESHOLD_PCT}% adoption (DECLARED_EXPIRY_ADOPTION_THRESHOLD_PCT, registered in workflows/scripts/config/setting-registry.tsv; fixed before this run's measurement — see this script's own header)."
  echo "GO/NO-GO: NO-GO — zero rules declare an expiry or read as temporary; no adoption denominator to measure against the threshold."
fi
echo

echo "LIMIT (stated, not papered over): an UNDECLARED temporary rule with no recognizable temporal language in its prose is invisible to this check by construction — the 'reads as temporary' bucket above is a small, fixed keyword heuristic, never a semantic reader, so it is a lower bound on unadopted temporariness, not a complete count."

exit 0
