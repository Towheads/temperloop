#!/usr/bin/env bash
# sandbox.sh — reusable hermetic env-sandbox test harness (temperloop#263,
# "sandbox-core", ADR K164 D6). Sourced, not executed.
#
# ISOLATION MODEL: NO container. A throwaway root (mktemp -d) plus HOME and
# all four XDG vars (XDG_CONFIG_HOME/XDG_STATE_HOME/XDG_DATA_HOME/
# XDG_CACHE_HOME) re-pointed inside it, scoped to a single subprocess
# invocation via `env` — NEVER `export`ed into the sourcing shell (verified
# by this file's own test suite, workflows/scripts/tests/lib/tests/
# test_sandbox.sh, test 1). A stubbed `gh` (and, when needed, a stubbed
# `claude`) sits on a sandbox-private PATH prefix so no real network call or
# credential is ever reachable from inside the sandbox.
#
# The re-pointed env is ADDITIVE (`env NAME=VAL... cmd`, never `env -i`, and
# nothing here `unset`s), so re-pointing HOME/XDG_* does NOT by itself
# neutralise a PUBLIC env knob a caller exported: every consumer reads such a
# knob as `${KNOB:-<HOME/XDG-derived default>}`, and the override arm
# short-circuits the sandboxed default. The three knobs that would otherwise
# steer a sandboxed run at a REAL machine path — CACHE_STORE_ROOT,
# TEMPERLOOP_HOME, TEMPERLOOP_BIN_DIR — are therefore PINNED inside
# $SANDBOX_ROOT by sandbox_env (temperloop#1154; see _sandbox_pin, and
# test_sandbox.sh test 6 for the positive assertion). An in-sandbox steer
# still works; an inherited real-machine value never reaches the sandbox.
#
# This is the SAME fake-gh + throwaway-tree idiom
# bin/subcommands/tests/test_init.sh and test_eject.sh already use for their
# own fixtures — EXTRACTED here verbatim (subtraction over mechanism, see
# CLAUDE.md § Design discipline) so this item's own dry-run-legs test (and
# any FUTURE install-surface test) doesn't reinvent a third copy. Those two
# existing suites are deliberately left as-is (their own inline fixtures
# keep working); a follow-up may migrate them onto this lib, but that is not
# this item's scope.
#
# INTEGRITY LAYER (temperloop#266, "sandbox-integrity", belt-and-suspenders
# on ADR K164 D6's no-VM isolation model): three more sandbox_* functions —
# sandbox_preflight_links (write preflight), sandbox_tripwire_snapshot /
# sandbox_tripwire_check (post-run drift tripwire on the REAL machine, not
# the sandbox), and sandbox_tree_manifest / sandbox_tree_diff (symlink-aware
# tree-manifest + diff, the tripwire's own reusable primitive) — appended
# below the original sandbox-core functions rather than reshaping them. See
# docs/features/sandbox-integrity.md for the full contract; their own
# tests live in workflows/scripts/tests/lib/tests/test_sandbox_integrity.sh.
#
# Usage (sourced, not executed):
#
#   HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
#   # shellcheck source=workflows/scripts/tests/lib/sandbox.sh
#   source "$HERE/lib/sandbox.sh"
#
#   sandbox_up                                 # throwaway root + HOME/XDG/bin dirs
#   sandbox_stub_gh                            # fake `gh` on the sandbox PATH
#   sandbox_run bash "$SOME_SCRIPT" --dry-run  # runs with HOME/XDG/PATH re-pointed
#   sandbox_down                               # rm -rf the throwaway root
#
# Public functions:
#   sandbox_up [prefix]
#     Creates the throwaway root (mktemp -d "${TMPDIR:-/tmp}/<prefix>-XXXXXX")
#     and its home/xdg/bin subdirectories. Must be called before anything
#     else in this file. Sets the SANDBOX_* globals documented below. ALSO
#     registers the root and installs the EXIT/HUP/INT/TERM cleanup traps
#     that make the root un-leakable on a failed, timed-out or cancelled run
#     (temperloop#1723 — see the ROOT-LEAK GUARD block further down for the
#     chaining, idempotence and SIGKILL-not-covered notes), and drops a
#     `.sandbox-root` marker file in the root for sandbox-sweep.sh.
#
#     A caller that wants its OWN EXIT trap chained rather than clobbered
#     should install it BEFORE sandbox_up — though a later sandbox_up call
#     re-arms and re-chains, so the harness's own interferer idiom (install a
#     trap between two sandbox_up calls) stays correct too.
#
#   sandbox_down
#     rm -rf the throwaway root and de-register it. Safe to call even if
#     sandbox_up was never called (no-op), and safe to call alongside the
#     traps above — the two are idempotent together, never a double-remove.
#     Under SANDBOX_KEEP=1 it RETAINS the root and says so on stderr.
#
#   sandbox_env
#     Populates the SANDBOX_ENV_ARGS array with the `NAME=VALUE` assignments
#     `env` needs to re-point HOME/XDG_*/PATH at the sandbox — plus, when
#     sandbox_stub_gh / sandbox_stub_claude have been called, the CALL_LOG /
#     CLAUDE_CALL_LOG assignments those stubs read. Called internally by
#     sandbox_run/sandbox_bash/sandbox_bootstrap_checkout; exposed directly
#     for a caller that needs to build its own `env "${SANDBOX_ENV_ARGS[@]}"
#     ...` invocation (e.g. to add one-off FAKE_* steering vars — see
#     sandbox_run's own note on that below).
#
#   sandbox_run <cmd> [args...]
#     Runs <cmd> with the sandbox env, via a plain `env NAME=VAL... cmd
#     args...` — the standard shell mechanism for "these vars apply to this
#     one subprocess only", never touching the calling shell's own
#     environment. Any FAKE_* steering var a caller wants the stubbed `gh`
#     to see (FAKE_PR_STATE, FAKE_LABEL_DELETE_RC, ...) can be set as an
#     ordinary bash temporary-assignment prefix on the sandbox_run call
#     itself, e.g. `FAKE_PR_STATE=OPEN sandbox_run bash "$INIT" ...` — bash
#     exports a temporary-assignment prefix on a function call into that
#     function's own subprocess tree exactly as it would for an external
#     command, and it does not persist afterward (verified in this file's
#     test suite, test 1).
#
#   sandbox_bash <script> [args...]
#     Like sandbox_run, but for an inline script string that needs shell
#     features (pipelines, `&&`, builtins) `env` alone can't express: runs
#     `env "${SANDBOX_ENV_ARGS[@]}" bash -c "<script>" sandbox-bash
#     [args...]`.
#
#   sandbox_stub_gh [call_log]
#     Installs a logging fake `gh` at $SANDBOX_BIN/gh — the exact call
#     shapes bin/subcommands/tests/test_init.sh and test_eject.sh's own
#     inline fixtures already use (same FAKE_* env-steered replies), so a
#     test written against those two suites' conventions runs unmodified
#     against this stub. Every invocation appends its argv to call_log
#     (default: $SANDBOX_ROOT/gh-calls.log, exposed as SANDBOX_GH_CALL_LOG).
#     Truncates any pre-existing call_log content.
#
#   sandbox_stub_claude [call_log]
#     Installs a minimal logging no-op fake `claude` at $SANDBOX_BIN/claude.
#     SUPERSEDED AS A DISPATCH REQUIREMENT (temperloop#412,
#     "subcommand-prereq-scoping"): the dispatcher's prereq gate
#     (bin/lib/common.sh: foundation_check_prereqs) now checks only the
#     tools a subcommand's own `# prereqs: ...` header declares — no
#     shipped subcommand declares `claude`, so dispatching through the real
#     `temperloop` CLI no longer requires this stub at all (previously it
#     was needed unconditionally, since the gate checked for `claude` on
#     PATH before dispatching ANY subcommand even though init.sh/eject.sh
#     never invoke it themselves — that was the bug #412 fixed). Kept
#     available for a caller that wants to simulate `claude` being present
#     for a subcommand that DOES call it directly (e.g. try.sh's shadow
#     triage step, or configure.sh's AI-guided mode) and inspect the call
#     log. call_log default: $SANDBOX_ROOT/claude-calls.log, exposed as
#     SANDBOX_CLAUDE_CALL_LOG.
#
#   sandbox_bootstrap_checkout <source_repo_dir>
#     Bare-clones <source_repo_dir> (at whatever it currently has committed
#     — this is a `git clone --bare`, so uncommitted worktree changes are
#     never included, matching this repo's own "commit first, then gates"
#     discipline) into the sandbox, then runs *that source checkout's own*
#     bin/bootstrap.sh against the clone over a file:// remote
#     (TEMPERLOOP_KERNEL_REPO=file://<bare-clone-path>) — the hermetic
#     stand-in for the curl-pipe-sh newcomer install bin/bootstrap.sh's own
#     header documents. Runs with the sandbox env (HOME/XDG_* re-pointed),
#     so bootstrap.sh's own $HOME-relative defaults
#     (TEMPERLOOP_HOME=$HOME/.local/share/temperloop,
#     TEMPERLOOP_BIN_DIR=$HOME/.local/bin) resolve inside the sandbox with
#     no extra overrides needed. On success sets SANDBOX_TEMPERLOOP to the
#     resulting `temperloop` binary's path.
#
# Globals set by sandbox_up (read-only after that call; sandbox_down clears
# nothing but the underlying directory — re-call sandbox_up for a fresh one):
#   SANDBOX_ROOT               the throwaway root
#   SANDBOX_HOME                $SANDBOX_ROOT/home
#   SANDBOX_XDG_CONFIG_HOME     $SANDBOX_ROOT/xdg/config
#   SANDBOX_XDG_STATE_HOME      $SANDBOX_ROOT/xdg/state
#   SANDBOX_XDG_DATA_HOME       $SANDBOX_ROOT/xdg/data
#   SANDBOX_XDG_CACHE_HOME      $SANDBOX_ROOT/xdg/cache
#   SANDBOX_BIN                 $SANDBOX_ROOT/bin (prepended onto PATH by
#                               sandbox_run/sandbox_bash)
#   SANDBOX_CACHE_STORE_ROOT    $SANDBOX_XDG_CACHE_HOME/temperloop
#   SANDBOX_TEMPERLOOP_HOME     $SANDBOX_HOME/.local/share/temperloop
#   SANDBOX_TEMPERLOOP_BIN_DIR  $SANDBOX_HOME/.local/bin
#                               (the last three are the public-knob pins
#                               sandbox_env emits — see _sandbox_pin)
#
# Additional globals set by other functions:
#   SANDBOX_GH_CALL_LOG         set by sandbox_stub_gh
#   SANDBOX_CLAUDE_CALL_LOG     set by sandbox_stub_claude
#   SANDBOX_TEMPERLOOP           set by sandbox_bootstrap_checkout on success
#
# ---------------------------------------------------------------------------
# INTEGRITY LAYER — public functions (temperloop#266, "sandbox-integrity")
# ---------------------------------------------------------------------------
#
#   sandbox_preflight_links <foundation_root> [<links_lib_override>]
#     Write PREFLIGHT: sources links.sh (default
#     <foundation_root>/workflows/scripts/install/links.sh; pass an
#     alternate path as the 2nd arg — a test-double seam, not a setting) and
#     runs its links_enumerate INSIDE the sandbox env (sandbox_run, so
#     links_enumerate's own $HOME-relative target computation resolves
#     against $SANDBOX_HOME), then asserts every emitted target path falls
#     under $SANDBOX_ROOT. Returns 0 iff every target resolves inside the
#     sandbox; on any escaping target, prints it to stderr and returns 1.
#     Call BEFORE the first write of a simulated install — it does no
#     writing itself, only enumerates + checks. Requires sandbox_up first.
#
#   sandbox_tripwire_snapshot <label> [path...]
#     Post-run drift TRIPWIRE, snapshot half. Hashes each given path (a
#     REAL, non-sandboxed machine path — never re-pointed by sandbox_run)
#     via sandbox_tree_manifest and stores the manifests under
#     $SANDBOX_ROOT/tripwire/<label>/, read-only (no mutation of the given
#     paths themselves). Defaults to the two real paths a sandboxed run
#     must never touch: $HOME/.claude and $HOME/.local/bin/temperloop. An
#     absent path is handled gracefully (recorded as a distinct "absent"
#     manifest entry, not an error) so this is safe to call on a machine
#     that has neither path yet. Call BEFORE a sandboxed run. Requires
#     sandbox_up first (the snapshot lives under $SANDBOX_ROOT, not the
#     paths being watched).
#
#   sandbox_tripwire_check <label>
#     Tripwire, check half. Re-hashes the SAME real paths recorded by the
#     matching sandbox_tripwire_snapshot call and diffs each against its
#     stored manifest (sandbox_tree_diff, no exclusions). Returns 0 iff
#     none drifted; on any drift, prints which real path changed to stderr
#     and returns 1. Call AFTER a sandboxed run.
#
#   sandbox_tree_manifest <root>
#     Symlink-aware tree-manifest generator: prints one tab-separated
#     `<relpath>\t<type>\t<hash-or-target>` record per line to stdout, type
#     one of file|symlink|absent. A symlink's OWN target string is
#     recorded via `readlink` — the link is never followed/descended into.
#     A missing <root> prints a single `.\tabsent\t` record rather than
#     erroring, so an existence flip is itself a detectable diff. Pure
#     read; no sandbox_up required (root can be any path, sandboxed or
#     real).
#
#   sandbox_tree_diff <manifest_a> <manifest_b> [<exclusions>]
#     Diffs two sandbox_tree_manifest outputs (file paths, not tree
#     roots). <exclusions>, if given, is either a path to a file of
#     newline-separated case-glob patterns (blank lines and `#`-comments
#     skipped) or, if not an existing file, a literal
#     whitespace/newline-separated inline pattern list — CALLER-SUPPLIED
#     only, nothing hardcoded here. A manifest record whose relpath
#     matches any pattern is ignored on BOTH sides before comparing.
#     Returns 0 iff the (post-exclusion) manifests are identical; on any
#     difference (added/removed/changed record, including a retargeted
#     symlink) prints a unified diff to stderr and returns 1.
#
# shellcheck shell=bash

