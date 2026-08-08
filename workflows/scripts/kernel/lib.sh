#!/usr/bin/env bash
#
# lib.sh — shared manifest parse/classify helpers for the kernel-manifest
# tooling (foundation #798, follow-on to #781's check-kernel-manifest.sh).
# Sourced by check-kernel-manifest.sh and list-kernel-set.sh so the
# parse + longest-pattern-wins matching logic lives in exactly ONE place
# instead of being copy-pasted per consumer.
#
# Sourced, not executed:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
#
# SHELL PORTABILITY — this file is SOURCED, so the shebang above is INERT and
# these functions run under WHATEVER shell the caller happens to be
# (temperloop#1177). On macOS that is routinely zsh: Claude Code's Bash tool
# runs the user's login shell, so every agent invocation of /assess's
# seam-straddling check and /build Step 3b's kernel backstop evaluates this
# code under zsh, not bash. Two zsh-vs-bash divergences bit the original
# implementation, and BOTH failed SILENTLY-ISH toward "not kernel" — the
# unsafe answer for a guard whose whole job is to stop kernel content being
# built in the wrong repo:
#
#   1. `${!ARRAY[@]}` (indexed-array-keys expansion) is a bash-ism. zsh
#      rejects it outright — `kernel_lib_classify:2: bad substitution` on
#      stderr, empty stdout, rc 1 — which is BIT-IDENTICAL to the legitimate
#      "no pattern matched" answer. Hence: no shell arrays here at all. The
#      manifest lives in ONE newline-delimited scalar, KERNEL_LIB_ENTRIES,
#      each line `<class> <pattern>` (the manifest's own normalized form).
#   2. zsh does NOT glob-match a pattern that arrives via PARAMETER EXPANSION
#      unless GLOB_SUBST is set — `case "$f" in $pat)` and `[[ "$f" == $pat ]]`
#      both quietly evaluate to NO MATCH under zsh, with no error at all. This
#      is the nastier half: fixing (1) alone leaves a matcher that runs clean
#      and answers "unclassified" for every path. `_kernel_lib_match` therefore
#      sets `localoptions globsubst` when it detects zsh (function-scoped,
#      restored on return; never executed under bash).
#
# Because a portability break in this file is INVISIBLE by construction, the
# loader FAILS CLOSED: `kernel_lib_load_manifest` runs `kernel_lib_selftest`
# (a known-answer match against a synthetic 2-entry fixture) BEFORE parsing,
# and refuses to load — loudly, rc 1 — if the matcher does not work in this
# shell. `kernel_lib_classify` then distinguishes "no pattern matched" (rc 1)
# from "CANNOT EVALUATE" (rc 2). A guard that cannot evaluate must never
# return the safe answer.
#
# Keep every construct below POSIX-shell-shaped (`case`, `[ ]`, parameter
# expansion) — no `[[ ]]`, no arrays, no arithmetic-context globs — so the
# supported set stays bash 3.2 (macOS), bash 5, and zsh 5.

# --- rc contract (consumers compare against these, never bare integers) ------
# 0                                — classified; class on stdout
# KERNEL_LIB_RC_NOMATCH        (1) — evaluated fine, no pattern matched
# KERNEL_LIB_RC_CANNOT_EVALUATE(2) — could NOT evaluate; a hard error for
#                                    every consumer, never "not kernel"
KERNEL_LIB_RC_NOMATCH=1
KERNEL_LIB_RC_CANNOT_EVALUATE=2

# The loaded manifest: newline-delimited `<class> <pattern>` lines.
KERNEL_LIB_ENTRIES=""
# Set to 1 by kernel_lib_load_manifest ONLY on full success (selftest passed,
# entries parsed, store verified). Empty means "cannot evaluate".
KERNEL_LIB_LOADED=""
# Out-param of _kernel_lib_match (avoids a subshell per classified path).
KERNEL_LIB_MATCH_CLASS=""
# A literal newline, for building KERNEL_LIB_ENTRIES — `$(printf '\n')` is
# useless here since command substitution strips trailing newlines.
KERNEL_LIB_NL='
'

# _kernel_lib_match <path> <entries>
#   Core longest-pattern-wins matcher. <entries> is a newline-delimited list of
#   `<class> <pattern>` lines. Sets KERNEL_LIB_MATCH_CLASS to the winning class
#   and returns 0; returns 1 (and empties it) when no pattern matched.
#   Internal — callers use kernel_lib_classify.
_kernel_lib_match() {
  if [ -n "${ZSH_VERSION:-}" ]; then  # setting:exempt — shell-provided identity var, not a tunable seam
    # zsh only globs an expanded parameter under GLOB_SUBST (see header note 2).
    # `localoptions` scopes the change to this function call.
    setopt localoptions globsubst
  fi
  local f="$1" entries="$2" entry cls pat plen best_len=-1
  KERNEL_LIB_MATCH_CLASS=""
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    cls="${entry%% *}"
    pat="${entry#* }"
    # shellcheck disable=SC2254  # intentional unquoted glob match
    case "$f" in
      $pat)
        plen=${#pat}
        if [ "$plen" -gt "$best_len" ]; then
          best_len="$plen"
          KERNEL_LIB_MATCH_CLASS="$cls"
        fi
        ;;
    esac
  done <<EOF
$entries
EOF
  [ -n "$KERNEL_LIB_MATCH_CLASS" ] || return 1
  return 0
}

