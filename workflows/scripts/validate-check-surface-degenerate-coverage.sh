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
# THIS SCRIPT IS ITSELF A REGISTERED CHECK SURFACE (all three cases, in
# check-surface-registry.tsv) — an earlier cut of this gate was not, which
# is exactly how its own absent/unreadable/empty-registry paths shipped
# unverified (a first review round found an EMPTY registry passed vacuously;
# see the EMPTY-REGISTRY check below). Registering the gate against itself is
# the structural fix, not a patch: the registry ratchet (§4 below) now makes
# it impossible to silently delete or downgrade this gate's own coverage.
#
# ── REGISTRY, NOT A GLOB (load-bearing — read before extending) ────────────
# The target set is workflows/scripts/config/check-surface-registry.tsv, a
# committed, human-reviewed list. A `validate-*.sh` FILENAME glob cannot reach
# motivating instance 3 above: `replay.sh diff-scope` is a SUBCOMMAND of a
# general orchestration script, not a file this repo names `validate-*`. A
# registry SURFACE token is therefore either a bare script path
# (`workflows/scripts/validate-provider-disclosure.sh`) or a
# `<script-path>:<subcommand>` pair (`workflows/scripts/model-comparison/
# replay.sh:diff-scope`), split on the LAST `:` — see _csd_surface_script()
# and _csd_surface_exists() below, which actually enforce this grammar (an
# earlier cut of this header cited a function of this name that did not
# exist; a row naming a script the tree doesn't have now fails
# SURFACE-NOT-FOUND rather than silently passing).
#
# NO LONGER A SEED SET — COVERAGE IS NO LONGER OPT-IN (temperloop#1491).
# The first cut of this gate (temperloop#1476) registered exactly the three
# surfaces epic #1409's motivating instances named, plus this gate itself,
# and said so honestly: an UNREGISTERED surface was not failed, it was simply
# not checked. That is a seed, not a class — the registry documented what
# somebody remembered, and a check surface added next month inherited the
# original defect silently. §5 below closes it: the candidate set is now
# ENUMERATED MECHANICALLY from the tree and a candidate with no disposition
# anywhere FAILS. Registering the rest of the repo's surfaces was the first
# OUTPUT of that assertion, never the fix itself — a longer hand-written list
# is still a list somebody sampled.
#
# ── The three config files ──────────────────────────────────────────────────
#   check-surface-registry.tsv            SURFACE / CASE / STATUS / TEST_FILE /
#                                          DETAIL — one row per (surface, case).
#                                          STATUS=covered rows are verified by
#                                          THIS gate (below); STATUS=not-
#                                          applicable rows carry a mandatory,
#                                          human-readable justification instead
#                                          (a git ref has no chmod-unreadable
#                                          analog — see the diff-scope rows).
#                                          NEVER EMPTY (see EMPTY-REGISTRY
#                                          below) and, once a (surface,case)
#                                          row lands, it can only be kept or
#                                          upgraded (not-applicable ->
#                                          covered) — see §4.
#   check-surface-degenerate-allowlist.tsv  SURFACE / REASON for every
#                                          registered-but-not-yet-compliant
#                                          surface. SHRINK-ONLY RATCHET
#                                          (acceptance criterion 3): a surface
#                                          name here can only be REMOVED
#                                          relative to the ratchet base ref,
#                                          never added — see §4. Starting
#                                          non-empty is expected, not a
#                                          failure.
#   check-surface-discovery.tsv            SURFACE / DISPOSITION / REASON for
#                                          every MECHANICALLY DISCOVERED
#                                          surface that is deliberately not
#                                          registered (temperloop#1491) —
#                                          `pending` (should be registered,
#                                          blocked on something named;
#                                          SHRINK-ONLY per §4c) or `excluded`
#                                          (not a registrable check surface).
#                                          §5 fails any discovered surface in
#                                          none of the three files. An ABSENT
#                                          ledger means ZERO dispositions,
#                                          which is the STRICT reading.
#
# ── What "covered" actually verifies (per case) ─────────────────────────────
#   1. TEST_FILE exists and is readable (else CANNOT EVALUATE — see below).
#   2. DETAIL is a SUBSTANTIAL, UNIQUE anchor: at least
#      $_CSD_ANCHOR_MIN_LEN non-whitespace characters, found via `grep -F`
#      in TEST_FILE EXACTLY ONCE (a duplicate is itself a collision risk —
#      MEDIUM 5), and the ONE matching line is not a `#`-comment. This is a
#      STRUCTURAL presence check, not a re-execution of the fixture —
#      quality-gates.sh already runs the fixture itself elsewhere; this
#      gate's own job is registry/mapping integrity, proven by the
#      discrimination test in this gate's own fixture suite (delete the
#      assertion line carrying the anchor, watch this gate go red naming the
#      surface+case, restore, watch it go green). The anchor must be written
#      ON the assertion itself (a `check_eq`/`check` call's own label
#      argument, or a `[ ... ] || fail "<anchor>"` line) — NOT a separate
#      `ok(...)` line that runs after the real assertions, which can survive
#      the assertions being deleted (the false-negative this gate's own
#      review caught, HIGH 2).
#   3. TEST_FILE is itself WIRED INTO an ACTIVE (non-commented) invocation
#      line in quality-gates.sh — see _csd_test_file_gated() below. A bare
#      substring grep over the whole file (the earlier cut) is satisfied by
#      a commented-out gate line, which is exactly how this repo disables a
#      suite (HIGH 3) — "a dedicated fixture nobody runs in CI proves
#      nothing" applies just as much to a DISABLED one.
#
# ── §4. The two ratchets (acceptance criterion 3, MEDIUM 4) ────────────────
# Both files are diffed against a resolved BASE REF (see §origin resolution
# below): a surface/row present at the base ref must still be reachable now.
#   - ALLOWLIST: a surface name present at the base ref but absent now is a
#     legal SHRINK (the surface became compliant). A surface name present
#     now but absent at the base ref is ALLOWLIST-GREW — a shrink-only
#     ratchet, never a place to add a newly-discovered non-compliant
#     surface.
#   - REGISTRY: the MIRROR-IMAGE ratchet. A (surface,case) row present at
#     the base ref must STILL be present now, and its STATUS may only
#     IMPROVE (not-applicable -> covered), never regress (covered ->
#     not-applicable) or vanish. "The cheapest escape from a failing anchor
#     is deleting the row" (MEDIUM 4) — this closes exactly that.
# BOOTSTRAP (the commit that introduces a config file for the first time) is
# exempt from its own ratchet, but ONLY when the file was genuinely ADDED in
# this diff per git's own rename-aware `--diff-filter=A` (MEDIUM 6b) — a
# RENAME of an already-ratcheted file is never treated as a fresh
# introduction, so renaming a file cannot be used to re-arm its own
# bootstrap exemption and smuggle a new entry through unratcheted.
# VENDORED-KERNEL SUBTREE ARM (temperloop#1559). In a COMPOSED OVERLAY the
# allowlist file is a symlink resolving into the vendored kernel subtree
# (`kernel/`, per scripts/update-kernel.sh's fixed `--prefix=kernel`), so
# every path seam is first resolved to its PHYSICAL path (symlinks followed)
# before the relpath/ratchet math — comparing a base-ref SYMLINK BLOB's
# target text as if it were TSV content is never meaningful. When the repo
# root carries `.kernel-pin` AND the resolved allowlist lands under
# `kernel/`, rows there are upstream-owned (hand edits inside kernel/ are
# forbidden; upstream's own CI already ran this same shrink-only ratchet
# when a row was added there), so re-ratcheting them against the OVERLAY's
# origin/main would false-fail every allowlist-growing vendor bump. Instead,
# a current row passes when present at the base ref's copy OR in the
# vendored kernel's own pulled content — the tree of the newest subtree
# SQUASH commit reachable from HEAD (the commit `git subtree pull --squash`
# minted, identified by its `git-subtree-dir: kernel` trailer; its tree IS
# the kernel repo root, so the lookup path drops the `kernel/` prefix). An
# overlay-authored row hand-edited into kernel/'s copy is in NEITHER set and
# still fails ALLOWLIST-GREW — the shrink-only intent survives, per-row. If
# no such squash commit is reachable (a consumer that vendored by copy, or a
# clone too shallow to see it), the arm degrades FAIL-CLOSED to the plain
# base-ref ratchet, and the verdict line says so. A kernel checkout (no
# `.kernel-pin`, no `kernel/` prefix) never enters this arm — its ratchet is
# byte-for-byte the pre-#1559 behavior.
# UNRESOLVABLE base ref (an EXPLICIT operator override that doesn't resolve)
# is CANNOT EVALUATE — never a silent pass, because "did it regress" is
# undecidable without a comparison point. NO ORIGIN REMOTE AT ALL (the
# auto-resolved default — MEDIUM 7) degrades to a quiet, reported SKIP
# instead, so a stranger's fresh/offline clone doesn't hard-fail `checks`.
# The verdict line always states, for EACH file, whether it was compared (and
# against what) or skipped (and why) — MEDIUM 6c, so a green run never looks
# identical to a silently-disabled ratchet.
#
# ── §origin resolution (MEDIUM 7) ───────────────────────────────────────────
# An explicit CHECK_SURFACE_ALLOWLIST_BASE_REF always wins verbatim (an
# operator's deliberate, possibly-broken override is CANNOT EVALUATE, never
# silently skipped). Otherwise: resolve refs/remotes/origin/HEAD, falling
# back to refs/remotes/origin/main, bailing (quiet SKIP) if there is no
# origin remote at all — the exact idiom
# workflows/scripts/lib/checkout-freshness.sh:60-62 already uses, so a
# stranger checkout whose default branch isn't literally "main" degrades the
# same way that guard does, rather than hard-failing `checks`.
#
# ── Fail-closed discipline (acceptance criterion 5) ─────────────────────────
# This gate must never itself be an instance of the defect it enforces
# against: it must not report success when it could not evaluate, AND it
# must not report success when it evaluated and found NOTHING (an absent
# registry fails closed; so must an EMPTY one — EMPTY-REGISTRY below, HIGH
# 1). Every hard stop (missing/unreadable registry or allowlist file, a
# registered TEST_FILE this gate cannot read, an unresolvable EXPLICIT
# ratchet base ref) routes through workflows/scripts/lib/cannot-evaluate.sh's
# cannot_evaluate_emit — the shared idiom hoisted in temperloop#1475 (epic
# #1409) specifically so a caller that forgets to branch still fails CLOSED
# (RC_CANNOT_EVALUATE=2, non-zero) rather than falling through to an
# implicit OK. Every ordinary FAIL (a missing fixture, an unjustified
# not-applicable claim, allowlist growth, a registry regression, an empty
# registry) is collected into one array and reported ALL AT ONCE, tagged
# with a stable prefix (MISSING-FIXTURE, TEST-FILE-NOT-GATED,
# EMPTY-REGISTRY, REGISTRY-REGRESSED, ...) naming the exact surface and case
# where one applies — never a bare non-zero exit (acceptance criterion 5).
#
# Usage:
#   workflows/scripts/validate-check-surface-degenerate-coverage.sh
#   (a direct-`bash` KERNEL_GATES entry in scripts/quality-gates.sh)
#
# Env overrides (FIXTURE-TEST SEAM, all optional — used by this gate's own
# fixture suite, workflows/scripts/tests/test_check_surface_degenerate_
# coverage.sh, to point every input at a scratch tree):
#   CHECK_SURFACE_REGISTRY_FILE          default: workflows/scripts/config/
#                                         check-surface-registry.tsv
#   CHECK_SURFACE_ALLOWLIST_FILE         default: workflows/scripts/config/
#                                         check-surface-degenerate-allowlist.tsv
#   CHECK_SURFACE_DISCOVERY_FILE         default: workflows/scripts/config/
#                                         check-surface-discovery.tsv
#   CHECK_SURFACE_DISCOVERY_ROOT         default: CHECK_SURFACE_REPO_ROOT —
#                                         the tree §5 enumerates
#   CHECK_SURFACE_QUALITY_GATES_FILE     default: scripts/quality-gates.sh
#   CHECK_SURFACE_GIT_REPO_ROOT          default: this repo's root — the repo
#                                         every `git` ratchet operation runs
#                                         against (a fixture points this at a
#                                         throwaway git repo)
#   CHECK_SURFACE_ALLOWLIST_BASE_REF     default: EMPTY — auto-resolved (see
#                                         §origin resolution); an explicit
#                                         value is used verbatim for BOTH
#                                         ratchets
#   CHECK_SURFACE_REPO_ROOT              default: this repo's root — the root
#                                         a relative TEST_FILE/quality-gates/
#                                         registry/allowlist path is resolved
#                                         against (MEDIUM 6a: every path seam
#                                         is resolved to absolute up front, so
#                                         an operator-supplied RELATIVE value
#                                         can never silently disable the
#                                         ratchet's own path-prefix check)
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
: "${CHECK_SURFACE_DISCOVERY_FILE:=$SCRIPT_DIR/config/check-surface-discovery.tsv}"
: "${CHECK_SURFACE_QUALITY_GATES_FILE:=$CHECK_SURFACE_REPO_ROOT/scripts/quality-gates.sh}"
# The tree §5's discovery pass enumerates. Defaults to the same root every
# other relative path seam resolves against, so a fixture that redirects
# CHECK_SURFACE_REPO_ROOT at a scratch tree redirects discovery with it.
: "${CHECK_SURFACE_DISCOVERY_ROOT:=$CHECK_SURFACE_REPO_ROOT}"
# Empty by default — §origin resolution auto-resolves at ratchet time. An
# operator-set value is honored VERBATIM (never re-resolved).
: "${CHECK_SURFACE_ALLOWLIST_BASE_REF:=}"

