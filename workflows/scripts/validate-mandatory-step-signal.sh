#!/usr/bin/env bash
#
# validate-mandatory-step-signal.sh — the MANDATORY-STEP BIRTH RULE gate
# (temperloop#1448, epic #1616).
#
# WHY THIS EXISTS. A workflow spec can declare a pipeline step MANDATORY in
# prose while nothing observable proves the step ever executes. The prose is
# the whole enforcement, and prose does not run. Three instances, none caught
# by any suite:
#   1. `/build` §3e's pre-push review pass was "mandatory for a
#      claude/commands/*.md diff" for ~a month while the default (Workflow)
#      path could not spawn a reviewer at all — the worker it was delegated to
#      has no way to spawn a nested subagent, so "run it or emit the skip
#      notice" collapsed to a guaranteed skip on every command-doc PR
#      (temperloop#1430). Detected only when somebody wrote a coverage script
#      after the fact.
#   2. §3e.6's "mandatory" class-A activation gate routed its no-predicate case
#      to a `/verify` capability that has never existed in this repo, paired
#      with a degradation clause that let the gate resolve to its own skip
#      notice on every run (temperloop#1387/#1451).
#   3. The INSTALLED claude/workflows/build-level.mjs ran six days stale
#      through an entire batch (temperloop#1397): batches merged a fix and kept
#      executing the pre-fix orchestrator. A mandatory-looking thing that
#      demonstrably was not running, invisible until two files were diffed by
#      hand.
# In every case the failure is the SAME SHAPE: a declaration with no execution
# signal is indistinguishable, from outside, from a step that silently never
# runs. This gate closes it structurally — declaring a step mandatory and
# shipping its execution signal become two halves of ONE change, exactly as
# § Capture/Backstop pairing already does for extraction rules
# (workflows/scripts/validate-capture-backstop.sh is the named precedent and
# this gate is deliberately built on the same mold, not a second one).
#
# ── THE SCOPE DECISION (load-bearing — read before extending) ───────────────
#
# (a) WHAT COUNTS AS "DECLARING A STEP MANDATORY". A sentence in a workflow
#     spec under `claude/commands/*.md` that makes the EXECUTION of a named
#     step or pass obligatory — the thing that could silently not happen is
#     THE RUNNING OF THE STEP. Recognized mechanically by a narrow marker
#     vocabulary (see MANDATORY_STEP_MARKER_RE below): `mandatory`,
#     `non-negotiable`, `not optional`, `never skip`.
#
#     `MUST` IS DELIBERATELY NOT A MARKER. RFC-2119 `MUST` is this tree's
#     house dialect for EVERY normative statement in a spec — 156 occurrences
#     across claude/commands/*.md, the overwhelming majority of them
#     constraints on how a step BEHAVES once it is running (an ordering rule, a
#     required flag, a required field in an artifact), not declarations that a
#     step runs at all. A ~1-in-156 signal is not a gate; it is a rule everyone
#     learns to route around. This is the identical measured narrowing
#     validate-exec-bit-registry.sh made when it rejected a shebang-keyed rule
#     (96 hits, ~1 real) for a registry-keyed one. The narrow vocabulary yields
#     18 sites on the tree at adoption, every one of which is dispositioned.
#
#     WHAT IS OUT OF SCOPE, and why: a constraint on HOW a step behaves fails
#     LOUDLY when violated — the step ran, it just did the wrong thing, and its
#     own output shows that. A step that never runs emits nothing at all, and
#     that silence is the only thing this gate exists to break. So an ordering
#     rule ("push before you watch CI"), an argument-shape rule ("the `--sha`
#     pin is required, not optional") and an artifact-field rule ("MUST record
#     `epic: <N>`") are `excluded` dispositions, not registry rows. So is prose
#     that merely REFERENCES a mandatory rule declared elsewhere — flagging a
#     doc for documenting the thing it documents is the temperloop#1152 defect
#     class (a guard that fires on documentation of its own subject).
#
#     Scope is `claude/commands/*.md` and nothing else: a pipeline STEP is a
#     step of a workflow spec. Agent charters under claude/agents/ declare a
#     reviewer's own behavior, not a step of a run.
#
# (b) WHAT COUNTS AS AN ACCEPTABLE EXECUTION SIGNAL. Four kinds, each named by
#     a row's KIND column and each mechanically checkable from a checkout:
#
#       tally    A structured, per-run field the EXECUTING CODE emits, so a run
#                that skipped the step says so in its own record. The canonical
#                instance is build-level.mjs's `review: { ran, skipped,
#                mandatory_ok }`, surfaced in the Step 6 summary.
#       guard    A static assertion, in a suite this repo's `checks` set
#                actually runs, that goes RED if the step's invocation is
#                removed or moved. A guard nobody runs proves nothing, so a
#                `guard` row must ALSO name the GATE token that runs it, and
#                that token must appear on an ACTIVE (non-commented) line of
#                scripts/quality-gates.sh.
#       refusal  The executing code REFUSES to complete without the mandated
#                thing — a fail-closed runtime exit, anchored in the enforcing
#                source (emit-command-run.sh's count-partition non-zero exit).
#       rollup   A cross-run coverage report of the step's execution rate
#                (workflows/scripts/workflow-reviewer-coverage.sh). Weakest of
#                the four — it detects a drift in aggregate rather than
#                per-run — but it is what caught instance 1, so it counts.
#
#     What does NOT count, in any kind: the spec's own prose, a second prose
#     restatement in another doc, or a test that merely asserts the SPEC TEXT
#     still says "mandatory". Those all re-verify the declaration, never the
#     execution.
#
# ── REGISTRY + DISCOVERY, because a registry alone is the same bug again ────
# An opt-in registry documents what somebody REMEMBERED; the next mandatory
# declaration inherits the original defect silently. So this gate does BOTH,
# the shape validate-check-surface-degenerate-coverage.sh's §5 established:
#   - every REGISTERED pair is checked whole (declaration half AND signal half
#     both resolve, or the pair is HALF-PRESENT and the build is red — the
#     capture/backstop verdict shape); and
#   - the candidate set is ENUMERATED MECHANICALLY from claude/commands/*.md,
#     and any marker line with NO disposition anywhere FAILS. Being absent from
#     the registry is not the same thing as being unchecked.
#
# ── The two config files ───────────────────────────────────────────────────
#   mandatory-step-registry.tsv    SPEC / STEP / DECLARATION / KIND / SIGNAL /
#                                   ANCHOR / GATE / NOTE — one row per
#                                   (mandatory declaration, execution signal)
#                                   pair. NEVER EMPTY (an empty registry is a
#                                   vacuous pass — EMPTY-REGISTRY below).
#   mandatory-step-discovery.tsv   SPEC / ANCHOR / DISPOSITION / REASON for
#                                   every discovered marker line deliberately
#                                   NOT registered. `excluded` = not a
#                                   step-execution declaration at all (see (a));
#                                   `pending` = it IS one and has no signal yet,
#                                   named as debt. An ABSENT ledger means ZERO
#                                   dispositions, which is the strict reading.
#
# ── THE BIRTH RULE'S TEETH: the `pending` ratchet ──────────────────────────
# `pending` is a SHRINK-ONLY ratchet against a resolved base ref, exactly like
# validate-exec-bit-registry.sh's grandfather allowlist. A `pending` row
# present at the base ref may be removed (the debt was paid); a `pending` row
# present NOW but not at the base ref is PENDING-GREW and fails. That single
# rule is what makes this a BIRTH rule rather than a backlog: a brand-new
# `**mandatory**` declaration CANNOT be parked — it must ship a registry row
# with a real signal, or be dispositioned `excluded` (a reviewable claim, in
# the diff, that it is not a step-execution declaration). The seed `pending`
# set is the pre-existing debt this rule was born owing, and it can only
# shrink. BOOTSTRAP (the commit that first adds the ledger) is exempt from its
# own ratchet, per git's rename-aware `--diff-filter=A`, so a RENAME can never
# re-arm the exemption.
#
# ── Fail-closed discipline ────────────────────────────────────────────────
# This gate must never be an instance of the class it enforces. Every hard
# stop (absent/unreadable/empty registry, an unreadable ledger, an absent or
# empty spec corpus, an unresolvable EXPLICIT base ref) routes through
# workflows/scripts/lib/cannot-evaluate.sh's cannot_evaluate_emit — exit 2,
# never a silent OK. Every ordinary FAIL is collected and reported ALL AT
# ONCE with a stable prefix naming the exact declaration.
#
# Usage:
#   workflows/scripts/validate-mandatory-step-signal.sh
#   (a direct-`bash` KERNEL_GATES entry in scripts/quality-gates.sh)
#
# Env overrides (FIXTURE-TEST SEAM, all optional — used by this gate's own
# fixture suite, workflows/scripts/tests/test_validate_mandatory_step_signal.sh,
# to point every input at a scratch tree):
#   MANDATORY_STEP_REGISTRY_FILE   default: workflows/scripts/config/
#                                   mandatory-step-registry.tsv
#   MANDATORY_STEP_DISCOVERY_FILE  default: workflows/scripts/config/
#                                   mandatory-step-discovery.tsv
#   MANDATORY_STEP_SPEC_DIR        default: <repo>/claude/commands — the spec
#                                   corpus the discovery pass enumerates
#   MANDATORY_STEP_QUALITY_GATES_FILE  default: <repo>/scripts/quality-gates.sh
#   MANDATORY_STEP_REPO_ROOT       default: this repo's root — the root a
#                                   relative SPEC/SIGNAL/config path resolves
#                                   against
#   MANDATORY_STEP_GIT_REPO_ROOT   default: this repo's root — the repo every
#                                   `git` ratchet operation runs against
#   MANDATORY_STEP_BASE_REF        default: EMPTY — auto-resolved (origin/HEAD
#                                   then origin/main); an explicit value is
#                                   used VERBATIM and, if it does not resolve,
#                                   is CANNOT EVALUATE rather than a quiet skip
#
# Kept POSIX-bash-3.2-friendly (no mapfile/associative arrays) — macOS dev
# shell + Linux CI, matching every other workflows/scripts/validate-*.sh.

