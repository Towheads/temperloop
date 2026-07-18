#!/usr/bin/env bash
#
# knowledge_sync.sh — EXPERIMENTAL thin operator entry over the knowledge
# store's OPTIONAL sync capability (ks_sync — temperloop#430, ADR 0003), so
# an operator can run a manual sync without hand-sourcing the lib:
#
#   workflows/scripts/lib/knowledge_sync.sh init <remote-url>
#   workflows/scripts/lib/knowledge_sync.sh push [-m <msg>]
#   workflows/scripts/lib/knowledge_sync.sh pull
#   workflows/scripts/lib/knowledge_sync.sh status
#
# DELIBERATELY NOT a `bin/temperloop` subcommand and NOT listed in the
# stranger-facing CLI reference (bin/README.md / the generated docs-site
# command reference): whether this surface is promoted to a first-class
# `temperloop sync` subcommand is a decision this thin entry keeps OPEN —
# adding it to the CLI reference now would freeze a contract surface
# (VERSIONING.md § CLI surface) around an experimental capability.
#
# Scope limits (see knowledge_store.contract.md § Sync):
#   - EXPERIMENTAL; single-writer assumption; no conflict story beyond
#     git's own (`pull` is --ff-only and fails loud on divergence).
#   - Single-tenant per $HOME: one flat store root, one remote.
#     Per-project partition is deferred — temperloop#418.
#   - MANUAL invocation only. Never wire this into launchd/cron/a hook —
#     sync is an operator action, like `git push` itself.
#   - The remote should be PRIVATE by default (the store is personal
#     working notes). Worked example:
#       gh repo create <owner>/knowledge-store --private
#       workflows/scripts/lib/knowledge_sync.sh init \
#         git@github.com:<owner>/knowledge-store.git
#
# Exit codes are ks_sync's own (0 ok / 2 usage / 3 skipped-unavailable /
# 4 sync-operation failure), passed through untouched.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

usage() {
  cat <<'USAGE'
usage: knowledge_sync.sh <init <remote-url> | push [-m <msg>] | pull | status>

EXPERIMENTAL manual git-backed sync for the knowledge store's plain-files
backend (exit 3 "skipped — sync unavailable for backend <name>" on a
backend that cannot implement it, e.g. obsidian). Single-tenant per $HOME
(per-project partition deferred: temperloop#418). Manual-only — never run
this from a scheduled or background job. Point it at a PRIVATE remote:

  gh repo create <owner>/knowledge-store --private
  knowledge_sync.sh init git@github.com:<owner>/knowledge-store.git
USAGE
}

case "${1:-}" in
  -h|--help|help)
    usage
    exit 0
    ;;
esac

# shellcheck source=workflows/scripts/lib/knowledge_store.sh
source "$HERE/knowledge_store.sh"

ks_sync "$@"