# shellcheck source=workflows/scripts/lib/cannot-evaluate.sh
source "$SCRIPT_DIR/lib/cannot-evaluate.sh"

PREFIX="validate-check-surface-degenerate-coverage"

_csd_cannot_evaluate() {
  cannot_evaluate_emit "$PREFIX" "$1"
  exit $?
}

# _csd_resolve_path <maybe-relative> — absolute paths pass through; anything
# else is resolved against CHECK_SURFACE_REPO_ROOT. Defined before the
# initial checks below so every file-path seam (registry/allowlist/quality-
# gates) can be normalized to absolute BEFORE anything downstream — MEDIUM
# 6a: an operator-supplied RELATIVE CHECK_SURFACE_ALLOWLIST_FILE used to
# silently defeat the ratchet's own "is this under the git repo root" prefix
# check, since that check only ever handled the absolute-by-default case.
_csd_resolve_path() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s\n' "$CHECK_SURFACE_REPO_ROOT/$1" ;;
  esac
}

CHECK_SURFACE_REGISTRY_FILE="$(_csd_resolve_path "$CHECK_SURFACE_REGISTRY_FILE")"
CHECK_SURFACE_ALLOWLIST_FILE="$(_csd_resolve_path "$CHECK_SURFACE_ALLOWLIST_FILE")"
CHECK_SURFACE_QUALITY_GATES_FILE="$(_csd_resolve_path "$CHECK_SURFACE_QUALITY_GATES_FILE")"
CHECK_SURFACE_DISCOVERY_FILE="$(_csd_resolve_path "$CHECK_SURFACE_DISCOVERY_FILE")"
CHECK_SURFACE_DISCOVERY_ROOT="$(_csd_resolve_path "$CHECK_SURFACE_DISCOVERY_ROOT")"