set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd)"

: "${MANDATORY_STEP_REPO_ROOT:=$DEFAULT_REPO_ROOT}"
: "${MANDATORY_STEP_GIT_REPO_ROOT:=$DEFAULT_REPO_ROOT}"
: "${MANDATORY_STEP_REGISTRY_FILE:=$SCRIPT_DIR/config/mandatory-step-registry.tsv}"
: "${MANDATORY_STEP_DISCOVERY_FILE:=$SCRIPT_DIR/config/mandatory-step-discovery.tsv}"
# OVERLAY EXTENSION FILES (temperloop#1738/#1740). In a COMPOSED OVERLAY both
# config files above are compat symlinks into the vendored kernel subtree, so a
# consumer that owns command specs of its own had nowhere to disposition their
# mandatory declarations: editing the vendored copy is forbidden, and replacing
# the symlink means owning a stale duplicate of every upstream row. Same
# `<base>.overlay.<ext>` shape as the kernel's other overlay-extension seams
# (setting-registry.overlay.tsv, capture-backstop-registry.overlay.md,
# check-surface-*.overlay.tsv). Absent in a kernel-only checkout.
: "${MANDATORY_STEP_REGISTRY_OVERLAY_FILE:=$SCRIPT_DIR/config/mandatory-step-registry.overlay.tsv}"
: "${MANDATORY_STEP_DISCOVERY_OVERLAY_FILE:=$SCRIPT_DIR/config/mandatory-step-discovery.overlay.tsv}"
: "${MANDATORY_STEP_SPEC_DIR:=$MANDATORY_STEP_REPO_ROOT/claude/commands}"
: "${MANDATORY_STEP_QUALITY_GATES_FILE:=$MANDATORY_STEP_REPO_ROOT/scripts/quality-gates.sh}"
# Empty by default — the ratchet auto-resolves at ratchet time. An
# operator-set value is honored VERBATIM (never re-resolved).
: "${MANDATORY_STEP_BASE_REF:=}"

