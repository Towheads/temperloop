#!/usr/bin/env bash
#
# validate-check-surface-degenerate-coverage.sh — the "a check that could not
# run reports success" gate (temperloop#1476, epic #1409).
#
# WHY THIS EXISTS. Three defects motivated epic #1409, each reached by a
# different mechanism, none caught by a test because every suite exercised
# only the happy path:
#   1. validate-provider-disclosure.sh printed OK / exit 0 when it could not
#      read its disclosure log.
#   2. validate-model-usage-emit.sh printed OK / exit 0 on an unreadable
#      directory and on `--file -` with closed stdin.
#   3. replay.sh diff-scope returned {"status":"eligible"} at exit 0 for an
#      unresolvable git ref.
# In every case the check RAN, could not actually evaluate its input, and
# reported success anyway. This gate closes the class structurally: every
# REGISTERED check surface must ship a fixture proving it exits non-zero on
# each degenerate input shape that applies to it — absent, unreadable, and
# empty — or be named on a shrink-only allowlist that documents why not yet.
#
# ── REGISTRY, NOT A GLOB (load-bearing — read before extending) ────────────
# The target set is workflows/scripts/config/check-surface-registry.tsv, a
# committed, human-reviewed list. A `validate-*.sh` FILENAME glob cannot reach
# motivating instance 3 above: `replay.sh diff-scope` is a SUBCOMMAND of a
# general orchestration script, not a file this repo names `validate-*`. A
# registry SURFACE token is therefore either a bare script path
# (`workflows/scripts/validate-provider-disclosure.sh`) or a
# `<script-path>:<subcommand>` pair (`workflows/scripts/model-comparison/
# replay.sh:diff-scope`) — see _csd_registry_surface_ok() below.
#
# SEED SET, DELIBERATELY NOT EXHAUSTIVE. This item registers the three
# surfaces epic #1409's own motivating instances named, plus the two
# explicitly out-of-scope surfaces on the allowlist (tagging.sh — #1480;
# batch.sh's line-141 bootstrap check — #1487). Dozens of other
# `validate-*.sh` scripts in this repo are not yet in the registry at all —
# a registry with a small seed set is legitimate (coverage is opt-in and
# grows as surfaces are added), never a reason to fall back to a glob. Widening
# the registry to the rest of the repo's check surfaces is future work.
#
# ── The two config files ────────────────────────────────────────────────────
#   check-surface-registry.tsv            SURFACE / CASE / STATUS / TEST_FILE /
#                                          DETAIL — one row per (surface, case).
#                                          STATUS=covered rows are verified by
#                                          THIS gate (below); STATUS=not-
#                                          applicable rows carry a mandatory,
#                                          human-readable justification instead
#                                          (a git ref has no chmod-unreadable
#                                          analog — see the diff-scope rows).
#   check-surface-degenerate-allowlist.tsv  SURFACE / REASON for every
#                                          registered-but-not-yet-compliant
#                                          surface. SHRINK-ONLY RATCHET
#                                          (acceptance criterion 3): this gate
#                                          fails if a surface name appears here
#                                          that did NOT already appear here at
#                                          the diff's merge base — see the
#                                          "ratchet" section below. Starting
#                                          non-empty is expected, not a failure.
#
# ── What "covered" actually verifies (three checks per case) ───────────────
#   1. TEST_FILE exists and is readable (else CANNOT EVALUATE — see below).
#   2. DETAIL (a literal substring) is found in TEST_FILE via `grep -F`. This
#      is a STRUCTURAL presence check, not a re-execution of the fixture —
#      quality-gates.sh already runs the fixture itself elsewhere; this gate's
#      own job is registry/mapping integrity, proven by the discrimination
#      test in this gate's own fixture suite (delete the anchor line, watch
#      this gate go red naming the surface+case, restore, watch it go green).
#   3. TEST_FILE is itself WIRED INTO quality-gates.sh (grepped for its
#      repo-relative path). A dedicated fixture nobody runs in CI proves
#      nothing — this is exactly the failure test_allowlist.sh's own header
#      warns about ("a suite not typed in this list NEVER RUNS IN CI").
#
# ── The ratchet (acceptance criterion 3) ────────────────────────────────────
# "Grows" is decided by diffing the CURRENT allowlist's surface-name set
# against the allowlist at CHECK_SURFACE_ALLOWLIST_BASE_REF (default
# origin/main; check_checkout_freshness — scripts/quality-gates.sh's own
# preflight — fetches it before any gate runs, same precondition
# claude/hooks/tests/differential-guard-vs-ref.sh already relies on). Any
# surface present now but ABSENT at the base ref is growth and FAILS, naming
# the new entry. Two legal non-growth shapes: the base ref lacks the file
# entirely (this PR is the one introducing it — the bootstrap case), or an
# entry was REMOVED (shrinking, always allowed). If the base ref itself does
# not resolve, this is CANNOT EVALUATE — never a silent pass — because
# "did it grow" is genuinely undecidable without a comparison point.
#
# ── Fail-closed discipline (acceptance criterion 5) ─────────────────────────
# This gate must never itself be an instance of the defect it enforces
# against: it must not report success when it could not evaluate. Every hard
# stop (missing/unreadable registry or allowlist file, a registered TEST_FILE
# this gate cannot read, an unresolvable ratchet base ref) routes through
# workflows/scripts/lib/cannot-evaluate.sh's cannot_evaluate_emit — the
# shared idiom hoisted in temperloop#1475 (epic #1409) specifically so a
# caller that forgets to branch still fails CLOSED (RC_CANNOT_EVALUATE=2,
# non-zero) rather than falling through to an implicit OK. Every ordinary
# FAIL (a missing fixture, an unjustified not-applicable claim, allowlist
# growth) is collected into one array and reported ALL AT ONCE, tagged with a
# stable prefix (MISSING-FIXTURE, TEST-FILE-NOT-GATED, ...) naming the exact
# surface and case — never a bare non-zero exit (acceptance criterion 5).
#
# Usage:
#   workflows/scripts/validate-check-surface-degenerate-coverage.sh
#   (a direct-`bash` KERNEL_GATES entry in scripts/quality-gates.sh)
#
# Env overrides (FIXTURE-TEST SEAM, all optional — used by this gate's own
# fixture suite, workflows/scripts/tests/test_validate_check_surface_
# degenerate_coverage.sh, to point every input at a scratch tree):
#   CHECK_SURFACE_REGISTRY_FILE          default: workflows/scripts/config/
#                                         check-surface-registry.tsv
#   CHECK_SURFACE_ALLOWLIST_FILE         default: workflows/scripts/config/
#                                         check-surface-degenerate-allowlist.tsv
#   CHECK_SURFACE_QUALITY_GATES_FILE     default: scripts/quality-gates.sh
#   CHECK_SURFACE_GIT_REPO_ROOT          default: this repo's root — the repo
#                                         `git show <ref>:<path>` runs against
#                                         for the ratchet (a fixture points
#                                         this at a throwaway git repo)
#   CHECK_SURFACE_ALLOWLIST_BASE_REF     default: origin/main
#   CHECK_SURFACE_REPO_ROOT              default: this repo's root — the root
#                                         a relative TEST_FILE/quality-gates
#                                         path is resolved against
#
# Kept POSIX-bash-3.2-friendly (no mapfile/associative arrays) — macOS dev
# shell + Linux CI, matching every other workflows/scripts/validate-*.sh.

