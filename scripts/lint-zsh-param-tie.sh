#!/usr/bin/env bash
#
# lint-zsh-param-tie.sh — mechanical guard against the temperloop#40 footgun.
#
# Under zsh the lowercase array parameters `path`, `cdpath`, `fpath`, `manpath`,
# and `mailpath` are TIED to the colon side of the matching uppercase env var
# (`path` <-> `PATH`, etc.). So in any file that is *sourced* into a shell, a
# `local path=…` (or a bare `path=…` assignment) silently rebinds `PATH` for that
# scope — which broke `ks_search` under zsh by making `uvx` unresolvable
# (temperloop#40, surfaced from <org>/foundation#987). bash treats these as
# ordinary variables, so the bash test suite and shellcheck are BLIND to it; this
# grep is the portable, zsh-free guard that keeps the fixed renames from being
# "corrected" back later.
#
# Scope: the libraries that are `source`d rather than executed — where the tie
# actually bites. Executed scripts get their own PATH scope and are out of scope.
#
# Exit 0 = clean; exit 1 = at least one tied-parameter local/assignment found.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# The sourced-library surface. Add globs here as new sourced-lib dirs appear.
LIB_GLOBS=(
  "$REPO_ROOT/workflows/scripts/lib"/*.sh
  "$REPO_ROOT/workflows/scripts/board/lib"/*.sh
)

# The zsh special parameters that are tied to a colon-path env var. `path` (PATH)
# is the dangerous one for subprocess lookup; the rest are covered for the same
# class of surprise.
TIED='path|cdpath|fpath|manpath|mailpath'

violations=0
for f in "${LIB_GLOBS[@]}"; do
  [ -e "$f" ] || continue   # a glob that matched nothing expands to itself
  # Strip comments FIRST so NOTE prose that names `path` is never flagged:
  #   - a full-line comment (optional leading whitespace then `#`)
  #   - a trailing comment (whitespace then `#` to end of line)
  # `${#arr}` / `$#` are left alone (their `#` is not preceded by whitespace).
  stripped="$(sed -E 's/^[[:space:]]*#.*$//; s/([[:space:]])#.*$/\1/' "$f")"
  # Two footgun forms:
  #   1. a `local` declaration listing a tied name as a bare word
  #   2. a bare assignment to a tied name at statement start
  # `\b<name>\b` does not match `doc_path`/`cfg_path`/`proj_path` (the `_` is a
  # word char, so there is no boundary), so the safe renames pass clean.
  hits="$(printf '%s\n' "$stripped" \
    | grep -nE "\\blocal\\b.*\\b(${TIED})\\b|^[[:space:]]*(${TIED})=" || true)"
  if [ -n "$hits" ]; then
    if [ "$violations" -eq 0 ]; then
      echo "lint-zsh-param-tie: FAIL — zsh-tied special parameter used as a local/assignment in a sourced lib:" >&2
      echo "  (under zsh these rebind PATH/CDPATH/… for the scope — use doc_path/cfg_path/proj_path instead; see temperloop#40)" >&2
    fi
    while IFS= read -r line; do
      printf '  %s:%s\n' "${f#"$REPO_ROOT"/}" "$line" >&2
    done <<EOF
$hits
EOF
    violations=$((violations + 1))
  fi
done

if [ "$violations" -gt 0 ]; then
  exit 1
fi
echo "lint-zsh-param-tie: OK — no zsh-tied special-parameter locals in sourced libs"
