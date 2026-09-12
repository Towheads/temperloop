#!/usr/bin/env bash
#
# Tests for check-join-keys.sh (temperloop#1910): a synthetic fixture set
# (tsv, shell lib, python loader, fixtures.json, pr-linkage.sh stub) proves
# the GREEN path and every RED path the checker's four checks can reach —
# a duplicate key, a missing required key, an undefined shell/python
# function, a missing pr-linkage.sh citation, a reintroduced inline regex,
# and a fixture-coverage gap — then restores each fixture to green to prove
# the checker discriminates rather than always failing.
#
# Mirrors the sibling test_check_reviewer_routing.sh's plain mktemp-fixture
# style (env-var seams point the checker at a throwaway fixture set, no git
# repo needed).

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="$(cd "$HERE/.." && pwd)"
CHECKER="$CONFIG_DIR/check-join-keys.sh"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/check-join-keys-test-XXXXXX")"
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT

pass=0
fail_count=0
ok() { pass=$((pass + 1)); echo "PASS: $1"; }
bad() { fail_count=$((fail_count + 1)); echo "FAIL: $1: $2"; }

# --- minimal, always-valid loader pair (shell + python) --------------------
write_good_lib() {
  cat >"$WORK/lib.sh" <<'EOF'
jk_run_id() { [ -z "${1:-}" ] && return 2; printf '%s' "$1"; }
jk_pr_number() { [ -z "${1:-}" ] && return 2; printf '%s' "$1"; }
EOF
}

write_good_py() {
  cat >"$WORK/loader.py" <<'EOF'
def run_id(raw):
    if not raw:
        return None
    return raw

def pr_number(raw):
    if not raw:
        return None
    return raw
EOF
}

write_good_tsv() {
  cat >"$WORK/join-keys.tsv" <<'EOF'
KEY	FORMS	NORMALIZE_RULE	ABSENT_SEMANTICS	LOADER_FUNCTIONS
session_full	x	passthrough	absent means unknown	shell:jk_run_id,py:run_id
session8	x	passthrough	absent means unknown	shell:jk_run_id,py:run_id
host_session_stamp	x	passthrough	absent means unknown	shell:jk_run_id,py:run_id
run_id	x	integer	absent means unknown, 0 is a value	shell:jk_run_id,py:run_id
pr_number	x	integer	absent means unknown, 0 is a value	shell:jk_pr_number,py:pr_number
message_id	x	passthrough	absent means unknown	shell:jk_run_id,py:run_id
plan_stem	x	passthrough	absent means unknown	shell:jk_run_id,py:run_id
EOF
}

write_good_fixtures() {
  cat >"$WORK/fixtures.json" <<'EOF'
[
  {"fn": "run_id", "args": ["1"], "status": "ok", "value": "1"},
  {"fn": "pr_number", "args": ["1"], "status": "ok", "value": "1"}
]
EOF
}

write_good_pr_linkage() {
  cat >"$WORK/pr-linkage.sh" <<'EOF'
#!/usr/bin/env bash
# sources join-keys-lib.sh and calls jk_closes_pattern.
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
open_pr_for_issue() {
  local pat
  pat="$(jk_closes_pattern "$2")"
}
EOF
}

reset_good_fixture_set() {
  write_good_lib
  write_good_py
  write_good_tsv
  write_good_fixtures
  write_good_pr_linkage
}

run_checker() {
  (
    JOIN_KEYS_TSV="$WORK/join-keys.tsv"
    JOIN_KEYS_LIB_SH="$WORK/lib.sh"
    JOIN_KEYS_PY="$WORK/loader.py"
    JOIN_KEYS_FIXTURES_JSON="$WORK/fixtures.json"
    JOIN_KEYS_PR_LINKAGE_SH="$WORK/pr-linkage.sh"
    export JOIN_KEYS_TSV JOIN_KEYS_LIB_SH JOIN_KEYS_PY JOIN_KEYS_FIXTURES_JSON JOIN_KEYS_PR_LINKAGE_SH
    bash "$CHECKER"
  )
}

# --- 1. GREEN: the baseline fixture set passes cleanly ---------------------
reset_good_fixture_set
if out="$(run_checker 2>&1)"; then
  ok "clean fixture set passes"
else
  bad "clean fixture set passes" "expected exit 0, got non-zero:
$out"
fi

# --- 2. RED: duplicate key --------------------------------------------------
reset_good_fixture_set
printf 'run_id\tx\tdup\tdup\tshell:jk_run_id,py:run_id\n' >>"$WORK/join-keys.tsv"
if out="$(run_checker 2>&1)"; then
  bad "duplicate key detected" "expected non-zero exit, checker passed:
$out"
else
  case "$out" in
    *DUPLICATE*) ok "duplicate key detected" ;;
    *) bad "duplicate key detected" "wrong failure reason:
$out" ;;
  esac
fi