[[ -f "$CHECK_SURFACE_REGISTRY_FILE" ]] || _csd_cannot_evaluate "registry file not found: $CHECK_SURFACE_REGISTRY_FILE"
[[ -r "$CHECK_SURFACE_REGISTRY_FILE" ]] || _csd_cannot_evaluate "registry file exists but is not readable: $CHECK_SURFACE_REGISTRY_FILE"

# An absent allowlist is legal (fully burned down); an UNREADABLE one is not.
if [[ -e "$CHECK_SURFACE_ALLOWLIST_FILE" && ! -r "$CHECK_SURFACE_ALLOWLIST_FILE" ]]; then
  _csd_cannot_evaluate "allowlist file exists but is not readable: $CHECK_SURFACE_ALLOWLIST_FILE"
fi

# Same rule as the allowlist: an ABSENT discovery ledger is legal and means
# ZERO dispositions (so §5 requires every discovered surface to be registered
# or allowlisted — strictly MORE demanding, never a silent pass); an
# UNREADABLE one is CANNOT EVALUATE, because "is this surface dispositioned"
# is undecidable without reading it.
if [[ -e "$CHECK_SURFACE_DISCOVERY_FILE" && ! -r "$CHECK_SURFACE_DISCOVERY_FILE" ]]; then
  _csd_cannot_evaluate "discovery ledger exists but is not readable: $CHECK_SURFACE_DISCOVERY_FILE"
fi

[[ -f "$CHECK_SURFACE_QUALITY_GATES_FILE" ]] || _csd_cannot_evaluate "quality-gates file not found: $CHECK_SURFACE_QUALITY_GATES_FILE"
[[ -r "$CHECK_SURFACE_QUALITY_GATES_FILE" ]] || _csd_cannot_evaluate "quality-gates file exists but is not readable: $CHECK_SURFACE_QUALITY_GATES_FILE"

failures=()
n_surfaces=0
n_covered_rows=0
n_not_applicable=0
_CSD_ANCHOR_MIN_LEN=12

# ---------------------------------------------------------------------------
# Tab-safe TSV line splitting (LOW 9). `IFS=$'\t' read` COLLAPSES consecutive
# tab characters because tab is one of bash's three special "IFS whitespace"
# characters regardless of what IFS is actually set to — a genuinely empty
# middle field (e.g. an accidentally-blank TEST_FILE column) silently shifts
# every field after it left instead of parsing as empty. `awk -F'\t'` does
# NOT collapse a single-character field separator, so every parse below goes
# through this helper: read the file/string through awk once, re-joining
# fields on \x1f (ASCII US, a byte that cannot appear in a text TSV), then
# `IFS=$'\x1f' read` — which does NOT collapse (\x1f is not IFS whitespace) —
# over the result.
#
# WHY \x1f AND NOT \x01 (temperloop#1649). The first cut of this helper joined
# on \x01, which is CORRECT on bash 4+ and SILENTLY BROKEN on bash 3.2 — the
# system /bin/bash on every macOS host, and what `bash scripts/quality-gates.sh`
# resolves to on the macos-latest runner. Bash uses 0x01 internally as CTLESC
# (its own quoting marker) and 0x7f as CTLNUL; bash 3.2's word splitting is not
# 8-bit clean for either, so `IFS=$'\x01' read -r a b c` on `a<0x01>b<0x01>c`
# does NOT split: it returns the WHOLE line, 0x01 bytes and all, in `$a`, and
# leaves `$b`/`$c` empty. Every registry row then parsed as one field, this
# gate reported "Checked 0 registered surface(s)" plus a BAD-CASE per row, and
# nightly-macos was red for seven consecutive nights while ubuntu (bash 5.x)
# stayed green. This is a BASH-VERSION defect, NOT the BSD-vs-GNU dialect
# family (temperloop#1549/#1422): the awk stage above emits byte-identical
# output on BSD and GNU awk alike — holding awk fixed and swapping only the
# bash binary flips the result. \x1f and \x1e are not bash marker bytes and
# split correctly on 3.2 and 5.x alike. scripts/lint-bash32-ctlesc-ifs.sh is
# the mechanical guard that keeps 0x01/0x7f from being reached for again.
# ---------------------------------------------------------------------------
_csd_tsv_file() { # <file> -> \x1f-joined lines on stdout
  awk -F'\t' 'BEGIN{OFS="\x1f"} {$1=$1; print}' "$1"
}
_csd_tsv_string() { # <string> -> \x1f-joined lines on stdout
  printf '%s' "$1" | awk -F'\t' 'BEGIN{OFS="\x1f"} {$1=$1; print}'
}

# _csd_surface_script <surface> -> the script-path half of a SURFACE token,
# splitting on the LAST `:` (a `<script>:<subcommand>` pair) or the whole
# token when there is no colon.
_csd_surface_script() {
  case "$1" in
    *:*) printf '%s\n' "${1%:*}" ;;
    *) printf '%s\n' "$1" ;;
  esac
}

# _csd_surface_exists <surface> -> rc 0 iff the SURFACE's script half exists
# in the tree (MEDIUM 8 — the documented SURFACE grammar, enforced for real:
# a row naming a script the tree does not have now fails, rather than
# silently passing).
_csd_surface_exists() {
  local script resolved
  script="$(_csd_surface_script "$1")"
  resolved="$(_csd_resolve_path "$script")"
  [[ -f "$resolved" ]]
}

