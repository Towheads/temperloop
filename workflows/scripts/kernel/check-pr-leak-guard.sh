#!/usr/bin/env bash
#
# check-pr-leak-guard.sh — diff-scoped public-repo leak guard (temperloop #74).
#
# temperloop is a PUBLIC kernel repo. The kernel/overlay authoring rule (no
# personal/org/private info in kernel content) already has a WHOLE-TREE
# backstop — check-personal-token-denylist.sh (personal/org tokens) and
# check-gitleaks-kernel.sh (secrets), both scanning the kernel-manifest file
# set. THIS script is the diff-scoped complement: it scans the ADDED lines of a
# PR's diff (across ALL git-tracked files, not just the manifest) and FAILS the
# merge when a personal/private token or a secret appears in newly-added
# content — the mechanical backstop to the authoring discipline, the same way
# validate-live-drain.sh backstops the live/drain rule.
#
# It is deliberately DRY with the whole-tree check: it reads the SAME
# personal-token-denylist.tsv (deny patterns), the SAME
# personal-token-denylist-exempt-files.txt (file-level exemptions), honours the
# SAME inline `denylist:allow` suppression marker, and reuses install-gitleaks.sh
# + gitleaks for the secrets half. "What counts as a leak" stays single-sourced;
# only the SCOPE (added diff lines vs. whole file content) differs.
#
# WIRING: run as `make test-pr-leak-guard` inside scripts/quality-gates.sh's
# KERNEL_GATES, so it rides the already-required `checks` status and gates
# pull_request AND merge_group with no branch-protection reconfiguration.
#
# BASE-REF RESOLUTION (the live scan needs a base to diff against):
#   1. --base / $LEAK_GUARD_BASE if non-empty
#   2. else origin/main if it resolves
#   3. else main if it resolves
#   4. else no base -> skip the live scan with a notice, exit 0 (keeps "green on
#      a clean tree" across push:main / worker / local contexts). Real PR CI
#      passes an explicit base via ci.yml, so enforcement is never skipped
#      there; detection is proven deterministically by the regression test
#      (tests/test_check_pr_leak_guard.sh) regardless of base.
#
# Usage:
#   check-pr-leak-guard.sh [--base REF] [--head REF] [--path PATHSPEC ...] [--relative]
#
# Env overrides (also the test seams):
#   LEAK_GUARD_BASE            base ref/sha to diff against (see resolution)
#   LEAK_GUARD_HEAD            head ref (default: HEAD)
#   LEAK_GUARD_PATHS           space-separated pathspec scope; default empty =
#                              whole tree (public-repo behavior). A private OVERLAY
#                              sets this (or passes --path kernel/) so the scan
#                              covers only the vendored subtree that round-trips to
#                              the public kernel — overlay-private files, which
#                              legitimately carry org/personal tokens, are excluded.
#   LEAK_GUARD_RELATIVE        non-empty (or --relative) → `git diff --relative`,
#                              limiting the scan to $ROOT's subtree AND emitting
#                              $ROOT-relative paths. An OVERLAY sets this so paths
#                              come back kernel-root-relative and match the shared
#                              exempt list; at the kernel repo root it is a no-op.
#   KERNEL_MANIFEST_ROOT       repo root (default: git toplevel of this script)
#   KERNEL_DENYLIST_FILE       deny-pattern tsv (default: sibling)
#   KERNEL_DENYLIST_EXEMPT_FILE  file-level exemptions (default: sibling)
#   GITLEAKS_BIN               gitleaks binary to use verbatim (test seam)
#   LEAK_GUARD_SKIP_SECRETS=1  skip the gitleaks (secrets) half entirely
#
# Kept bash-3.2 friendly (macOS default shell) — no mapfile/associative arrays.

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT_DEFAULT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

: "${KERNEL_MANIFEST_ROOT:=$REPO_ROOT_DEFAULT}"
: "${KERNEL_DENYLIST_FILE:=$SCRIPT_DIR/personal-token-denylist.tsv}"
: "${KERNEL_DENYLIST_EXEMPT_FILE:=$SCRIPT_DIR/personal-token-denylist-exempt-files.txt}"
: "${LEAK_GUARD_HEAD:=HEAD}"