# Guard against double-sourcing (same idiom as workflows/scripts/install/links.sh).
if [[ "${_SANDBOX_SH_LOADED:-}" == "1" ]]; then
  return 0
fi
_SANDBOX_SH_LOADED=1

# ---------------------------------------------------------------------------
# ROOT-LEAK GUARD (temperloop#1723)
#
# THE LEAK. A throwaway root is ~1GB for the install-surface suites, and
# every suite removed it with a single `sandbox_down` on its LAST line. That
# line is only reached on the HAPPY path: `fail()` is `exit 1`, so a failed
# assertion — plus a timeout kill, a CI cancellation, or an ENOSPC — walked
# past it and stranded the root. Measured cost: $TMPDIR holding 215 leaked
# roots totalling ~180GB, which filled a 460GB disk and killed a validation
# batch mid-run.
#
# THE FIX, AND WHY IT LIVES HERE. `sandbox_up` installs the cleanup traps
# ITSELF, so every existing caller became safe with no edit and no new
# caller can forget. Three properties the implementation below holds:
#
#   REGISTERED, NOT LATEST-ONLY. Every root sandbox_up ever creates in this
#   shell is appended to _SANDBOX_ROOTS, so a suite that calls sandbox_up
#   many times (bin/subcommands/tests/test_uninstall.sh does, 13 times) has
#   EVERY root reclaimed, not just the one $SANDBOX_ROOT happens to name at
#   the moment of death.
#
#   CHAINED, NEVER CLOBBERING. A caller's own EXIT/signal handler is
#   captured (via `trap -p`, whose output is bash's own re-runnable quoting
#   — so no unescaping is guessed at) into a _sandbox_prior_<SIG> function
#   and run FIRST, before the root it may still need is removed. Traps are
#   re-armed on EVERY sandbox_up call, so a caller that installs its own
#   EXIT trap AFTER the first sandbox_up (which the harness's own
#   test_sandbox.sh does at its test-5 interferer) is re-chained rather than
#   left holding a clobbered trap. A signal the caller deliberately IGNORES
#   (`trap '' TERM`) is left alone.
#
#   IDEMPOTENT. `rm -rf` on an already-removed root is a no-op, and
#   sandbox_down de-registers, so the explicit trailing `sandbox_down` call
#   the suites already carry and the trap can both run without conflict —
#   which is why test_install_lifecycle.sh's "sandbox_down removed the root"
#   assertion still means what it did.
#
# WHAT IS **NOT** COVERED: SIGKILL (`kill -9`, an OOM kill, the SIGKILL leg
# of a candidate timeout) is untrappable by construction — no trap can fire.
# A root leaked that way is reclaimed by the sweeper,
# workflows/scripts/tests/lib/sandbox-sweep.sh, which is the ONLY remedy for
# that path (and for roots already stranded before this guard existed).
#
# DEBUGGABILITY ESCAPE: export SANDBOX_KEEP=1 to RETAIN every root — for
# diagnosing a red suite. It is loud on stderr, and it applies to the
# explicit `sandbox_down` call as well as to the traps, so "keep" means
# keep. A suite that ASSERTS its root was removed therefore fails under
# SANDBOX_KEEP; that is the flag working, not a regression.
# ---------------------------------------------------------------------------

