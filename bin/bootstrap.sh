#!/bin/sh
# bootstrap.sh — one-line installer for the `temperloop` CLI (foundation
# #765 Epic D "newcomer experience", item cli-entrypoint-bootstrap / #849;
# renamed from `foundation` to `temperloop` in foundation #893 — see
# Decisions/foundation - Kernel public name TemperLoop).
#
# POSIX /bin/sh on purpose (not bash) — this is the script a `curl | sh`
# one-liner runs, and `sh` is the one shell guaranteed present. It has no
# dependency on the rest of this repo: it only needs `git` and a POSIX
# shell, both already on the machine.
#
# INSPECT FIRST (recommended) — read it before you run it:
#
#   curl -fsSL https://raw.githubusercontent.com/Towheads/temperloop/main/bin/bootstrap.sh -o temperloop-bootstrap.sh  # denylist:allow — the kernel repo's own public URL (its identity, like board.sh's board 7 entry)
#   less temperloop-bootstrap.sh   # read what it actually does
#   sh temperloop-bootstrap.sh
#
# ONE-LINE, once you trust the source:
#
#   curl -fsSL https://raw.githubusercontent.com/Towheads/temperloop/main/bin/bootstrap.sh | sh  # denylist:allow — same rationale as above
#
# WHAT THIS SCRIPT DOES, IN ORDER — nothing else. No shell-rc edits, no
# sudo, no writes outside the two paths below:
#   1. Shallow-clones (or, on re-run, fast-forward-updates in place) the
#      public temperloop repo into $TEMPERLOOP_HOME.
#   2. Symlinks $TEMPERLOOP_HOME/bin/temperloop onto
#      $TEMPERLOOP_BIN_DIR/temperloop — and, so an existing `foundation
#      <sub>` caller keeps working through the rename window, also symlinks
#      the checkout's kernel/bin/foundation compat shim onto
#      $TEMPERLOOP_BIN_DIR/foundation (the shim is removed in v0.17.0).
#   3. Prints a PATH reminder if $TEMPERLOOP_BIN_DIR isn't on it already.
#
# ENV KNOBS + RENAME WINDOW (temperloop#165, v0.15.0): TEMPERLOOP_KERNEL_REPO,
# TEMPERLOOP_HOME, and TEMPERLOOP_BIN_DIR are the canonical override names,
# renamed from the pre-rename FOUNDATION_* prefix. Read-old-write-new: a
# legacy FOUNDATION_* var still works while its TEMPERLOOP_* twin is unset
# (precedence: new > old > built-in default) and prints a one-line
# deprecation notice; the legacy names are removed in v0.17.0 (VERSIONING.md
# pre-1.0 bump rules; the v0.15.0 CHANGELOG BREAKING entry carries the
# migration note).
#
# UNINSTALL: remove $TEMPERLOOP_BIN_DIR/temperloop, $TEMPERLOOP_BIN_DIR/foundation,
# and $TEMPERLOOP_HOME — `temperloop eject` documents removal of anything
# ELSE the CLI wrote to a target repo it was pointed at; this bootstrap's
# own footprint is exactly those three paths, nothing more.
#
# NOTE for maintainers: the two default paths below are also stated in
# kernel/bin/lib/common.sh (FOUNDATION_CLI_HOME_DEFAULT /
# FOUNDATION_CLI_BIN_DEFAULT) and kernel/bin/README.md. This script runs
# BEFORE any of that repo exists on disk, so it cannot source or read
# either — keep all three literal values in sync by hand if either default
# ever changes.
set -eu

# --- legacy FOUNDATION_* env-var fallback window (removed in v0.17.0) ------
# TEMPERLOOP_LEGACY_WINDOW_CLOSED is a TEST/SIMULATION-ONLY seam (never set
# in production use; same registry-exempt status as BUILD_QUOTA_NOW): =1
# simulates the post-v0.17.0 removal so the legible failure below stays
# testable before the removal release ships.
_tl_legacy_notice() {
  # $1 = legacy var name (set in the caller's environment), $2 = new name
  if [ "${TEMPERLOOP_LEGACY_WINDOW_CLOSED:-0}" = "1" ]; then # knob:exempt — test/simulation-only seam
    echo "bootstrap: ERROR — \$$1 is no longer read: it was renamed \$$2 in v0.15.0 and the legacy name was removed in v0.17.0. Set \$$2 and re-run." >&2
    exit 1
  fi
  echo "bootstrap: NOTE — \$$1 is deprecated: renamed \$$2 in v0.15.0; the legacy name still works but is removed in v0.17.0. Set \$$2 instead." >&2
}
if [ -z "${TEMPERLOOP_KERNEL_REPO+x}" ] && [ -n "${FOUNDATION_KERNEL_REPO+x}" ]; then
  _tl_legacy_notice FOUNDATION_KERNEL_REPO TEMPERLOOP_KERNEL_REPO
