#!/usr/bin/env bash
# Regression tests for scripts/lint-pipe-grep-q.sh (temperloop#1050).
#
# The gate this backstops: `<writer> | grep -q <pat>`. `grep -q` exits ZERO at
# its FIRST match without draining the pipe, so the writer upstream takes
# SIGPIPE (status 141) and, under `set -o pipefail`, the whole pipeline reports
# 141 even though grep matched. It is a RACE — it fires only when the writer is
# still writing — so the same line passes for months and then fails once.
#
# WHY THESE TESTS EXIST AT ALL. A lint asserted to cover a class but never shown
# to FIRE on that class is not a lint; that is the temperloop#1098 lesson this
# suite inherits. So T1 is load-bearing: it feeds the lint the VERBATIM pre-sweep
# line from bin/subcommands/init.sh and requires a non-zero exit. T2 then fences
# the cluster space — `q` is not always first, and the tree carried `-q`, `-qv`,
# `-qx`, `-qE`, `-qF`, `-qiE`, `-qxF`, `-Eq`, `-Eqi`, `-Eiq` and `-Fxq` — because
# a naive `s/ -q / /` detector no-ops on every clustered site and looks green.
# T3 fences the false positives: an UNPIPED `grep -q file` is correct and must
# stay silent, and a `#` comment that merely NAMES the shape must stay silent
# too (firing on prose about the shape is the temperloop#1152 defect class this
# same epic fixes) — while a `#` inside a quoted grep PATTERN must NOT buy a
# real site an exemption.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LINT="$ROOT/scripts/lint-pipe-grep-q.sh"
PASS=0
FAIL=0

pass() { echo "  ✓ $1"; PASS=$((PASS + 1)); }
fail() { echo "  ✗ $1"; FAIL=$((FAIL + 1)); }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/lint-pipe-grep-q.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

# A single-quote character, kept out of the fixtures' own quoting by name.
Q="'"

FIXN=0
FIX_NAME=(); FIX_EXPECT=(); FIX_PATH=()
# fixture <name> <expect: fail|ok> <content>
fixture() {
  FIXN=$((FIXN + 1))
  FIX_NAME[FIXN]="$1"; FIX_EXPECT[FIXN]="$2"
  FIX_PATH[FIXN]="$WORK/$1.sh"
  printf '%s\n' "$3" > "$WORK/$1.sh"
}

# ── Must FIRE: the cluster space ────────────────────────────────────────────
fixture bare_q            fail "echo x | grep -q foo"
fixture q_first_iE        fail "echo x | grep -qiE ${Q}^foo${Q}"
fixture q_first_v         fail "echo x | grep -qv ${Q}foo${Q}"
fixture q_first_xF        fail "echo x | grep -qxF \"\$needle\""
fixture q_last_Fxq        fail "printf ${Q}%s\\n${Q} \"\$1\" | grep -Fxq \"\$2\""
fixture q_middle_Eqi      fail "echo x | grep -Eqi ${Q}^foo${Q}"
fixture q_last_Eiq        fail "echo x | grep -Eiq \"\$auth_re\""
fixture q_then_ddash      fail "echo x | grep -Eq -- \"\$pat\""
fixture fgrep_q           fail "echo x | fgrep -qx foo"
fixture egrep_q           fail "echo x | egrep -q ${Q}^foo${Q}"
fixture zgrep_q           fail "echo x | zgrep -q foo"
fixture no_space_pipe     fail "echo x|grep -q foo"
fixture command_grep_q    fail "echo x | command grep -q foo"
fixture inside_bash_c     fail "bash -c \"jq -r ${Q}.id${Q} f | grep -qx 1175\""
# The quote-aware comment strip must NOT hand this real site an exemption just
# because a `#` appears earlier inside a single-quoted grep pattern.
fixture hash_in_pattern   fail "grep -nE ${Q}^[0-9]+:[[:space:]]*#${Q} f | grep -q ."

# ── Must STAY SILENT ────────────────────────────────────────────────────────
# The sanctioned fix, at each cluster shape the sweep produced.
fixture fixed_redirect    ok   "printf ${Q}%s\\n${Q} \"\$1\" | grep -Fx \"\$2\" >/dev/null"
fixture fixed_bare        ok   "echo x | grep foo >/dev/null && echo hit"
fixture fixed_in_bash_c   ok   "bash -c \"jq -r ${Q}.id${Q} f | grep -x 1175 >/dev/null\""
# Unpiped grep -q reads a FILE: no writer to signal, early exit is a pure win.
fixture unpiped_grep_q    ok   "grep -q foo /etc/hosts && echo hit"
fixture unpiped_clustered ok   "if grep -Fxq \"\$n\" \"\$f\"; then echo hit; fi"
# Prose that merely NAMES the shape (temperloop#1152 class).
fixture whole_line_comment ok  "# Herestring, not \`echo \"\$out\" | grep -q\`: -q stops at the first match
echo ok"
fixture indented_comment  ok   "  # the earlier \`echo \"\$output\" | grep -q …\` pattern was a live race
echo ok"
fixture trailing_comment  ok   "echo ok   # avoid \`printf | grep -Fxq …\` here — see temperloop#1050"
# Piped greps with no q anywhere in the cluster.
fixture piped_no_q        ok   "echo x | grep -vE ${Q}^foo${Q}"
fixture piped_count       ok   "n=\$(echo x | grep -c foo)"
# `pgrep` is not grep; its trailing letters must not be misread as one.
fixture pgrep             ok   "echo x | pgrep -q foo"