# Basename of the marker file sandbox_up drops in each root. Its presence is
# what makes a leaked root identifiable to the sweeper without guessing at
# `mktemp` prefixes.
SANDBOX_MARKER_NAME=".sandbox-root"

_SANDBOX_ROOTS=()
_SANDBOX_ANNOUNCED=()

# sandbox_keep_requested — 0 (true) iff the caller asked to RETAIN roots.
# Accepts the falsey spellings explicitly so `SANDBOX_KEEP=0` means "no".
sandbox_keep_requested() {
  case "${SANDBOX_KEEP:-}" in
    "" | 0 | no | No | NO | false | False | FALSE) return 1 ;;
    *) return 0 ;;
  esac
}

_sandbox_register_root() {
  _SANDBOX_ROOTS+=("$1")
}

_sandbox_forget_root() {
  local target="$1" kept=() r
  for r in ${_SANDBOX_ROOTS[@]+"${_SANDBOX_ROOTS[@]}"}; do
    [[ "$r" == "$target" ]] || kept+=("$r")
  done
  _SANDBOX_ROOTS=(${kept[@]+"${kept[@]}"})
  return 0
}

# Announce a retained root ONCE, however many cleanup paths reach it.
_sandbox_announce_keep() {
  local root="$1" a
  for a in ${_SANDBOX_ANNOUNCED[@]+"${_SANDBOX_ANNOUNCED[@]}"}; do
    [[ "$a" == "$root" ]] && return 0
  done
  _SANDBOX_ANNOUNCED+=("$root")
  printf 'sandbox: SANDBOX_KEEP set — RETAINING %s\n' "$root" >&2
  printf 'sandbox:   inspect it, then remove it yourself (or run: bash %s --apply).\n' \
    "workflows/scripts/tests/lib/sandbox-sweep.sh" >&2
  printf 'sandbox:   a suite that asserts the root was removed will fail under SANDBOX_KEEP.\n' >&2
  return 0
}

# Remove (or, under SANDBOX_KEEP, report) every root registered in this shell.
# Safe to call any number of times.
_sandbox_cleanup_all() {
  local r
  for r in ${_SANDBOX_ROOTS[@]+"${_SANDBOX_ROOTS[@]}"}; do
    [[ -n "$r" ]] || continue
    if sandbox_keep_requested; then
      if [[ -e "$r" ]]; then
        _sandbox_announce_keep "$r"
      fi
      continue
    fi
    rm -rf "$r"
  done
  if ! sandbox_keep_requested; then
    _SANDBOX_ROOTS=()
  fi
  return 0
}

# EXIT-trap half. Never calls `exit`, so the script's own exit status — which
# a caller's chained prior handler has already seen as $? — is preserved.
_sandbox_on_exit() {
  _sandbox_cleanup_all
}

# Signal half. Cleans up, then exits 128+N so the shell reports the
# conventional signal status AND the EXIT chain (including a caller's own
# EXIT handler) still gets to run — which a bare re-raise would skip.
_sandbox_on_signal() {
  local num="$2"
  _sandbox_cleanup_all
  exit $((128 + num))
}

# _sandbox_arm_one <SIG> <handler> — install <handler> for <SIG>, chaining
# whatever the caller already had bound there.
_sandbox_arm_one() {
  local sig="$1" handler="$2" line body prior_fn="_sandbox_prior_$1"
  line="$(trap -p "$sig" 2>/dev/null)"
  if [[ -n "$line" ]]; then
    # `trap -p` prints `trap -- '<body>' <NAME>`, where <NAME> is EXIT or the
    # SIG-prefixed signal name and <body> is single-quoted with bash's own
    # escaping. Strip only the fixed prefix and the trailing name (shortest
    # match from the end, so a body containing spaces or newlines survives),
    # then re-emit the STILL-QUOTED body into an `eval` — no hand-rolled
    # unescaping, so an apostrophe in the caller's handler cannot corrupt it.
    body="${line#trap -- }"
    body="${body% *}"
    case "$body" in
      *_sandbox_on_exit* | *_sandbox_on_signal*)
        # Already ours (a re-arm after another sandbox_up) — nothing to chain.
        return 0
        ;;
      "''")
        # The caller deliberately IGNORES this signal; honour that.
        return 0
        ;;
    esac
    eval "${prior_fn}() { eval ${body}
}"
    handler="$prior_fn; $handler"
  fi
  # Deliberate immediate expansion: the composed handler must be baked in now.
  # shellcheck disable=SC2064
  trap "$handler" "$sig"
  return 0
}

_sandbox_arm_traps() {
  _sandbox_arm_one EXIT '_sandbox_on_exit'
  _sandbox_arm_one HUP '_sandbox_on_signal HUP 1'
  _sandbox_arm_one INT '_sandbox_on_signal INT 2'
  _sandbox_arm_one TERM '_sandbox_on_signal TERM 15'
  return 0
}