set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd)"

: "${CHECK_SURFACE_REPO_ROOT:=$DEFAULT_REPO_ROOT}"
: "${CHECK_SURFACE_GIT_REPO_ROOT:=$DEFAULT_REPO_ROOT}"
: "${CHECK_SURFACE_REGISTRY_FILE:=$SCRIPT_DIR/config/check-surface-registry.tsv}"
: "${CHECK_SURFACE_ALLOWLIST_FILE:=$SCRIPT_DIR/config/check-surface-degenerate-allowlist.tsv}"
: "${CHECK_SURFACE_QUALITY_GATES_FILE:=$CHECK_SURFACE_REPO_ROOT/scripts/quality-gates.sh}"
: "${CHECK_SURFACE_ALLOWLIST_BASE_REF:=origin/main}"

# shellcheck source=workflows/scripts/lib/cannot-evaluate.sh
source "$SCRIPT_DIR/lib/cannot-evaluate.sh"

PREFIX="validate-check-surface-degenerate-coverage"

_csd_cannot_evaluate() {
  cannot_evaluate_emit "$PREFIX" "$1"
  exit $?
}

[[ -f "$CHECK_SURFACE_REGISTRY_FILE" ]] || _csd_cannot_evaluate "registry file not found: $CHECK_SURFACE_REGISTRY_FILE"
[[ -r "$CHECK_SURFACE_REGISTRY_FILE" ]] || _csd_cannot_evaluate "registry file exists but is not readable: $CHECK_SURFACE_REGISTRY_FILE"

