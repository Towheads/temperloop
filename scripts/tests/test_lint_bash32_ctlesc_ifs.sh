#!/usr/bin/env bash
# Regression tests for scripts/lint-bash32-ctlesc-ifs.sh (temperloop#1649).
#
# The gate this backstops: `IFS=$'\x01'` splits correctly on bash 4+ and NOT AT
# ALL on bash 3.2 — every macOS system /bin/bash, and the `bash` that
# `scripts/quality-gates.sh` resolves to on the macos-latest runner. Two gate
# validators shipped that idiom to `main`; both they and both of their test
# suites went red, and `nightly-macos.yml` stayed red for seven consecutive
# nights while the ubuntu leg (bash 5.x) stayed green throughout.
#
# WHY THESE TESTS EXIST AT ALL. Same reason as the sibling suite for
# lint-bash32-cmdsubst-comment.sh: a lint ASSERTED to cover a class without ever
# being shown to fire on it is not coverage. T1 is therefore the load-bearing
# test — it feeds the lint the VERBATIM pre-fix lines from
# validate-check-surface-degenerate-coverage.sh and requires a non-zero exit. The
# rest fence in the false positives a wider rule produces; T-AWK in particular
# pins the deliberate NON-coverage of the awk side, which an earlier cut of this
# lint flagged and which is measurably correct code.
#
# T-GROUND re-measures the lint's own PREMISE on any host that actually has a
# bash 3.2 (macOS does): that 0x01/0x7f genuinely fail to split there and 0x1f
# genuinely does. On bash-4+-only hosts (ubuntu CI) it skips and says so, and the
# fixture expectations still gate. That is what keeps this file's claims from
# silently rotting into folklore.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LINT="$ROOT/scripts/lint-bash32-ctlesc-ifs.sh"
PASS=0
FAIL=0

pass() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/lint-ctlesc-ifs.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# fixture <name> <expect: fail|ok> <content>
FIXN=0
FIX_NAME=(); FIX_EXPECT=(); FIX_PATH=()
fixture() {
  FIXN=$((FIXN + 1))
  FIX_NAME[FIXN]="$1"; FIX_EXPECT[FIXN]="$2"
  FIX_PATH[FIXN]="$WORK/$1.sh"
  printf '%s\n' "$3" >"$WORK/$1.sh"
}

# ── T1: the REAL pre-fix input. These two lines are copied verbatim from
#    workflows/scripts/validate-check-surface-degenerate-coverage.sh as it stood
#    on `main` while nightly-macos was red. A lint that does not fire on THIS is
#    not a guard for this class, whatever else it does. ──────────────────────
fixture real_prefix_validator fail '#!/usr/bin/env bash
_csd_tsv_file() {
  awk -F'"'"'\t'"'"' '"'"'BEGIN{OFS="\x01"} {$1=$1; print}'"'"' "$1"
}
while IFS=$'"'"'\x01'"'"' read -r surface case_ status test_file detail; do
  echo "$surface"
done < <(_csd_tsv_file "$REG")'

# ── Must FIRE: every spelling of the two marker bytes bash accepts ──────────
fixture hex_x01      fail 'while IFS=$'"'"'\x01'"'"' read -r a b; do :; done'
fixture hex_x1_short fail 'while IFS=$'"'"'\x1'"'"' read -r a b; do :; done'
fixture octal_001    fail 'while IFS=$'"'"'\001'"'"' read -r a b; do :; done'
fixture octal_01     fail 'while IFS=$'"'"'\01'"'"' read -r a b; do :; done'
fixture octal_1      fail 'while IFS=$'"'"'\1'"'"' read -r a b; do :; done'
fixture ctlnul_x7f   fail 'while IFS=$'"'"'\x7f'"'"' read -r a b; do :; done'
fixture ctlnul_x7F   fail 'while IFS=$'"'"'\x7F'"'"' read -r a b; do :; done'
fixture ctlnul_177   fail 'while IFS=$'"'"'\177'"'"' read -r a b; do :; done'
fixture local_ifs    fail 'f() { local IFS=$'"'"'\x01'"'"'; set -- $s; echo "$1"; }'

# ── Must NOT fire: the safe replacement bytes ───────────────────────────────
fixture safe_x1f ok 'while IFS=$'"'"'\x1f'"'"' read -r a b; do :; done'
fixture safe_x1e ok 'while IFS=$'"'"'\x1e'"'"' read -r a b; do :; done'
fixture safe_x02 ok 'while IFS=$'"'"'\x02'"'"' read -r a b; do :; done'
fixture safe_tab ok 'while IFS=$'"'"'\t'"'"' read -r a b; do :; done'

# ── Must NOT fire: the AWK side. Deliberate non-coverage, measured — awk is
#    8-bit clean for these bytes on both bashes, and so is carrying them through
#    a command substitution. This exact shape is live and CORRECT in
#    workflows/scripts/validate-activation-registry.sh. ──────────────────────
fixture awk_dash_f_only ok 'slug="$(printf '"'"'%s'"'"' "$row" | awk -F'"'"'\1'"'"' '"'"'{print $1}'"'"')"'
fixture awk_ofs_only    ok 'awk -F'"'"'\t'"'"' '"'"'BEGIN{OFS="\x01"} {$1=$1; print}'"'"' "$f" >"$out"'