# The marker vocabulary. Deliberately narrow — see § THE SCOPE DECISION (a)
# above for why `MUST` is not in it. Matched case-insensitively against a
# lowercased copy of the line, so `MANDATORY`, `Mandatory` and `mandatory` are
# one marker, not three.
MANDATORY_STEP_MARKER_RE='mandatory|non-negotiable|not optional|never skip'

# shellcheck source=workflows/scripts/lib/cannot-evaluate.sh
source "$SCRIPT_DIR/lib/cannot-evaluate.sh"

PREFIX="validate-mandatory-step-signal"

_mss_cannot_evaluate() {
  cannot_evaluate_emit "$PREFIX" "$1"
  exit $?
}

# _mss_resolve_path <maybe-relative> — absolute paths pass through; anything
# else resolves against MANDATORY_STEP_REPO_ROOT.
_mss_resolve_path() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s\n' "$MANDATORY_STEP_REPO_ROOT/$1" ;;
  esac
}

MANDATORY_STEP_REGISTRY_FILE="$(_mss_resolve_path "$MANDATORY_STEP_REGISTRY_FILE")"
MANDATORY_STEP_DISCOVERY_FILE="$(_mss_resolve_path "$MANDATORY_STEP_DISCOVERY_FILE")"
MANDATORY_STEP_REGISTRY_OVERLAY_FILE="$(_mss_resolve_path "$MANDATORY_STEP_REGISTRY_OVERLAY_FILE")"
MANDATORY_STEP_DISCOVERY_OVERLAY_FILE="$(_mss_resolve_path "$MANDATORY_STEP_DISCOVERY_OVERLAY_FILE")"
MANDATORY_STEP_SPEC_DIR="$(_mss_resolve_path "$MANDATORY_STEP_SPEC_DIR")"
MANDATORY_STEP_QUALITY_GATES_FILE="$(_mss_resolve_path "$MANDATORY_STEP_QUALITY_GATES_FILE")"

[[ -f "$MANDATORY_STEP_REGISTRY_FILE" ]] || _mss_cannot_evaluate "registry file not found: $MANDATORY_STEP_REGISTRY_FILE"
[[ -r "$MANDATORY_STEP_REGISTRY_FILE" ]] || _mss_cannot_evaluate "registry file exists but is not readable: $MANDATORY_STEP_REGISTRY_FILE"

# An absent discovery ledger is legal (zero dispositions — the STRICT reading,
# since every discovered marker then needs a registry row). An UNREADABLE one
# is not: it is indistinguishable from a ledger full of dispositions we cannot
# see, so it fails closed.
if [[ -e "$MANDATORY_STEP_DISCOVERY_FILE" && ! -r "$MANDATORY_STEP_DISCOVERY_FILE" ]]; then
  _mss_cannot_evaluate "discovery ledger exists but is not readable: $MANDATORY_STEP_DISCOVERY_FILE"
fi

# The overlay twins follow the same rule: ABSENT is legal (a kernel-only
# checkout) and contributes zero rows; PRESENT-BUT-UNREADABLE fails closed,
# because a row this gate cannot read is indistinguishable from one that is
# not there.
for _mss_ov in "$MANDATORY_STEP_REGISTRY_OVERLAY_FILE" "$MANDATORY_STEP_DISCOVERY_OVERLAY_FILE"; do
  if [[ -e "$_mss_ov" && ! -r "$_mss_ov" ]]; then
    _mss_cannot_evaluate "overlay extension file exists but is not readable: $_mss_ov"
  fi
done
unset _mss_ov

[[ -d "$MANDATORY_STEP_SPEC_DIR" ]] || _mss_cannot_evaluate "spec corpus directory not found: $MANDATORY_STEP_SPEC_DIR"
[[ -r "$MANDATORY_STEP_SPEC_DIR" && -x "$MANDATORY_STEP_SPEC_DIR" ]] || _mss_cannot_evaluate "spec corpus directory exists but is not readable: $MANDATORY_STEP_SPEC_DIR"

failures=()
notes=()
n_registered=0
n_discovered=0