# An absent allowlist is legal (fully burned down); an UNREADABLE one is not.
if [[ -e "$CHECK_SURFACE_ALLOWLIST_FILE" && ! -r "$CHECK_SURFACE_ALLOWLIST_FILE" ]]; then
  _csd_cannot_evaluate "allowlist file exists but is not readable: $CHECK_SURFACE_ALLOWLIST_FILE"
fi

[[ -f "$CHECK_SURFACE_QUALITY_GATES_FILE" ]] || _csd_cannot_evaluate "quality-gates file not found: $CHECK_SURFACE_QUALITY_GATES_FILE"
[[ -r "$CHECK_SURFACE_QUALITY_GATES_FILE" ]] || _csd_cannot_evaluate "quality-gates file exists but is not readable: $CHECK_SURFACE_QUALITY_GATES_FILE"

failures=()
n_surfaces=0
n_covered_rows=0
n_not_applicable=0

# _csd_resolve_path <maybe-relative> — absolute paths pass through; anything
# else is resolved against CHECK_SURFACE_REPO_ROOT.
_csd_resolve_path() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s\n' "$CHECK_SURFACE_REPO_ROOT/$1" ;;
  esac
}

# ---------------------------------------------------------------------------
# 1. Parse the registry: SURFACE<TAB>CASE<TAB>STATUS<TAB>TEST_FILE<TAB>DETAIL
# ---------------------------------------------------------------------------
# One accumulator per surface x case, bash-3.2-safe (no associative arrays):
# parallel arrays keyed by "surface|case" strings, checked for duplicates as
# we go.
seen_keys=""
known_surfaces=""
surface_cases_seen=""

while IFS=$'\t' read -r surface case_ status test_file detail || [[ -n "$surface" ]]; do
  line="$surface"
  [[ -z "$line" ]] && continue
  case "$line" in \#*) continue ;; esac
  [[ -z "${surface:-}" ]] && continue

  case "$case_" in
    absent | unreadable | empty) ;;
    *)
      failures+=("BAD-CASE  $surface — unrecognized case '$case_' (want one of: absent, unreadable, empty)")
      continue
      ;;
  esac
  case "$status" in
    covered | not-applicable) ;;
    *)
      failures+=("BAD-STATUS  $surface [$case_] — unrecognized status '$status' (want: covered, not-applicable)")
      continue
      ;;
  esac

  key="$surface|$case_"
  case $'\n'"$seen_keys" in
    *$'\n'"$key"$'\n'*)
      failures+=("DUPLICATE-CASE  $surface — case '$case_' is registered more than once")
      continue
      ;;
  esac
  seen_keys="$seen_keys$key
"

  # Track the surface set (deduped) for the case-completeness pass below.
  case $'\n'"$known_surfaces"$'\n' in
    *$'\n'"$surface"$'\n'*) ;;
    *) known_surfaces="${known_surfaces:-}$surface
" ;;
  esac
  surface_cases_seen="${surface_cases_seen:-}$key