# _csd_discovery_surface_exists <surface> -> rc 0 iff the SURFACE's script
# half exists under the DISCOVERY root. Same check as _csd_surface_exists
# above, resolved against CHECK_SURFACE_DISCOVERY_ROOT instead of
# CHECK_SURFACE_REPO_ROOT: a discovery-ledger row's path is by construction
# relative to the tree §5 enumerates. In production the two roots are the
# same path, so this is identical to _csd_surface_exists; they diverge only
# under a fixture that redirects one of them.
_csd_discovery_surface_exists() {
  local script resolved
  script="$(_csd_surface_script "$1")"
  case "$script" in
    /*) resolved="$script" ;;
    *) resolved="$CHECK_SURFACE_DISCOVERY_ROOT/$script" ;;
  esac
  [[ -f "$resolved" ]]
}

# _csd_test_file_gated <quality-gates-file> <test_file> -> rc 0 iff
# <test_file> appears on an ACTIVE (non-comment) invocation line — HIGH 3: a
# bare substring grep over the whole file is satisfied by a COMMENTED-OUT
# gate line, which is exactly how this repo disables a suite. A line counts
# as active iff, after stripping leading whitespace, it does not start with
# `#` and contains "bash" or "make" (quality-gates.sh's only two invocation
# verbs) somewhere on it alongside the test file path.
_csd_test_file_gated() {
  local qg="$1" tf="$2" line trimmed
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in *"$tf"*) ;; *) continue ;; esac
    trimmed="${line#"${line%%[![:space:]]*}"}"
    case "$trimmed" in
      '#'*) continue ;; # a comment line never counts, regardless of content
    esac
    case "$trimmed" in
      *bash* | *make*) return 0 ;;
    esac
  done <"$qg"
  return 1
}

# _csd_anchor_ok <file> <detail> -> rc 0 iff DETAIL is a valid anchor:
# substantial (>= _CSD_ANCHOR_MIN_LEN non-whitespace-trimmed chars), found in
# FILE via `grep -F` EXACTLY ONCE, and that one match is not a `#`-comment
# line (MEDIUM 5). Sets _csd_anchor_reason on failure.
_csd_anchor_ok() {
  local file="$1" detail="$2" trimmed count matching_line trimmed_line
  trimmed="$(printf '%s' "$detail" | awk '{ gsub(/^[ \t]+|[ \t]+$/, ""); print }')"
  if [[ "${#trimmed}" -lt "$_CSD_ANCHOR_MIN_LEN" ]]; then
    _csd_anchor_reason="anchor is too short or whitespace-only (want >= $_CSD_ANCHOR_MIN_LEN non-whitespace character(s)): \"$detail\""
    return 1
  fi
  count="$(grep -Fc -- "$detail" "$file" 2>/dev/null || true)"
  case "$count" in '' | *[!0-9]*) count=0 ;; esac
  if [[ "$count" -eq 0 ]]; then
    _csd_anchor_reason="anchor not found in $file: \"$detail\" (the registered proof that a non-zero-exit degenerate-input fixture exists appears to have been removed or never landed)"
    return 1
  fi
  if [[ "$count" -gt 1 ]]; then
    _csd_anchor_reason="anchor appears $count times in $file (want exactly 1 — a duplicated anchor is itself a collision risk, MEDIUM 5): \"$detail\""
    return 1
  fi
  matching_line="$(grep -F -- "$detail" "$file")"
  trimmed_line="${matching_line#"${matching_line%%[![:space:]]*}"}"
  case "$trimmed_line" in
    '#'*)
      _csd_anchor_reason="anchor's only match in $file is inside a comment line, not a live assertion: \"$detail\""
      return 1
      ;;
  esac
  return 0
}

# ---------------------------------------------------------------------------
# 1. Parse the registry: SURFACE<TAB>CASE<TAB>STATUS<TAB>TEST_FILE<TAB>DETAIL
# ---------------------------------------------------------------------------
# One accumulator per surface x case, bash-3.2-safe (no associative arrays):
# parallel strings keyed by "surface|case" markers, checked for duplicates as
# we go. current_registry_status additionally records "surface\x02case\x02status"
# triples for the registry ratchet (§4).
seen_keys=""
known_surfaces=""
surface_cases_seen=""
current_registry_status=""

while IFS=$'\x1f' read -r surface case_ status test_file detail || [[ -n "${surface:-}" ]]; do
  [[ -z "${surface:-}" ]] && continue
  case "$surface" in \#*) continue ;; esac

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
  is_new_surface=0
  case $'\n'"$known_surfaces"$'\n' in
    *$'\n'"$surface"$'\n'*) ;;
    *)
      known_surfaces="${known_surfaces:-}$surface
"
      is_new_surface=1
      ;;
  esac
  surface_cases_seen="${surface_cases_seen:-}$key
"
  current_registry_status="${current_registry_status:-}$surface"$'\x02'"$case_"$'\x02'"$status
"

  # MEDIUM 8: the SURFACE grammar is enforced for real — check once per
  # newly-seen surface (cheap, and avoids 3 duplicate failure lines for the
  # same bad surface across its three case rows).
  if [[ "$is_new_surface" -eq 1 ]] && ! _csd_surface_exists "$surface"; then
    failures+=("SURFACE-NOT-FOUND  $surface — the script half ($(_csd_surface_script "$surface")) does not exist in the tree")
  fi

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
    elif ! _csd_anchor_ok "$resolved_test_file" "$detail"; then
      failures+=("MISSING-FIXTURE  $surface [$case_] — ${_csd_anchor_reason}")
    fi
    # The test file must actually run in CI on an ACTIVE line, or its
    # fixture proves nothing (HIGH 3).
    if ! _csd_test_file_gated "$CHECK_SURFACE_QUALITY_GATES_FILE" "$test_file"; then
      failures+=("TEST-FILE-NOT-GATED  $surface [$case_] — $test_file is referenced by the registry but has no ACTIVE (non-commented) invocation in $CHECK_SURFACE_QUALITY_GATES_FILE, so its fixture never runs in CI")
    fi
  else
    n_not_applicable=$((n_not_applicable + 1))
    trimmed_detail="$(printf '%s' "${detail:-}" | awk '{ gsub(/^[ \t]+|[ \t]+$/, ""); print }')"
    if [[ -z "$trimmed_detail" ]]; then
      failures+=("NOT-APPLICABLE-UNJUSTIFIED  $surface [$case_] — status=not-applicable requires a non-empty justification in DETAIL")
    fi
  fi
done < <(_csd_tsv_file "$CHECK_SURFACE_REGISTRY_FILE")

# ---------------------------------------------------------------------------
# 1b. EMPTY-REGISTRY (HIGH 1): a registry with zero parsed surfaces is a
#    vacuous pass in exactly the same shape epic #1409 exists to close —
#    absent and unreadable already fail closed above; empty (or comment-only)
#    must too. A file with malformed-only rows already populates `failures`
#    via BAD-CASE/BAD-STATUS above and is not silently green, so this check
#    fires ONLY on the genuinely-empty/comment-only case.
# ---------------------------------------------------------------------------
if [[ -z "${known_surfaces:-}" ]]; then
  failures+=("EMPTY-REGISTRY  $CHECK_SURFACE_REGISTRY_FILE parses to ZERO registered check surfaces — an empty or comment-only registry is a vacuous pass, exactly the defect class this gate exists to close")
fi

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
  while IFS=$'\x1f' read -r a_surface a_reason || [[ -n "${a_surface:-}" ]]; do
    [[ -z "${a_surface:-}" ]] && continue
    case "$a_surface" in \#*) continue ;; esac
    trimmed_reason="$(printf '%s' "${a_reason:-}" | awk '{ gsub(/^[ \t]+|[ \t]+$/, ""); print }')"
    if [[ -z "$trimmed_reason" ]]; then
      failures+=("ALLOWLIST-UNJUSTIFIED  $a_surface — every allowlist entry requires a non-empty REASON")
    fi
    if ! _csd_surface_exists "$a_surface"; then
      failures+=("SURFACE-NOT-FOUND  $a_surface — the script half ($(_csd_surface_script "$a_surface")) does not exist in the tree")
    fi
    allowlist_surfaces="$allowlist_surfaces$a_surface
"
  done < <(_csd_tsv_file "$CHECK_SURFACE_ALLOWLIST_FILE")
fi

# ---------------------------------------------------------------------------
# 3b. Parse the DISCOVERY DISPOSITION LEDGER: SURFACE<TAB>DISPOSITION<TAB>
#     REASON (temperloop#1491). This is the third, and last, legal home for a
#     check surface: registered (compliant), allowlisted (registered but not
#     yet proven), or dispositioned here (`pending` — should be registered,
#     blocked on something named; `excluded` — not a registrable check
#     surface at all). §5 below fails any MECHANICALLY DISCOVERED surface
#     that is in none of the three. An absent ledger parses to zero rows,
#     which is the strict reading, not a lenient one.
# ---------------------------------------------------------------------------
discovery_surfaces=""
discovery_pending=""
n_pending=0
n_excluded=0
if [[ -f "$CHECK_SURFACE_DISCOVERY_FILE" ]]; then
  while IFS=$'\x1f' read -r d_surface d_disp d_reason || [[ -n "${d_surface:-}" ]]; do
    [[ -z "${d_surface:-}" ]] && continue
    case "$d_surface" in \#*) continue ;; esac
    case "${d_disp:-}" in
      pending)
        n_pending=$((n_pending + 1))
        discovery_pending="$discovery_pending$d_surface
"
        ;;
      excluded) n_excluded=$((n_excluded + 1)) ;;
      *)
        failures+=("BAD-DISPOSITION  $d_surface — unrecognized disposition '${d_disp:-}' in $CHECK_SURFACE_DISCOVERY_FILE (want: pending, excluded)")
        continue
        ;;
    esac
    trimmed_reason="$(printf '%s' "${d_reason:-}" | awk '{ gsub(/^[ \t]+|[ \t]+$/, ""); print }')"
    if [[ -z "$trimmed_reason" ]]; then
      failures+=("DISPOSITION-UNJUSTIFIED  $d_surface — every discovery-ledger row requires a non-empty REASON (a disposition without a reason is the silence this ledger exists to end)")
    fi
    if ! _csd_discovery_surface_exists "$d_surface"; then
      failures+=("SURFACE-NOT-FOUND  $d_surface — the script half ($(_csd_surface_script "$d_surface")) does not exist in the tree (a stale discovery-ledger row: prune it)")
    fi
    discovery_surfaces="$discovery_surfaces$d_surface
"
  done < <(_csd_tsv_file "$CHECK_SURFACE_DISCOVERY_FILE")
fi

# A ledger row for a surface that has SINCE been registered (or allowlisted)
# is SUPERSEDED, not a failure. This is deliberate and load-bearing for
# concurrent work: the PR that registers a `pending` surface is authored
# against a tree where the row still exists, and hard-failing on the overlap
# would make every such registration a two-PR dance. The row is reported so
# it gets pruned, and it can never HIDE anything — the surface is compliant
# by the registry's own rules either way.
superseded_lines=()
if [[ -n "$discovery_surfaces" ]]; then
  while IFS= read -r d_surface; do
    [[ -z "$d_surface" ]] && continue
    case $'\n'"${known_surfaces:-}"$'\n' in
      *$'\n'"$d_surface"$'\n'*)
        superseded_lines+=("note: discovery-ledger row $d_surface is SUPERSEDED — the surface is now in $CHECK_SURFACE_REGISTRY_FILE; prune the ledger row")
        continue
        ;;
    esac
    case $'\n'"$allowlist_surfaces" in
      *$'\n'"$d_surface"$'\n'*)
        superseded_lines+=("note: discovery-ledger row $d_surface is SUPERSEDED — the surface is now on $CHECK_SURFACE_ALLOWLIST_FILE; prune the ledger row")
        ;;
    esac
  done <<<"$discovery_surfaces"
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
# 4. THE TWO RATCHETS.
# ---------------------------------------------------------------------------
ratchet_lines=()

# §origin resolution (MEDIUM 7): an explicit override wins verbatim; a
# resolvable git working tree with no explicit override auto-resolves via
# origin/HEAD -> origin/main -> "no origin, skip quietly" (checkout-
# freshness.sh's own idiom).
_csd_ratchet_base_ref=""
_csd_ratchet_explicit=0
_csd_ratchet_skip_reason=""
if [[ -n "$CHECK_SURFACE_ALLOWLIST_BASE_REF" ]]; then
  _csd_ratchet_base_ref="$CHECK_SURFACE_ALLOWLIST_BASE_REF"
  _csd_ratchet_explicit=1
elif git -C "$CHECK_SURFACE_GIT_REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  _csd_ratchet_base_ref="$(git -C "$CHECK_SURFACE_GIT_REPO_ROOT" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)"
  if [[ -z "$_csd_ratchet_base_ref" ]] && git -C "$CHECK_SURFACE_GIT_REPO_ROOT" show-ref --verify --quiet refs/remotes/origin/main; then
    _csd_ratchet_base_ref="origin/main"
  fi
  if [[ -z "$_csd_ratchet_base_ref" ]]; then
    _csd_ratchet_skip_reason="no origin remote resolvable in $CHECK_SURFACE_GIT_REPO_ROOT (checked refs/remotes/origin/HEAD then refs/remotes/origin/main)"
  fi
else
  _csd_ratchet_skip_reason="$CHECK_SURFACE_GIT_REPO_ROOT is not a git working tree"
fi

if [[ -n "$_csd_ratchet_base_ref" ]]; then
  if ! git -C "$CHECK_SURFACE_GIT_REPO_ROOT" rev-parse --verify -q "${_csd_ratchet_base_ref}^{commit}" >/dev/null 2>&1; then
    if [[ "$_csd_ratchet_explicit" -eq 1 ]]; then
      _csd_cannot_evaluate "the ratchet base ref ($_csd_ratchet_base_ref) does not resolve in $CHECK_SURFACE_GIT_REPO_ROOT — cannot determine whether the allowlist/registry regressed"
    fi
    # An AUTO-resolved ref that fails to resolve as a commit (rare — the
    # symbolic-ref/show-ref probes above already require it to exist) is
    # treated the same as "no origin": skip quietly rather than abort.
    _csd_ratchet_skip_reason="the auto-resolved ratchet base ref ($_csd_ratchet_base_ref) does not resolve to a commit in $CHECK_SURFACE_GIT_REPO_ROOT"
    _csd_ratchet_base_ref=""
  fi
fi

# _csd_ratchet_file_added <relpath> -> rc 0 iff <relpath> was genuinely ADDED
# (never existed under this exact path before) since _csd_ratchet_base_ref,
# per git's own RENAME-AWARE diff (-M) — MEDIUM 6b. A rename FROM an
# already-ratcheted file is never treated as a bootstrap, so a
# rename-plus-new-entry attack can't hide behind "this exact path never
# existed before": the renamed-to path fails this check, the ratchet
# proceeds, `git show <base>:<new-path>` fails (nothing there under the new
# name), prev content is empty, and every current entry is flagged as
# grown/regressed — fail CLOSED on the exploit, not silently bootstrapped.
_csd_ratchet_file_added() {
  local relpath="$1" added
  # NO path filter on the diff itself (load-bearing, not a stray omission):
  # `git diff -M ... -- <path>` restricted to a SINGLE path defeats rename
  # detection outright — git's renamer needs BOTH the old and new path in
  # view to pair them, and a single-path filter shows it only the new side,
  # which it then reports as a bare ADD every time. Verified empirically: the
  # exact same rename, diffed with `-- newpath` reports `A newpath`; diffed
  # with no path filter at all correctly reports nothing under --diff-filter=A
  # (the pair is recognized as a rename instead). So: compute the FULL
  # add-list once, then look for an EXACT match.
  added="$(git -C "$CHECK_SURFACE_GIT_REPO_ROOT" diff -M --diff-filter=A --name-only "$_csd_ratchet_base_ref" 2>/dev/null)"
  # No `-q` on a piped grep (temperloop#1050): `grep -q` exits at its FIRST
  # match without draining the pipe, so the upstream `printf` can take
  # SIGPIPE and, under `set -o pipefail` (this script's own shebang line),
  # report 141 nondeterministically instead of the match. Drop `q`, redirect
  # to /dev/null instead.
  printf '%s\n' "$added" | grep -Fx -- "$relpath" >/dev/null
}

# _csd_physical_path <abs-path> -> the fully symlink-resolved (physical) form
# on stdout: the final-component symlink chain is followed via the repo's
# standard readlink loop (portable — no GNU readlink -f), then the containing
# directory is physicalized with `cd -P`. A path whose parent directory does
# not exist passes through unchanged (downstream -f/-r checks own that
# failure). Needed by the ratchet (temperloop#1559): in a composed overlay
# the allowlist/registry files are SYMLINKS into the vendored kernel subtree,
# and `git show <ref>:<symlink-path>` returns the link's TARGET TEXT, not the
# file content — so every relpath the ratchet feeds to git must be computed
# from physical paths, never the symlink spelling.
_csd_physical_path() {
  local p="$1" dir
  while [[ -L "$p" ]]; do
    dir="$(cd -P "$(dirname "$p")" 2>/dev/null && pwd)" || { printf '%s\n' "$p"; return 0; }
    p="$(readlink "$p")"
    case "$p" in /*) ;; *) p="$dir/$p" ;; esac
  done
  dir="$(cd -P "$(dirname "$p")" 2>/dev/null && pwd)" || { printf '%s\n' "$p"; return 0; }
  printf '%s/%s\n' "$dir" "$(basename "$p")"
}

# _csd_ratchet_relpath <resolved-abs-path> -> the PHYSICAL path relative to
# the PHYSICAL CHECK_SURFACE_GIT_REPO_ROOT on stdout, rc 1 (no output) if it
# is not under that root at all. Both sides are physicalized so a symlinked
# config file (or a symlink-bearing root, e.g. macOS /var -> /private/var)
# compares apples to apples.
_csd_ratchet_relpath() {
  local resolved="$1" relpath root_phys
  resolved="$(_csd_physical_path "$resolved")"
  root_phys="$(cd -P "$CHECK_SURFACE_GIT_REPO_ROOT" 2>/dev/null && pwd)" || root_phys="$CHECK_SURFACE_GIT_REPO_ROOT"
  relpath="${resolved#"$root_phys"/}"
  [[ "$relpath" != "$resolved" ]] || return 1
  printf '%s\n' "$relpath"
}

# _csd_kernel_squash_commit -> the newest subtree squash commit reachable
# from HEAD carrying a `git-subtree-dir: kernel` trailer (the commit `git
# subtree pull --prefix=kernel --squash` minted), empty + rc 1 if none. Its
# tree is the KERNEL REPO ROOT (unprefixed), so a path inside it drops the
# leading `kernel/`.
_csd_kernel_squash_commit() {
  local squash
  squash="$(git -C "$CHECK_SURFACE_GIT_REPO_ROOT" log -1 --format=%H --grep='^git-subtree-dir: kernel$' HEAD 2>/dev/null)"
  [[ -n "$squash" ]] || return 1
  printf '%s\n' "$squash"
}

# --- 4a. Allowlist ratchet: surface SET may only shrink. ---
if [[ -z "$_csd_ratchet_skip_reason" ]]; then
  allowlist_relpath="$(_csd_ratchet_relpath "$CHECK_SURFACE_ALLOWLIST_FILE")" || allowlist_relpath=""
  # Vendored-kernel subtree arm (temperloop#1559 — see §4 header): activates
  # only when the repo root declares a vendored kernel (.kernel-pin) AND the
  # physically-resolved allowlist lands inside kernel/. A kernel checkout has
  # neither, so it can never enter this arm.
  kernel_squash=""
  kernel_arm_note=""
  if [[ -n "$allowlist_relpath" && -f "$CHECK_SURFACE_GIT_REPO_ROOT/.kernel-pin" ]]; then
    case "$allowlist_relpath" in
      kernel/*)
        kernel_squash="$(_csd_kernel_squash_commit)" || kernel_squash=""
        if [[ -z "$kernel_squash" ]]; then
          kernel_arm_note=" [vendored-kernel arm unavailable: .kernel-pin present and $allowlist_relpath resolves into kernel/, but no subtree squash commit with a 'git-subtree-dir: kernel' trailer is reachable from HEAD — fell back to the plain base-ref ratchet, fail-closed]"
        fi
        ;;
    esac
  fi
  if [[ -z "$allowlist_relpath" ]]; then
    ratchet_lines+=("allowlist ratchet: SKIPPED ($CHECK_SURFACE_ALLOWLIST_FILE is not under $CHECK_SURFACE_GIT_REPO_ROOT)")
  elif [[ -n "$kernel_squash" ]]; then
    # Kernel arm: prev = the base ref's copy (absent -> empty, no bootstrap
    # exemption needed — an empty prev just means every row must be
    # upstream-blessed); upstream = the squash commit's own copy (its tree
    # is the kernel repo root, so the path drops the kernel/ prefix). A row
    # passes when present in EITHER; a row in neither is overlay-authored
    # growth and fails.
    prev_content="$(git -C "$CHECK_SURFACE_GIT_REPO_ROOT" show "${_csd_ratchet_base_ref}:${allowlist_relpath}" 2>/dev/null)" || prev_content=""
    prev_surfaces=""
    if [[ -n "$prev_content" ]]; then
      while IFS=$'\x1f' read -r p_surface _rest || [[ -n "${p_surface:-}" ]]; do
        [[ -z "${p_surface:-}" ]] && continue
        case "$p_surface" in \#*) continue ;; esac
        prev_surfaces="$prev_surfaces$p_surface
"
      done < <(_csd_tsv_string "$prev_content")
    fi
    kernel_inner_path="${allowlist_relpath#kernel/}"
    upstream_content="$(git -C "$CHECK_SURFACE_GIT_REPO_ROOT" show "${kernel_squash}:${kernel_inner_path}" 2>/dev/null)" || upstream_content=""
    upstream_surfaces=""
    if [[ -n "$upstream_content" ]]; then
      while IFS=$'\x1f' read -r u_surface _rest || [[ -n "${u_surface:-}" ]]; do
        [[ -z "${u_surface:-}" ]] && continue
        case "$u_surface" in \#*) continue ;; esac
        upstream_surfaces="$upstream_surfaces$u_surface
"
      done < <(_csd_tsv_string "$upstream_content")
    fi
    if [[ -n "$allowlist_surfaces" ]]; then
      while IFS= read -r cur_surface; do
        [[ -z "$cur_surface" ]] && continue
        case $'\n'"$prev_surfaces" in
          *$'\n'"$cur_surface"$'\n'*) continue ;;
        esac
        case $'\n'"$upstream_surfaces" in
          *$'\n'"$cur_surface"$'\n'*) continue ;;
        esac
        failures+=("ALLOWLIST-GREW  $cur_surface — present in $CHECK_SURFACE_ALLOWLIST_FILE now but neither at $_csd_ratchet_base_ref nor in the vendored kernel's own pulled content (subtree squash ${kernel_squash}); the allowlist is a shrink-only ratchet, and a row the kernel upstream never shipped is overlay-authored growth, never a place to add a newly-discovered non-compliant surface")
      done <<<"$allowlist_surfaces"
    fi
    ratchet_lines+=("allowlist ratchet: checked against $_csd_ratchet_base_ref:$allowlist_relpath + vendored-kernel squash $kernel_squash (subtree-sourced rows ratchet against the kernel subtree's own pulled content)")
  elif _csd_ratchet_file_added "$allowlist_relpath"; then
    ratchet_lines+=("allowlist ratchet: SKIPPED (bootstrap — $allowlist_relpath was added in this diff, nothing to compare against)")
  else
    prev_content="$(git -C "$CHECK_SURFACE_GIT_REPO_ROOT" show "${_csd_ratchet_base_ref}:${allowlist_relpath}" 2>/dev/null)" || prev_content=""
    prev_surfaces=""
    if [[ -n "$prev_content" ]]; then
      while IFS=$'\x1f' read -r p_surface _rest || [[ -n "${p_surface:-}" ]]; do
        [[ -z "${p_surface:-}" ]] && continue
        case "$p_surface" in \#*) continue ;; esac
        prev_surfaces="$prev_surfaces$p_surface
"
      done < <(_csd_tsv_string "$prev_content")
    fi
    if [[ -n "$allowlist_surfaces" ]]; then
      while IFS= read -r cur_surface; do
        [[ -z "$cur_surface" ]] && continue
        case $'\n'"$prev_surfaces" in
          *$'\n'"$cur_surface"$'\n'*) ;;
          *) failures+=("ALLOWLIST-GREW  $cur_surface — present in $CHECK_SURFACE_ALLOWLIST_FILE now but not at $_csd_ratchet_base_ref; the allowlist is a shrink-only ratchet (acceptance criterion 3), never a place to add a newly-discovered non-compliant surface") ;;
        esac
      done <<<"$allowlist_surfaces"
    fi
    ratchet_lines+=("allowlist ratchet: checked against $_csd_ratchet_base_ref:$allowlist_relpath$kernel_arm_note")
  fi
else
  ratchet_lines+=("allowlist ratchet: SKIPPED ($_csd_ratchet_skip_reason)")
fi

# --- 4b. Registry ratchet: (surface,case) rows may only grow or improve
#          status (not-applicable -> covered), never shrink or downgrade
#          (covered -> not-applicable), MEDIUM 4. ---
if [[ -z "$_csd_ratchet_skip_reason" ]]; then
  registry_relpath="$(_csd_ratchet_relpath "$CHECK_SURFACE_REGISTRY_FILE")" || registry_relpath=""
  if [[ -z "$registry_relpath" ]]; then
    ratchet_lines+=("registry ratchet: SKIPPED ($CHECK_SURFACE_REGISTRY_FILE is not under $CHECK_SURFACE_GIT_REPO_ROOT)")
  elif _csd_ratchet_file_added "$registry_relpath"; then
    ratchet_lines+=("registry ratchet: SKIPPED (bootstrap — $registry_relpath was added in this diff, nothing to compare against)")
  else
    prev_reg_content="$(git -C "$CHECK_SURFACE_GIT_REPO_ROOT" show "${_csd_ratchet_base_ref}:${registry_relpath}" 2>/dev/null)" || prev_reg_content=""
    if [[ -n "$prev_reg_content" ]]; then
      while IFS=$'\x1f' read -r p_surface p_case p_status _rest || [[ -n "${p_surface:-}" ]]; do
        [[ -z "${p_surface:-}" ]] && continue
        case "$p_surface" in \#*) continue ;; esac
        [[ -z "${p_case:-}" || -z "${p_status:-}" ]] && continue
        # Find the CURRENT status for this (surface,case), if any.
        cur_status=""
        case $'\n'"$current_registry_status" in
          *$'\n'"$p_surface"$'\x02'"$p_case"$'\x02'*)
            # -F$'\x02' (ANSI-C quoted), NOT -F'\x02': a single-quoted '\x02'
            # passes awk the LITERAL 4-character string backslash-x-0-2 —
            # awk's own -F escape processing covers \t/\n but not \xNN hex
            # escapes portably (confirmed absent on macOS's built-in awk), so
            # a single-quoted form silently falls back to treating "\x02" as
            # a 4-char REGEX field separator that never matches the real
            # 0x02 bytes in the data. ANSI-C quoting expands the escape in
            # bash BEFORE awk ever sees it, so awk gets the real byte.
            cur_status="$(printf '%s\n' "$current_registry_status" | awk -F$'\x02' -v s="$p_surface" -v c="$p_case" '$1==s && $2==c {print $3; exit}')"
            ;;
        esac
        if [[ -z "$cur_status" ]]; then
          failures+=("REGISTRY-REGRESSED  $p_surface [$p_case] — was '$p_status' at $_csd_ratchet_base_ref, now ABSENT; the registry may only grow or improve, never shrink (the cheapest escape from a failing anchor is deleting its row, so row deletion is ratcheted shut)")
        elif [[ "$p_status" == "covered" && "$cur_status" == "not-applicable" ]]; then
          failures+=("REGISTRY-REGRESSED  $p_surface [$p_case] — was 'covered' at $_csd_ratchet_base_ref, now 'not-applicable'; downgrading a covered case counts as growth-in-reverse, never allowed")
        fi
      done < <(_csd_tsv_string "$prev_reg_content")
    fi
    ratchet_lines+=("registry ratchet: checked against $_csd_ratchet_base_ref:$registry_relpath")
  fi
else
  ratchet_lines+=("registry ratchet: SKIPPED ($_csd_ratchet_skip_reason)")
fi

# _csd_pending_from_content <tsv-content> -> the `pending` SURFACE column of
# a discovery-ledger blob, one per line. Used by 4c for BOTH sides of the
# comparison (the base ref's copy and, in a composed overlay, the vendored
# kernel's own pulled copy).
_csd_pending_from_content() {
  local content="$1" c_surface c_disp _c_rest out=""
  [[ -n "$content" ]] || return 0
  while IFS=$'\x1f' read -r c_surface c_disp _c_rest || [[ -n "${c_surface:-}" ]]; do
    [[ -z "${c_surface:-}" ]] && continue
    case "$c_surface" in \#*) continue ;; esac
    [[ "${c_disp:-}" == "pending" ]] || continue
    out="$out$c_surface
"
  done < <(_csd_tsv_string "$content")
  printf '%s' "$out"
}

# --- 4c. Pending ratchet (temperloop#1491): the discovery ledger's `pending`
#         SET may only SHRINK, exactly like the allowlist in 4a. Without it
#         this ledger would be a nicer-looking version of the hole §5 closes
#         — a newly-discovered surface parked forever behind a one-line
#         excuse. `excluded` rows are deliberately NOT ratcheted: a new
#         script that legitimately matches the name glob without being a
#         gated check needs a home, and an `excluded` row is a reviewed claim
#         in the diff, the same trust model the registry's own
#         `not-applicable` already runs on. Same vendored-kernel arm as 4a
#         (a row upstream shipped is upstream-ratcheted, not overlay growth).
if [[ -z "$_csd_ratchet_skip_reason" ]]; then
  discovery_relpath="$(_csd_ratchet_relpath "$CHECK_SURFACE_DISCOVERY_FILE")" || discovery_relpath=""
  if [[ ! -f "$CHECK_SURFACE_DISCOVERY_FILE" ]]; then
    ratchet_lines+=("pending ratchet: SKIPPED (no discovery ledger at $CHECK_SURFACE_DISCOVERY_FILE — zero dispositions, which §5 enforces strictly rather than leniently)")
  elif [[ -z "$discovery_relpath" ]]; then
    ratchet_lines+=("pending ratchet: SKIPPED ($CHECK_SURFACE_DISCOVERY_FILE is not under $CHECK_SURFACE_GIT_REPO_ROOT)")
  elif _csd_ratchet_file_added "$discovery_relpath"; then
    ratchet_lines+=("pending ratchet: SKIPPED (bootstrap — $discovery_relpath was added in this diff, nothing to compare against)")
  else
    prev_disc_content="$(git -C "$CHECK_SURFACE_GIT_REPO_ROOT" show "${_csd_ratchet_base_ref}:${discovery_relpath}" 2>/dev/null)" || prev_disc_content=""
    prev_pending="$(_csd_pending_from_content "$prev_disc_content")"
    upstream_pending=""
    disc_kernel_squash=""
    if [[ -f "$CHECK_SURFACE_GIT_REPO_ROOT/.kernel-pin" ]]; then
      case "$discovery_relpath" in
        kernel/*)
          disc_kernel_squash="$(_csd_kernel_squash_commit)" || disc_kernel_squash=""
          if [[ -n "$disc_kernel_squash" ]]; then
            upstream_disc_content="$(git -C "$CHECK_SURFACE_GIT_REPO_ROOT" show "${disc_kernel_squash}:${discovery_relpath#kernel/}" 2>/dev/null)" || upstream_disc_content=""
            upstream_pending="$(_csd_pending_from_content "$upstream_disc_content")"
          fi
          ;;
      esac
    fi
    if [[ -n "$discovery_pending" ]]; then
      while IFS= read -r cur_pending; do
        [[ -z "$cur_pending" ]] && continue
        case $'\n'"$prev_pending" in
          *$'\n'"$cur_pending"$'\n'*) continue ;;
        esac
        if [[ -n "$upstream_pending" ]]; then
          case $'\n'"$upstream_pending" in
            *$'\n'"$cur_pending"$'\n'*) continue ;;
          esac
        fi
        failures+=("PENDING-GREW  $cur_pending — listed 'pending' in $CHECK_SURFACE_DISCOVERY_FILE now but not at $_csd_ratchet_base_ref; the pending set is a shrink-only ratchet, so a NEWLY DISCOVERED check surface must be registered (or argued 'excluded'), never parked")
      done <<<"$discovery_pending"
    fi
    ratchet_lines+=("pending ratchet: checked against $_csd_ratchet_base_ref:$discovery_relpath${disc_kernel_squash:+ + vendored-kernel squash $disc_kernel_squash}")
  fi
else
  ratchet_lines+=("pending ratchet: SKIPPED ($_csd_ratchet_skip_reason)")
fi

# ---------------------------------------------------------------------------
# 5. THE DISCOVERY PASS (temperloop#1491) — THE COVERAGE ASSERTION.
#
# Everything above this point verifies surfaces somebody REMEMBERED to name.
# That is the defect temperloop#1491 exists to close: coverage was opt-in, so
# an unregistered check surface was not failed, it was simply not checked —
# and a fix that registered exactly the surfaces one person had noticed would
# reproduce that same sampling one generation later. This pass replaces the
# sampling with an enumeration: it derives the candidate set MECHANICALLY
# from the tree and FAILS CLOSED (UNREGISTERED-SURFACE) on any candidate that
# is in NONE of the three legal homes — the registry, the allowlist, or the
# discovery ledger. Silence stops being a disposition.
#
# THE PREDICATE: a tracked file whose BASENAME matches one of this repo's
# three check-script name families — `validate-*.sh`, `check-*.sh`,
# `lint-*.sh` — with `tests/`, `fixtures/`, `node_modules/` and `.git/`
# pruned (a fixture is not a gate), plus the vendored `kernel/` subtree
# pruned in a composed overlay (those surfaces are upstream-owned, and
# upstream's own CI ran this same pass over them).
#
# TRACKED, not merely present: enumeration prefers `git ls-files`, so a
# developer's untracked scratch `check-foo.sh` cannot fail the gate. A root
# that is not a git work tree (a fixture's scratch tree) falls back to
# `find`. Which one ran is stated in the verdict — a pass must never look
# identical to a pass that enumerated nothing.
#
# WHAT THE PREDICATE CANNOT SEE is stated, not implied, in
# check-surface-discovery.tsv's own header: SUBCOMMAND surfaces (no filename
# glob reaches `replay.sh:diff-scope` — the reason this is a registry at all)
# and check-shaped scripts outside the three name families (a `claude/hooks/`
# guard, whose contract is the INVERSE of this class: a guard that cannot
# evaluate must fail OPEN so it never blocks the operator). Both keep their
# existing by-hand home.
# ---------------------------------------------------------------------------
[[ -d "$CHECK_SURFACE_DISCOVERY_ROOT" ]] || _csd_cannot_evaluate "discovery root not found: $CHECK_SURFACE_DISCOVERY_ROOT — cannot enumerate the candidate check surfaces"

_csd_prune_kernel=0
[[ -f "$CHECK_SURFACE_DISCOVERY_ROOT/.kernel-pin" ]] && _csd_prune_kernel=1

# _csd_is_candidate <repo-relative-path> -> rc 0 iff the path is a candidate
# check surface under the predicate documented above.
_csd_is_candidate() {
  local p="$1" base
  case "$p" in
    tests/* | */tests/* | fixtures/* | */fixtures/* | node_modules/* | */node_modules/* | .git/* | */.git/*) return 1 ;;
  esac
  if [[ "$_csd_prune_kernel" -eq 1 ]]; then
    case "$p" in kernel/*) return 1 ;; esac
  fi
  base="${p##*/}"
  case "$base" in
    validate-*.sh | check-*.sh | lint-*.sh) return 0 ;;
  esac
  return 1
}

