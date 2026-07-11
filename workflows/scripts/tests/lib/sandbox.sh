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
# This is the SAME fake-gh + throwaway-tree idiom
# bin/subcommands/tests/test_init.sh and test_eject.sh already use for their
# own fixtures — EXTRACTED here verbatim (subtraction over mechanism, see
# CLAUDE.md § Design discipline) so this item's own dry-run-legs test (and
# any FUTURE install-surface test) doesn't reinvent a third copy. Those two
# existing suites are deliberately left as-is (their own inline fixtures
# keep working); a follow-up may migrate them onto this lib, but that is not
# this item's scope.
#
# OUT OF SCOPE (a separate follow-up item, "sandbox-integrity" — see this
# item's own NOTE): a write-preflight, a drift tripwire, or a tree-diff
# helper. This file's functions are named/shaped so those can be added as
# new sandbox_* functions later without reshaping what already exists here.
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
#     else in this file. Sets the SANDBOX_* globals documented below.
#
#   sandbox_down
#     rm -rf the throwaway root. Safe to call even if sandbox_up was never
#     called (no-op).
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
#     Installs a minimal logging no-op fake `claude` at $SANDBOX_BIN/claude
#     — needed only because bin/temperloop's dispatcher prereq gate
#     (bin/lib/common.sh: foundation_check_prereqs) requires `claude` on
#     PATH before dispatching ANY subcommand; init.sh/eject.sh never invoke
#     it themselves. call_log default: $SANDBOX_ROOT/claude-calls.log,
#     exposed as SANDBOX_CLAUDE_CALL_LOG.
#
#   sandbox_bootstrap_checkout <source_repo_dir>
#     Bare-clones <source_repo_dir> (at whatever it currently has committed
#     — this is a `git clone --bare`, so uncommitted worktree changes are
#     never included, matching this repo's own "commit first, then gates"
#     discipline) into the sandbox, then runs *that source checkout's own*
#     bin/bootstrap.sh against the clone over a file:// remote
#     (FOUNDATION_KERNEL_REPO=file://<bare-clone-path>) — the hermetic
#     stand-in for the curl-pipe-sh newcomer install bin/bootstrap.sh's own
#     header documents. Runs with the sandbox env (HOME/XDG_* re-pointed),
#     so bootstrap.sh's own $HOME-relative defaults
#     (FOUNDATION_HOME=$HOME/.local/share/temperloop,
#     FOUNDATION_BIN_DIR=$HOME/.local/bin) resolve inside the sandbox with
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
#
# Additional globals set by other functions:
#   SANDBOX_GH_CALL_LOG         set by sandbox_stub_gh
#   SANDBOX_CLAUDE_CALL_LOG     set by sandbox_stub_claude
#   SANDBOX_TEMPERLOOP           set by sandbox_bootstrap_checkout on success
#
# shellcheck shell=bash

# Guard against double-sourcing (same idiom as workflows/scripts/install/links.sh).
if [[ "${_SANDBOX_SH_LOADED:-}" == "1" ]]; then
  return 0
fi
_SANDBOX_SH_LOADED=1

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
  mkdir -p \
    "$SANDBOX_HOME" \
    "$SANDBOX_XDG_CONFIG_HOME" \
    "$SANDBOX_XDG_STATE_HOME" \
    "$SANDBOX_XDG_DATA_HOME" \
    "$SANDBOX_XDG_CACHE_HOME" \
    "$SANDBOX_BIN"
}

# ---------------------------------------------------------------------------
sandbox_down() {
  [[ -n "${SANDBOX_ROOT:-}" ]] || return 0
  rm -rf "$SANDBOX_ROOT"
}

# ---------------------------------------------------------------------------
sandbox_env() {
  : "${SANDBOX_ROOT:?sandbox_env: call sandbox_up first}"
  SANDBOX_ENV_ARGS=(
    "HOME=$SANDBOX_HOME"
    "XDG_CONFIG_HOME=$SANDBOX_XDG_CONFIG_HOME"
    "XDG_STATE_HOME=$SANDBOX_XDG_STATE_HOME"
    "XDG_DATA_HOME=$SANDBOX_XDG_DATA_HOME"
    "XDG_CACHE_HOME=$SANDBOX_XDG_CACHE_HOME"
    "PATH=$SANDBOX_BIN:$PATH"
  )
  if [[ -n "${SANDBOX_GH_CALL_LOG:-}" ]]; then
    SANDBOX_ENV_ARGS+=("CALL_LOG=$SANDBOX_GH_CALL_LOG")
  fi
  if [[ -n "${SANDBOX_CLAUDE_CALL_LOG:-}" ]]; then
    SANDBOX_ENV_ARGS+=("CLAUDE_CALL_LOG=$SANDBOX_CLAUDE_CALL_LOG")
  fi
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
# Minimal no-op stand-in — only needed so bin/temperloop's dispatcher
# prereq gate (bin/lib/common.sh: foundation_check_prereqs) finds `claude`
# on PATH before dispatching a subcommand; init.sh/eject.sh never invoke it
# themselves. $CLAUDE_CALL_LOG is injected by sandbox_env.
printf '%s\n' "$*" >> "$CLAUDE_CALL_LOG"
exit 0
FAKE_CLAUDE_EOF
  chmod +x "$SANDBOX_BIN/claude"
  SANDBOX_CLAUDE_CALL_LOG="$call_log"
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
      FOUNDATION_KERNEL_REPO="file://$upstream" \
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
