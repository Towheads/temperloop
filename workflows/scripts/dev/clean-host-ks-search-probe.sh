#!/usr/bin/env bash
#
# clean-host-ks-search-probe.sh — the IN-CONTAINER half of the clean-host
# ks_search validation (temperloop#1635).
#
# This script never runs on a developer's machine. Its driver,
# workflows/scripts/dev/validate-clean-host-ks-search.sh, copies it plus
# workflows/scripts/lib/ into a throwaway Linux container that has `uv` on
# PATH and nothing else, and runs it there. Read that driver's usage header
# first — it owns the why, the opt-in posture, and the Docker preflight.
#
# WHAT IT PROVES. temperloop#1113 moved the knowledge_search backend from a
# per-run `uvx` resolution to an installed uv tool, and kept the zero-setup
# first run alive through the availability gate's lazy install. Every test of
# that switch stubs `uv` — deliberately, because kernel principle 3 forbids a
# live-network install inside the gated suite. So the real stranger path
# (clean host, only uv, no `doctor` run, first ks_search) had never been
# executed. This script executes it and asserts the issue's three acceptance
# checks:
#
#   1. a first ks_search on a clean host RETURNS RESULTS;
#   2. the install lands ENTIRELY under the adapter's pinned bm home —
#      nothing in ~/.local/share, ~/.local/bin, or a shared uv cache;
#   3. a second ks_search performs NO further install.
#
# HOW EACH ONE IS MADE FALSIFIABLE, since "it worked" is the easiest verdict
# to fake:
#   * The corpus is a real (tiny) fixture of three notes with disjoint
#     subjects, and the query names one of them. "Returns results" therefore
#     means "returned the RIGHT note", not "returned a non-empty stream" — an
#     empty store would satisfy the weaker assertion vacuously.
#   * ripgrep is deliberately NOT installed in the image, so ks_search's
#     score-0 lexical fallback cannot fire. A hit here is a real semantic hit
#     from the backend, and the probe asserts the fallback notice is absent.
#   * "No further install" is asserted four independent ways: a PATH SHIM
#     that logs every `uv` invocation (run 2 must produce zero), the absence
#     of the adapter's own install/index notices on run 2's stderr, unchanged
#     mtimes on the entry point / pin stamp / tool dir, and a third run with
#     `uv` removed from PATH entirely that must still answer.
#
# Assertions COLLECT rather than abort: one run surfaces every failure, and
# the exit code is non-zero if any failed. Everything observed is printed
# verbatim under `--- OBSERVED ---` blocks, so the driver's transcript is the
# recorded evidence rather than a summary of it.
#
# It reaches for a few library-PRIVATE accessors (_ks_bm_pin_id,
# _ks_bm_bin_path). That is deliberate and is what makes the assertions
# target the paths the adapter ACTUALLY uses instead of paths this file
# guessed and would then have to keep in sync by hand.
#
# Env (all set by the driver; the defaults keep this runnable by hand inside
# a container for debugging):
#   KS_PROBE_LIB       directory holding the copied knowledge_*.sh libraries
#   KS_PROBE_CORPUS    where to write the fixture corpus
#   KS_PROBE_BM_HOME   the adapter's isolated home (KNOWLEDGE_SEARCH_BM_HOME)
#
# Linux-only by construction (it runs inside the image the driver builds), so
# GNU `stat -c` and friends are used without a BSD fallback.
#
# Exit: 0 = every assertion passed; 1 = one or more failed.

set -uo pipefail

LIB="${KS_PROBE_LIB:-/ks-lib}"           # setting:exempt — driver-injected container path, not an operator tunable
CORPUS="${KS_PROBE_CORPUS:-/corpus}"     # setting:exempt — driver-injected container path, not an operator tunable
BM_HOME="${KS_PROBE_BM_HOME:-/clean/bm-home}"  # setting:exempt — driver-injected container path, not an operator tunable
SHIM_DIR=/shim
UV_CALL_LOG=/tmp/uv-calls.log

PASS_COUNT=0
FAIL_COUNT=0

pass() { PASS_COUNT=$((PASS_COUNT + 1)); printf 'PASS  %s\n' "$1"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); printf 'FAIL  %s\n' "$1"; }

