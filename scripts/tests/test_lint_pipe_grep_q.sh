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
#
# T3 was widened by temperloop#1420 to the PRINTED-TEXT half of the same #1152
# class: the shape inside an `echo`/`printf` help string, or inside a `cat
# <<EOF` usage block, is emitted rather than executed and must stay silent —
# that false positive fired on the linter's OWN usage text and blocked the
# v0.29.0 vendor. The exemption is by PARSE POSITION, so the fixtures fence both
# sides of it: a string handed to a SHELL (`bash -c`, `eval`, `ssh`, a `bash
# <<EOF` heredoc) is still code and must still FIRE, and T8 asserts the
# discrimination directly — the same byte-identical text, code line named,
# string line not.
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
# A literal tab, for the `<<-` heredoc fixture whose terminator must be
# tab-indented (and which an editor's trailing-whitespace strip would eat).
TAB="$(printf '\t')"

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
# temperloop#1420: the printed-text exemption is by PARSE POSITION, so a string
# handed to a SHELL is still code and must still fire — at every executor shape.
fixture in_eval_string    fail "eval \"jq -r ${Q}.id${Q} f | grep -qx 1175\""
fixture in_ssh_string     fail "ssh host \"tail -n 100 log | grep -q ready\""
fixture in_sh_c_string    fail "find . -exec /bin/sh -c \"cat {} | grep -q x\" \\;"
fixture heredoc_to_shell  fail "bash <<${Q}EOF${Q}
echo x | grep -q foo
EOF
echo done"
# A `<<<` herestring is NOT a heredoc: misreading one would swallow the rest of
# the file and silently un-scan the real site below it.
fixture after_herestring  fail "grep -q foo <<< \"\$v\"
echo x | grep -q bar"
# Nor is an arithmetic left-shift, even with a SHOUT_CASE right operand.
fixture after_shift       fail "n=\$(( a << B ))
echo x | grep -q bar"
# The quote strip is CONTENT-only: the delimiters survive, so a pipeline that
# merely passes THROUGH a quoted argument still reads as a pipeline.
fixture pipe_after_string fail "echo \"hello world\" | grep -q hello"

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
# ── temperloop#1420: PRINTED TEXT that merely SHOWS the shape ───────────────
# (1) The verbatim overlay site from the issue — an echoed probe instruction.
fixture echoed_help       ok   "echo \"      curl -s  http://127.0.0.1:9080/ | grep -q ${Q}Directory listing${Q} && echo ROOT-BROKEN || echo root-ok\""
# (2) The linter's OWN usage text, the line that blocked the v0.29.0 vendor.
fixture printf_own_help   ok   "echo \"     <writer> | grep -Fxq \\\"\\\$needle\\\"\" >&2"
# (3) A message handed to a non-shell command (a logging/abort helper).
fixture die_message       ok   "die \"usage: <writer> | grep -q <pat> is banned — see temperloop#1050\""
# (4) The same text merely stored in a variable.
fixture assigned_help     ok   "msg=\"see: printf x | grep -qx y\""
# (5) A heredoc usage block, in all three delimiter forms. The body is printed,
#     never executed, so it carries no pipeline and no writer to signal.
fixture heredoc_quoted    ok   "cat <<${Q}USAGE${Q}
  probe:  curl -s http://x/ | grep -q ready && echo up
USAGE
echo done"
fixture heredoc_bare      ok   "cat <<USAGE
  probe:  curl -s http://x/ | grep -q ready && echo up
