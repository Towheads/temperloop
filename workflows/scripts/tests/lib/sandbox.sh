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
# ---------------------------------------------------------------------------
# INTEGRITY LAYER — public functions (temperloop#266, "sandbox-integrity")
# ---------------------------------------------------------------------------
#
#   sandbox_preflight_links <foundation_root> [<links_lib_override>]
#     Write PREFLIGHT: sources links.sh (default
#     <foundation_root>/workflows/scripts/install/links.sh; pass an
#     alternate path as the 2nd arg — a test-double seam, not a knob) and
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