# assert <label> <command...>  — the command's own exit status IS the verdict.
# Taking a command rather than a pre-computed `$?` keeps the condition and its
# label on one line and leaves no window for an intervening command to
# overwrite the status being reported.
assert() { local label="$1"; shift; if "$@"; then pass "$label"; else fail "$label"; fi; }
refute() { local label="$1"; shift; if "$@"; then fail "$label"; else pass "$label"; fi; }

# Invoked indirectly, as `assert/refute <label> have <cmd>`.
# shellcheck disable=SC2329
have()      { command -v "$1" >/dev/null 2>&1; }
section()   { printf '\n=== %s ===\n' "$1"; }
observed()  { printf -- '--- OBSERVED: %s ---\n' "$1"; }

# Whole-second wall clock: the interesting deltas here are tens of seconds (a
# cold install) against sub-second (a warm search), so finer precision on a
# container's shared CPU would be false precision.
now() { date +%s; }

# ---------------------------------------------------------------------------
section "0. host identity"
# ---------------------------------------------------------------------------
observed "uname / os-release / uv version"
uname -m
grep -E '^(PRETTY_NAME|VERSION_ID)=' /etc/os-release || true
uv --version || true

# ---------------------------------------------------------------------------
section "1. the host really is clean"
# ---------------------------------------------------------------------------
assert "uv is on PATH" have uv
refute "no basic-memory on PATH (nothing pre-installed to fall back on)" have basic-memory
refute "no ~/.local/share before the run" test -e "$HOME/.local/share"
refute "no ~/.local/bin before the run"   test -e "$HOME/.local/bin"
refute "no shared uv cache at ~/.cache/uv before the run" test -e "$HOME/.cache/uv"
refute "the adapter's bm home does not exist yet ($BM_HOME)" test -e "$BM_HOME"

observed "\$HOME before the run"
find "$HOME" -maxdepth 3 | sort

# ---------------------------------------------------------------------------
section "2. fixture corpus"
# ---------------------------------------------------------------------------
# Three notes, disjoint subjects, no shared vocabulary — so a hit on one is
# evidence of retrieval rather than of there being only one document.
mkdir -p "$CORPUS"
cat > "$CORPUS/kestrel-migration.md" <<'NOTE'
---
title: Kestrel migration plan
---
# Kestrel migration plan

We are migrating the kestrel ingest service off the legacy queue and onto a
durable log. The rollout is staged: shadow reads first, then dual writes,
then a cutover once replay lag is under one second.
NOTE
cat > "$CORPUS/otter-retention.md" <<'NOTE'
---
title: Otter retention policy
---
# Otter retention policy

Otter keeps raw telemetry for ninety days, then compacts it into daily
rollups. Deletion is driven by a nightly sweep that honours legal holds.
NOTE
cat > "$CORPUS/badger-oncall.md" <<'NOTE'
---
title: Badger on-call runbook
---
# Badger on-call runbook

When the badger alert fires, check the dashboard, then drain the affected
shard before restarting. Escalate to the platform team after ten minutes.
NOTE
observed "corpus"
ls -1 "$CORPUS"

export KNOWLEDGE_STORE_ROOT="$CORPUS"
export KNOWLEDGE_SEARCH_BM_HOME="$BM_HOME"

# shellcheck source=/dev/null
source "$LIB/knowledge_store.sh"
# shellcheck source=/dev/null
source "$LIB/knowledge_search.sh"
# The adapter bounds its install and its cold-start index only when the
# caller has already provided run_with_timeout — a stranger's first search
# through a script that sources the adapter is exactly that caller, so the
# probe provides it too.
# shellcheck source=/dev/null
source "$LIB/portable-timeout.sh"

printf 'pin=%s\nentry point=%s\ncorpus=%s\n' \
  "$(_ks_bm_pin_id)" "$(_ks_bm_bin_path)" "$(ks_root)"

# ---------------------------------------------------------------------------
section "3. the zero-side-effect probe reports NOT READY"
# ---------------------------------------------------------------------------
ks_search_available --probe >/dev/null 2>&1
probe_rc=$?
assert "ks_search_available --probe exits 3 on a clean host (got $probe_rc)" \
  test "$probe_rc" -eq 3
refute "--probe wrote nothing — still no bm home" test -e "$BM_HOME"