# --- 3. RED: missing required key ------------------------------------------
reset_good_fixture_set
grep -v '^run_id' "$WORK/join-keys.tsv" >"$WORK/join-keys.tsv.new"
mv "$WORK/join-keys.tsv.new" "$WORK/join-keys.tsv"
if out="$(run_checker 2>&1)"; then
  bad "missing required key detected" "expected non-zero exit, checker passed:
$out"
else
  case "$out" in
    *"MISSING: required join key 'run_id'"*) ok "missing required key detected" ;;
    *) bad "missing required key detected" "wrong failure reason:
$out" ;;
  esac
fi

# --- 4. RED: undefined shell function ---------------------------------------
reset_good_fixture_set
sed -i.bak 's/shell:jk_pr_number/shell:jk_pr_number_typo/' "$WORK/join-keys.tsv" && rm -f "$WORK/join-keys.tsv.bak"
if out="$(run_checker 2>&1)"; then
  bad "undefined shell function detected" "expected non-zero exit, checker passed:
$out"
else
  case "$out" in
    *"UNDEFINED"*"jk_pr_number_typo"*) ok "undefined shell function detected" ;;
    *) bad "undefined shell function detected" "wrong failure reason:
$out" ;;
  esac
fi

# --- 5. RED: undefined python function --------------------------------------
reset_good_fixture_set
sed -i.bak 's/py:pr_number/py:pr_number_typo/' "$WORK/join-keys.tsv" && rm -f "$WORK/join-keys.tsv.bak"
if out="$(run_checker 2>&1)"; then
  bad "undefined python function detected" "expected non-zero exit, checker passed:
$out"
else
  case "$out" in
    *"UNDEFINED"*"pr_number_typo"*) ok "undefined python function detected" ;;
    *) bad "undefined python function detected" "wrong failure reason:
$out" ;;
  esac
fi

# --- 6. RED: pr-linkage.sh missing citation (no source of the lib) --------
reset_good_fixture_set
cat >"$WORK/pr-linkage.sh" <<'EOF'
#!/usr/bin/env bash
open_pr_for_issue() { :; }
EOF
if out="$(run_checker 2>&1)"; then
  bad "missing lib citation detected" "expected non-zero exit, checker passed:
$out"
else
  case "$out" in
    *"CITATION MISSING"*"join-keys-lib.sh"*) ok "missing lib citation detected" ;;
    *) bad "missing lib citation detected" "wrong failure reason:
$out" ;;
  esac
fi

# --- 7. RED: pr-linkage.sh missing jk_closes_pattern call -------------------
reset_good_fixture_set
cat >"$WORK/pr-linkage.sh" <<'EOF'
#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
open_pr_for_issue() { :; }
EOF
if out="$(run_checker 2>&1)"; then
  bad "missing jk_closes_pattern call detected" "expected non-zero exit, checker passed:
$out"
else
  case "$out" in
    *"CITATION MISSING"*"jk_closes_pattern"*) ok "missing jk_closes_pattern call detected" ;;
    *) bad "missing jk_closes_pattern call detected" "wrong failure reason:
$out" ;;
  esac
fi

# --- 8. RED: pr-linkage.sh restates the closing-keyword regex inline -------
reset_good_fixture_set
cat >"$WORK/pr-linkage.sh" <<'EOF'
#!/usr/bin/env bash
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
open_pr_for_issue() {
  jq -r --arg n "$2" '.[] | select(.body | test("(?i)(close[sd]?|fix(e[sd])?|resolve[sd]?)[[:space:]]+#" + $n + "\\b"))'
}
EOF
if out="$(run_checker 2>&1)"; then
  bad "inline regex restatement detected" "expected non-zero exit, checker passed:
$out"
else
  case "$out" in
    *"DRIFT"*"restates the closing-keyword regex"*) ok "inline regex restatement detected" ;;
    *) bad "inline regex restatement detected" "wrong failure reason:
$out" ;;
  esac
fi

# --- 9. RED: fixture-coverage gap ------------------------------------------
reset_good_fixture_set
echo '[{"fn": "run_id", "args": ["1"], "status": "ok", "value": "1"}]' >"$WORK/fixtures.json"
if out="$(run_checker 2>&1)"; then
  bad "fixture gap detected" "expected non-zero exit, checker passed:
$out"
else
  case "$out" in
    *"FIXTURE GAP"*"pr_number"*) ok "fixture gap detected" ;;
    *) bad "fixture gap detected" "wrong failure reason:
$out" ;;
  esac
fi

# --- 10. GREEN again: prove the checker discriminates, not always-red -----
reset_good_fixture_set
if out="$(run_checker 2>&1)"; then
  ok "restored fixture set passes again (discrimination control)"
else
  bad "restored fixture set passes again (discrimination control)" "expected exit 0, got non-zero:
$out"
fi

echo
echo "$pass passed, $fail_count failed"
if [ "$fail_count" -ne 0 ]; then
  exit 1
fi