# kernel_lib_selftest
#   Known-answer probe of _kernel_lib_match against a synthetic fixture: does
#   glob matching, longest-pattern-wins, and the no-match path actually work in
#   THIS shell? rc 0 = the matcher is trustworthy here; rc 1 = it is not, and
#   nothing downstream may treat a "no match" as meaningful. This is the
#   mechanism that turns an invisible portability break into a loud failure.
kernel_lib_selftest() {
  local fixture
  fixture="overlay a/*${KERNEL_LIB_NL}kernel a/b/*${KERNEL_LIB_NL}"
  # A matching path must win with the LONGER pattern ("a/b/*", not "a/*").
  _kernel_lib_match 'a/b/c.md' "$fixture" || return 1
  [ "$KERNEL_LIB_MATCH_CLASS" = "kernel" ] || return 1
  # A non-matching path must report no match, not a stale/blank success.
  if _kernel_lib_match 'z/z.md' "$fixture"; then
    return 1
  fi
  [ -z "$KERNEL_LIB_MATCH_CLASS" ] || return 1
  return 0
}

# kernel_lib_load_manifest <manifest_file>
#   Parses <manifest_file> into KERNEL_LIB_ENTRIES. Blank lines and #-comments
#   (to end of line) are skipped. Returns non-zero — loudly, on stderr — on a
#   malformed line, an unknown class, a missing/zero-entry manifest, a shell
#   whose matcher fails kernel_lib_selftest, or an entry store that did not
#   populate. KERNEL_LIB_LOADED is set ONLY on complete success, so a later
#   kernel_lib_classify can tell "cannot evaluate" from "no match".
kernel_lib_load_manifest() {
  local manifest_file="${1:-}"
  local lineno=0 nparsed=0 nstored=0 raw line cls pat
  KERNEL_LIB_ENTRIES=""
  KERNEL_LIB_LOADED=""

  if ! kernel_lib_selftest; then
    echo "kernel_lib_load_manifest: CANNOT EVALUATE — the glob matcher does not work in this shell (${ZSH_VERSION:+zsh $ZSH_VERSION}${BASH_VERSION:+bash $BASH_VERSION}); refusing to load so no caller can read a false 'not matched' (temperloop#1177)" >&2
    return 1
  fi

  if [ -z "$manifest_file" ] || [ ! -f "$manifest_file" ]; then
    echo "kernel_lib_load_manifest: manifest not found: ${manifest_file:-<no path given>}" >&2
    return 1
  fi

  while IFS= read -r raw || [ -n "$raw" ]; do
    lineno=$((lineno + 1))
    line="${raw%%#*}"
    line="${line#"${line%%[![:space:]]*}"}"
    line="${line%"${line##*[![:space:]]}"}"
    [ -n "$line" ] || continue

    cls="${line%% *}"
    pat="${line#* }"
    if [ "$cls" = "$line" ]; then
      echo "kernel_lib_load_manifest: malformed line $lineno (no glob after class): $raw" >&2
      return 1
    fi
    case "$cls" in
      kernel | overlay | split) ;;
      *)
        echo "kernel_lib_load_manifest: bad class '$cls' at line $lineno: $raw" >&2
        return 1
        ;;
    esac
    KERNEL_LIB_ENTRIES="${KERNEL_LIB_ENTRIES}${cls} ${pat}${KERNEL_LIB_NL}"
    nparsed=$((nparsed + 1))
  done < "$manifest_file"

  if [ "$nparsed" -eq 0 ]; then
    echo "kernel_lib_load_manifest: manifest has zero entries — nothing to check" >&2
    return 1
  fi

  # Post-populate check: the store MUST hold exactly the lines we parsed. This
  # catches a shell that accepted every append and kept none of them — the
  # failure mode that, left unchecked, presents as a fully-loaded manifest that
  # classifies nothing.
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    nstored=$((nstored + 1))
  done <<EOF
$KERNEL_LIB_ENTRIES
EOF
  if [ "$nstored" -ne "$nparsed" ]; then
    echo "kernel_lib_load_manifest: CANNOT EVALUATE — parsed $nparsed manifest entr(ies) but the entry store holds $nstored; refusing to load (fail closed)" >&2
    KERNEL_LIB_ENTRIES=""
    return 1
  fi

  KERNEL_LIB_LOADED=1
  return 0
}