# ---------------------------------------------------------------------------
# Tab-safe TSV line splitting. `IFS=$'\t' read` collapses consecutive tabs
# (tab is IFS-whitespace), so a genuinely empty middle field silently shifts
# every later field left. Route through awk once, re-joining on \x1f (ASCII
# US), and read on that — \x1f is not IFS whitespace, so it does not collapse.
# \x1f and NOT \x01: 0x01 is bash's own CTLESC marker byte and bash 3.2 (the
# system /bin/bash on macOS, and what `bash scripts/quality-gates.sh` resolves
# to on the macos-latest runner) does not split on it — it returns the whole
# line in the FIRST variable instead. scripts/lint-bash32-ctlesc-ifs.sh is the
# mechanical guard for that class (temperloop#1649).
# ---------------------------------------------------------------------------
_mss_tsv_file() { # <file> -> \x1f-joined lines on stdout
  awk -F'\t' 'BEGIN{OFS="\x1f"} {$1=$1; print}' "$1"
}
# _mss_tsv_files <file...> -> \x1f-joined rows, each PREFIXED with its source
# file, so a failure names the file the row actually came from rather than
# hardcoding the kernel path once the overlay extension is unioned in.
# _mss_row_unadopted_upstream <src> -> rc 0 iff a row from <src> naming a spec
# ABSENT here should be tolerated rather than failed (temperloop#1740). Same
# rule as the check-surface gate: a vendoring consumer (repo-root .kernel-pin)
# adopts a SUBSET of the kernel's command specs, so an upstream row naming an
# unadopted one is expected. A row from an OVERLAY extension naming a missing
# spec is still stale, and still fails.
# Declared HERE, not beside the ratchet: `ratchet_lines=()` is initialised
# after the parse loops, so a note appended during parsing would be wiped.
unadopted_lines=()
_mss_row_unadopted_upstream() {
  [[ -f "$MANDATORY_STEP_GIT_REPO_ROOT/.kernel-pin" ]] || return 1
  case "$1" in
    "$MANDATORY_STEP_REGISTRY_OVERLAY_FILE" | "$MANDATORY_STEP_DISCOVERY_OVERLAY_FILE") return 1 ;;
  esac
  return 0
}

_mss_tsv_files() {
  local _f
  for _f in "$@"; do
    [[ -f "$_f" && -r "$_f" ]] || continue
    awk -F'\t' -v SRC="$_f" 'BEGIN{OFS="\x1f"} {$1=$1; print SRC OFS $0}' "$_f"
  done
}
_mss_tsv_string() { # <string> -> \x1f-joined lines on stdout
  printf '%s' "$1" | awk -F'\t' 'BEGIN{OFS="\x1f"} {$1=$1; print}'
}

_mss_trim() { printf '%s' "${1:-}" | awk '{ gsub(/^[ \t]+|[ \t]+$/, ""); print }'; }

# _mss_count_fixed <file> <needle> — how many lines of <file> contain <needle>
# as a LITERAL substring. `grep -c -F` and never a regex: a DECLARATION anchor
# is prose full of backticks, asterisks and parentheses, every one of which a
# regex would reinterpret.
_mss_count_fixed() {
  local f="$1" needle="$2" n
  n="$(grep -c -F -- "$needle" "$f" 2>/dev/null)" || n=0
  [[ -n "$n" ]] || n=0
  printf '%s\n' "$n"
}

# _mss_has_marker <text> — rc 0 iff <text> carries a mandatory marker.
_mss_has_marker() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | grep -E -- "$MANDATORY_STEP_MARKER_RE" >/dev/null
}

# _mss_gate_active <gate-token> — rc 0 iff <gate-token> appears on an ACTIVE
# (non-comment) line of quality-gates.sh that actually invokes something. A
# bare substring grep over the whole file is satisfied by a COMMENTED-OUT gate
# line, which is exactly how this repo disables a suite — "a guard nobody runs
# proves nothing" applies just as much to a DISABLED one. Same predicate shape
# as validate-check-surface-degenerate-coverage.sh's _csd_test_file_gated().
_mss_gate_active() {
  local token="$1" line trimmed
  [[ -r "$MANDATORY_STEP_QUALITY_GATES_FILE" ]] || return 1
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in *"$token"*) ;; *) continue ;; esac
    trimmed="${line#"${line%%[![:space:]]*}"}"
    case "$trimmed" in
      '#'*) continue ;;
    esac
    case "$trimmed" in
      *bash* | *make*) return 0 ;;
    esac
  done <"$MANDATORY_STEP_QUALITY_GATES_FILE"
  return 1
}

# ---------------------------------------------------------------------------
# 1. Parse the discovery ledger first — the registry pass and the discovery
#    pass both need its dispositions.
#    Row shape: SPEC <TAB> ANCHOR <TAB> DISPOSITION <TAB> REASON
#    Records are kept as \x1f-joined "spec\x1fanchor" keys plus parallel
#    disposition text, bash-3.2 style (no associative arrays).
# ---------------------------------------------------------------------------
ledger_keys=""     # newline-separated "<spec>\x1f<anchor>"
ledger_pending=""  # newline-separated "<spec>\x1f<anchor>" for DISPOSITION=pending
n_pending=0
n_excluded=0
# EITHER source is enough: a composed overlay may carry only the overlay twin.
if [[ -f "$MANDATORY_STEP_DISCOVERY_FILE" || -f "$MANDATORY_STEP_DISCOVERY_OVERLAY_FILE" ]]; then
  while IFS=$'\x1f' read -r src d_spec d_anchor d_disp d_reason || [[ -n "${src:-}" ]]; do
    [[ -z "${d_spec:-}" ]] && continue
    case "$d_spec" in \#*) continue ;; esac

    d_anchor="${d_anchor:-}"
    d_disp="$(_mss_trim "${d_disp:-}")"
    if [[ -z "$d_anchor" ]]; then
      failures+=("LEDGER-MALFORMED  $d_spec — a discovery-ledger row requires a non-empty ANCHOR (the literal substring of the marker line it disposes)")
      continue
    fi

    key="$d_spec"$'\x1f'"$d_anchor"
    case $'\n'"$ledger_keys" in
      *$'\n'"$key"$'\n'*)
        failures+=("LEDGER-DUPLICATE  $d_spec :: $d_anchor — dispositioned more than once")
        continue
        ;;
    esac
    ledger_keys="$ledger_keys$key