# _csd_enumerate <root> -> every candidate-shaped path under <root>, one per
# line, REPO-RELATIVE. `git ls-files` when <root> is a work tree (the
# "tracked" half of the predicate), `find` otherwise.
_csd_enumerate() {
  local root="$1" line
  if [[ "$_csd_discovery_source" == "git ls-files" ]]; then
    git -C "$root" ls-files 2>/dev/null
  else
    find "$root" -type f \( -name 'validate-*.sh' -o -name 'check-*.sh' -o -name 'lint-*.sh' \) 2>/dev/null |
      while IFS= read -r line; do printf '%s\n' "${line#"$root"/}"; done
  fi
}

_csd_discovery_source="find"
if git -C "$CHECK_SURFACE_DISCOVERY_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  _csd_discovery_source="git ls-files"
fi

n_discovered=0
n_undispositioned=0
while IFS= read -r cand; do
  [[ -z "$cand" ]] && continue
  _csd_is_candidate "$cand" || continue
  n_discovered=$((n_discovered + 1))
  case $'\n'"${known_surfaces:-}"$'\n' in *$'\n'"$cand"$'\n'*) continue ;; esac
  case $'\n'"$allowlist_surfaces" in *$'\n'"$cand"$'\n'*) continue ;; esac
  case $'\n'"$discovery_surfaces" in *$'\n'"$cand"$'\n'*) continue ;; esac
  n_undispositioned=$((n_undispositioned + 1))
  failures+=("UNREGISTERED-SURFACE  $cand — a check surface discovered mechanically in the tree with NO disposition anywhere: it is not in $CHECK_SURFACE_REGISTRY_FILE, not on $CHECK_SURFACE_ALLOWLIST_FILE, and has no row in $CHECK_SURFACE_DISCOVERY_FILE. Register it (with its absent/unreadable/empty rows), or add a reasoned 'pending'/'excluded' row to the discovery ledger — an unchecked check surface is no longer a legal state")
