#!/usr/bin/env bash
# Regression tests for scripts/lint-bash32-cmdsubst-comment.sh (temperloop#1098).
#
# The gate this backstops: an apostrophe inside a `#` comment (or a here-doc body)
# within a `$( … )` command substitution is invisible to bash 5 but makes bash 3.2
# — every macOS /bin/bash — swallow the closing paren, rendering the whole file
# unparseable. workflows/scripts/install/doctor.sh shipped exactly that break to
# `main` and stayed green through shellcheck AND the ubuntu-only pre-merge CI.
#
# WHY THESE TESTS EXIST AT ALL. The failure temperloop#1098 is really about is not
# the typo — it is a lint ASSERTED to cover a class without ever being shown to
# fire on it. So T1 is the load-bearing test: it feeds the lint the REAL pre-fix
# doctor.sh region and requires a non-zero exit. The rest fence in the false
# positives a naive implementation would produce.
#
# EVERY fixture below carries its own recorded bash-3.2 ground truth (BREAKS /
# PARSES), measured with `/bin/bash -n` on bash 3.2.57. Where a bash 3.2 is
# actually available at /bin/bash, T9 re-measures every fixture and asserts the
# lint verdict MATCHES that ground truth, so these comments cannot silently rot.
# On bash 4+ hosts (ubuntu CI) T9 skips and the recorded expectations still gate.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LINT="$ROOT/scripts/lint-bash32-cmdsubst-comment.sh"
PASS=0
FAIL=0

pass() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/lint-bash32.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# A single-quote character, kept out of the here-docs below (which are quoted, so
# nothing expands inside them) by writing the fixtures with printf instead.
Q="'"

# fixture <name> <expect: fail|ok> <bash32: BREAKS|PARSES> <content>
FIXN=0
fixture() {
  FIXN=$((FIXN + 1))
  FIX_NAME[FIXN]="$1"; FIX_EXPECT[FIXN]="$2"; FIX_B32[FIXN]="$3"
  FIX_PATH[FIXN]="$WORK/$1.sh"
  printf '%s\n' "$4" > "$WORK/$1.sh"
}
FIX_NAME=(); FIX_EXPECT=(); FIX_B32=(); FIX_PATH=()

# ── Must FIRE ───────────────────────────────────────────────────────────────
fixture comment_in_cmdsubst fail BREAKS "x=\"\$(
  # it${Q}s a comment
  echo hi
)\""

fixture trailing_comment fail BREAKS "x=\"\$(
  echo hi  # it${Q}s trailing
)\""

fixture nested_cmdsubst_closed_first fail BREAKS "x=\"\$(
  y=\$(echo a)
  # it${Q}s a comment
  echo \"\$y\"
)\""

fixture heredoc_odd_apostrophes fail BREAKS "x=\"\$(
  cat <<EOF
don${Q}t
EOF
)\""

# ── Must STAY SILENT ────────────────────────────────────────────────────────
fixture toplevel_comment ok PARSES "x=\"\$( echo hi )\"
# it${Q}s a top-level comment, entirely safe"

fixture plain_subshell ok PARSES "(
  # it${Q}s a plain subshell, not a substitution
  echo hi
)"

fixture backticks ok PARSES "x=\`
  # it${Q}s a backtick substitution — bash 3.2 lexes these correctly
  echo hi