# ---------------------------------------------------------------------------
section "4. ACCEPTANCE 1 — the FIRST ks_search returns results"
# ---------------------------------------------------------------------------
QUERY='how does the kestrel migration cut over'
t0="$(now)"
ks_search "$QUERY" --limit 5 >/tmp/run1.out 2>/tmp/run1.err
run1_rc=$?
t1="$(now)"
run1_secs=$((t1 - t0))

observed "run 1 stdout"
cat /tmp/run1.out
observed "run 1 stderr"
cat /tmp/run1.err
printf 'run1_exit=%s run1_seconds=%s\n' "$run1_rc" "$run1_secs"

assert "first ks_search exits 0 (got $run1_rc)" test "$run1_rc" -eq 0
assert "first ks_search returns a NON-EMPTY result stream" test -s /tmp/run1.out

run1_top="$(head -1 /tmp/run1.out | jq -r '.doc_id // empty' 2>/dev/null)"
assert "the top hit is the note the query is about (got '${run1_top:-<none>}')" \
  test "$run1_top" = "kestrel-migration.md"

run1_score="$(head -1 /tmp/run1.out | jq -r '.score // empty' 2>/dev/null)"
assert "the hit carries a real backend score, not the score-0 fallback sentinel (score=${run1_score:-<none>})" \
  test "${run1_score:-0}" != "0"

refute "the ripgrep fallback never fired (rg is deliberately absent from this image)" \
  grep -q 'ripgrep lexical fallback' /tmp/run1.err

assert "the lazy install fired on THIS run (the adapter said so on stderr)" \
  grep -q 'installing basic-memory==' /tmp/run1.err

assert "the cold-start index fired on THIS run (temperloop#1635)" \
  grep -q 'first use of project' /tmp/run1.err

# ---------------------------------------------------------------------------
section "5. ACCEPTANCE 2 — every byte written stays under the pinned bm home"
# ---------------------------------------------------------------------------
refute "nothing in ~/.local/share"            test -e "$HOME/.local/share"
refute "nothing in ~/.local/bin"              test -e "$HOME/.local/bin"
refute "no shared uv cache at ~/.cache/uv"    test -e "$HOME/.cache/uv"
refute "no uv state under ~/.local/state/uv"  test -e "$HOME/.local/state/uv"

assert "the entry point landed where the adapter looks for it" \
  test -x "$BM_HOME/uv-tool-bin/basic-memory"

stamp="$(cat "$BM_HOME/uv-tool-bin/.ks-installed-pin" 2>/dev/null)"
assert "the pin stamp matches the configured pin (got '${stamp:-<none>}')" \
  test "$stamp" = "$(_ks_bm_pin_id)"

# The ONE thing the adapter legitimately writes outside its bm home is the
# read log (knowledge_store.sh's KNOWLEDGE_READ_LOG, under XDG_STATE_HOME).
# The assertion names that exact escape set rather than claiming nothing at
# all escapes — a claim this very run would falsify.
observed "\$HOME after the run"
find "$HOME" -maxdepth 5 | sort
stray="$(find "$HOME" -mindepth 1 \
  -not -path "$HOME/.bashrc" -not -path "$HOME/.profile" \
  -not -path "$HOME/.local" \
  -not -path "$HOME/.local/state" \
  -not -path "$HOME/.local/state/foundation" \
  -not -path "$HOME/.local/state/foundation/knowledge-reads.log" \
  | sort)"
observed "unexpected \$HOME entries (should be empty)"
printf '%s\n' "${stray:-<none>}"
assert "the only thing written outside the bm home is the knowledge read log" \
  test -z "$stray"