"

    if [[ -z "$(_mss_trim "${d_reason:-}")" ]]; then
      failures+=("DISPOSITION-UNJUSTIFIED  $d_spec :: $d_anchor — every discovery-ledger row requires a non-empty REASON (a disposition without a reason is the silence this ledger exists to end)")
    fi

    case "$d_disp" in
      pending)
        n_pending=$((n_pending + 1))
        ledger_pending="$ledger_pending$key
"
        ;;
      excluded) n_excluded=$((n_excluded + 1)) ;;
      *)
        failures+=("DISPOSITION-UNKNOWN  $d_spec :: $d_anchor — DISPOSITION is '${d_disp:-<empty>}'; must be 'pending' or 'excluded'")
        continue
        ;;
    esac

    # A ledger row whose anchor no longer appears in its spec is STALE: the
    # declaration it dispositioned was reworded or removed, and the row now
    # silently exempts nothing (or, worse, is read as covering a different
    # line). Prune it in the same change that reworded the prose.
    spec_path="$(_mss_resolve_path "$d_spec")"
    if [[ ! -r "$spec_path" ]]; then
      if _mss_row_unadopted_upstream "$src"; then
        unadopted_lines+=("note: ledger row $d_spec :: $d_anchor names a command spec this repo did not adopt — an upstream row for unadopted content, skipped (temperloop#1740)")
      else
        failures+=("LEDGER-SPEC-NOT-FOUND  $d_spec :: $d_anchor — the spec file does not exist or is not readable at $spec_path")
      fi
      continue
    fi
    if [[ "$(_mss_count_fixed "$spec_path" "$d_anchor")" -eq 0 ]]; then
      failures+=("LEDGER-STALE  $d_spec :: $d_anchor — the ANCHOR no longer appears in $d_spec; the declaration was reworded or removed, so prune the ledger row in the same change")
    fi
  done < <(_mss_tsv_files "$MANDATORY_STEP_DISCOVERY_FILE" "$MANDATORY_STEP_DISCOVERY_OVERLAY_FILE")
fi

# ---------------------------------------------------------------------------
# 2. Parse and check the registry.
#    Row shape: SPEC <TAB> STEP <TAB> DECLARATION <TAB> KIND <TAB> SIGNAL
#               <TAB> ANCHOR <TAB> GATE <TAB> NOTE
# ---------------------------------------------------------------------------
registry_keys=""  # newline-separated "<spec>\x1f<declaration>"
while IFS=$'\x1f' read -r src r_spec r_step r_decl r_kind r_signal r_anchor r_gate r_note || [[ -n "${src:-}" ]]; do
  [[ -z "${r_spec:-}" ]] && continue
  case "$r_spec" in \#*) continue ;; esac

  r_decl="${r_decl:-}"
  r_kind="$(_mss_trim "${r_kind:-}")"
  r_signal="$(_mss_trim "${r_signal:-}")"
  r_anchor="${r_anchor:-}"
  r_gate="$(_mss_trim "${r_gate:-}")"
  # `-` is the registry's documented "no gate" placeholder (a TSV column is
  # easier to read filled than blank). Normalise it to empty here, ONCE, so no
  # later check can mistake a literal dash for a gate token — it is a substring
  # of almost every hyphenated path in quality-gates.sh, so a raw `-` would
  # otherwise satisfy the guard-wiring check by accident.
  [[ "$r_gate" == "-" ]] && r_gate=""

  if [[ -z "$r_decl" ]]; then
    failures+=("REGISTRY-MALFORMED  $r_spec — a registry row requires a non-empty DECLARATION (the literal substring that carries the mandatory marker)")
    continue
  fi

  key="$r_spec"$'\x1f'"$r_decl"
  case $'\n'"$registry_keys" in
    *$'\n'"$key"$'\n'*)
      failures+=("REGISTRY-DUPLICATE  $r_spec :: $r_decl — registered more than once")
      continue
      ;;
  esac
  registry_keys="$registry_keys$key