\`"

fixture hash_inside_string ok PARSES "x=\"\$(
  echo \"# it${Q}s inside a string, not a comment\"
)\""

fixture even_parity_heredoc ok PARSES "x=\"\$(
  cat <<EOF
the operator${Q}s machine, and the operator${Q}s identity
EOF
)\""

fixture param_expansion_hash ok PARSES "arr=(a b)
x=\"\$(
  echo \"\${#arr[@]} \$# a#b\"
)\""

fixture case_pattern ok PARSES "case x in
  # it${Q}s a comment beside a case pattern
  x) echo hi ;;
esac"

run_lint() { bash "$LINT" "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# T1 (LOAD-BEARING) — the lint must FIRE on the real pre-fix doctor.sh region.
# This is a verbatim copy of the comment block commit 16f6f91 shipped, the one
# that made doctor.sh unparseable on every macOS. A lint that cannot reject THIS
# has not gated the class no matter what its other tests say.
# ---------------------------------------------------------------------------
cat > "$WORK/prefix_doctor.sh" <<'PREFIX_EOF'
#!/usr/bin/env bash
_cross_checkout_kernel_pin_tag() {
  local checkout="$1"
  local env_reconcile="${SCRIPT_DIR}/../build/env-reconcile.sh"
  local tag

  tag="$(
    # env-reconcile.sh's own arg-parse loop reads "$@" — and since this
    # function was itself CALLED with an argument (checkout), that argument
    # is still $1 here, not empty. Left un-cleared, `source` inherits it as
    # env-reconcile.sh's own positional params, its arg-parse loop treats
    # the checkout path as an unrecognized flag, and it `exit 2`s before
    # kernel_pin_tag_of is ever defined (silently — the caller only sees an
    # empty, rc!=0 command substitution). Scoped to THIS subshell only, so
    # the enclosing function's own "$@"/"$1" is untouched.
    set --
    # shellcheck source=/dev/null
    source "$env_reconcile" 2>/dev/null
    kernel_pin_tag_of "$checkout" 2>/dev/null
  )" || tag=""

  printf '%s\n' "$tag"
}
PREFIX_EOF

if run_lint "$WORK/prefix_doctor.sh"; then
  fail "T1: lint exited 0 on the REAL pre-fix doctor.sh region — the gate does not fire on the known-bad input"
else
  pass "T1: lint fires (non-zero) on the real pre-fix doctor.sh region"
fi

# The same region with the apostrophes reworded — the shipped fix — must pass.
sed "s/env-reconcile.sh's own/the env-reconcile.sh/g; s/function's own/function keeps its own/g" \
  "$WORK/prefix_doctor.sh" > "$WORK/fixed_doctor.sh"
if run_lint "$WORK/fixed_doctor.sh"; then
  pass "T2: lint exits 0 once the same region is reworded (the shipped fix)"
else
  fail "T2: lint still fires after the apostrophes were reworded — false positive on the fix"
fi

# ---------------------------------------------------------------------------
# T3..T13 — one assertion per fixture, positive and negative.
# ---------------------------------------------------------------------------
i=1
while [ "$i" -le "$FIXN" ]; do
  name="${FIX_NAME[i]}"; expect="${FIX_EXPECT[i]}"; path="${FIX_PATH[i]}"
  if run_lint "$path"; then got=ok; else got=fail; fi
  if [ "$got" = "$expect" ]; then
    if [ "$expect" = "fail" ]; then pass "fixture '$name': lint fires, as required"
    else pass "fixture '$name': lint stays silent, as required"; fi
  else
    if [ "$expect" = "fail" ]; then fail "fixture '$name': MISSED — lint exited 0 on a construct that breaks bash 3.2"
    else fail "fixture '$name': FALSE POSITIVE — lint fired on a construct bash 3.2 accepts"; fi
  fi
  i=$((i + 1))
done

# ---------------------------------------------------------------------------
# T-last — ground-truth cross-check. Where /bin/bash really is bash 3.x, assert
# every fixture's recorded BREAKS/PARSES expectation against the real parser, so
# the table above cannot drift away from what bash 3.2 actually does. bash 4+
# hosts (ubuntu CI) skip — bash 4.0 fixed the bug, so there is nothing to measure.
# ---------------------------------------------------------------------------
b32=""
if [ -x /bin/bash ]; then
  case "$(/bin/bash -c 'echo "${BASH_VERSINFO[0]}"' 2>/dev/null)" in
    1|2|3) b32=/bin/bash ;;
  esac
fi

if [ -z "$b32" ]; then
  echo "  SKIP: no bash 3.x at /bin/bash (this host runs bash 4+) — recorded"
  echo "        BREAKS/PARSES expectations still gated the assertions above."
else
  i=1
  while [ "$i" -le "$FIXN" ]; do
    name="${FIX_NAME[i]}"; want="${FIX_B32[i]}"; path="${FIX_PATH[i]}"
    if "$b32" -n "$path" 2>/dev/null; then real=PARSES; else real=BREAKS; fi
    if [ "$real" = "$want" ]; then
      pass "ground truth '$name': bash 3.2 really does $real"
    else
      fail "ground truth '$name': recorded $want but bash 3.2 actually $real — the fixture table has drifted"
    fi
    i=$((i + 1))
  done
  if "$b32" -n "$WORK/prefix_doctor.sh" 2>/dev/null; then
    fail "ground truth: bash 3.2 accepted the pre-fix doctor.sh region — fixture no longer reproduces #1098"
  else
    pass "ground truth: bash 3.2 rejects the pre-fix doctor.sh region (reproduces #1098)"
  fi
  if "$b32" -n "$WORK/fixed_doctor.sh" 2>/dev/null; then
    pass "ground truth: bash 3.2 accepts the reworded region (the fix really fixes it)"
  else
    fail "ground truth: bash 3.2 still rejects the reworded region"
  fi
fi

echo "  ---"
echo "  PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
