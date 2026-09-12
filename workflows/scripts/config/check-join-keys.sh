#!/usr/bin/env bash
#
# check-join-keys.sh — structural + citation lint for the join-key registry
# (workflows/scripts/config/join-keys.tsv, temperloop#1910), mirroring the
# shape of its sibling config checkers (check-reviewer-routing.sh,
# check-setting-registry.sh): a duplicate-key structural check, a citation
# check (pr-linkage.sh actually reads its `Closes #N` pattern through the
# shared loader), and a set-membership check (every LOADER_FUNCTIONS entry
# the registry names is a function BOTH loaders actually define — so the
# registry cannot silently drift from what the loaders implement).
#
# Four checks:
#   1. STRUCTURAL   — every data row has exactly 5 tab-separated fields, no
#                     KEY is claimed by two rows, NORMALIZE_RULE and
#                     ABSENT_SEMANTICS are non-empty, and every key this
#                     item's own scope names (session id forms, run id,
#                     message id, PR number, plan-note stem) is present.
#   2. FUNCTION COVERAGE — every row's `shell:<fn>` name is defined in
#                     join-keys-lib.sh and every `py:<fn>` name is defined in
#                     join_keys.py — a row naming a function neither loader
#                     implements is caught here, not discovered at call time.
#   3. PR-LINKAGE CITATION — pr-linkage.sh sources join-keys-lib.sh and calls
#                     jk_closes_pattern; it does NOT restate the closing-
#                     keyword regex body inline (the "own parsing is
#                     deleted" acceptance bar) — a reintroduced inline
#                     literal is exactly the drift this registry exists to
#                     prevent.
#   4. FIXTURE COVERAGE — the cross-language agreement fixture file exists,
#                     is non-empty JSON, and every registry KEY's function
#                     name appears in at least one fixture row (the
#                     agreement test itself, tests/test_join_keys.sh, is
#                     what actually PROVES shell/python agreement on each
#                     fixture — this check only proves the fixture set has
#                     no blind spot against the registry).
#
# Usage:
#   check-join-keys.sh
#
# Env overrides (fixture-driven tests, mirroring check-reviewer-routing.sh):
#   JOIN_KEYS_TSV            path to join-keys.tsv (default: sibling file)
#   JOIN_KEYS_LIB_SH         path to join-keys-lib.sh (default: sibling file)
#   JOIN_KEYS_PY             path to join_keys.py (default: sibling file)
#   JOIN_KEYS_FIXTURES_JSON  path to join-keys-fixtures.json (default: sibling file)
#   JOIN_KEYS_PR_LINKAGE_SH  path to pr-linkage.sh (default:
#                            workflows/scripts/build/lib/pr-linkage.sh under
#                            the repo root)
#
# Kept bash-3.2-portable (no associative arrays, no mapfile), matching every
# other workflows/scripts/config/*.sh checker.

set -uo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

: "${JOIN_KEYS_TSV:=$SCRIPT_DIR/join-keys.tsv}"
: "${JOIN_KEYS_LIB_SH:=$SCRIPT_DIR/join-keys-lib.sh}"
: "${JOIN_KEYS_PY:=$SCRIPT_DIR/join_keys.py}"
: "${JOIN_KEYS_FIXTURES_JSON:=$SCRIPT_DIR/join-keys-fixtures.json}"
: "${JOIN_KEYS_PR_LINKAGE_SH:=$REPO_ROOT/workflows/scripts/build/lib/pr-linkage.sh}"

for f in "$JOIN_KEYS_TSV" "$JOIN_KEYS_LIB_SH" "$JOIN_KEYS_PY" "$JOIN_KEYS_FIXTURES_JSON" "$JOIN_KEYS_PR_LINKAGE_SH"; do
  if [ ! -f "$f" ]; then
    echo "check-join-keys: required file not found: $f" >&2
    exit 1
  fi
  if [ ! -r "$f" ]; then
    echo "check-join-keys: required file not readable: $f" >&2
    exit 1
  fi
done

violations=0

# --- 1. structural: parse rows, dedupe keys, required fields non-empty ----
keys=()
loader_fn_pairs=()  # "shell_fn:py_fn" per row, parallel to keys
row_count=0
while IFS=$'\t' read -r key forms normalize absent loaders || [ -n "${key:-}" ]; do
  [ -z "${key:-}" ] && continue
  case "$key" in \#*) continue ;; esac
  [ "$key" = "KEY" ] && continue
  row_count=$((row_count + 1))
  if [ -z "${forms:-}" ] || [ -z "${normalize:-}" ] || [ -z "${absent:-}" ] || [ -z "${loaders:-}" ]; then
    echo "MALFORMED: row for key '$key' has an empty required column (need 5 non-empty tab-separated fields)"
    violations=$((violations + 1))
    continue
  fi
  for existing in "${keys[@]+"${keys[@]}"}"; do
    if [ "$existing" = "$key" ]; then
      echo "DUPLICATE: join key '$key' is declared by more than one row"
      violations=$((violations + 1))
    fi
  done
  keys+=("$key")

  shell_fn="$(printf '%s' "$loaders" | sed -n 's/.*shell:\([A-Za-z0-9_]*\).*/\1/p')"
  py_fn="$(printf '%s' "$loaders" | sed -n 's/.*py:\([A-Za-z0-9_]*\).*/\1/p')"
  if [ -z "$shell_fn" ] || [ -z "$py_fn" ]; then
    echo "MALFORMED: key '$key' LOADER_FUNCTIONS column '$loaders' does not name both a shell:<fn> and a py:<fn>"
    violations=$((violations + 1))
    shell_fn=""
    py_fn=""
  fi
  loader_fn_pairs+=("$shell_fn:$py_fn")