observed "bm home footprint"
du -sh "$BM_HOME"
du -sh "$BM_HOME"/* "$BM_HOME"/.[a-z]* 2>/dev/null | sort -k2

# A source build is a real finding about the stranger path on this
# architecture, not a detail — uv only creates built-wheels-v* when it had to
# compile a dependency from an sdist.
observed "uv source-built wheels (empty = every dependency had a prebuilt wheel)"
ls -1 "$BM_HOME"/uv-cache/built-wheels-v* 2>/dev/null || printf '<none>\n'

# ---------------------------------------------------------------------------
section "6. ACCEPTANCE 3 — a SECOND ks_search installs nothing"
# ---------------------------------------------------------------------------
# A PATH shim in front of the real uv: any invocation at all now leaves a
# trace, so "no install" is observed rather than inferred.
mkdir -p "$SHIM_DIR"
real_uv="$(command -v uv)"
cat > "$SHIM_DIR/uv" <<SHIM
#!/usr/bin/env bash
printf 'UV CALL: %s\n' "\$*" >> "$UV_CALL_LOG"
exec "$real_uv" "\$@"
SHIM
chmod +x "$SHIM_DIR/uv"
: > "$UV_CALL_LOG"
export PATH="$SHIM_DIR:$PATH"

bin_target="$BM_HOME/uv-tool-bin/basic-memory"
stamp_path="$BM_HOME/uv-tool-bin/.ks-installed-pin"
before_mtimes="$(stat -c %Y "$bin_target" "$stamp_path" "$BM_HOME/uv-tools" | tr '\n' ' ')"

t2="$(now)"
ks_search "$QUERY" --limit 5 >/tmp/run2.out 2>/tmp/run2.err
run2_rc=$?
t3="$(now)"
run2_secs=$((t3 - t2))

observed "run 2 stdout"
cat /tmp/run2.out
observed "run 2 stderr"
cat /tmp/run2.err
printf 'run2_exit=%s run2_seconds=%s (run1 was %ss)\n' "$run2_rc" "$run2_secs" "$run1_secs"

assert "second ks_search exits 0 (got $run2_rc)" test "$run2_rc" -eq 0
assert "second ks_search still returns results"  test -s /tmp/run2.out

observed "uv invocations during run 2 (should be empty)"
cat "$UV_CALL_LOG"
refute "the second search invoked uv ZERO times" test -s "$UV_CALL_LOG"

refute "no install notice on the second search" \
  grep -q 'installing basic-memory==' /tmp/run2.err
refute "no cold-start index on the second search" \
  grep -q 'first use of project' /tmp/run2.err

after_mtimes="$(stat -c %Y "$bin_target" "$stamp_path" "$BM_HOME/uv-tools" | tr '\n' ' ')"
assert "the entry point, the pin stamp and the tool dir are untouched (before='$before_mtimes' after='$after_mtimes')" \
  test "$before_mtimes" = "$after_mtimes"

# ---------------------------------------------------------------------------
section "7. a warm search does not need uv on PATH at all"
# ---------------------------------------------------------------------------
# The strongest form of "no further install": take uv away entirely. If the
# warm path still answers, no install path was on it.
uv_dir="$(dirname "$real_uv")"
stripped_path="$(printf '%s' "$PATH" | tr ':' '\n' \
  | grep -vx "$SHIM_DIR" | grep -vx "$uv_dir" | paste -sd: -)"
# A SUBSHELL, not a `PATH=… ks_search` prefix: a variable assignment prefixed
# onto a shell FUNCTION persists into the calling shell in bash, and losing uv
# from this script's own PATH for good would poison every later step.
( export PATH="$stripped_path"; ks_search "$QUERY" --limit 5 ) >/tmp/run3.out 2>/tmp/run3.err
run3_rc=$?
observed "run 3 (uv removed from PATH) stdout"
cat /tmp/run3.out
observed "run 3 stderr"
cat /tmp/run3.err
assert "a warm ks_search still answers with uv removed from PATH (exit $run3_rc)" \
  test "$run3_rc" -eq 0
assert "run 3 returned results" test -s /tmp/run3.out

# ---------------------------------------------------------------------------
section "VERDICT"
# ---------------------------------------------------------------------------
printf 'arch=%s pin=%s\n' "$(uname -m)" "$(_ks_bm_pin_id)"
printf 'first-run seconds=%s (install + index + search), warm-run seconds=%s\n' \
  "$run1_secs" "$run2_secs"
printf 'bm home footprint=%s\n' "$(du -sh "$BM_HOME" | cut -f1)"
printf 'passed=%s failed=%s\n' "$PASS_COUNT" "$FAIL_COUNT"

if [ "$FAIL_COUNT" -gt 0 ]; then
  printf 'RESULT: FAIL (%s assertion(s) failed)\n' "$FAIL_COUNT"
  exit 1
fi
printf 'RESULT: PASS (%s assertions)\n' "$PASS_COUNT"
exit 0
