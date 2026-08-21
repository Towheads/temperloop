#!/usr/bin/env bash
#
# validate-exec-bit-registry.sh — gates the dropped executable bit, keyed to
# an explicit registry (temperloop#1326, epic #1415).
#
# WHY THIS EXISTS. A script can lose its executable bit and stay green
# forever: every gate in this repo invokes its target scripts as
# `bash <path>` or via a `make` target, so the bit is irrelevant to CI. It
# matters only for direct `./script` invocation and for a file reading as
# intentionally-executable to a human. Two instances were caught by hand in
# this repo's own history, both surfacing only as an incidental
# `mode change 100755 => 100644` line in rebase output; neither appeared in
# review findings. Both were fixed by hand before this gate existed.
#
# WHY REGISTRY-KEYED, NOT SHEBANG-KEYED. The originating issue proposed "a
# lint that flags a tracked .sh/.py carrying a shebang whose mode is not
# 755, with an opt-out list for sourced libraries." Measured against this
# tree, that rule fires on 96 files, of which the overwhelming majority
# (sourced libraries, `bash test_x.sh` harnesses, config files sourced by
# other scripts) are CORRECTLY non-executable — a one-in-96 signal is not a
# gate. This gate instead follows the shape workflows/scripts/
# validate-check-surface-degenerate-coverage.sh established (temperloop#1476,
# epic #1409): an explicit, opt-in REGISTRY of scripts that must carry the
# bit, plus a shrink-only GRANDFATHER ALLOWLIST for known-but-not-yet-fixed
# debt, so growing the registry never forces an unrelated PR to fix every
# gap in the same breath.
#
# THIS GATE'S OWN LIVE DISCRIMINATION INSTANCE: the seed registry is this
# repo's `workflows/scripts/validate-*.sh` family. On adoption day,
# workflows/scripts/validate-check-surface-degenerate-coverage.sh had lost
# its bit (a rebase mode-change, invisible to CI) while its 15 siblings
# still carried 755 — restoring it is this item's own red-before/green-after
# proof.
#
# ── The two config files ────────────────────────────────────────────────────
#   exec-bit-registry.tsv              PATH / REASON — one row per script
#                                       required to carry the executable bit.
#                                       NEVER EMPTY (see EMPTY-REGISTRY below)
#                                       and, once a path lands, it can only be
#                                       kept (see the registry ratchet below).
#   exec-bit-grandfather-allowlist.tsv PATH / REASON for every registered-but-
#                                       not-yet-compliant path. SHRINK-ONLY
#                                       RATCHET: a path here can only be
#                                       REMOVED relative to the ratchet base
#                                       ref, never added — see §ratchet below.
#                                       Starting empty is expected.
#
# ── What this gate checks, per registered path ──────────────────────────────
#   1. The path exists in the tree (else PATH-NOT-FOUND).
#   2. The path's REASON is non-empty (else MISSING-REASON).
#   3. The path's current FILESYSTEM permission bits carry at least one
#      execute bit ([[ -x ]] — the same predicate that determines whether
#      `./script` works, which is exactly what this gate exists to protect).
#      A registered path that fails this check is EXEC-BIT-MISSING (naming
#      the file and its actual octal mode) UNLESS it is also named on the
#      grandfather allowlist, in which case it is a reported, non-failing
#      KNOWN-DEBT line.
#   4. A path that both PASSES (3) and is STILL on the grandfather allowlist
#      is GRANDFATHER-STALE — paying debt down means removing the exemption
#      in the same PR that restores the bit, not just fixing the bit.
#
# ── §ratchet — the grandfather allowlist may only shrink ───────────────────
# Same shape as validate-check-surface-degenerate-coverage.sh's allowlist
# ratchet (temperloop#1476 §4), simplified to a single PATH column (this
# gate carries no per-case STATUS axis): the allowlist is diffed against a
# resolved BASE REF. A path present at the base ref but absent now is a
# legal SHRINK. A path present now but absent at the base ref is
# ALLOWLIST-GREW — never a place to add a newly-discovered non-compliant
# path without registering it first and paying it down over time, per its
# own header. BOOTSTRAP (the commit that introduces the allowlist file for
# the first time, per git's rename-aware --diff-filter=A) is exempt from its
# own ratchet. An UNRESOLVABLE EXPLICIT base ref is CANNOT EVALUATE; NO
# ORIGIN REMOTE AT ALL degrades to a quiet, reported SKIP (checkout-
# freshness.sh's own idiom, reused verbatim below).
#
# ── Fail-closed discipline ───────────────────────────────────────────────────
# This gate must never itself be an instance of the defect it enforces
# against: it must not report success when it could not evaluate (an absent
# or unreadable registry/allowlist routes through workflows/scripts/lib/
# cannot-evaluate.sh's cannot_evaluate_emit, RC_CANNOT_EVALUATE=2), and it
# must not report success when it evaluated and found NOTHING (an EMPTY
# registry is a regular FAIL, EMPTY-REGISTRY, exit 1 — mirroring
# validate-check-surface-degenerate-coverage.sh's own HIGH-1 fix). Every
# ordinary FAIL is collected and reported ALL AT ONCE, tagged with a stable
# prefix, naming the exact path — never a bare non-zero exit.
#
# Usage:
#   workflows/scripts/validate-exec-bit-registry.sh
#   (a direct-`bash` KERNEL_GATES entry in scripts/quality-gates.sh)
#
# Env overrides (FIXTURE-TEST SEAM, all optional):
#   EXEC_BIT_REGISTRY_FILE       default: workflows/scripts/config/
#                                 exec-bit-registry.tsv
#   EXEC_BIT_ALLOWLIST_FILE      default: workflows/scripts/config/
#                                 exec-bit-grandfather-allowlist.tsv
#   EXEC_BIT_GIT_REPO_ROOT       default: this repo's root — the repo every
#                                 `git` ratchet operation runs against
#   EXEC_BIT_ALLOWLIST_BASE_REF  default: EMPTY — auto-resolved (see
#                                 §ratchet); an explicit value is used
#                                 verbatim
#   EXEC_BIT_REPO_ROOT           default: this repo's root — the root a
#                                 relative registry/allowlist/registered path
#                                 is resolved against
#
# Kept POSIX-bash-3.2-friendly (no mapfile/associative arrays) — macOS dev
# shell + Linux CI, matching every other workflows/scripts/validate-*.sh.