# ── Must NOT fire: prose that merely names the shape (temperloop#1152 class),
#    and an unrelated backreference on a line that has a separator on it. ────
fixture comment_naming_shape ok '# Never write IFS=$'"'"'\x01'"'"' here — bash 3.2 does not split on it.
echo ok'
fixture trailing_comment_naming_shape ok 'echo ok  # was IFS=$'"'"'\001'"'"' before temperloop#1649'
fixture sed_backref ok 'echo "$x" | awk -F: '"'"'{print $2}'"'"' | sed '"'"'s/\(a\)/\1/'"'"''
fixture identifier_ending_in_ifs ok 'MYIFS=$'"'"'\x01'"'"'
echo "$MYIFS" >/dev/null'

echo "── lint-bash32-ctlesc-ifs: fixture verdicts ──"
i=1
while [ "$i" -le "$FIXN" ]; do
  name="${FIX_NAME[$i]}"; expect="${FIX_EXPECT[$i]}"; path="${FIX_PATH[$i]}"
  bash "$LINT" "$path" >/dev/null 2>&1
  rc=$?
  if [ "$expect" = "fail" ]; then
    if [ "$rc" -ne 0 ]; then pass "$name — FIRES (rc=$rc), as required"
    else fail "$name — lint exited 0 on a known-bad marker-byte IFS"; fi
  else
    if [ "$rc" -eq 0 ]; then pass "$name — silent, as required"
    else fail "$name — FALSE POSITIVE: lint exited $rc on legal code"; fi
  fi
  i=$((i + 1))
done

echo
echo "── the lint names the offending file and line ──"
REPORT="$(bash "$LINT" "${FIX_PATH[1]}" 2>&1 1>/dev/null || true)"
case "$REPORT" in
  *real_prefix_validator.sh:*) pass "the report cites the offending file:line" ;;
  *) fail "the report does not cite file:line — got: $REPORT" ;;
esac
case "$REPORT" in
  *0x01*) pass "the report names the marker byte" ;;
  *) fail "the report does not name the marker byte" ;;
esac
case "$REPORT" in
  *'\x1f'*) pass "the report names the sanctioned replacement byte" ;;
  *) fail "the report does not name the replacement byte" ;;
esac

echo
echo "── the two repaired validators are clean, and --list resolves a file set ──"
if bash "$LINT" \
  "$ROOT/workflows/scripts/validate-check-surface-degenerate-coverage.sh" \
  "$ROOT/workflows/scripts/validate-exec-bit-registry.sh" >/dev/null 2>&1; then
  pass "both repaired validators pass the lint"
else
  fail "a repaired validator still trips the lint"
fi
if [ "$(bash "$LINT" --list 2>/dev/null | wc -l | tr -d ' ')" -gt 10 ]; then
  pass "--list resolves the tracked shell set"
else
  fail "--list resolved an implausibly small file set"
fi
# The lint must never flag ITSELF or this file, both of which carry the shape as
# data — self-exemption is by resolved path, so a vendored copy is covered too.
if bash "$LINT" >/dev/null 2>&1; then
  pass "the whole tracked set is clean (self-exemption holds)"
else
  fail "the lint is not clean over the tracked set"
fi

echo
echo "── T-GROUND: re-measure the lint's PREMISE on a real bash 3.2, if present ──"
B32=""
if [ -x /bin/bash ]; then
  case "$(/bin/bash --version 2>/dev/null | head -n 1)" in
    *"version 3."*) B32=/bin/bash ;;
  esac
fi
if [ -z "$B32" ]; then
  echo "  – skipped — no bash 3.x at /bin/bash on this host (bash 4+ splits every"
  echo "    byte correctly, so there is nothing to re-measure here); the recorded"
  echo "    fixture expectations above still gate."
else
  # 0x01 (CTLESC) and 0x7f (CTLNUL) must NOT split; 0x1f must.
  got01="$("$B32" -c 'printf "a\x01b\n" | { IFS=$'"'"'\x01'"'"' read -r a b; printf "%s" "$b"; }')"
  got7f="$("$B32" -c 'printf "a\x7fb\n" | { IFS=$'"'"'\x7f'"'"' read -r a b; printf "%s" "$b"; }')"
  got1f="$("$B32" -c 'printf "a\x1fb\n" | { IFS=$'"'"'\x1f'"'"' read -r a b; printf "%s" "$b"; }')"
  if [ -z "$got01" ]; then pass "ground truth: bash 3.2 does NOT split on 0x01 (the bug is real)"
  else fail "ground truth: bash 3.2 SPLIT on 0x01 — this lint's premise no longer holds"; fi
  if [ -z "$got7f" ]; then pass "ground truth: bash 3.2 does NOT split on 0x7f (CTLNUL is covered for the same reason)"
  else fail "ground truth: bash 3.2 SPLIT on 0x7f — narrow this lint to 0x01 only"; fi
  if [ "$got1f" = "b" ]; then pass "ground truth: bash 3.2 DOES split on 0x1f (the sanctioned replacement works)"
  else fail "ground truth: bash 3.2 did NOT split on 0x1f — the sanctioned replacement byte is wrong"; fi
fi

echo
if [ "$FAIL" -gt 0 ]; then
  echo "test_lint_bash32_ctlesc_ifs: FAILED $FAIL of $((PASS + FAIL))"
  exit 1
fi
echo "test_lint_bash32_ctlesc_ifs: OK — all $PASS checks passed"