USAGE
echo done"
fixture heredoc_dash      ok   "cat <<-USAGE
${TAB}probe:  curl -s http://x/ | grep -q ready && echo up
${TAB}USAGE
echo done"

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
# _composed_overlay_reason <root> — self-scoping detection (temperloop#1505),
# same two signals as workflows/scripts/validate-onramp-anchors.sh's own
# inline copy (itself matching workflows/scripts/tests/lib/sandbox.sh's
# sandbox_skip_if_composed_tree, temperloop#267/#488/#1490) — reimplemented
# inline as a predicate rather than sourced, because sandbox.sh's version
# `exit 0`s the WHOLE calling suite and T4 needs to self-scope only ITS OWN
# five-path coverage assertion, leaving T1/T2/T3/T5/T6 (which reference no
# checkout-shape-dependent path) running for real on any checkout shape.
# Prints a reason and returns 0 iff <root> is a composed overlay; prints
# nothing and returns 1 on a kernel-native checkout.
# ---------------------------------------------------------------------------
_composed_overlay_reason() {
  local root="$1"
  if [ -f "$root/claude/CLAUDE.kernel.md" ] && [ -f "$root/claude/CLAUDE.overlay.md" ]; then
    printf '%s\n' "claude/CLAUDE.overlay.md is present beside claude/CLAUDE.kernel.md under $root/claude"
    return 0
  fi
  if [ -d "$root/kernel" ] && { [ -f "$root/kernel/bin/temperloop" ] || [ -f "$root/kernel/claude/CLAUDE.kernel.md" ]; }; then
    printf '%s\n' "a kernel/ subtree is vendored at the repo root ($root/kernel)"
    return 0
  fi
  return 1
}

# ---------------------------------------------------------------------------
# T4 — the default file set has neither of the two blind spots temperloop#1050
# names. There is deliberately NO pipefail predicate, so a sourced lib that sets
# no `set` line (issue-marker-probe.sh — a live site, visible only WITHOUT such a
# predicate) is covered; and the set is not `*.sh`-only, so the extensionless
# entry points that DO set pipefail are covered too.
#
# SELF-SCOPED (temperloop#1505): the five paths below are asserted by exact
# git-tracked granularity. On a composed overlay whose top-level dirs (bin,
# .temperloop, workflows, ...) are DIRECTORY symlinks into a vendored
# kernel/ subtree, `git ls-files` tracks each such dir as ONE symlink entry
# and can never enumerate a path underneath it — bin/temperloop is simply
# not a tracked path at that root, regardless of the file existing on disk.
# That is a structural property of git, not a lint defect (see T4-overlay
# below, which proves both that this predicate correctly detects the shape
# and that the underlying symptom reproduces on a synthetic fixture). A
# kernel-native checkout (this worktree) is unaffected and must still run
# these five checks for real and strictly.
# ---------------------------------------------------------------------------
echo "T4 — default file set covers extensionless scripts and pipefail-less libs"
listing="$(bash "$LINT" --list 2>/dev/null)"
if overlay_reason="$(_composed_overlay_reason "$ROOT")"; then
  echo "  SKIP: T4 coverage checks — composed overlay tree detected ($overlay_reason)."
  echo "    git tracks bin/.temperloop/workflows (etc.) as directory symlinks into"
  echo "    kernel/ here, so git ls-files cannot enumerate bin/temperloop and its"
  echo "    siblings as individually tracked paths at this root — T4 asserts"
  echo "    kernel-native path granularity a symlink-vendored consumer structurally"
  echo "    cannot have (temperloop#1505). Exiting this check 0 (legible skip, not"
  echo "    a failure); T1/T2/T3/T5/T6 are unaffected and still run for real."
else
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
fi