# ---------------------------------------------------------------------------
sandbox_up() {
  local prefix="${1:-sandbox}"
  SANDBOX_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/${prefix}-XXXXXX")"
  SANDBOX_HOME="$SANDBOX_ROOT/home"
  SANDBOX_XDG_CONFIG_HOME="$SANDBOX_ROOT/xdg/config"
  SANDBOX_XDG_STATE_HOME="$SANDBOX_ROOT/xdg/state"
  SANDBOX_XDG_DATA_HOME="$SANDBOX_ROOT/xdg/data"
  SANDBOX_XDG_CACHE_HOME="$SANDBOX_ROOT/xdg/cache"
  SANDBOX_BIN="$SANDBOX_ROOT/bin"
  # Sandbox-interior values for the three PUBLIC env knobs that would
  # otherwise let a caller's exported value steer a sandboxed run at a REAL
  # machine path (temperloop#1154). Each is pinned to exactly the path its
  # own default derivation ALREADY produces inside the sandbox — so nothing
  # about a clean run changes; the pin only removes the inherit-from-caller
  # arm:
  #   CACHE_STORE_ROOT   <- $XDG_CACHE_HOME/temperloop  (the expression
  #                         workflows/scripts/install/links.sh's
  #                         links_provision_cache_stores derives, and that
  #                         uninstall.sh / eject.sh / deploy-mini.sh
  #                         re-derive identically)
  #   TEMPERLOOP_HOME    <- $HOME/.local/share/temperloop  (bin/bootstrap.sh)
  #   TEMPERLOOP_BIN_DIR <- $HOME/.local/bin               (bin/bootstrap.sh)
  # See sandbox_env for why an UNpinned knob is a live leak vector, not a
  # theoretical one.
  SANDBOX_CACHE_STORE_ROOT="$SANDBOX_XDG_CACHE_HOME/temperloop"
  SANDBOX_TEMPERLOOP_HOME="$SANDBOX_HOME/.local/share/temperloop"
  SANDBOX_TEMPERLOOP_BIN_DIR="$SANDBOX_HOME/.local/bin"
  mkdir -p \
    "$SANDBOX_HOME" \
    "$SANDBOX_XDG_CONFIG_HOME" \
    "$SANDBOX_XDG_STATE_HOME" \
    "$SANDBOX_XDG_DATA_HOME" \
    "$SANDBOX_XDG_CACHE_HOME" \
    "$SANDBOX_BIN"
  # Root-leak guard (temperloop#1723 — see the block above sandbox_up).
  # The marker is what lets sandbox-sweep.sh identify a LEAKED root
  # positively, rather than guessing from a `mktemp` prefix. Timestamp is
  # stored UTC (a machine-parsed record, never a display surface).
  {
    printf '# temperloop test sandbox root (workflows/scripts/tests/lib/sandbox.sh)\n'
    printf 'prefix=%s\n' "$prefix"
    printf 'pid=%s\n' "$$"
    printf 'suite=%s\n' "${0##*/}"
    printf 'created=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  } >"$SANDBOX_ROOT/$SANDBOX_MARKER_NAME"
  _sandbox_register_root "$SANDBOX_ROOT"
  _sandbox_arm_traps
}

# ---------------------------------------------------------------------------
sandbox_down() {
  [[ -n "${SANDBOX_ROOT:-}" ]] || return 0
  if sandbox_keep_requested; then
    _sandbox_announce_keep "$SANDBOX_ROOT"
    return 0
  fi
  rm -rf "$SANDBOX_ROOT"
  _sandbox_forget_root "$SANDBOX_ROOT"
  return 0
}

# ---------------------------------------------------------------------------
# _sandbox_pin <VAR_NAME> <sandbox_default>  (internal, temperloop#1154)
#
# Prints the value sandbox_env should assign to <VAR_NAME>. The rule is
# "always inside $SANDBOX_ROOT", implemented as:
#   - the caller's current value, IFF it already resolves under $SANDBOX_ROOT
#     — this preserves the documented temporary-assignment-prefix steering
#     seam (`CACHE_STORE_ROOT="$SANDBOX_ROOT/custom" sandbox_run ...`, which
#     bin/subcommands/tests/test_uninstall.sh test 7 relies on);
#   - the sandbox default otherwise — which is the leak-closing arm: a value
#     inherited from the real environment (an operator's or CI runner's
#     exported knob) can never reach a sandboxed process.
# Deliberately NOT an unconditional override: that would break in-sandbox
# steering, and deliberately NOT a `:-` default: that would leave the leak
# open. Both properties are asserted by test_sandbox.sh test 6.
# ---------------------------------------------------------------------------
_sandbox_pin() {
  local name="$1" fallback="$2" cur
  cur="${!name:-}"
  case "$cur" in
    "$SANDBOX_ROOT" | "$SANDBOX_ROOT"/*) printf '%s' "$cur" ;;
    *) printf '%s' "$fallback" ;;
  esac
}

# ---------------------------------------------------------------------------
sandbox_env() {
  : "${SANDBOX_ROOT:?sandbox_env: call sandbox_up first}"
  local _sb_cache_store_root _sb_temperloop_home _sb_temperloop_bin_dir _sb_bm_home
  _sb_cache_store_root="$(_sandbox_pin CACHE_STORE_ROOT "$SANDBOX_CACHE_STORE_ROOT")"
  # KNOWLEDGE_SEARCH_BM_HOME (temperloop#1658). A FOURTH documented public
  # knob (workflows/scripts/lib/knowledge_search.sh) whose whole purpose is
  # relocating the ~380MB basic-memory tool home — so an operator exporting
  # it is expected, not exotic. Unpinned, the additive-env rule this block
  # already states applies in its most damaging form: a sandbox test that
  # seeds a fixture at ${KNOWLEDGE_SEARCH_BM_HOME:-...} writes to the REAL
  # tool home, and sandbox_down (which removes only $SANDBOX_ROOT) leaves
  # the damage in place. Caught by the §3e shell-reviewer before the first
  # such test shipped.
  _sb_bm_home="$(_sandbox_pin KNOWLEDGE_SEARCH_BM_HOME "$SANDBOX_XDG_STATE_HOME/foundation/basic-memory-home")"
  _sb_temperloop_home="$(_sandbox_pin TEMPERLOOP_HOME "$SANDBOX_TEMPERLOOP_HOME")"
  _sb_temperloop_bin_dir="$(_sandbox_pin TEMPERLOOP_BIN_DIR "$SANDBOX_TEMPERLOOP_BIN_DIR")"
  SANDBOX_ENV_ARGS=(
    "HOME=$SANDBOX_HOME"
    "XDG_CONFIG_HOME=$SANDBOX_XDG_CONFIG_HOME"
    "XDG_STATE_HOME=$SANDBOX_XDG_STATE_HOME"
    "XDG_DATA_HOME=$SANDBOX_XDG_DATA_HOME"
    "XDG_CACHE_HOME=$SANDBOX_XDG_CACHE_HOME"
    "PATH=$SANDBOX_BIN:$PATH"
    # --- explicit public-knob pins (temperloop#1154) ---------------------
    # This env is ADDITIVE: sandbox_run/sandbox_bash invoke `env NAME=VAL...
    # cmd`, never `env -i`, and nothing in this file `unset`s anything. So a
    # knob that is merely ABSENT from this array is NOT neutralised by
    # re-pointing HOME/XDG_* — a caller that exported it wins outright,
    # because every consumer reads it as `${KNOB:-<HOME/XDG-derived
    # default>}` and the override arm short-circuits the default. All three
    # below are documented public knobs (bin/README.md,
    # workflows/scripts/board/lib/CACHE-STORE.md, boards.conf.example), so
    # an operator or a CI runner exporting one is expected, not exotic.
    #
    # That today's suites happen to survive without these pins is a
    # TEST-COVERAGE ACCIDENT, not a guarantee: they exercise only `help`,
    # `init --dry-run` and `eject --dry-run`, none of which reach the cache
    # root — while links_provision_cache_stores (reached from the shipped
    # `temperloop install`) does an unconditional `mkdir -p` on it. The pins
    # close the hole ahead of the first suite that walks a writing path.
    # Asserted positively by test_sandbox.sh test 6.
    "CACHE_STORE_ROOT=$_sb_cache_store_root"
    "TEMPERLOOP_HOME=$_sb_temperloop_home"
    "TEMPERLOOP_BIN_DIR=$_sb_temperloop_bin_dir"
    "KNOWLEDGE_SEARCH_BM_HOME=$_sb_bm_home"
  )
  if [[ -n "${SANDBOX_GH_CALL_LOG:-}" ]]; then
    SANDBOX_ENV_ARGS+=("CALL_LOG=$SANDBOX_GH_CALL_LOG")
  fi
  if [[ -n "${SANDBOX_CLAUDE_CALL_LOG:-}" ]]; then
    SANDBOX_ENV_ARGS+=("CLAUDE_CALL_LOG=$SANDBOX_CLAUDE_CALL_LOG")
  fi
}

# ---------------------------------------------------------------------------
# sandbox_env_omit <VAR>... (temperloop#1154)
#
# Rebuilds SANDBOX_ENV_ARGS (via sandbox_env) with the named assignments
# REMOVED, so the invoked process sees those variables genuinely UNSET rather
# than pinned. `env` cannot express this after the fact — its options must
# precede its assignments, so an `-u NAME` cannot cancel a `NAME=VAL` already
# in the array.
#
# This is a narrow, named opt-out for a suite whose SUBJECT is a variable's
# unset-ness, not a general escape hatch: bin/bootstrap.sh's legacy-env
# refusal fires only when the TEMPERLOOP_* name is unset-or-empty, so
# workflows/scripts/tests/test_rename_compat.sh's leg 1 cannot assert it
# while sandbox_env pins TEMPERLOOP_HOME/TEMPERLOOP_BIN_DIR. Any caller
# reaching for this is deliberately re-opening a leak vector for the
# duration of one assertion — call sandbox_env again straight after to
# restore the pins, and keep the un-pinned window to legs that write nothing
# outside the sandbox.
# ---------------------------------------------------------------------------
sandbox_env_omit() {
  sandbox_env
  local keep=() a name want drop
  for a in "${SANDBOX_ENV_ARGS[@]}"; do
    name="${a%%=*}"
    drop=0
    for want in "$@"; do
      if [ "$name" = "$want" ]; then
        drop=1
        break
      fi
    done
    [ "$drop" = "1" ] || keep+=("$a")
  done
  SANDBOX_ENV_ARGS=("${keep[@]}")
}

# ---------------------------------------------------------------------------
sandbox_run() {
  sandbox_env
  env "${SANDBOX_ENV_ARGS[@]}" "$@"
}

# ---------------------------------------------------------------------------
sandbox_bash() {
  local script="$1"
  shift
  sandbox_env
  env "${SANDBOX_ENV_ARGS[@]}" bash -c "$script" sandbox-bash "$@"
}

# ---------------------------------------------------------------------------
sandbox_stub_gh() {
  : "${SANDBOX_BIN:?sandbox_stub_gh: call sandbox_up first}"
  local call_log="${1:-$SANDBOX_ROOT/gh-calls.log}"
  : > "$call_log"
  cat > "$SANDBOX_BIN/gh" <<'FAKE_GH_EOF'
#!/usr/bin/env bash
# Extracted from bin/subcommands/tests/test_init.sh / test_eject.sh's own
# fake-gh fixtures (temperloop#263) — same FAKE_*-env-steered call shapes,
# one shared copy instead of two ad-hoc ones. $CALL_LOG is injected by
# sandbox_env (never hardcoded here), matching those fixtures' own
# CALL_LOG-as-env-var convention.
printf '%s\n' "$*" >> "$CALL_LOG"
case "$1" in
  auth)
    exit "${FAKE_AUTH_RC:-0}"
    ;;
  api)
    case "$*" in
      *required_status_checks*)
        # GET (no --method) probes existence; --method DELETE reverts.
        case "$*" in
          *"--method DELETE"*) exit "${FAKE_REQUIRED_CHECK_DELETE_RC:-0}" ;;
          *) exit "${FAKE_REQUIRED_CHECK_GET_RC:-${FAKE_REQUIRED_CHECK_RC:-0}}" ;;
        esac
        ;;
      *"git/refs/heads/"*) exit 0 ;;
      */branches/*/protection*)
        echo "HTTP 404" >&2
        exit 1
        ;;
      */labels*)
        printf '[]'
        exit 0
        ;;
    esac
    exit 0
    ;;
  label)
    case "$2" in
      delete) exit "${FAKE_LABEL_DELETE_RC:-0}" ;;
      # mirrors the real `gh label list --json name -q '.[].name'` output
      # shape: plain names, one per line.
      list) printf '%s\n' ${FAKE_EXISTING_LABELS:-} ;;
      create) exit 0 ;;
    esac
    exit 0
    ;;
  project)
    case "$2" in
      delete) exit "${FAKE_PROJECT_DELETE_RC:-0}" ;;
      view) exit "${FAKE_PROJECT_VIEW_RC:-0}" ;;
      create)
        echo "https://github.com/orgs/${FAKE_OWNER:-acme}/projects/${FAKE_PROJECT_NUM:-42}"
        exit 0
        ;;
    esac
    exit 0
    ;;
  pr)
    case "$2" in
      view) printf '%s' "${FAKE_PR_STATE:-MERGED}" ;;
      close) exit "${FAKE_PR_CLOSE_RC:-0}" ;;
      create)
        if [ -n "${FAKE_PR_EXISTS:-}" ]; then
          echo "a pull request for branch \"$FAKE_PR_BRANCH\" into branch \"main\" already exists: https://github.com/${FAKE_GH_REPO:-acme/widget}/pull/${FAKE_PR_NUM:-9}" >&2
          exit 1
        fi
        echo "https://github.com/${FAKE_GH_REPO:-acme/widget}/pull/${FAKE_PR_NUM:-9}"
        exit 0
        ;;
    esac
    exit 0
    ;;