set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd)"

: "${EXEC_BIT_REPO_ROOT:=$DEFAULT_REPO_ROOT}"
: "${EXEC_BIT_GIT_REPO_ROOT:=$DEFAULT_REPO_ROOT}"
: "${EXEC_BIT_REGISTRY_FILE:=$SCRIPT_DIR/config/exec-bit-registry.tsv}"
: "${EXEC_BIT_ALLOWLIST_FILE:=$SCRIPT_DIR/config/exec-bit-grandfather-allowlist.tsv}"
# Empty by default — §ratchet auto-resolves at ratchet time. An
# operator-set value is honored VERBATIM (never re-resolved).
: "${EXEC_BIT_ALLOWLIST_BASE_REF:=}"

# shellcheck source=workflows/scripts/lib/cannot-evaluate.sh
source "$SCRIPT_DIR/lib/cannot-evaluate.sh"

PREFIX="validate-exec-bit-registry"

_exb_cannot_evaluate() {
  cannot_evaluate_emit "$PREFIX" "$1"
  exit $?
}

# _exb_resolve_path <maybe-relative> — absolute paths pass through; anything
# else is resolved against EXEC_BIT_REPO_ROOT.
_exb_resolve_path() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s\n' "$EXEC_BIT_REPO_ROOT/$1" ;;
  esac
}

EXEC_BIT_REGISTRY_FILE="$(_exb_resolve_path "$EXEC_BIT_REGISTRY_FILE")"
EXEC_BIT_ALLOWLIST_FILE="$(_exb_resolve_path "$EXEC_BIT_ALLOWLIST_FILE")"

[[ -f "$EXEC_BIT_REGISTRY_FILE" ]] || _exb_cannot_evaluate "registry file not found: $EXEC_BIT_REGISTRY_FILE"
[[ -r "$EXEC_BIT_REGISTRY_FILE" ]] || _exb_cannot_evaluate "registry file exists but is not readable: $EXEC_BIT_REGISTRY_FILE"

# An absent allowlist is legal (fully burned down); an UNREADABLE one is not.
if [[ -e "$EXEC_BIT_ALLOWLIST_FILE" && ! -r "$EXEC_BIT_ALLOWLIST_FILE" ]]; then
  _exb_cannot_evaluate "allowlist file exists but is not readable: $EXEC_BIT_ALLOWLIST_FILE"
fi

failures=()
n_registered=0