fi
if [ -z "${TEMPERLOOP_HOME+x}" ] && [ -n "${FOUNDATION_HOME+x}" ]; then
  _tl_legacy_notice FOUNDATION_HOME TEMPERLOOP_HOME
fi
if [ -z "${TEMPERLOOP_BIN_DIR+x}" ] && [ -n "${FOUNDATION_BIN_DIR+x}" ]; then
  _tl_legacy_notice FOUNDATION_BIN_DIR TEMPERLOOP_BIN_DIR
fi

TEMPERLOOP_KERNEL_REPO="${TEMPERLOOP_KERNEL_REPO:-${FOUNDATION_KERNEL_REPO:-https://github.com/Towheads/temperloop.git}}"  # denylist:allow — the kernel repo's own clone URL is this script's load-bearing default (override via TEMPERLOOP_KERNEL_REPO); the repo's identity, not a personal-token leak
TEMPERLOOP_HOME="${TEMPERLOOP_HOME:-${FOUNDATION_HOME:-$HOME/.local/share/temperloop}}"
TEMPERLOOP_BIN_DIR="${TEMPERLOOP_BIN_DIR:-${FOUNDATION_BIN_DIR:-$HOME/.local/bin}}"

if ! command -v git >/dev/null 2>&1; then
  echo "bootstrap: 'git' not found on PATH — install git and re-run." >&2
  exit 1
fi

if [ -d "$TEMPERLOOP_HOME/.git" ]; then
  echo "bootstrap: $TEMPERLOOP_HOME already exists — updating in place..."
  git -C "$TEMPERLOOP_HOME" pull --ff-only
else
  echo "bootstrap: cloning $TEMPERLOOP_KERNEL_REPO -> $TEMPERLOOP_HOME ..."
  git clone --depth 1 "$TEMPERLOOP_KERNEL_REPO" "$TEMPERLOOP_HOME"
fi

if [ ! -f "$TEMPERLOOP_HOME/bin/temperloop" ]; then
  echo "bootstrap: $TEMPERLOOP_HOME/bin/temperloop not found after clone — the" >&2
  echo "  repo layout may have changed; nothing was symlinked onto your PATH." >&2
  exit 1
fi

mkdir -p "$TEMPERLOOP_BIN_DIR"
chmod +x "$TEMPERLOOP_HOME/bin/temperloop"
ln -sf "$TEMPERLOOP_HOME/bin/temperloop" "$TEMPERLOOP_BIN_DIR/temperloop"
echo "bootstrap: installed -> $TEMPERLOOP_BIN_DIR/temperloop (-> $TEMPERLOOP_HOME/bin/temperloop)"

# Compat: also put the `foundation` shim on PATH (kernel/bin/foundation
# execs temperloop) so an existing `foundation <sub>` caller — a script, a
# shell alias, muscle memory — keeps working after a fresh install too.
# Windowed with the rest of the rename (temperloop#165): the shim prints a
# one-line deprecation notice per invocation and is removed in v0.17.0.
if [ -f "$TEMPERLOOP_HOME/bin/foundation" ]; then
  chmod +x "$TEMPERLOOP_HOME/bin/foundation"
  ln -sf "$TEMPERLOOP_HOME/bin/foundation" "$TEMPERLOOP_BIN_DIR/foundation"
  echo "bootstrap: installed -> $TEMPERLOOP_BIN_DIR/foundation (compat shim -> $TEMPERLOOP_HOME/bin/foundation; deprecated, removed in v0.17.0)"
fi

case ":$PATH:" in
  *":$TEMPERLOOP_BIN_DIR:"*)
    ;;
  *)
    echo "bootstrap: NOTE — $TEMPERLOOP_BIN_DIR is not on your PATH. Add, e.g.:"
    echo "    export PATH=\"$TEMPERLOOP_BIN_DIR:\$PATH\""
    echo "  to your shell profile, then open a new shell."
    ;;
esac

echo "bootstrap: done. Next: temperloop help"