"

  if [[ "$status" == "covered" ]]; then
    n_covered_rows=$((n_covered_rows + 1))
    if [[ -z "${test_file:-}" || "$test_file" == "-" ]]; then
      failures+=("MISSING-TEST-FILE  $surface [$case_] — status=covered but no TEST_FILE given")
      continue
    fi
    resolved_test_file="$(_csd_resolve_path "$test_file")"
    if [[ ! -f "$resolved_test_file" ]]; then
      _csd_cannot_evaluate "$surface [$case_] names TEST_FILE=$test_file, which does not exist at $resolved_test_file — cannot verify a fixture mapping this gate cannot read"
    fi
    if [[ ! -r "$resolved_test_file" ]]; then
      _csd_cannot_evaluate "$surface [$case_] names TEST_FILE=$test_file ($resolved_test_file), which exists but is not readable"
    fi
    if [[ -z "${detail:-}" ]]; then
      failures+=("MISSING-ANCHOR  $surface [$case_] — status=covered but no DETAIL (anchor string) given")
      continue
    fi
    if ! grep -F -q -- "$detail" "$resolved_test_file"; then
      failures+=("MISSING-FIXTURE  $surface [$case_] — anchor not found in $test_file: \"$detail\" (the registered proof that a non-zero-exit degenerate-input fixture exists appears to have been removed or never landed)")
    fi
    # The test file must actually run in CI, or its fixture proves nothing.
    if ! grep -F -q -- "$test_file" "$CHECK_SURFACE_QUALITY_GATES_FILE"; then
      failures+=("TEST-FILE-NOT-GATED  $surface [$case_] — $test_file is referenced by the registry but scripts/quality-gates.sh never invokes it, so its fixture never runs in CI")
    fi
  else
    n_not_applicable=$((n_not_applicable + 1))
    trimmed_detail="$(printf '%s' "${detail:-}" | awk '{ gsub(/^[ \t]+|[ \t]+$/, ""); print }')"
    if [[ -z "$trimmed_detail" ]]; then
      failures+=("NOT-APPLICABLE-UNJUSTIFIED  $surface [$case_] — status=not-applicable requires a non-empty justification in DETAIL")
    fi
  fi
done <"$CHECK_SURFACE_REGISTRY_FILE"

# ---------------------------------------------------------------------------
# 2. Case-completeness: every registered surface must carry all three cases
#    (each exactly once — duplicates were already caught above).
# ---------------------------------------------------------------------------
if [[ -n "${known_surfaces:-}" ]]; then
  while IFS= read -r surface; do
    [[ -z "$surface" ]] && continue
    n_surfaces=$((n_surfaces + 1))
    for want_case in absent unreadable empty; do
      case $'\n'"${surface_cases_seen:-}" in
        *$'\n'"$surface|$want_case"$'\n'*) ;;
        *) failures+=("REGISTRY-INCOMPLETE  $surface — no '$want_case' row (every registered surface needs absent/unreadable/empty, each covered or explicitly not-applicable)") ;;
      esac
    done
  done <<<"$known_surfaces"
fi

# ---------------------------------------------------------------------------
# 3. Parse the allowlist: SURFACE<TAB>REASON. Absent file == fully burned
#    down (legal, not a failure).
# ---------------------------------------------------------------------------
allowlist_surfaces=""
if [[ -f "$CHECK_SURFACE_ALLOWLIST_FILE" ]]; then
  while IFS=$'\t' read -r a_surface a_reason || [[ -n "$a_surface" ]]; do
    [[ -z "${a_surface:-}" ]] && continue
    case "$a_surface" in \#*) continue ;; esac
    trimmed_reason="$(printf '%s' "${a_reason:-}" | awk '{ gsub(/^[ \t]+|[ \t]+$/, ""); print }')"
    if [[ -z "$trimmed_reason" ]]; then
      failures+=("ALLOWLIST-UNJUSTIFIED  $a_surface — every allowlist entry requires a non-empty REASON")
    fi
    allowlist_surfaces="$allowlist_surfaces$a_surface
"
  done <"$CHECK_SURFACE_ALLOWLIST_FILE"
fi

# Registry/allowlist must be disjoint: a surface cannot be both compliant and
# acknowledged non-compliant.
if [[ -n "${known_surfaces:-}" && -n "$allowlist_surfaces" ]]; then
  while IFS= read -r surface; do
    [[ -z "$surface" ]] && continue
    case $'\n'"$allowlist_surfaces" in
      *$'\n'"$surface"$'\n'*) failures+=("REGISTRY-ALLOWLIST-COLLISION  $surface — registered as covered AND listed on the allowlist; a surface is one or the other, never both") ;;
    esac
  done <<<"$known_surfaces"
