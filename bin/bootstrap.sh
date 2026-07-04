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
#      public temperloop repo into $FOUNDATION_HOME.
#   2. Symlinks $FOUNDATION_HOME/bin/temperloop onto
#      $FOUNDATION_BIN_DIR/temperloop — and, so an existing `foundation
#      <sub>` caller keeps working, also symlinks the checkout's
#      kernel/bin/foundation compat shim onto $FOUNDATION_BIN_DIR/foundation.
#   3. Prints a PATH reminder if $FOUNDATION_BIN_DIR isn't on it already.
#
# UNINSTALL: remove $FOUNDATION_BIN_DIR/temperloop, $FOUNDATION_BIN_DIR/foundation,
# and $FOUNDATION_HOME — `foundation eject` documents removal of anything
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

FOUNDATION_KERNEL_REPO="${FOUNDATION_KERNEL_REPO:-https://github.com/Towheads/temperloop.git}"  # denylist:allow — the kernel repo's own clone URL is this script's load-bearing default (override via FOUNDATION_KERNEL_REPO); the repo's identity, not a personal-token leak
FOUNDATION_HOME="${FOUNDATION_HOME:-$HOME/.local/share/temperloop}"
FOUNDATION_BIN_DIR="${FOUNDATION_BIN_DIR:-$HOME/.local/bin}"

if ! command -v git >/dev/null 2>&1; then
  echo "bootstrap: 'git' not found on PATH — install git and re-run." >&2
  exit 1
fi

if [ -d "$FOUNDATION_HOME/.git" ]; then
  echo "bootstrap: $FOUNDATION_HOME already exists — updating in place..."
  git -C "$FOUNDATION_HOME" pull --ff-only
else
  echo "bootstrap: cloning $FOUNDATION_KERNEL_REPO -> $FOUNDATION_HOME ..."
  git clone --depth 1 "$FOUNDATION_KERNEL_REPO" "$FOUNDATION_HOME"
fi

if [ ! -f "$FOUNDATION_HOME/bin/temperloop" ]; then
  echo "bootstrap: $FOUNDATION_HOME/bin/temperloop not found after clone — the" >&2
  echo "  repo layout may have changed; nothing was symlinked onto your PATH." >&2
  exit 1
fi

mkdir -p "$FOUNDATION_BIN_DIR"
chmod +x "$FOUNDATION_HOME/bin/temperloop"
ln -sf "$FOUNDATION_HOME/bin/temperloop" "$FOUNDATION_BIN_DIR/temperloop"
echo "bootstrap: installed -> $FOUNDATION_BIN_DIR/temperloop (-> $FOUNDATION_HOME/bin/temperloop)"

# Compat: also put the `foundation` shim on PATH (kernel/bin/foundation
# execs temperloop) so an existing `foundation <sub>` caller — a script, a
# shell alias, muscle memory — keeps working after a fresh install too.
if [ -f "$FOUNDATION_HOME/bin/foundation" ]; then
  chmod +x "$FOUNDATION_HOME/bin/foundation"
  ln -sf "$FOUNDATION_HOME/bin/foundation" "$FOUNDATION_BIN_DIR/foundation"
  echo "bootstrap: installed -> $FOUNDATION_BIN_DIR/foundation (compat shim -> $FOUNDATION_HOME/bin/foundation)"
fi

case ":$PATH:" in
  *":$FOUNDATION_BIN_DIR:"*)
    ;;
  *)
    echo "bootstrap: NOTE — $FOUNDATION_BIN_DIR is not on your PATH. Add, e.g.:"
    echo "    export PATH=\"$FOUNDATION_BIN_DIR:\$PATH\""
    echo "  to your shell profile, then open a new shell."
    ;;
esac

echo "bootstrap: done. Next: temperloop help"