# ---------------------------------------------------------------------------
# Tab-safe TSV line splitting — same rationale as validate-check-surface-
# degenerate-coverage.sh's own helper (LOW 9 there): `IFS=$'\t' read`
# collapses consecutive tabs because tab is one of bash's IFS-whitespace
# characters, so a genuinely empty middle field silently shifts every field
# after it left. Route through awk once, re-joining on \x1f (ASCII US), then
# read on that (\x1f is not IFS whitespace, so it does not collapse).
#
# WHY \x1f AND NOT \x01 (temperloop#1649) — see the fuller note on the
# corresponding helper in validate-check-surface-degenerate-coverage.sh. Short
# form: 0x01 is bash's own CTLESC marker byte (0x7f is CTLNUL), and bash 3.2 —
# the system /bin/bash on macOS, and what `bash scripts/quality-gates.sh`
# resolves to on the macos-latest runner — does not split on either. It returns
# the whole line in the FIRST variable instead, 0x01 bytes and all, so every
# registry row parsed as one field and this gate was red on nightly-macos for
# seven consecutive nights while ubuntu (bash 5.x) stayed green. A BASH-VERSION
# defect, not a BSD-vs-GNU awk dialect one: the awk stage above emits
# byte-identical output under BSD and GNU awk alike.
# scripts/lint-bash32-ctlesc-ifs.sh is the mechanical guard.
# ---------------------------------------------------------------------------
_exb_tsv_file() { # <file> -> \x1f-joined lines on stdout
  awk -F'\t' 'BEGIN{OFS="\x1f"} {$1=$1; print}' "$1"
}
_exb_tsv_string() { # <string> -> \x1f-joined lines on stdout
  printf '%s' "$1" | awk -F'\t' 'BEGIN{OFS="\x1f"} {$1=$1; print}'
}

# _exb_mode <resolved-path> -> best-effort octal permission mode string for
# a human-readable failure message ("unknown" if neither stat dialect
# works). GNU `stat -c` tried first, BSD/macOS `stat -f` second — same
# two-branch feature-detection idiom this repo already uses in
# workflows/scripts/build/env-reconcile.sh and workflows/scripts/drain/
# vault_hygiene_report.sh. This is DIAGNOSTIC ONLY: the pass/fail predicate
# is always `[[ -x ]]`, never a parsed mode string.
_exb_mode() {
  local f="$1" m
  if m="$(stat -c '%a' "$f" 2>/dev/null)" && [[ -n "$m" ]]; then
    printf '%s\n' "$m"
    return 0
  fi
  if m="$(stat -f '%OLp' "$f" 2>/dev/null)" && [[ -n "$m" ]]; then
    printf '%s\n' "$m"
    return 0
  fi
  printf 'unknown\n'
}

# ---------------------------------------------------------------------------
# 1. Parse the allowlist first (PATH<TAB>REASON) — the registry pass below
#    needs to know allowlist membership to classify each registered path.
#    Absent file == fully burned down (legal, not a failure).
# ---------------------------------------------------------------------------
allowlist_paths=""
if [[ -f "$EXEC_BIT_ALLOWLIST_FILE" ]]; then
  while IFS=$'\x1f' read -r a_path a_reason || [[ -n "${a_path:-}" ]]; do
    [[ -z "${a_path:-}" ]] && continue
    case "$a_path" in \#*) continue ;; esac
    trimmed_reason="$(printf '%s' "${a_reason:-}" | awk '{ gsub(/^[ \t]+|[ \t]+$/, ""); print }')"
    if [[ -z "$trimmed_reason" ]]; then
      failures+=("ALLOWLIST-UNJUSTIFIED  $a_path — every allowlist entry requires a non-empty REASON")
    fi
    case $'\n'"$allowlist_paths" in
      *$'\n'"$a_path"$'\n'*) failures+=("ALLOWLIST-DUPLICATE  $a_path — listed more than once") ;;
      *) allowlist_paths="$allowlist_paths$a_path
" ;;
    esac
  done < <(_exb_tsv_file "$EXEC_BIT_ALLOWLIST_FILE")
fi

# ---------------------------------------------------------------------------
# 2. Parse the registry: PATH<TAB>REASON. Every registered path is checked
#    for existence, a non-empty REASON, and its current executable bit.
# ---------------------------------------------------------------------------
seen_paths=""
current_registry_paths=""
while IFS=$'\x1f' read -r r_path r_reason || [[ -n "${r_path:-}" ]]; do
  [[ -z "${r_path:-}" ]] && continue
  case "$r_path" in \#*) continue ;; esac

  case $'\n'"$seen_paths" in
    *$'\n'"$r_path"$'\n'*)
      failures+=("DUPLICATE-PATH  $r_path — registered more than once")
      continue
      ;;
  esac
  seen_paths="$seen_paths$r_path
"
  current_registry_paths="$current_registry_paths$r_path