# ---------------------------------------------------------------------------
# T4-overlay — proves the self-scoping above on a SYNTHETIC composed-overlay
# fixture (temperloop#1505), reproducing the exact shape: a vendored kernel/
# subtree plus directory symlinks at the overlay root (bin -> kernel/bin,
# .temperloop -> kernel/.temperloop, workflows -> kernel/workflows, scripts
# -> kernel/scripts — the entry-point symlink T7 above already uses this
# same idiom for). Never reads the operator's real ~/dev/foundation.
#
# Proves three things:
#   (a) the fixture genuinely reproduces the symptom — all five paths are
#       unreachable via `git ls-files` through the fixture's own directory
#       symlinks, exactly like the temperloop#1505 report;
#   (b) _composed_overlay_reason correctly FLAGS the synthetic overlay root;
#   (c) _composed_overlay_reason correctly leaves THIS kernel-native
#       checkout ($ROOT) unflagged — the skip branch above never fires here.
# ---------------------------------------------------------------------------
echo "T4-overlay — composed-overlay detection reproduces + self-scopes the temperloop#1505 symptom"
SYNTH="$(mktemp -d "${TMPDIR:-/tmp}/lint-t4-overlay.XXXXXX")"
(
  set -e
  mkdir -p "$SYNTH/kernel/bin" "$SYNTH/kernel/.temperloop/report.d" \
           "$SYNTH/kernel/workflows/scripts/report-producers" \
           "$SYNTH/kernel/workflows/scripts/lib" "$SYNTH/kernel/scripts"
  cp "$LINT" "$SYNTH/kernel/scripts/lint-pipe-grep-q.sh"
  printf '#!/usr/bin/env bash\necho ok\n' > "$SYNTH/kernel/bin/temperloop"
  printf '#!/usr/bin/env bash\necho ok\n' > "$SYNTH/kernel/bin/foundation"
  printf '#!/usr/bin/env bash\necho ok\n' > "$SYNTH/kernel/.temperloop/report.d/tokens"
  printf '#!/usr/bin/env bash\necho ok\n' > "$SYNTH/kernel/workflows/scripts/report-producers/tokens"
  printf '#!/usr/bin/env bash\necho ok\n' > "$SYNTH/kernel/workflows/scripts/lib/issue-marker-probe.sh"
  chmod +x "$SYNTH/kernel/bin/temperloop" "$SYNTH/kernel/bin/foundation" \
           "$SYNTH/kernel/.temperloop/report.d/tokens" \
           "$SYNTH/kernel/workflows/scripts/report-producers/tokens"
  ln -s kernel/bin "$SYNTH/bin"
  ln -s kernel/.temperloop "$SYNTH/.temperloop"
  ln -s kernel/workflows "$SYNTH/workflows"
  ln -s kernel/scripts "$SYNTH/scripts"
  git -C "$SYNTH" init -q
  git -C "$SYNTH" add -A
  git -c user.name=test -c user.email=test@test -C "$SYNTH" commit -q -m synth
)

synth_listing="$(cd "$SYNTH" && bash scripts/lint-pipe-grep-q.sh --list 2>/dev/null)"
synth_missing=0
for want in \
  bin/temperloop \
  bin/foundation \
  .temperloop/report.d/tokens \
  workflows/scripts/report-producers/tokens \
  workflows/scripts/lib/issue-marker-probe.sh
do
  printf '%s\n' "$synth_listing" | grep -Fx "$want" >/dev/null || synth_missing=$((synth_missing + 1))
done
if [ "$synth_missing" -eq 5 ]; then
  pass "T4-overlay: synthetic fixture reproduces the symptom (all 5 paths unreachable via git ls-files through the dir symlinks)"
else
  fail "T4-overlay: synthetic fixture did not reproduce the symptom ($synth_missing/5 paths missing; expected 5) — fixture shape may not match the real overlay layout"
fi

if synth_reason="$(_composed_overlay_reason "$SYNTH")"; then
  pass "T4-overlay: detection correctly flags the synthetic composed-overlay fixture ($synth_reason)"
else
  fail "T4-overlay: detection did NOT flag the synthetic fixture — T4 would fail there instead of emitting a named skip"
fi

# The NEGATIVE control must be a fixture, not $ROOT. An earlier revision
# asserted "$ROOT is not a composed overlay" — true in this repo, FALSE in
# every vendoring consumer, so the suite failed for a consumer whose tree the
# detection had correctly flagged. That is the very class temperloop#1505
# fixed, reintroduced one check below the fix. So: build a synthetic
# KERNEL-NATIVE tree (real dirs, no kernel/ subtree, no overlay marker) and
# assert detection leaves IT unflagged. Both directions are then proven by
# fixtures and the result no longer depends on where the suite is run from.
SYNTH_NATIVE="$(mktemp -d "${TMPDIR:-/tmp}/lint-t4-native.XXXXXX")"
(
  set -e
  mkdir -p "$SYNTH_NATIVE/bin" "$SYNTH_NATIVE/claude" "$SYNTH_NATIVE/scripts"
  printf '#!/usr/bin/env bash\necho ok\n' > "$SYNTH_NATIVE/bin/temperloop"
  chmod +x "$SYNTH_NATIVE/bin/temperloop"
  : > "$SYNTH_NATIVE/claude/CLAUDE.kernel.md"
  git -C "$SYNTH_NATIVE" init -q
  git -C "$SYNTH_NATIVE" add -A
  git -c user.name=test -c user.email=test@test -C "$SYNTH_NATIVE" commit -q -m synth-native
)
if native_reason="$(_composed_overlay_reason "$SYNTH_NATIVE")"; then
  fail "T4-overlay: detection wrongly flagged a synthetic KERNEL-NATIVE tree ($native_reason) — T4's real coverage checks would skip where they must run"