esac
exit 0
FAKE_GH_EOF
  chmod +x "$SANDBOX_BIN/gh"
  SANDBOX_GH_CALL_LOG="$call_log"
}

# ---------------------------------------------------------------------------
sandbox_stub_claude() {
  : "${SANDBOX_BIN:?sandbox_stub_claude: call sandbox_up first}"
  local call_log="${1:-$SANDBOX_ROOT/claude-calls.log}"
  : > "$call_log"
  cat > "$SANDBOX_BIN/claude" <<'FAKE_CLAUDE_EOF'
#!/usr/bin/env bash
# Minimal no-op stand-in for a subcommand that calls `claude` directly
# (try.sh's shadow triage, configure.sh's AI-guided mode) — no longer
# needed just to satisfy bin/temperloop's dispatcher prereq gate, which
# (temperloop#412) checks `claude` only for a subcommand that declares it
# via a `# prereqs: ...` header; none shipped today do. $CLAUDE_CALL_LOG is
# injected by sandbox_env.
printf '%s\n' "$*" >> "$CLAUDE_CALL_LOG"
exit 0
FAKE_CLAUDE_EOF
  chmod +x "$SANDBOX_BIN/claude"
  SANDBOX_CLAUDE_CALL_LOG="$call_log"
}

# ---------------------------------------------------------------------------
# sandbox_skip_if_composed_tree <suite-name> <repo-root> [extra-rationale]
#
# A legible SKIP (exit 0) for a suite that is scoped to a KERNEL-ONLY checkout.
# Sourced, so the `exit 0` ends the calling suite.
#
# WHY THIS EXISTS: every suite that calls sandbox_bootstrap_checkout below
# bootstraps THIS repo from `$repo/bin/bootstrap.sh`. That path only exists
# when the repo root IS the kernel. In an overlay that vendors the kernel as a
# subtree the root is the overlay and the CLI lives at kernel/bin/, so the
# suite errors out on a layout it was never scoped to — it is re-testing
# kernel-owned install behaviour the kernel's own CI already covers, at a path
# the overlay does not own.
#
# The detection is temperloop#267's, extracted verbatim from
# test_install_lifecycle.sh (subtraction over mechanism, per this file's own
# header) rather than copied into each sibling: #267 got this right and its
# three siblings simply never inherited it, which is the whole of #363.
#
# Detection order matters — cheapest, most specific signal first:
#   1. composed CLAUDE (overlay beside kernel) — the definitive overlay marker;
#   2. a vendored kernel/ subtree at the root;
#   3. our own tree is a subtree INSIDE a larger repo (git toplevel != root).
# The caller passes its OWN repo root rather than this lib deriving one: in a
# composed tree these suites are reached through a compat symlink, so a root
# derived here from BASH_SOURCE would resolve to the kernel subtree (with
# `cd -P`) or the overlay (without) depending purely on that flag — exactly the
# ambiguity being guarded against. Every caller already computes REPO_ROOT.
sandbox_skip_if_composed_tree() {
  local suite="${1:?sandbox_skip_if_composed_tree: suite name required}"
  local repo_root="${2:?sandbox_skip_if_composed_tree: repo root required}"
  local extra="${3:-}"
  local reason=""

  if [ -f "$repo_root/claude/CLAUDE.kernel.md" ] && [ -f "$repo_root/claude/CLAUDE.overlay.md" ]; then
    reason="claude/CLAUDE.overlay.md is present beside claude/CLAUDE.kernel.md under $repo_root/claude"
  elif [ -d "$repo_root/kernel" ] && { [ -f "$repo_root/kernel/bin/temperloop" ] || [ -f "$repo_root/kernel/claude/CLAUDE.kernel.md" ]; }; then
    reason="a kernel/ subtree is vendored at the repo root ($repo_root/kernel)"
  else
    local toplevel root_phys top_phys
    toplevel="$(git -C "$repo_root" rev-parse --show-toplevel 2>/dev/null || true)"
    if [ -n "$toplevel" ]; then
      # Physical-path both sides (cd -P) before comparing — on macOS $TMPDIR
      # and /var symlinks make logical string comparison unreliable.
      root_phys="$(cd -P "$repo_root" && pwd)"
      top_phys="$(cd -P "$toplevel" && pwd)"
      if [ "$root_phys" != "$top_phys" ]; then
        reason="this suite's own tree ($repo_root) is a vendored subtree inside a larger repo ($toplevel), not a standalone kernel checkout"
      fi
    fi
  fi

  [ -n "$reason" ] || return 0

  echo "SKIP: $suite — composed overlay tree detected ($reason)."
  echo "  This suite is scoped to a kernel-only checkout by design (temperloop#267):"
  if [ -n "$extra" ]; then
    echo "  $extra"
  else
    echo "  it bootstraps this repo's own install CLI from bin/bootstrap.sh, which"
    echo "  exists only when the repo root IS the kernel. A vendoring overlay reaches"
    echo "  that CLI at kernel/bin/ and has no reason to re-test kernel-owned install"
    echo "  behaviour the kernel's own CI already covers."
  fi
  echo "  Exiting 0 (legible skip, not a failure)."
  exit 0
}