ROOT="$KERNEL_MANIFEST_ROOT"
BASE="${LEAK_GUARD_BASE:-}"
HEAD="$LEAK_GUARD_HEAD"

# Optional pathspec scope. Default (empty) = whole tree — temperloop's public-repo
# behavior, unchanged. A private OVERLAY that vendors this guard runs it with
# `--path kernel/` (or LEAK_GUARD_PATHS) so it scans only the subtree that
# round-trips to the public kernel; overlay-private files (which legitimately carry
# org/personal tokens) never leave the private repo and must not be scanned.
PATHS=()
if [[ -n "${LEAK_GUARD_PATHS:-}" ]]; then read -r -a PATHS <<<"$LEAK_GUARD_PATHS"; fi

# --relative / LEAK_GUARD_RELATIVE: run `git diff --relative` so the scan is
# limited to $ROOT's subtree AND emits paths RELATIVE to $ROOT. In an OVERLAY,
# $ROOT is the vendored kernel/ subtree (a subdir of the overlay repo), so this
# both scopes to kernel/ and makes the reported paths kernel-root-relative — the
# form the shared exempt list (personal-token-denylist-exempt-files.txt, one
# git-relative path per line) is written in, so exemptions match exactly as in the
# kernel repo's own CI. At the kernel repo root (temperloop) $ROOT IS the toplevel,
# so --relative is a no-op there — public-repo whole-tree behavior is unchanged.
RELATIVE="${LEAK_GUARD_RELATIVE:-}"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --base) BASE="$2"; shift 2 ;;
    --head) HEAD="$2"; shift 2 ;;
    --path) PATHS+=("$2"); shift 2 ;;
    --relative) RELATIVE=1; shift ;;
    *) echo "check-pr-leak-guard: unknown argument '$1'" >&2; exit 2 ;;
  esac
done