# kernel_lib_classify <path>
#   Echoes the class ("kernel"/"overlay"/"split") of the longest matching
#   pattern already loaded via kernel_lib_load_manifest. "Longest pattern wins"
#   — most-specific override. THREE distinct outcomes, never collapsed:
#     rc 0 — matched; class on stdout
#     rc 1 (KERNEL_LIB_RC_NOMATCH)         — evaluated, nothing matched
#     rc 2 (KERNEL_LIB_RC_CANNOT_EVALUATE) — no usable manifest is loaded, so
#           there is NO answer; stderr says so. Consumers MUST treat this as a
#           hard error, never as "not kernel".
kernel_lib_classify() {
  local f="${1:-}"
  if [ -z "${KERNEL_LIB_LOADED:-}" ]; then  # setting:exempt — internal load-state flag this lib itself sets, with a defensive :- for `set -u`
    echo "kernel_lib_classify: CANNOT EVALUATE '$f' — no manifest is loaded (kernel_lib_load_manifest did not succeed in this shell); returning rc ${KERNEL_LIB_RC_CANNOT_EVALUATE} rather than a false 'not matched' (temperloop#1177)" >&2
    return "$KERNEL_LIB_RC_CANNOT_EVALUATE"
  fi
  _kernel_lib_match "$f" "$KERNEL_LIB_ENTRIES" || return "$KERNEL_LIB_RC_NOMATCH"
  printf '%s' "$KERNEL_LIB_MATCH_CLASS"
}

# kernel_lib_resolve_for_classify <repo_root> <files_path>
#   Map a plan item's repo-relative `files:` path to the KERNEL-MANIFEST-RELATIVE
#   path that kernel_lib_classify expects, resolving the symlinked-vendored-kernel
#   case the manifest is otherwise blind to (foundation#1050).
#
#   The manifest patterns are authored relative to the KERNEL repo root
#   (`claude/agents/*`, never `kernel/claude/agents/*`). A consumer vendors the
#   kernel as a subtree (`<repo>/kernel/…`) surfaced via directory symlinks
#   (`<repo>/claude/agents -> ../kernel/claude/agents`), so a `files:` path that
#   points at kernel content arrives in a form the manifest can't match — either
#   the git-real vendored form `kernel/claude/agents/foo.md` (unmatched → falls
#   through to overlay/local, the #1050 mis-scope) or the surface symlink form
#   `claude/agents/foo.md` (a symlink whose REAL location is under `kernel/`).
#   check-kernel-manifest.sh dodges this by `cd`-ing into the subtree root before
#   `git ls-files` (temperloop#680), but /assess classifies AUTHORED paths and
#   can't cd — so it needs this explicit mapping instead.
#
#   Mapping (layout-agnostic, subtree detected by CLAUDE.kernel.md presence, per
#   the #1050 decision — no hardcoded `kernel/` prefix):
#     1. Resolve <repo_root>/<files_path> through symlinks (the DIRECTORY, via
#        `cd … && pwd -P` — the foundation case is a DIR symlink; this is
#        portable, no BSD `readlink -f`).
#     2. Walk UP from the resolved directory to the NEAREST ancestor holding
#        `claude/CLAUDE.kernel.md` — the kernel root that OWNS this file, be it a
#        vendored subtree (`<repo>/kernel`) or the repo root itself (the kernel
#        repo, where this is a no-op that returns the path unchanged).
#     3. Print the resolved path RELATIVE to that kernel root — already
#        manifest-relative, ready for kernel_lib_classify.
#   Falls back to the literal <files_path> when the path can't be resolved (file
#   or dir absent) or no kernel-root ancestor is found — so a genuine overlay
#   file, or a not-yet-created path, classifies exactly as before. Best-effort
#   and never fails: the worst case is the pre-#1050 literal-path behavior.
#     kernel_lib_resolve_for_classify <repo_root> <files_path>  ->  path to classify
kernel_lib_resolve_for_classify() {
  local repo_root="${1:-}" files_path="${2:-}" abs dir real probe kroot
  { [ -n "$repo_root" ] && [ -n "$files_path" ]; } || { printf '%s' "$files_path"; return 0; }
  abs="$repo_root/$files_path"
  # Resolve symlinks in the DIRECTORY path (covers the vendored-dir-symlink case)
  # and re-attach the basename; fall back to the literal path if the dir is gone.
  # `CDPATH=` neutralizes a CDPATH inherited from the caller's env: with a
  # RELATIVE repo_root, a bare `cd <relpath>` consults CDPATH and, on a hit,
  # ECHOES the resolved dir to stdout — which would land inside this command
  # substitution and corrupt $dir (defeating the best-effort contract).
  dir="$(CDPATH='' cd "$(dirname "$abs")" 2>/dev/null && pwd -P)" || { printf '%s' "$files_path"; return 0; }
  real="$dir/$(basename "$abs")"
  # Walk up to the nearest ancestor that IS a kernel root (holds CLAUDE.kernel.md).
  kroot=""
  probe="$dir"
  while [ -n "$probe" ] && [ "$probe" != "/" ]; do
    if [ -f "$probe/claude/CLAUDE.kernel.md" ]; then kroot="$probe"; break; fi
    probe="$(dirname "$probe")"
  done
  if [ -n "$kroot" ]; then
    # kroot is an ancestor of dir (found by walking dirname up from it), so real
    # always begins with "$kroot"/; the case is defensive, not a live branch.
    case "$real" in
      "$kroot"/*) printf '%s' "${real#"$kroot"/}"; return 0 ;;
    esac
  fi
  printf '%s' "$files_path"
}
