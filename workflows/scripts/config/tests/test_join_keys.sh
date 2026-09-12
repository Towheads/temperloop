#!/usr/bin/env bash
#
# test_join_keys.sh — the cross-language AGREEMENT test for the join-key
# registry's two loaders (temperloop#1910). Drives every fixture in
# join-keys-fixtures.json through BOTH join-keys-lib.sh's `jk_apply` and
# join_keys.py's `apply` CLI, and asserts the two produce byte-identical
# "STATUS<TAB>VALUE" output for every single fixture — the actual proof
# behind this item's "the shell and Python loaders agree on every fixture"
# acceptance bullet (full UUID, 8-char, `host:sess8`, and the absent-versus-
# zero discipline on run_id/pr_number, per join-keys.tsv's ABSENT_SEMANTICS
# column).
#
# Also asserts each loader independently produces the fixture's OWN expected
# status/value — so a fixture bug that made both loaders wrong the SAME way
# (the failure mode a pure agreement check alone cannot catch) still fails.
#
# Requires: python3, jq (both already hard dependencies of this repo's
# pr-linkage.sh / board tooling). No network.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$(cd "$HERE/.." && pwd)"
LIB="$CONFIG_DIR/join-keys-lib.sh"
PY="$CONFIG_DIR/join_keys.py"
FIXTURES="$CONFIG_DIR/join-keys-fixtures.json"

# shellcheck source=workflows/scripts/config/join-keys-lib.sh
source "$LIB"

fail=0
total=0

if ! command -v jq >/dev/null 2>&1; then
  echo "test_join_keys: jq not found — cannot parse fixtures" >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "test_join_keys: python3 not found" >&2
  exit 1
fi

n_fixtures="$(jq -e 'if type=="array" then length else error("not an array") end' "$FIXTURES")" || {
  echo "test_join_keys: $FIXTURES is not a JSON array" >&2
  exit 1
}
case "$n_fixtures" in
  '' | *[!0-9]*)
    echo "test_join_keys: could not determine a numeric fixture count from $FIXTURES" >&2
    exit 1
    ;;
esac
if [ "$n_fixtures" -eq 0 ]; then
  echo "test_join_keys: zero fixtures in $FIXTURES" >&2
  exit 1
fi

i=0
while [ "$i" -lt "$n_fixtures" ]; do
  fn="$(jq -r ".[$i].fn" "$FIXTURES")"
  exp_status="$(jq -r ".[$i].status" "$FIXTURES")"
  exp_value="$(jq -r ".[$i].value" "$FIXTURES")"
  nargs="$(jq -r ".[$i].args | length" "$FIXTURES")"
  args=()
  j=0
  while [ "$j" -lt "$nargs" ]; do
    args+=("$(jq -r ".[$i].args[$j]" "$FIXTURES")")
    j=$((j + 1))
  done

  total=$((total + 1))
  label="fixture #$i ($fn ${args[*]:-})"

  shell_out="$(jk_apply "$fn" "${args[@]+"${args[@]}"}")"
  shell_status="${shell_out%%$'\t'*}"
  shell_value="${shell_out#*$'\t'}"

  py_out="$(python3 "$PY" apply "$fn" "${args[@]+"${args[@]}"}")"
  py_status="${py_out%%$'\t'*}"
  py_value="${py_out#*$'\t'}"

  ok=1
  if [ "$shell_status" != "$exp_status" ] || [ "$shell_value" != "$exp_value" ]; then
    printf 'FAIL: %s: shell loader gave %s/%s, expected %s/%s\n' "$label" "$shell_status" "$shell_value" "$exp_status" "$exp_value"
    ok=0
  fi
  if [ "$py_status" != "$exp_status" ] || [ "$py_value" != "$exp_value" ]; then
    printf 'FAIL: %s: python loader gave %s/%s, expected %s/%s\n' "$label" "$py_status" "$py_value" "$exp_status" "$exp_value"
    ok=0
  fi
  if [ "$shell_status" != "$py_status" ] || [ "$shell_value" != "$py_value" ]; then
    printf 'FAIL: %s: loaders DISAGREE — shell=%s/%s python=%s/%s\n' "$label" "$shell_status" "$shell_value" "$py_status" "$py_value"
    ok=0
  fi
  if [ "$ok" -eq 1 ]; then
    echo "PASS: $label -> $exp_status/$exp_value"
  else
    fail=1
  fi

  i=$((i + 1))
done

echo
if [ "$fail" -ne 0 ]; then
  echo "FAIL: one or more of $total fixture(s) disagreed or mismatched expectations" >&2
  exit 1
fi
echo "OK — $total fixture(s): shell and python loaders agree, and both match expected status/value"