git_root() { git -C "$ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; }
if ! git_root; then
  echo "check-pr-leak-guard: $ROOT is not a git checkout" >&2
  exit 1
fi

# --- resolve base ref -------------------------------------------------------
resolve_base() {
  local b="$1"
  if [[ -n "$b" ]]; then
    if git -C "$ROOT" rev-parse --verify -q "$b^{commit}" >/dev/null 2>&1; then
      printf '%s' "$b"; return 0
    fi
    echo "check-pr-leak-guard: base ref '$b' does not resolve" >&2
    return 1
  fi
  local cand
  for cand in origin/main main; do
    if git -C "$ROOT" rev-parse --verify -q "$cand^{commit}" >/dev/null 2>&1; then
      printf '%s' "$cand"; return 0
    fi
  done
  return 1
}

if ! BASE="$(resolve_base "$BASE")"; then
  echo "check-pr-leak-guard: no base ref resolvable (tried \$LEAK_GUARD_BASE, origin/main, main) — skipping the live diff scan."
  echo "check-pr-leak-guard: nothing to scan; OK (regression test gates detection independently)."
  exit 0
fi

# Three-dot compares HEAD against the merge-base with BASE (the PR's own
# additions, unaffected by BASE advancing). Fall back to two-dot if the two
# share no common ancestor (should not happen in a normal PR).
DIFF_RANGE="$BASE...$HEAD"
if ! git -C "$ROOT" merge-base "$BASE" "$HEAD" >/dev/null 2>&1; then
  DIFF_RANGE="$BASE..$HEAD"
fi

# --- load deny patterns -----------------------------------------------------
if [[ ! -f "$KERNEL_DENYLIST_FILE" ]]; then
  echo "check-pr-leak-guard: denylist not found at $KERNEL_DENYLIST_FILE" >&2
  exit 1
fi
patterns=()
descriptions=()
while IFS=$'\t' read -r pat desc; do
  [[ -z "${pat:-}" ]] && continue
  case "$pat" in \#*) continue ;; esac
  patterns+=("$pat")
  descriptions+=("$desc")
done < "$KERNEL_DENYLIST_FILE"

# Overlay: the operator-personal rows (name, personal emails, machine names,
# Sentry slug, vault path, private org/handle) do NOT ship in the tracked,
# public denylist (temperloop#438) — they live in a sibling, gitignored
# personal-token-denylist.local.tsv. UNION it in when present; DEGRADE LEGIBLY
# (a one-line NOTE, never a silent skip) when absent, so a stranger's
# kernel-only clone still runs — scanning added lines against the tracked
# structural/example rows only — and the coverage gap is visible rather than
# silent. Path defaults to the sibling of KERNEL_DENYLIST_FILE (overridable via
# KERNEL_DENYLIST_LOCAL_FILE, a test seam). This is the same single-source read
# the whole-tree check-personal-token-denylist.sh does, kept DRY.
: "${KERNEL_DENYLIST_LOCAL_FILE:=${KERNEL_DENYLIST_FILE%.tsv}.local.tsv}"
if [[ -f "$KERNEL_DENYLIST_LOCAL_FILE" ]]; then
  _local_rows=0
  while IFS=$'\t' read -r pat desc; do
    [[ -z "${pat:-}" ]] && continue
    case "$pat" in \#*) continue ;; esac
    patterns+=("$pat")
    descriptions+=("$desc")
    _local_rows=$((_local_rows + 1))
  done < "$KERNEL_DENYLIST_LOCAL_FILE"
  echo "check-pr-leak-guard: loaded $_local_rows operator-personal overlay row(s) from ${KERNEL_DENYLIST_LOCAL_FILE##*/}" >&2
else
  echo "check-pr-leak-guard: NOTE — no personal-token-denylist.local.tsv overlay present; scanning added lines against the tracked structural/example rows only (operator-personal tokens are enforced only where the gitignored overlay exists)." >&2
fi

if [[ ${#patterns[@]} -eq 0 ]]; then
  echo "check-pr-leak-guard: denylist has zero entries — nothing to check" >&2
  exit 1
fi

# --- load file-level exemptions ---------------------------------------------
exempt_files=()
if [[ -f "$KERNEL_DENYLIST_EXEMPT_FILE" ]]; then
  while IFS= read -r ex || [[ -n "$ex" ]]; do
    ex="${ex%%#*}"
    ex="${ex#"${ex%%[![:space:]]*}"}"
    ex="${ex%"${ex##*[![:space:]]}"}"
    [[ -z "$ex" ]] && continue
    exempt_files+=("$ex")
  done < "$KERNEL_DENYLIST_EXEMPT_FILE"
fi
_is_exempt() {
  local target="$1" ex
  for ex in "${exempt_files[@]+"${exempt_files[@]}"}"; do
    [[ "$target" == "$ex" ]] && return 0
  done
  return 1
}

# --- collect added lines from the diff --------------------------------------
# Emits, one record per added line: "<path>\t<line-text>". Exempt files are
# dropped here so BOTH halves (personal + secrets) honour the exemption.
# A pathspec scope (PATHS) restricts the scan to the vendored subtree in an
# overlay; empty = whole tree. The `--` guards against a path that looks like a rev.
# --relative (RELATIVE) limits to $ROOT's subtree and emits $ROOT-relative paths.
diff_opts=(--no-color --unified=0)
[[ -n "$RELATIVE" ]] && diff_opts+=(--relative)
if [[ ${#PATHS[@]} -gt 0 ]]; then
  DIFF_RAW="$(git -C "$ROOT" diff "${diff_opts[@]}" "$DIFF_RANGE" -- "${PATHS[@]}" 2>/dev/null || true)"
else
  DIFF_RAW="$(git -C "$ROOT" diff "${diff_opts[@]}" "$DIFF_RANGE" 2>/dev/null || true)"
fi

TMP_ADDED="$(mktemp "${TMPDIR:-/tmp}/leak-guard-added.XXXXXX")"
SECRETS_DIR="$(mktemp -d "${TMPDIR:-/tmp}/leak-guard-secrets.XXXXXX")"
cleanup() { rm -f "$TMP_ADDED"; rm -rf "$SECRETS_DIR"; }
trap cleanup EXIT

cur=""
added_count=0
while IFS= read -r line; do
  case "$line" in
    '+++ '*)
      # "+++ b/path" (or "+++ /dev/null" for a deletion). Strip the "b/".
      p="${line#+++ }"
      case "$p" in
        b/*) cur="${p#b/}" ;;
        *)   cur="" ;;
      esac
      ;;
    '+++'*) : ;;                 # defensive; handled above
    '+'*)
      # An added content line (single leading '+'). Not a header.
      [[ -z "$cur" ]] && continue
      _is_exempt "$cur" && continue
      text="${line#+}"
      printf '%s\t%s\n' "$cur" "$text" >> "$TMP_ADDED"
      # Mirror into the per-file secrets tree, preserving path/extension so
      # gitleaks' filename-aware rules see real context.
      dest="$SECRETS_DIR/$cur"
      mkdir -p "$(dirname "$dest")" 2>/dev/null || true
      printf '%s\n' "$text" >> "$dest"
      added_count=$((added_count + 1))
      ;;
    *) : ;;
  esac
done <<EOF
$DIFF_RAW
EOF

if [[ ${#PATHS[@]} -gt 0 ]]; then
  echo "check-pr-leak-guard: scanning $added_count added line(s) in diff range $DIFF_RANGE (scope: ${PATHS[*]})"
else
  echo "check-pr-leak-guard: scanning $added_count added line(s) in diff range $DIFF_RANGE"
fi

violations=0

# --- personal/org token half -----------------------------------------------
# One grep pass per pattern over the collected "<path>\t<text>" records. A
# record whose text carries `denylist:allow` is suppressed (same marker the
# whole-tree check honours).
if [[ $added_count -gt 0 ]]; then
  for i in "${!patterns[@]}"; do
    pat="${patterns[$i]}"
    while IFS= read -r rec; do
      [[ -z "$rec" ]] && continue
      path="${rec%%$'\t'*}"
      text="${rec#*$'\t'}"
      case "$text" in *denylist:allow*) continue ;; esac
      if printf '%s' "$text" | grep -Eq -- "$pat"; then
        printf 'LEAK  %s: [%s] %s\n    + %s\n' \
          "$path" "$pat" "${descriptions[$i]}" "$text"
        violations=$((violations + 1))
      fi
    done < "$TMP_ADDED"
  done
fi

# --- secrets half (gitleaks over the added lines) ---------------------------
if [[ "${LEAK_GUARD_SKIP_SECRETS:-0}" == "1" ]]; then
  echo "check-pr-leak-guard: secrets half skipped (LEAK_GUARD_SKIP_SECRETS=1)"
elif [[ $added_count -eq 0 ]]; then
  : # nothing added; no secrets to scan
else
  gitleaks_bin="${GITLEAKS_BIN:-}"
  if [[ -z "$gitleaks_bin" ]]; then
    gitleaks_bin="$("$SCRIPT_DIR/install-gitleaks.sh" 2>/dev/null || true)"
  fi
  if [[ -z "$gitleaks_bin" || ! -x "$gitleaks_bin" ]]; then
    # Fail-open on tooling absence: the whole-tree check-gitleaks-kernel.sh gate
    # already hard-covers secrets in the kernel set on every PR, so a diff-scoped
    # miss here is belt-and-suspenders, not the sole secrets net.
    echo "check-pr-leak-guard: WARNING — gitleaks unavailable; skipping the diff secrets scan (whole-tree gitleaks gate still applies)" >&2
  else
    set +e
    gl_out="$("$gitleaks_bin" detect --no-git --source "$SECRETS_DIR" --no-banner --exit-code 1 2>&1)"
    gl_rc=$?
    set -e 2>/dev/null || true
    if [[ $gl_rc -ne 0 ]]; then
      echo "LEAK  secret(s) detected by gitleaks in added lines:"
      printf '%s\n' "$gl_out" | sed 's/^/    /'
      violations=$((violations + 1))
    fi
  fi
fi

echo "---"
if (( violations > 0 )); then
  echo "check-pr-leak-guard: FAIL — $violations leak finding(s) in added diff lines" >&2
  echo "Fix: remove the personal/private token or secret from the added lines." >&2
  echo "     A genuinely-load-bearing literal may carry a trailing '# denylist:allow — <reason>'" >&2
  echo "     marker (personal tokens) or a gitleaks inline 'gitleaks:allow' comment (secrets)," >&2
  echo "     or the file may be added to $KERNEL_DENYLIST_EXEMPT_FILE." >&2
  exit 1
fi
echo "check-pr-leak-guard: OK — 0 leaks in $added_count added line(s)"