"
  n_registered=$((n_registered + 1))

  [[ -n "$(_mss_trim "${r_step:-}")" ]] || failures+=("MISSING-STEP  $r_spec :: $r_decl — every registry row must name the STEP the declaration governs")
  [[ -n "$(_mss_trim "${r_note:-}")" ]] || failures+=("MISSING-NOTE  $r_spec :: $r_decl — every registry row requires a non-empty NOTE saying how this signal discharges this declaration")

  # --- the DECLARATION half -------------------------------------------------
  spec_path="$(_mss_resolve_path "$r_spec")"
  if [[ ! -r "$spec_path" ]]; then
    if _mss_row_unadopted_upstream "$src"; then
      unadopted_lines+=("note: registry row $r_spec :: $r_decl names a command spec this repo did not adopt — an upstream row for unadopted content, skipped (temperloop#1740)")
    else
      failures+=("SPEC-NOT-FOUND  $r_spec :: $r_decl — the spec file does not exist or is not readable at $spec_path")
    fi
    continue
  fi
  decl_hits="$(_mss_count_fixed "$spec_path" "$r_decl")"
  if [[ "$decl_hits" -eq 0 ]]; then
    failures+=("HALF-PRESENT  $r_spec :: $r_decl — the DECLARATION half is gone: the anchor no longer appears in $r_spec. Retire the row deliberately (and its signal, if nothing else needs it) rather than leaving a pair that validates nothing")
    continue
  elif [[ "$decl_hits" -gt 1 ]]; then
    failures+=("DECLARATION-AMBIGUOUS  $r_spec :: $r_decl — the anchor matches $decl_hits lines in $r_spec; lengthen it until it identifies exactly one declaration")
    continue
  fi
  # The marker test is against the whole LINE the anchor identifies, not the
  # anchor text itself: the anchor's job is to pin down WHICH line, and a
  # declaration's marker often sits elsewhere on that same line. This is also
  # what keeps the registry and the discovery pass in exact agreement — a row
  # can only ever be satisfied by a line the discovery pass would itself have
  # flagged, so a registry row can never quietly cover a non-declaration.
  decl_line="$(grep -F -m1 -- "$r_decl" "$spec_path" 2>/dev/null)"
  if ! _mss_has_marker "$decl_line"; then
    failures+=("DECLARATION-NOT-MANDATORY  $r_spec :: $r_decl — the line this anchor identifies carries no mandatory marker ($MANDATORY_STEP_MARKER_RE), so it is not a declaration this registry can be satisfied by; anchor on the declaring line itself")
  fi

  # --- the SIGNAL half ------------------------------------------------------
  case "$r_kind" in
    tally | guard | refusal | rollup) ;;
    *)
      failures+=("SIGNAL-KIND-UNKNOWN  $r_spec :: $r_decl — KIND is '${r_kind:-<empty>}'; must be one of tally|guard|refusal|rollup (see § THE SCOPE DECISION (b))")
      continue
      ;;
  esac

  if [[ -z "$r_signal" || -z "$r_anchor" ]]; then
    failures+=("HALF-PRESENT  $r_spec :: $r_decl — the SIGNAL half is missing: a registry row must name both a SIGNAL file and an ANCHOR within it. A declaration with no execution signal is exactly the defect this gate exists to close")
    continue
  fi

  signal_path="$(_mss_resolve_path "$r_signal")"
  if [[ ! -r "$signal_path" ]]; then
    failures+=("HALF-PRESENT  $r_spec :: $r_decl — the SIGNAL half is gone: $r_signal does not exist or is not readable at $signal_path")
    continue
  fi
  if [[ "$(_mss_count_fixed "$signal_path" "$r_anchor")" -eq 0 ]]; then
    failures+=("SIGNAL-ANCHOR-MISSING  $r_spec :: $r_decl — the ANCHOR is not present in $r_signal, so the signal this declaration relies on is gone or was renamed: $r_anchor")
    continue
  fi

  # A `guard` is only a signal if something runs it.
  if [[ "$r_kind" == "guard" ]]; then
    if [[ -z "$r_gate" ]]; then
      failures+=("GUARD-UNGATED  $r_spec :: $r_decl — a KIND=guard row must name the GATE token that runs the guard (a quality-gates.sh invocation line); a guard nobody runs proves nothing")
    elif ! _mss_gate_active "$r_gate"; then
      failures+=("GUARD-NOT-GATED  $r_spec :: $r_decl — GATE token '$r_gate' does not appear on an ACTIVE (non-commented) invocation line of $MANDATORY_STEP_QUALITY_GATES_FILE; a commented-out gate line is how this repo DISABLES a suite")
    fi
  elif [[ -n "$r_gate" ]]; then
    notes+=("note: $r_spec :: $r_decl carries a GATE token on a KIND=$r_kind row; GATE is only checked for KIND=guard")
  fi
done < <(_mss_tsv_files "$MANDATORY_STEP_REGISTRY_FILE" "$MANDATORY_STEP_REGISTRY_OVERLAY_FILE")

# ---------------------------------------------------------------------------
# 2b. EMPTY-REGISTRY — a registry with zero parsed rows is a vacuous pass.
#     Absent and unreadable already fail closed above; empty (or comment-only)
#     must too, or this gate ships the very defect class it enforces against.
# ---------------------------------------------------------------------------
if [[ "$n_registered" -eq 0 ]]; then
  failures+=("EMPTY-REGISTRY  $MANDATORY_STEP_REGISTRY_FILE parses to ZERO rows — an empty or comment-only registry is a vacuous pass, exactly the defect class this gate exists to close")
fi

# ---------------------------------------------------------------------------
# 3. THE DISCOVERY PASS — enumerate every mandatory-marker line in the spec
#    corpus and require a disposition for each.
#
#    Fenced code blocks are skipped: a ``` block in a spec is an EXAMPLE or a
#    literal command, not a declaration, and flagging one would be the
#    temperloop#1152 class (a guard that fires on a demonstration of its own
#    subject). The fence toggle resets at every file boundary.
# ---------------------------------------------------------------------------
spec_files=""
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  spec_files="$spec_files$f
"
done < <(find "$MANDATORY_STEP_SPEC_DIR" -maxdepth 1 -type f -name '*.md' 2>/dev/null | LC_ALL=C sort)