else
  pass "T4-overlay: detection correctly leaves a synthetic kernel-native tree unflagged — T4 still runs for real where it belongs"
fi

# Report which arm THIS checkout is, for legibility. Both are correct; this is
# an observation, never an assertion, precisely so the suite passes identically
# on the kernel repo and on a vendoring consumer.
if this_reason="$(_composed_overlay_reason "$ROOT")"; then
  echo "  note: this checkout is a composed overlay ($this_reason) — T4 above emitted its named skip, as designed"
else
  echo "  note: this checkout is kernel-native — T4 above ran its coverage checks for real"
fi

rm -rf "$SYNTH" "$SYNTH_NATIVE"

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

# ---------------------------------------------------------------------------
# T7 — vendored-overlay self-exemption (temperloop#1490). REPRODUCES the
# exact shape a consuming overlay repo vendors this kernel through:
#   <synth>/kernel/scripts/lint-pipe-grep-q.sh          (real vendored file)
#   <synth>/kernel/scripts/tests/test_lint_pipe_grep_q.sh (real vendored file)
#   <synth>/scripts/lint-pipe-grep-q.sh -> ../kernel/scripts/lint-pipe-grep-q.sh
#   <synth>/scripts/tests -> ../kernel/scripts/tests        (whole-dir symlink,
#     the same shape as foundation's real `scripts/tests -> ../kernel/
#     scripts/tests`)
# git-tracked so `git ls-files` (the lint's own file-set source) lists BOTH
# the compat-symlink entry point AND the two vendored originals under
# kernel/ — the exact condition that produced 42 false positives before this
# fix (REPO_ROOT resolves to the overlay root through the entry-point
# symlink, so a literal-string SELF/SELF_TEST comparison never matched the
# kernel/-prefixed paths git also lists for the very same physical files).
#
# Proves TWO things, not one: (a) the two vendored originals stay silent —
# self-exemption survived the overlay reflection; (b) a THIRD file dropped
# in the same vendored kernel/ tree, that is NOT one of the two exempt
# files, still gets flagged — the fix narrows the match to exactly two
# resolved paths, never widens it to the whole kernel/ prefix.
# ---------------------------------------------------------------------------
echo "T7 — vendored-overlay self-exemption (only the two named files, not the whole kernel/ prefix)"
SYNTH="$(mktemp -d "${TMPDIR:-/tmp}/lint-pipe-grep-q-overlay.XXXXXX")"
(
  set -e
  mkdir -p "$SYNTH/kernel/scripts/tests" "$SYNTH/scripts"
  cp "$LINT" "$SYNTH/kernel/scripts/lint-pipe-grep-q.sh"
  cp "$ROOT/scripts/tests/test_lint_pipe_grep_q.sh" "$SYNTH/kernel/scripts/tests/test_lint_pipe_grep_q.sh"
  # A genuine violation living INSIDE the vendored kernel/ tree, deliberately
  # NOT one of the two exempt files — this must still be flagged.
  printf '#!/usr/bin/env bash\necho x | grep -q needle\n' \
    > "$SYNTH/kernel/scripts/tests/test_something_else.sh"
  ln -s ../kernel/scripts/lint-pipe-grep-q.sh "$SYNTH/scripts/lint-pipe-grep-q.sh"
  ln -s ../kernel/scripts/tests "$SYNTH/scripts/tests"
  git -C "$SYNTH" init -q
  git -C "$SYNTH" add -A
  git -c user.name=test -c user.email=test@test -C "$SYNTH" commit -q -m synth
)