# ---------------------------------------------------------------------------
sandbox_bootstrap_checkout() {
  : "${SANDBOX_ROOT:?sandbox_bootstrap_checkout: call sandbox_up first}"
  local source_repo="${1:?sandbox_bootstrap_checkout: source repo dir required}"
  local upstream="$SANDBOX_ROOT/kernel-upstream.git"
  local bootstrap_script="$source_repo/bin/bootstrap.sh"

  git -C "$source_repo" rev-parse --show-toplevel >/dev/null 2>&1 \
    || { echo "sandbox_bootstrap_checkout: '$source_repo' is not a git working tree" >&2; return 1; }
  [[ -f "$bootstrap_script" ]] \
    || { echo "sandbox_bootstrap_checkout: $bootstrap_script not found" >&2; return 1; }

  # A local bare mirror of the source checkout's COMMITTED content — never
  # its uncommitted worktree changes (git clone reads through .git, not the
  # working directory). Served back to bootstrap.sh over file:// so the
  # newcomer install path never touches the real network.
  git clone -q --bare "$source_repo" "$upstream" || return 1

  sandbox_env
  if ! env "${SANDBOX_ENV_ARGS[@]}" \
      TEMPERLOOP_KERNEL_REPO="file://$upstream" \
      sh "$bootstrap_script"; then
    return 1
  fi

  if [[ -x "$SANDBOX_HOME/.local/bin/temperloop" ]]; then
    SANDBOX_TEMPERLOOP="$SANDBOX_HOME/.local/bin/temperloop"
  else
    SANDBOX_TEMPERLOOP="$SANDBOX_HOME/.local/share/temperloop/bin/temperloop"
  fi
  [[ -x "$SANDBOX_TEMPERLOOP" ]] \
    || { echo "sandbox_bootstrap_checkout: bootstrap.sh ran but $SANDBOX_TEMPERLOOP is not executable" >&2; return 1; }
}

# =============================================================================
# INTEGRITY LAYER (temperloop#266, "sandbox-integrity") — see the header doc
# block above for the public contract of each function below.
# =============================================================================