if [[ -z "$spec_files" ]]; then
  _mss_cannot_evaluate "spec corpus $MANDATORY_STEP_SPEC_DIR contains no *.md files — a discovery pass over an empty corpus establishes nothing"
fi

undisposed=""
while IFS= read -r spec_abs; do
  [[ -n "$spec_abs" ]] || continue
  spec_rel="${spec_abs#"$MANDATORY_STEP_REPO_ROOT"/}"
  in_fence=0
  lineno=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    lineno=$((lineno + 1))
    case "$(_mss_trim "$line")" in
      '```'*) in_fence=$((1 - in_fence)); continue ;;
    esac
    [[ "$in_fence" -eq 1 ]] && continue
    _mss_has_marker "$line" || continue
    n_discovered=$((n_discovered + 1))

    disposed=0
    # Registered? A registry row for this spec whose DECLARATION is a literal
    # substring of this line.
    while IFS= read -r k; do
      [[ -n "$k" ]] || continue
      k_spec="${k%%$'\x1f'*}"
      k_anchor="${k#*$'\x1f'}"
      [[ "$k_spec" == "$spec_rel" ]] || continue
      case "$line" in *"$k_anchor"*) disposed=1; break ;; esac
    done <<EOF
$registry_keys
EOF
    if [[ "$disposed" -eq 0 ]]; then
      while IFS= read -r k; do
        [[ -n "$k" ]] || continue
        k_spec="${k%%$'\x1f'*}"
        k_anchor="${k#*$'\x1f'}"
        [[ "$k_spec" == "$spec_rel" ]] || continue
        case "$line" in *"$k_anchor"*) disposed=1; break ;; esac
      done <<EOF
$ledger_keys
EOF
    fi

    if [[ "$disposed" -eq 0 ]]; then
      undisposed="$undisposed$spec_rel:$lineno
"
      failures+=("UNDISPOSED-DECLARATION  $spec_rel:$lineno — this line declares something mandatory but has NO disposition: no $MANDATORY_STEP_REGISTRY_FILE row pairing it with an execution signal, and no $MANDATORY_STEP_DISCOVERY_FILE row saying why it needs none. Ship the signal in this same change (the birth rule), or disposition it 'excluded' with a reason. Line: $(_mss_trim "$line" | cut -c1-160)")
    fi
  done <"$spec_abs"
done <<EOF
$spec_files
EOF

# ---------------------------------------------------------------------------
# 4. THE `pending` RATCHET — shrink-only. See § THE BIRTH RULE'S TEETH above.
# ---------------------------------------------------------------------------
ratchet_lines=()

_mss_base_ref=""
_mss_base_explicit=0
_mss_ratchet_skip_reason=""
if [[ -n "$MANDATORY_STEP_BASE_REF" ]]; then
  _mss_base_ref="$MANDATORY_STEP_BASE_REF"
  _mss_base_explicit=1
elif git -C "$MANDATORY_STEP_GIT_REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  _mss_base_ref="$(git -C "$MANDATORY_STEP_GIT_REPO_ROOT" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)"
  if [[ -z "$_mss_base_ref" ]] && git -C "$MANDATORY_STEP_GIT_REPO_ROOT" show-ref --verify --quiet refs/remotes/origin/main; then
    _mss_base_ref="origin/main"
  fi
  if [[ -z "$_mss_base_ref" ]]; then
    _mss_ratchet_skip_reason="no origin remote resolvable in $MANDATORY_STEP_GIT_REPO_ROOT (checked refs/remotes/origin/HEAD then refs/remotes/origin/main)"
  fi
else
  _mss_ratchet_skip_reason="$MANDATORY_STEP_GIT_REPO_ROOT is not a git working tree"
fi

if [[ -n "$_mss_base_ref" ]]; then
  if ! git -C "$MANDATORY_STEP_GIT_REPO_ROOT" rev-parse --verify -q "${_mss_base_ref}^{commit}" >/dev/null 2>&1; then
    if [[ "$_mss_base_explicit" -eq 1 ]]; then
      _mss_cannot_evaluate "the ratchet base ref ($_mss_base_ref) does not resolve in $MANDATORY_STEP_GIT_REPO_ROOT — cannot determine whether the pending set grew"
    fi
    _mss_ratchet_skip_reason="the auto-resolved ratchet base ref ($_mss_base_ref) does not resolve to a commit in $MANDATORY_STEP_GIT_REPO_ROOT"
    _mss_base_ref=""
  fi
fi

# _mss_file_added <relpath> -> rc 0 iff <relpath> was genuinely ADDED since
# the base ref, per git's own rename-aware diff (-M). No path filter on the
# diff itself — a single-path filter defeats rename detection, which is how a
# RENAME would otherwise re-arm the bootstrap exemption.
_mss_file_added() {
  local relpath="$1" added
  added="$(git -C "$MANDATORY_STEP_GIT_REPO_ROOT" diff -M --diff-filter=A --name-only "$_mss_base_ref" 2>/dev/null)"
  printf '%s\n' "$added" | grep -Fx -- "$relpath" >/dev/null
}

_mss_relpath() {
  local resolved="$1" relpath
  relpath="${resolved#"$MANDATORY_STEP_GIT_REPO_ROOT"/}"
  [[ "$relpath" != "$resolved" ]] || return 1
  printf '%s\n' "$relpath"
}