if (cd "$SYNTH" && bash scripts/lint-pipe-grep-q.sh); then
  fail "T7: expected the lint to FAIL (a genuine violation sits in kernel/scripts/tests/test_something_else.sh), got a clean exit"
else
  out="$(cd "$SYNTH" && bash scripts/lint-pipe-grep-q.sh 2>&1 || true)"
  if printf '%s\n' "$out" | grep -F 'test_something_else.sh' >/dev/null; then
    pass "T7: still flags a genuine violation inside the vendored kernel/ tree"
  else
    fail "T7: did not name kernel/scripts/tests/test_something_else.sh in its report:"
    printf '%s\n' "$out" | sed 's/^/      | /'
  fi
  if printf '%s\n' "$out" | grep -F 'lint-pipe-grep-q.sh:' >/dev/null \
     || printf '%s\n' "$out" | grep -F 'test_lint_pipe_grep_q.sh:' >/dev/null; then
    fail "T7: the two self-exempt files were flagged (self-exemption did not survive the overlay reflection):"
    printf '%s\n' "$out" | sed 's/^/      | /'
  else
    pass "T7: neither self-exempt file (compat-symlink entry point or vendored kernel/ original) was flagged"
  fi
fi

# Neutralize the one genuine violation and re-run: with NO real violation
# left, the lint must now exit 0 clean — proving the two vendored originals
# really are exempt (not merely under-scanned alongside a masking failure).
rm -f "$SYNTH/kernel/scripts/tests/test_something_else.sh"
if (cd "$SYNTH" && bash scripts/lint-pipe-grep-q.sh >/dev/null 2>&1); then
  pass "T7: clean overlay tree (violation removed) exits 0 — the two vendored originals are genuinely exempt, not just outrun by a masking failure"
else
  fail "T7: overlay tree still fails after removing the one genuine violation:"
  (cd "$SYNTH" && bash scripts/lint-pipe-grep-q.sh) 2>&1 | sed 's/^/      | /'
fi

rm -rf "$SYNTH"

# ---------------------------------------------------------------------------
# T8 — DISCRIMINATION (temperloop#1420). The fixtures above prove each side
# separately, which a lint that had simply gone blind would also satisfy. This
# proves the two sides apart on ONE file whose text is byte-identical in both
# positions: the same `printf x | grep -qx y` appears once inside a printed
# help string, once inside a `cat <<EOF` usage block, and once as an executed
# pipeline. The lint must FAIL, and its report must name the executable line
# and ONLY it — a line-number assertion, not just an exit code.
# ---------------------------------------------------------------------------
echo "T8 — discrimination: identical text, code line named, printed/heredoc lines not"
cat > "$WORK/discriminate.sh" <<'DISC_EOF'
#!/usr/bin/env bash
usage() {
  echo "  probe:  printf x | grep -qx y"
  cat <<'USAGE'
  probe:  printf x | grep -qx y
USAGE
}
printf x | grep -qx y
DISC_EOF

disc_out="$(bash "$LINT" "$WORK/discriminate.sh" 2>&1)"
if bash "$LINT" "$WORK/discriminate.sh" >/dev/null 2>&1; then
  fail "T8: the executed \`printf x | grep -qx y\` on line 8 was not flagged at all (the lint has gone blind, not selective)"
else
  pass "T8: still FAILS on the file (the executed pipeline is caught)"
fi
if printf '%s\n' "$disc_out" | grep -F 'discriminate.sh:8:' >/dev/null; then
  pass "T8: names line 8 — the executed pipeline"
else
  fail "T8: did NOT name line 8 (the executed pipeline):"
  printf '%s\n' "$disc_out" | sed 's/^/      | /'
fi
for textline in 3 5; do
  if printf '%s\n' "$disc_out" | grep -F "discriminate.sh:$textline:" >/dev/null; then
    fail "T8: wrongly named line $textline — that occurrence is printed text, not code:"
    printf '%s\n' "$disc_out" | sed 's/^/      | /'
  else
    pass "T8: does not name line $textline (printed text stays silent)"
  fi
done