done <"$JOIN_KEYS_TSV"

if [ "$row_count" -eq 0 ]; then
  echo "check-join-keys: zero data rows parsed from $JOIN_KEYS_TSV" >&2
  exit 1
fi

# every key this item's own scope names must be present.
required_keys="session_full session8 host_session_stamp run_id pr_number message_id plan_stem"
for rk in $required_keys; do
  found=0
  for k in "${keys[@]+"${keys[@]}"}"; do
    [ "$k" = "$rk" ] && found=1 && break
  done
  if [ "$found" -eq 0 ]; then
    echo "MISSING: required join key '$rk' (session id forms / run id / message id / PR number / plan-note stem scope) has no row in $JOIN_KEYS_TSV"
    violations=$((violations + 1))
  fi
done

# --- 2. function coverage: every named shell/py function is DEFINED -------
for i in "${!keys[@]}"; do
  pair="${loader_fn_pairs[$i]}"
  [ -z "$pair" ] && continue
  shell_fn="${pair%%:*}"
  py_fn="${pair##*:}"
  if ! grep -qE "^${shell_fn}\(\)" "$JOIN_KEYS_LIB_SH"; then
    echo "UNDEFINED: key '${keys[$i]}' names shell function '$shell_fn', not found (as a \`${shell_fn}()\` definition) in $JOIN_KEYS_LIB_SH"
    violations=$((violations + 1))
  fi
  if ! grep -qE "^def ${py_fn}\(" "$JOIN_KEYS_PY"; then
    echo "UNDEFINED: key '${keys[$i]}' names python function '$py_fn', not found (as a \`def ${py_fn}(\` definition) in $JOIN_KEYS_PY"
    violations=$((violations + 1))
  fi
done

# --- 3. pr-linkage citation: sources the lib, calls the shared function,
#        and no longer restates the closing-keyword regex body inline ------
if ! grep -q 'join-keys-lib\.sh' "$JOIN_KEYS_PR_LINKAGE_SH"; then
  echo "CITATION MISSING: $JOIN_KEYS_PR_LINKAGE_SH does not source join-keys-lib.sh"
  violations=$((violations + 1))
fi
if ! grep -q 'jk_closes_pattern' "$JOIN_KEYS_PR_LINKAGE_SH"; then
  echo "CITATION MISSING: $JOIN_KEYS_PR_LINKAGE_SH does not call jk_closes_pattern"
  violations=$((violations + 1))
fi
if grep -qE 'close\[sd\]\?\|fix\(e\[sd\]\)\?\|resolve\[sd\]\?' "$JOIN_KEYS_PR_LINKAGE_SH"; then
  echo "DRIFT: $JOIN_KEYS_PR_LINKAGE_SH restates the closing-keyword regex body inline — this pattern's single home is jk_closes_pattern (join-keys-lib.sh)"
  violations=$((violations + 1))
fi

# --- 4. fixture coverage: every key's function name appears in a fixture --
if ! command -v jq >/dev/null 2>&1; then
  echo "check-join-keys: jq not found — cannot validate fixture coverage" >&2
  exit 1
fi
if ! jq -e 'type=="array" and length>0' "$JOIN_KEYS_FIXTURES_JSON" >/dev/null 2>&1; then
  echo "FIXTURES EMPTY: $JOIN_KEYS_FIXTURES_JSON is not a non-empty JSON array"
  violations=$((violations + 1))
else
  for i in "${!keys[@]}"; do
    pair="${loader_fn_pairs[$i]}"
    [ -z "$pair" ] && continue
    py_fn="${pair##*:}"
    if ! jq -e --arg fn "$py_fn" 'any(.[]; .fn == $fn)' "$JOIN_KEYS_FIXTURES_JSON" >/dev/null 2>&1; then
      echo "FIXTURE GAP: key '${keys[$i]}' (function '$py_fn') has no fixture row in $JOIN_KEYS_FIXTURES_JSON"
      violations=$((violations + 1))
    fi
  done
fi

echo
if [ "$violations" -gt 0 ]; then
  echo "FAIL: $violations join-key registry violation(s)" >&2
  exit 1
fi
echo "OK — join-keys.tsv (${#keys[@]} key(s)) structurally sound, both loaders define every named function, pr-linkage.sh cites the shared loader with no inline regex restatement, and every key has fixture coverage"