# The pending set is a UNION across the kernel ledger and its overlay twin
# (temperloop#1738), so the ratchet is too. Ratcheting only the kernel half
# would report every overlay-authored row as PENDING-GREW forever; not
# ratcheting the overlay half would make it the debt parking lot this ratchet
# exists to prevent. Each source contributes its own ALLOWED set; a current row
# is growth only if it is in none of them.
_mss_allowed_pending=""
# ALWAYS append through this helper, never by bare `$( )` concatenation.
# `$( )` strips EVERY trailing newline, and the membership test below closes on
# one (`*$'\n'"$item"$'\n'*`), so an un-terminated contribution makes its LAST
# entry unmatchable and falsely PENDING-GREW on every run. This is the same
# trap §4c of validate-check-surface-degenerate-coverage.sh documents; it bit
# this refactor too, which is why it is now a helper rather than a convention.
_mss_allow_add() {
  local chunk="$1"
  [[ -n "$chunk" ]] || return 0
  _mss_allowed_pending="$_mss_allowed_pending$chunk"$'\n'
}
_mss_pending_from_content() { # <content> -> "<spec>\x1f<anchor>" lines
  local content="$1" p_spec p_anchor p_disp _p_rest out=""
  [[ -n "$content" ]] || return 0
  while IFS=$'\x1f' read -r p_spec p_anchor p_disp _p_rest || [[ -n "${p_spec:-}" ]]; do
    [[ -z "${p_spec:-}" ]] && continue
    case "$p_spec" in \#*) continue ;; esac
    [[ "$(_mss_trim "${p_disp:-}")" == "pending" ]] || continue
    out="$out$p_spec"$'\x1f'"${p_anchor:-}
"
  done < <(_mss_tsv_string "$content")
  printf '%s' "$out"
}
if [[ -z "$_mss_ratchet_skip_reason" ]]; then
  for _mss_ledger in "$MANDATORY_STEP_DISCOVERY_FILE" "$MANDATORY_STEP_DISCOVERY_OVERLAY_FILE"; do
    [[ -f "$_mss_ledger" ]] || continue
    _mss_ledger_relpath="$(_mss_relpath "$_mss_ledger")" || _mss_ledger_relpath=""
    if [[ -z "$_mss_ledger_relpath" ]]; then
      # Not under the git root: the base-ref side is unreadable, so this file
      # cannot be ratcheted. GRANDFATHER its rows and SAY so — contributing
      # nothing would falsely report them as growth.
      _mss_allow_add "$(_mss_pending_from_content "$(cat "$_mss_ledger")")"
      ratchet_lines+=("pending ratchet: SKIPPED for $_mss_ledger (not under $MANDATORY_STEP_GIT_REPO_ROOT — its rows are grandfathered, not checked)")
      continue
    fi
    if _mss_file_added "$_mss_ledger_relpath"; then
      _mss_allow_add "$(_mss_pending_from_content "$(cat "$_mss_ledger")")"
      ratchet_lines+=("pending ratchet: SKIPPED for $_mss_ledger_relpath (bootstrap — added in this diff, nothing to compare against)")
      continue
    fi
    _mss_prev="$(git -C "$MANDATORY_STEP_GIT_REPO_ROOT" show "${_mss_base_ref}:${_mss_ledger_relpath}" 2>/dev/null)" || _mss_prev=""
    _mss_allow_add "$(_mss_pending_from_content "$_mss_prev")"
    ratchet_lines+=("pending ratchet: checked against $_mss_base_ref:$_mss_ledger_relpath")
  done
  if [[ -n "$ledger_pending" ]]; then
    while IFS= read -r cur; do
      [[ -n "$cur" ]] || continue
      case $'\n'"$_mss_allowed_pending" in
        *$'\n'"$cur"$'\n'*) ;;
        *)
          failures+=("PENDING-GREW  ${cur%%$'\x1f'*} :: ${cur#*$'\x1f'} — dispositioned 'pending' now but not at $_mss_base_ref in any disposition source. 'pending' is a SHRINK-ONLY ratchet: a NEW mandatory declaration must ship its execution signal in the same change (the birth rule), not be parked as debt. Register it with a signal, or disposition it 'excluded' if it is not a step-execution declaration at all")
          ;;
      esac
    done <<EOF
$ledger_pending
EOF
  fi
else
  ratchet_lines+=("pending ratchet: SKIPPED ($_mss_ratchet_skip_reason)")
fi

# ---------------------------------------------------------------------------
# Verdict.
# ---------------------------------------------------------------------------
echo "Checked $n_registered registered (declaration, signal) pair(s) over $n_discovered discovered marker line(s) in ${MANDATORY_STEP_SPEC_DIR#"$MANDATORY_STEP_REPO_ROOT"/}"
echo "Dispositions: $n_excluded excluded, $n_pending pending (see ${MANDATORY_STEP_DISCOVERY_FILE#"$MANDATORY_STEP_REPO_ROOT"/})"
printf '%s\n' "${ratchet_lines[@]}"
if (( ${#unadopted_lines[@]} > 0 )); then
  printf '%s\n' "${unadopted_lines[@]}"
fi
if (( ${#notes[@]} > 0 )); then
  printf '%s\n' "${notes[@]}"
fi
if (( ${#failures[@]} > 0 )); then
  printf '%s\n' "${failures[@]}"
  echo "---"
  echo "failures: ${#failures[@]}"
  echo "$PREFIX: FAIL"
  exit 1
fi
echo "$PREFIX: OK"