# ---------------------------------------------------------------------------
# _sandbox_sha256 <file>  (internal)
#
# Portable sha256 of a single regular file — prefers GNU coreutils
# sha256sum, falls back to BSD/macOS shasum -a 256 (same binary shasum(1)
# also ships on Linux, but sha256sum is the more common default there).
# ---------------------------------------------------------------------------
_sandbox_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# ---------------------------------------------------------------------------
sandbox_preflight_links() {
  local foundation="${1:?sandbox_preflight_links: foundation repo root required}"
  local links_lib="${2:-$foundation/workflows/scripts/install/links.sh}"
  : "${SANDBOX_ROOT:?sandbox_preflight_links: call sandbox_up first}"

  if [[ ! -f "$links_lib" ]]; then
    echo "sandbox_preflight_links: links lib not found: $links_lib" >&2
    return 1
  fi

  local out
  # shellcheck disable=SC2016  # deliberately single-quoted: $1/$2 must
  # expand inside the sandboxed bash -c subprocess (as its own positional
  # params), never in this caller shell — same idiom sandbox_bash documents.
  out="$(sandbox_run bash -c '
    # shellcheck disable=SC1090  # dynamic path, resolved by the caller
    source "$1"
    links_enumerate "$2"
  ' sandbox-preflight-links "$links_lib" "$foundation")" || {
    echo "sandbox_preflight_links: links_enumerate failed" >&2
    return 1
  }

  local target kind bad=0
  local src  # 3rd tab field — deliberately unused, only target/kind matter
  # shellcheck disable=SC2034  # see comment above: src is read but unused.
  while IFS=$'\t' read -r target kind src; do
    [[ -n "$target" ]] || continue
    case "$target" in
      "$SANDBOX_ROOT"/*) : ;;
      *)
        echo "sandbox_preflight_links: target escapes sandbox root: $target (kind=$kind)" >&2
        bad=1
        ;;
    esac
  done <<<"$out"

  return "$bad"
}

# ---------------------------------------------------------------------------
sandbox_tree_manifest() {
  local root="${1:?sandbox_tree_manifest: root path required}"

  if [[ ! -e "$root" && ! -L "$root" ]]; then
    printf '.\tabsent\t\n'
    return 0
  fi
  if [[ -L "$root" ]]; then
    printf '.\tsymlink\t%s\n' "$(readlink "$root")"
    return 0
  fi
  if [[ -f "$root" ]]; then
    printf '.\tfile\t%s\n' "$(_sandbox_sha256 "$root")"
    return 0
  fi

  # Directory: walk with plain `find` (never -L — a symlinked subdir is
  # recorded as a symlink record, never descended into) and emit one record
  # per file/symlink, sorted by relpath for a stable, diffable manifest.
  local entry relpath
  local lines=()
  while IFS= read -r entry; do
    relpath="${entry#"$root"/}"
    if [[ -L "$entry" ]]; then
      lines+=("$(printf '%s\tsymlink\t%s' "$relpath" "$(readlink "$entry")")")
    elif [[ -f "$entry" ]]; then
      lines+=("$(printf '%s\tfile\t%s' "$relpath" "$(_sandbox_sha256 "$entry")")")
    fi
  done < <(find "$root" \( -type f -o -type l \) | LC_ALL=C sort)

  if [[ ${#lines[@]} -gt 0 ]]; then
    printf '%s\n' "${lines[@]}"
  fi
}

# ---------------------------------------------------------------------------
# _sandbox_tree_diff_filter <manifest_path> <patterns>  (internal)
#
# Prints <manifest_path>'s records, dropping any whose relpath (field 1)
# case-matches a pattern in the whitespace/newline-separated <patterns>
# list, re-sorted by relpath so two independently-generated manifests
# compare stably regardless of walk order.
# ---------------------------------------------------------------------------
_sandbox_tree_diff_filter() {
  local manifest_path="$1" patterns="$2"
  local relpath type hash pat excluded

  while IFS=$'\t' read -r relpath type hash; do
    [[ -n "$relpath" ]] || continue
    excluded=0
    if [[ -n "$patterns" ]]; then
      # shellcheck disable=SC2086  # intentional word-splitting: <patterns>
      # is a caller-supplied space/newline-separated list of glob patterns.
      for pat in $patterns; do
        # shellcheck disable=SC2254  # deliberately unquoted: $pat is a glob
        # pattern here, not a literal — quoting would break exclusion
        # matching (the whole point of this caller-supplied pattern list).
        case "$relpath" in
          $pat) excluded=1; break ;;
        esac
      done
    fi
    [[ "$excluded" -eq 1 ]] && continue
    printf '%s\t%s\t%s\n' "$relpath" "$type" "$hash"
  done < "$manifest_path" | LC_ALL=C sort -t "$(printf '\t')" -k1,1
}

# ---------------------------------------------------------------------------
sandbox_tree_diff() {
  local manifest_a="${1:?sandbox_tree_diff: manifest A required}"
  local manifest_b="${2:?sandbox_tree_diff: manifest B required}"
  local exclude_arg="${3:-}"

  [[ -f "$manifest_a" ]] || { echo "sandbox_tree_diff: manifest A not found: $manifest_a" >&2; return 2; }
  [[ -f "$manifest_b" ]] || { echo "sandbox_tree_diff: manifest B not found: $manifest_b" >&2; return 2; }

  local exclude_list=""
  if [[ -n "$exclude_arg" ]]; then
    if [[ -f "$exclude_arg" ]]; then
      exclude_list="$(grep -v '^[[:space:]]*#' "$exclude_arg" 2>/dev/null | grep -v '^[[:space:]]*$')"
    else
      exclude_list="$exclude_arg"
    fi
  fi

  local filtered_a filtered_b
  filtered_a="$(_sandbox_tree_diff_filter "$manifest_a" "$exclude_list")"
  filtered_b="$(_sandbox_tree_diff_filter "$manifest_b" "$exclude_list")"

  if [[ "$filtered_a" == "$filtered_b" ]]; then
    return 0
  fi

  echo "sandbox_tree_diff: manifests differ (after exclusions):" >&2
  diff -u <(printf '%s\n' "$filtered_a") <(printf '%s\n' "$filtered_b") >&2
  return 1
}

# ---------------------------------------------------------------------------
sandbox_tripwire_snapshot() {
  : "${SANDBOX_ROOT:?sandbox_tripwire_snapshot: call sandbox_up first}"
  local label="${1:?sandbox_tripwire_snapshot: label required}"
  shift
  local paths=("$@")
  if [[ ${#paths[@]} -eq 0 ]]; then
    paths=("$HOME/.claude" "$HOME/.local/bin/temperloop")
  fi

  local dir="$SANDBOX_ROOT/tripwire/$label"
  mkdir -p "$dir"
  : > "$dir/paths.list"

  local i=0 p
  for p in "${paths[@]}"; do
    printf '%s\n' "$p" >> "$dir/paths.list"
    sandbox_tree_manifest "$p" > "$dir/$i.manifest"
    i=$((i + 1))
  done
}

# ---------------------------------------------------------------------------
sandbox_tripwire_check() {
  : "${SANDBOX_ROOT:?sandbox_tripwire_check: call sandbox_up first}"
  local label="${1:?sandbox_tripwire_check: label required}"
  local dir="$SANDBOX_ROOT/tripwire/$label"

  if [[ ! -f "$dir/paths.list" ]]; then
    echo "sandbox_tripwire_check: no snapshot found for label '$label' (call sandbox_tripwire_snapshot first)" >&2
    return 2
  fi

  local i=0 p bad=0 after
  while IFS= read -r p; do
    [[ -n "$p" ]] || { i=$((i + 1)); continue; }
    after="$dir/$i.after.manifest"
    sandbox_tree_manifest "$p" > "$after"
    if ! sandbox_tree_diff "$dir/$i.manifest" "$after"; then
      echo "sandbox_tripwire_check: drift detected under real path: $p" >&2
      bad=1
    fi
    i=$((i + 1))
  done < "$dir/paths.list"

  return "$bad"
}

# =============================================================================
# RESIDUE GUARD (temperloop#1154) — the real-HOME no-residue tripwire that
# workflows/scripts/tests/lib/tests/test_sandbox.sh (test 5) and
# workflows/scripts/tests/test_sandbox_dry_run_legs.sh (test 5) both assert
# with. HOISTED here from those two files, where it existed as two verbatim
# copies whose COMMENTS had already drifted apart — #377 fixed the bm-prune
# flake in one and #382 had to chase the identical bug in the other. One
# definition, so the next contract change is made once.
#
#   sandbox_real_candidates [real_home]
#     Populates SANDBOX_REAL_CANDIDATES[] with the real-HOME paths a REAL
#     (unsandboxed) bin/bootstrap.sh + init.sh + eject.sh run would write to
#     if HOME/XDG_* were not re-pointed. Defaults real_home to $HOME — pass
#     an explicit root to build a SYNTHETIC candidate set (what
#     test_sandbox.sh test 6 does, so a deliberate-leak meta-test can prove
#     the guard still fires without writing to the operator's actual HOME).
#
#   sandbox_snapshot_path <path>
#     "absent", or "present:<n>" where <n> is a portable file-count
#     fingerprint (no stat flags; works on both BSD/macOS and GNU find).
#
#   sandbox_snapshot_real_candidates
#     Fills SANDBOX_REAL_SNAPS[] with sandbox_snapshot_path of every entry in
#     SANDBOX_REAL_CANDIDATES[]. Call BEFORE the sandboxed run.
#
#   sandbox_diff_real_candidates
#     Re-snapshots the same entries and compares against SANDBOX_REAL_SNAPS[].
#     Returns 0 iff every one is unchanged; otherwise prints the single
#     canonical drift message to STDOUT (so a caller can splice it into its
#     own `fail`) and returns 1. Call AFTER the sandboxed run.
#
#   sandbox_cache_interferer_start / _count / _stop
#     A CONTINUOUS third-party writer against the resolved REAL cache store
#     root — the concurrency this guard must be immune to, made active
#     rather than assumed. See those functions' own comments.
# =============================================================================

# ---------------------------------------------------------------------------
sandbox_real_candidates() {
  local real_home="${1:-$HOME}"
  # The two legacy `foundation`-named entries stay in the tripwire
  # deliberately: the temperloop#165 window closed in v0.19.0, so NOTHING
  # should write them any more, and that is precisely what makes them worth
  # asserting.
  #
  # $real_home/.cache/temperloop is DELIBERATELY ABSENT (temperloop#1154).
  # Two independent reasons, and the first is what makes the second safe:
  #   (a) its leak vector is CLOSED at the source — CACHE_STORE_ROOT is now
  #       pinned inside $SANDBOX_ROOT by sandbox_env (see _sandbox_pin), and
  #       that redirect is asserted positively by test_sandbox.sh test 6.
  #       Sampling the real root is no longer the thing standing between a
  #       sandboxed run and the operator's cache;
  #   (b) it is SHARED MUTABLE STATE. Any concurrent board-adapter process
  #       (board.sh's cross-process cache, cache-store reads/writes) writes
  #       that root at will, from outside this test's process tree. A
  #       count-sampled shared path cannot attribute a delta to the
  #       sandboxed run, so keeping it could only ever add third-party
  #       noise — the same flake class #377/#382 removed for the
  #       basic-memory store, arriving here by a different door.
  # The removal is safe BECAUSE OF (a); (b) alone would not justify
  # deleting a working leak detector.
  SANDBOX_REAL_CANDIDATES=(
    "$real_home/.local/share/temperloop"
    "$real_home/.local/bin/temperloop"
    "$real_home/.local/bin/foundation"
    "$real_home/.config/foundation"
    "$real_home/.local/state/foundation"
  )
}

# ---------------------------------------------------------------------------
sandbox_snapshot_path() {
  # The basic-memory knowledge store (F#946) lives under
  # ~/.local/state/foundation/{basic-memory-home,bm-*} and is LIVE,
  # concurrently written runtime state — churned on-demand by ks_search /
  # the CLAUDE.kernel.md § Phase-1 parity `bm` leg from any other session or
  # hook, with hundreds of files created inside a single test window. It is
  # NOT the bootstrap residue this guard looks for, so counting it makes the
  # no-residue assertion flake on unrelated concurrent bm activity
  # (temperloop#377, and #382 for the second copy this hoist retires).
  # Prune the bm subtrees:
  #   - by directory NAME — the bm dirs only ever appear under
  #     .local/state/foundation, so a global name-prune cannot hide
  #     bootstrap residue leaked into any other candidate path;
  #   - via -prune, so the 400k+-file store is never descended (fast, and
  #     the count stays a leak-detector, not a store-size measurement).
  local p="$1"
  if [ -e "$p" ]; then
    printf 'present:%s' "$(find "$p" \( -name basic-memory-home -o -name 'bm-*' \) -prune -o -print 2>/dev/null | wc -l | tr -d ' ')"
  else
    printf 'absent'
  fi
}

# ---------------------------------------------------------------------------
sandbox_snapshot_real_candidates() {
  : "${SANDBOX_REAL_CANDIDATES:?sandbox_snapshot_real_candidates: call sandbox_real_candidates first}"
  local p
  SANDBOX_REAL_SNAPS=()
  for p in "${SANDBOX_REAL_CANDIDATES[@]}"; do
    SANDBOX_REAL_SNAPS+=("$(sandbox_snapshot_path "$p")")
  done
}

# ---------------------------------------------------------------------------
sandbox_diff_real_candidates() {
  : "${SANDBOX_REAL_CANDIDATES:?sandbox_diff_real_candidates: call sandbox_real_candidates first}"
  local i=0 p after bad=0
  for p in "${SANDBOX_REAL_CANDIDATES[@]}"; do
    after="$(sandbox_snapshot_path "$p")"
    if [ "$after" != "${SANDBOX_REAL_SNAPS[$i]}" ]; then
      printf 'real-HOME path changed during a sandboxed run: %s (before: %s, after: %s)\n' \
        "$p" "${SANDBOX_REAL_SNAPS[$i]}" "$after"
      bad=1
    fi
    i=$((i + 1))
  done
  return "$bad"
}

# ---------------------------------------------------------------------------
# sandbox_cache_interferer_start (temperloop#1154)
#
# Backgrounds a CONTINUOUS writer against the resolved REAL cache store root
# — `${CACHE_STORE_ROOT:-${XDG_CACHE_HOME:-$HOME/.cache}/temperloop}`
# evaluated in the CALLER's (unsandboxed) environment, i.e. the exact
# expression links.sh / uninstall.sh / eject.sh / deploy-mini.sh resolve.
#
# WHY a live writer rather than a comment: dropping the real cache root from
# SANDBOX_REAL_CANDIDATES makes the no-residue assertion immune to concurrent
# third-party cache writes — but a leg that merely ASSERTS the paths are
# unchanged, with nothing writing, passes VACUOUSLY and would keep passing if
# the path were silently re-added. An active interferer is what makes the
# assertion capable of observing an interferer.
#
# Each iteration creates a NEW uniquely-named marker file, because the
# fingerprint sandbox_snapshot_path takes is a file COUNT — re-touching one
# file would not move it. Markers are namespaced by pid so a concurrent run
# of the sibling suite cleans up only its own.
#
# The 0.1s pause is a CPU courtesy only: this loop stays alive across a
# whole bootstrap+dispatch cycle, and a bare spin would peg a core for the
# duration without making the leg any stronger.
# ---------------------------------------------------------------------------
sandbox_cache_interferer_start() {
  SANDBOX_CACHE_INTERFERER_ROOT="${CACHE_STORE_ROOT:-${XDG_CACHE_HOME:-$HOME/.cache}/temperloop}"
  SANDBOX_CACHE_INTERFERER_TAG="$$"
  SANDBOX_CACHE_INTERFERER_CREATED_ROOT=0
  SANDBOX_CACHE_INTERFERER_PID=""

  if [ ! -d "$SANDBOX_CACHE_INTERFERER_ROOT" ]; then
    mkdir -p "$SANDBOX_CACHE_INTERFERER_ROOT" 2>/dev/null || {
      echo "sandbox_cache_interferer_start: could not create $SANDBOX_CACHE_INTERFERER_ROOT" >&2
      return 1
    }
    SANDBOX_CACHE_INTERFERER_CREATED_ROOT=1
  fi

  (
    n=0
    while :; do
      : > "$SANDBOX_CACHE_INTERFERER_ROOT/.sandbox-interferer-$SANDBOX_CACHE_INTERFERER_TAG-$n" 2>/dev/null || true
      n=$((n + 1))
      sleep 0.1
    done
  ) &
  SANDBOX_CACHE_INTERFERER_PID=$!
}

# ---------------------------------------------------------------------------
# sandbox_cache_interferer_count — how many marker files this run's
# interferer has laid down so far. A caller asserts this is non-trivial
# BEFORE stopping (stop deletes them), which is what proves the leg is not
# vacuous: the interferer really did write the real cache root, concurrently,
# during the assertion window.
# ---------------------------------------------------------------------------
sandbox_cache_interferer_count() {
  [ -n "${SANDBOX_CACHE_INTERFERER_ROOT:-}" ] || { printf '0'; return 0; }
  find "$SANDBOX_CACHE_INTERFERER_ROOT" -maxdepth 1 \
    -name ".sandbox-interferer-$SANDBOX_CACHE_INTERFERER_TAG-*" 2>/dev/null | wc -l | tr -d ' '
}

# ---------------------------------------------------------------------------
# sandbox_cache_interferer_stop — kill the writer and remove exactly what it
# created (its own pid-namespaced markers, plus the root itself only if this
# run created it). Idempotent, and safe to wire onto an EXIT trap so an
# aborting suite never leaves a spinner or a marker behind.
# ---------------------------------------------------------------------------
sandbox_cache_interferer_stop() {
  [ -n "${SANDBOX_CACHE_INTERFERER_PID:-}" ] || return 0
  kill "$SANDBOX_CACHE_INTERFERER_PID" 2>/dev/null || true
  wait "$SANDBOX_CACHE_INTERFERER_PID" 2>/dev/null || true
  SANDBOX_CACHE_INTERFERER_PID=""
  rm -f "$SANDBOX_CACHE_INTERFERER_ROOT"/.sandbox-interferer-"$SANDBOX_CACHE_INTERFERER_TAG"-* 2>/dev/null || true
  if [ "${SANDBOX_CACHE_INTERFERER_CREATED_ROOT:-0}" = "1" ]; then
    rmdir "$SANDBOX_CACHE_INTERFERER_ROOT" 2>/dev/null || true
    SANDBOX_CACHE_INTERFERER_CREATED_ROOT=0
  fi
}