# ---------------------------------------------------------------------------
# T9 — the temperloop#1420 report reproduced on a COMPOSED/VENDORING OVERLAY
# layout, which is where it actually fired and where it blocked the v0.29.0
# vendor. Same synthetic overlay shape T7 builds (vendored kernel/ subtree +
# compat symlinks), plus an OVERLAY-OWNED script carrying the issue's second
# instance verbatim: an `echo` of a probe instruction that names the shape.
# That file is not self-exempt and no filename allowlist can reach it, so it is
# the honest test of the parse-position rule. Then a genuinely EXECUTED
# `curl … | grep -q …` is added to the same overlay tree and must fire — the
# discrimination, asserted where the defect lived.
# ---------------------------------------------------------------------------
echo "T9 — composed/vendoring overlay: printed help clean, executed pipeline flagged"
SYNTH="$(mktemp -d "${TMPDIR:-/tmp}/lint-pipe-grep-q-vendor.XXXXXX")"
(
  set -e
  mkdir -p "$SYNTH/kernel/scripts/tests" "$SYNTH/scripts" "$SYNTH/infra/launchd"
  cp "$LINT" "$SYNTH/kernel/scripts/lint-pipe-grep-q.sh"
  cp "$ROOT/scripts/tests/test_lint_pipe_grep_q.sh" "$SYNTH/kernel/scripts/tests/test_lint_pipe_grep_q.sh"
  ln -s ../kernel/scripts/lint-pipe-grep-q.sh "$SYNTH/scripts/lint-pipe-grep-q.sh"
  ln -s ../kernel/scripts/tests "$SYNTH/scripts/tests"
  # temperloop#1420's second instance, verbatim: overlay code that merely
  # PRINTS an instruction naming the shape.
  {
    printf '#!/usr/bin/env bash\n'
    printf 'echo "      curl -s  http://127.0.0.1:9080/ | grep -q %sDirectory listing%s && echo ROOT-BROKEN || echo root-ok"\n' "$Q" "$Q"
  } > "$SYNTH/infra/launchd/install-dashboard-serve.sh"
  git -C "$SYNTH" init -q
  git -C "$SYNTH" add -A
  git -c user.name=test -c user.email=test@test -C "$SYNTH" commit -q -m synth
)

if (cd "$SYNTH" && bash scripts/lint-pipe-grep-q.sh >/dev/null 2>&1); then
  pass "T9: overlay tree lints CLEAN — neither the vendored kernel/ help text nor the overlay's echoed instruction is flagged"
else
  fail "T9: overlay tree still fails on printed help text (the v0.29.0 vendor blocker):"
  (cd "$SYNTH" && bash scripts/lint-pipe-grep-q.sh) 2>&1 | sed 's/^/      | /'
fi

# The other half: a genuinely EXECUTED pipeline in the same overlay tree — the
# third hit of the real v0.29.0 run, which was correct and must stay correct.
printf '#!/usr/bin/env bash\ncurl -s http://127.0.0.1:9080/ | grep -q ready && echo up\n' \
  > "$SYNTH/infra/launchd/serve-dashboard.sh"
git -C "$SYNTH" add -A
git -c user.name=test -c user.email=test@test -C "$SYNTH" commit -q -m synth-exec
vendor_out="$(cd "$SYNTH" && bash scripts/lint-pipe-grep-q.sh 2>&1 || true)"
if printf '%s\n' "$vendor_out" | grep -F 'infra/launchd/serve-dashboard.sh:2:' >/dev/null; then
  pass "T9: the executed \`curl … | grep -q …\` in the overlay tree IS flagged"
else
  fail "T9: the executed overlay pipeline was not flagged — the gate has gone blind on a vendored tree:"
  printf '%s\n' "$vendor_out" | sed 's/^/      | /'
fi
if printf '%s\n' "$vendor_out" | grep -F 'install-dashboard-serve.sh' >/dev/null; then
  fail "T9: the echoed instruction was flagged alongside the real site:"
  printf '%s\n' "$vendor_out" | sed 's/^/      | /'
else
  pass "T9: and the echoed instruction beside it stays silent"
fi

rm -rf "$SYNTH"

echo
echo "test_lint_pipe_grep_q: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