fi

# ---------------------------------------------------------------------------
# 4. The ratchet: the allowlist's surface set may only SHRINK relative to
#    CHECK_SURFACE_ALLOWLIST_BASE_REF.
# ---------------------------------------------------------------------------
allowlist_rel="${CHECK_SURFACE_ALLOWLIST_FILE#"$CHECK_SURFACE_GIT_REPO_ROOT"/}"
if [[ "$allowlist_rel" == "$CHECK_SURFACE_ALLOWLIST_FILE" ]]; then
  # Not under CHECK_SURFACE_GIT_REPO_ROOT at all — the ratchet has nothing to
  # diff against (a fixture exercising the registry/allowlist checks above in
  # isolation, outside any git repo). Skip the ratchet rather than fail: this
  # is a scoping choice for a caller that deliberately isolated the config
  # files from git, not a "cannot evaluate" state.
  :
else
  if ! git -C "$CHECK_SURFACE_GIT_REPO_ROOT" rev-parse --verify -q "${CHECK_SURFACE_ALLOWLIST_BASE_REF}^{commit}" >/dev/null 2>&1; then
    _csd_cannot_evaluate "the allowlist ratchet base ref ($CHECK_SURFACE_ALLOWLIST_BASE_REF) does not resolve in $CHECK_SURFACE_GIT_REPO_ROOT — cannot determine whether the allowlist grew"
  fi
  prev_content=""
  prev_show_rc=0
  prev_content="$(git -C "$CHECK_SURFACE_GIT_REPO_ROOT" show "${CHECK_SURFACE_ALLOWLIST_BASE_REF}:${allowlist_rel}" 2>/dev/null)" || prev_show_rc=$?
  if [[ "$prev_show_rc" -ne 0 ]]; then
    # `git show <ref>:<path>` failed. The ref itself already resolved above,
    # so this means the path does not exist AT that ref — the bootstrap
    # case (this PR is the one introducing the allowlist file). Skip the
    # ratchet entirely rather than treating "no prior file" as "prior file
    # had zero entries", which would fail every current entry as GREW on
    # the very commit that creates the list.
    :
  else
    prev_surfaces=""
    if [[ -n "$prev_content" ]]; then
      while IFS=$'\t' read -r p_surface _rest || [[ -n "$p_surface" ]]; do
        [[ -z "${p_surface:-}" ]] && continue
        case "$p_surface" in \#*) continue ;; esac
        prev_surfaces="$prev_surfaces$p_surface
"
      done <<<"$prev_content"
    fi
    if [[ -n "$allowlist_surfaces" ]]; then
      while IFS= read -r cur_surface; do
        [[ -z "$cur_surface" ]] && continue
        case $'\n'"$prev_surfaces" in
          *$'\n'"$cur_surface"$'\n'*) ;;
          *) failures+=("ALLOWLIST-GREW  $cur_surface — present in $CHECK_SURFACE_ALLOWLIST_FILE now but not at $CHECK_SURFACE_ALLOWLIST_BASE_REF; the allowlist is a shrink-only ratchet (acceptance criterion 3), never a place to add a newly-discovered non-compliant surface") ;;
        esac
      done <<<"$allowlist_surfaces"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# Verdict.
# ---------------------------------------------------------------------------
n_allowlisted=0
if [[ -n "$allowlist_surfaces" ]]; then
  n_allowlisted="$(printf '%s' "$allowlist_surfaces" | grep -c . || true)"
fi
echo "Checked $n_surfaces registered surface(s) ($n_covered_rows covered row(s), $n_not_applicable not-applicable row(s)); $n_allowlisted surface(s) on the allowlist ($CHECK_SURFACE_ALLOWLIST_FILE)"
if (( ${#failures[@]} > 0 )); then
  printf '%s\n' "${failures[@]}"
  echo "---"
  echo "failures: ${#failures[@]}"
  echo "$PREFIX: FAIL"
  exit 1
fi
echo "$PREFIX: OK"