run_lint() { bash "$LINT" "$1" >/dev/null 2>&1; }

# ---------------------------------------------------------------------------
# T1 (LOAD-BEARING) — the lint must FIRE on the real pre-sweep site.
# Verbatim from bin/subcommands/init.sh:1147 as it stood on origin/main@b1e3787,
# inside its real function so the fixture is genuinely the code that shipped.
# A lint that cannot reject THIS has not gated the class.
# ---------------------------------------------------------------------------
cat > "$WORK/prefix_init.sh" <<'PREFIX_EOF'
#!/usr/bin/env bash
set -euo pipefail
_init_line_present() {
  printf '%s\n' "$1" | grep -Fxq "$2"
}
PREFIX_EOF

echo "T1 — fires on the real pre-sweep bin/subcommands/init.sh site"
if run_lint "$WORK/prefix_init.sh"; then
  fail "lint exited 0 on the known-bad pre-sweep site (it must FAIL)"
else
  pass "lint rejects the pre-sweep \`printf … | grep -Fxq …\` site"
fi

# ---------------------------------------------------------------------------
# T2/T3 — every fixture, against its recorded expectation.
# ---------------------------------------------------------------------------
echo "T2/T3 — fixture expectations (fire on the cluster space, silent on prose)"
i=1
while [ "$i" -le "$FIXN" ]; do
  name="${FIX_NAME[i]}"; want="${FIX_EXPECT[i]}"; path="${FIX_PATH[i]}"
  if run_lint "$path"; then got=ok; else got=fail; fi
  if [ "$got" = "$want" ]; then
    pass "$name (expected $want)"
  else
    fail "$name: expected $want, got $got"
    sed 's/^/      | /' "$path"
  fi
  i=$((i + 1))
done

# ---------------------------------------------------------------------------
# T4 — the default file set has neither of the two blind spots temperloop#1050
# names. There is deliberately NO pipefail predicate, so a sourced lib that sets
# no `set` line (issue-marker-probe.sh — a live site, visible only WITHOUT such a
# predicate) is covered; and the set is not `*.sh`-only, so the extensionless
# entry points that DO set pipefail are covered too.
# ---------------------------------------------------------------------------
echo "T4 — default file set covers extensionless scripts and pipefail-less libs"
listing="$(bash "$LINT" --list 2>/dev/null)"
for want in \
  bin/temperloop \
  bin/foundation \
  .temperloop/report.d/tokens \
  workflows/scripts/report-producers/tokens \
  workflows/scripts/lib/issue-marker-probe.sh
do
  if printf '%s\n' "$listing" | grep -Fx "$want" >/dev/null; then
    pass "file set includes $want"
  else
    fail "file set MISSING $want"
  fi
done

# ---------------------------------------------------------------------------
# T5 — self-exemption. The lint and this test necessarily carry the shape as
# data; neither may appear in the file set, and passing either explicitly must
# still exit 0.
# ---------------------------------------------------------------------------
echo "T5 — self-exemption (the lint and its test carry the shape as data)"
for self in scripts/lint-pipe-grep-q.sh scripts/tests/test_lint_pipe_grep_q.sh; do
  if printf '%s\n' "$listing" | grep -Fx "$self" >/dev/null; then
    fail "$self must be self-exempt but appears in the file set"
  else
    pass "$self is self-exempt from the default file set"
  fi
  if run_lint "$ROOT/$self"; then
    pass "$self passes when linted explicitly"
  else
    fail "$self fired on itself when linted explicitly"
  fi
done

# ---------------------------------------------------------------------------
# T6 — the tree-wide predicate. This is the completeness criterion for the
# temperloop#1050 sweep: not a site COUNT (which goes stale the moment anyone
# adds a script), but the lint exiting 0 over the whole tracked shell set.
# ---------------------------------------------------------------------------
echo "T6 — tree-wide predicate: the lint is clean over the tracked shell set"
if bash "$LINT" >/dev/null 2>&1; then
  pass "lint exits 0 over the whole tracked tree"
else
  fail "lint found a piped grep -q in the tree:"
  bash "$LINT" 2>&1 | sed 's/^/      | /'
fi

echo
echo "test_lint_pipe_grep_q: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