"
  n_registered=$((n_registered + 1))

  trimmed_reason="$(printf '%s' "${r_reason:-}" | awk '{ gsub(/^[ \t]+|[ \t]+$/, ""); print }')"
  if [[ -z "$trimmed_reason" ]]; then
    failures+=("MISSING-REASON  $r_path — every registry entry requires a non-empty REASON")
  fi

  resolved="$(_exb_resolve_path "$r_path")"
  if [[ ! -e "$resolved" ]]; then
    failures+=("PATH-NOT-FOUND  $r_path — does not exist in the tree at $resolved")
    continue
  fi

  is_grandfathered=0
  case $'\n'"${allowlist_paths:-}" in
    *$'\n'"$r_path"$'\n'*) is_grandfathered=1 ;;
  esac

  if [[ -x "$resolved" ]]; then
    if [[ $is_grandfathered -eq 1 ]]; then
      failures+=("GRANDFATHER-STALE  $r_path — registered path is now compliant (executable) but still listed on $EXEC_BIT_ALLOWLIST_FILE; remove its allowlist line in the same PR that restores the bit")
    fi
  else
    mode="$(_exb_mode "$resolved")"
    if [[ $is_grandfathered -eq 1 ]]; then
      echo "KNOWN-DEBT  $r_path — mode $mode, not executable, but grandfathered (see $EXEC_BIT_ALLOWLIST_FILE)"
    else
      failures+=("EXEC-BIT-MISSING  $r_path — registered as requiring the executable bit but mode is $mode (want an owner/group/other execute bit set)")
    fi
  fi
done < <(_exb_tsv_file "$EXEC_BIT_REGISTRY_FILE")

# ---------------------------------------------------------------------------
# 2b. EMPTY-REGISTRY: a registry with zero parsed paths is a vacuous pass —
#     absent and unreadable already fail closed above; empty (or
#     comment-only) must too.
# ---------------------------------------------------------------------------
if [[ "$n_registered" -eq 0 ]]; then
  failures+=("EMPTY-REGISTRY  $EXEC_BIT_REGISTRY_FILE parses to ZERO registered paths — an empty or comment-only registry is a vacuous pass, exactly the defect class this gate exists to close")
fi

# ---------------------------------------------------------------------------
# 3. Every allowlist entry must also be a registered path — the allowlist
#    exempts a REGISTERED path's debt, never a place to acknowledge a path
#    the registry does not (yet) claim.
# ---------------------------------------------------------------------------
if [[ -n "${allowlist_paths:-}" ]]; then
  while IFS= read -r a_path; do
    [[ -z "$a_path" ]] && continue
    case $'\n'"${current_registry_paths:-}" in
      *$'\n'"$a_path"$'\n'*) ;;
      *) failures+=("ALLOWLIST-UNREGISTERED  $a_path — listed on the grandfather allowlist but not present in $EXEC_BIT_REGISTRY_FILE; register it first") ;;
    esac
  done <<<"$allowlist_paths"
fi

# ---------------------------------------------------------------------------
# 4. §ratchet — the grandfather allowlist may only shrink.
# ---------------------------------------------------------------------------
ratchet_lines=()

_exb_ratchet_base_ref=""
_exb_ratchet_explicit=0
_exb_ratchet_skip_reason=""
if [[ -n "$EXEC_BIT_ALLOWLIST_BASE_REF" ]]; then
  _exb_ratchet_base_ref="$EXEC_BIT_ALLOWLIST_BASE_REF"
  _exb_ratchet_explicit=1
elif git -C "$EXEC_BIT_GIT_REPO_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  _exb_ratchet_base_ref="$(git -C "$EXEC_BIT_GIT_REPO_ROOT" symbolic-ref --short refs/remotes/origin/HEAD 2>/dev/null)"
  if [[ -z "$_exb_ratchet_base_ref" ]] && git -C "$EXEC_BIT_GIT_REPO_ROOT" show-ref --verify --quiet refs/remotes/origin/main; then
    _exb_ratchet_base_ref="origin/main"
  fi
  if [[ -z "$_exb_ratchet_base_ref" ]]; then
    _exb_ratchet_skip_reason="no origin remote resolvable in $EXEC_BIT_GIT_REPO_ROOT (checked refs/remotes/origin/HEAD then refs/remotes/origin/main)"
  fi
else
  _exb_ratchet_skip_reason="$EXEC_BIT_GIT_REPO_ROOT is not a git working tree"
fi