done < <(_csd_enumerate "$CHECK_SURFACE_DISCOVERY_ROOT")

if [[ "$n_discovered" -eq 0 ]]; then
  failures+=("EMPTY-DISCOVERY  the discovery pass enumerated ZERO candidate check surfaces under $CHECK_SURFACE_DISCOVERY_ROOT (source: $_csd_discovery_source) — an enumeration that finds nothing is a vacuous pass, exactly the defect class this gate exists to close")
fi

# ---------------------------------------------------------------------------
# Verdict.
# ---------------------------------------------------------------------------
n_allowlisted=0
if [[ -n "$allowlist_surfaces" ]]; then
  n_allowlisted="$(printf '%s' "$allowlist_surfaces" | grep -c . || true)"
fi
echo "Checked $n_surfaces registered surface(s) ($n_covered_rows covered row(s), $n_not_applicable not-applicable row(s)); $n_allowlisted surface(s) on the allowlist ($CHECK_SURFACE_ALLOWLIST_FILE)"
echo "Discovery pass: $n_discovered candidate check surface(s) enumerated from $CHECK_SURFACE_DISCOVERY_ROOT via $_csd_discovery_source; $n_pending pending + $n_excluded excluded in $CHECK_SURFACE_DISCOVERY_FILE; $n_undispositioned undispositioned"
printf '%s\n' "${ratchet_lines[@]}"
if (( ${#superseded_lines[@]} > 0 )); then
  printf '%s\n' "${superseded_lines[@]}"
fi
if (( ${#failures[@]} > 0 )); then
  printf '%s\n' "${failures[@]}"
  echo "---"
  echo "failures: ${#failures[@]}"
  echo "$PREFIX: FAIL"
  exit 1
fi
echo "$PREFIX: OK"