if [[ -n "$_exb_ratchet_base_ref" ]]; then
  if ! git -C "$EXEC_BIT_GIT_REPO_ROOT" rev-parse --verify -q "${_exb_ratchet_base_ref}^{commit}" >/dev/null 2>&1; then
    if [[ "$_exb_ratchet_explicit" -eq 1 ]]; then
      _exb_cannot_evaluate "the ratchet base ref ($_exb_ratchet_base_ref) does not resolve in $EXEC_BIT_GIT_REPO_ROOT — cannot determine whether the allowlist regressed"
    fi
    _exb_ratchet_skip_reason="the auto-resolved ratchet base ref ($_exb_ratchet_base_ref) does not resolve to a commit in $EXEC_BIT_GIT_REPO_ROOT"
    _exb_ratchet_base_ref=""
  fi
fi

# _exb_ratchet_file_added <relpath> -> rc 0 iff <relpath> was genuinely ADDED
# since _exb_ratchet_base_ref, per git's own rename-aware diff (-M). No path
# filter on the diff itself — a single-path filter defeats rename detection
# (see validate-check-surface-degenerate-coverage.sh's identical helper for
# the full rationale).
_exb_ratchet_file_added() {
  local relpath="$1" added
  added="$(git -C "$EXEC_BIT_GIT_REPO_ROOT" diff -M --diff-filter=A --name-only "$_exb_ratchet_base_ref" 2>/dev/null)"
  printf '%s\n' "$added" | grep -Fx -- "$relpath" >/dev/null
}

_exb_ratchet_relpath() {
  local resolved="$1" relpath
  relpath="${resolved#"$EXEC_BIT_GIT_REPO_ROOT"/}"
  [[ "$relpath" != "$resolved" ]] || return 1
  printf '%s\n' "$relpath"
}

if [[ -z "$_exb_ratchet_skip_reason" ]]; then
  allowlist_relpath="$(_exb_ratchet_relpath "$EXEC_BIT_ALLOWLIST_FILE")" || allowlist_relpath=""
  if [[ -z "$allowlist_relpath" ]]; then
    ratchet_lines+=("allowlist ratchet: SKIPPED ($EXEC_BIT_ALLOWLIST_FILE is not under $EXEC_BIT_GIT_REPO_ROOT)")
  elif _exb_ratchet_file_added "$allowlist_relpath"; then
    ratchet_lines+=("allowlist ratchet: SKIPPED (bootstrap — $allowlist_relpath was added in this diff, nothing to compare against)")
  else
    prev_content="$(git -C "$EXEC_BIT_GIT_REPO_ROOT" show "${_exb_ratchet_base_ref}:${allowlist_relpath}" 2>/dev/null)" || prev_content=""
    prev_paths=""
    if [[ -n "$prev_content" ]]; then
      while IFS=$'\x1f' read -r p_path _rest || [[ -n "${p_path:-}" ]]; do
        [[ -z "${p_path:-}" ]] && continue
        case "$p_path" in \#*) continue ;; esac
        prev_paths="$prev_paths$p_path
"
      done < <(_exb_tsv_string "$prev_content")
    fi
    if [[ -n "${allowlist_paths:-}" ]]; then
      while IFS= read -r cur_path; do
        [[ -z "$cur_path" ]] && continue
        case $'\n'"$prev_paths" in
          *$'\n'"$cur_path"$'\n'*) ;;
          *) failures+=("ALLOWLIST-GREW  $cur_path — present in $EXEC_BIT_ALLOWLIST_FILE now but not at $_exb_ratchet_base_ref; the allowlist is a shrink-only ratchet (acceptance criterion 2), never a place to add a newly-discovered non-compliant path without registering and paying it down") ;;
        esac
      done <<<"$allowlist_paths"
    fi
    ratchet_lines+=("allowlist ratchet: checked against $_exb_ratchet_base_ref:$allowlist_relpath")
  fi
else
  ratchet_lines+=("allowlist ratchet: SKIPPED ($_exb_ratchet_skip_reason)")
fi

# ---------------------------------------------------------------------------
# Verdict.
# ---------------------------------------------------------------------------
n_allowlisted=0
if [[ -n "${allowlist_paths:-}" ]]; then
  n_allowlisted="$(printf '%s' "$allowlist_paths" | grep -c . || true)"
fi
echo "Checked $n_registered registered path(s); $n_allowlisted path(s) on the grandfather allowlist ($EXEC_BIT_ALLOWLIST_FILE)"
printf '%s\n' "${ratchet_lines[@]}"
if (( ${#failures[@]} > 0 )); then
  printf '%s\n' "${failures[@]}"
  echo "---"
  echo "failures: ${#failures[@]}"
  echo "$PREFIX: FAIL"
  exit 1
fi
echo "$PREFIX: OK"
