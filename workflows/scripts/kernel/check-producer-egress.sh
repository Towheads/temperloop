#!/usr/bin/env bash
#
# check-producer-egress.sh — mechanical egress lint over Epic E's
# before/after value-loop producers (foundation #766, "privacy/egress audit
# over the Epic E value-loop surface" item).
#
# THE OPT-IN EGRESS SURFACE FOR THIS VALUE LOOP, DOCUMENTED HERE (the ONE
# place this is written down — see this item's own scope note; there is no
# separate doc tree for it):
#
#   EMPTY. As of this writing, every producer this check covers reads and
#   writes LOCAL FILES ONLY — `.foundation/baseline.jsonl`,
#   `.foundation/report.d/*`, `.foundation/.gitignore`, and the XDG
#   dismiss-marker under `${XDG_STATE_HOME:-$HOME/.local/state}/foundation/
#   report-offer-dismissed/` — with exactly ONE sanctioned exception:
#   `baseline-snapshot.sh`'s own `gh pr list` / `gh issue list` / `gh auth
#   status` calls (see baseline_snapshot.contract.md's header + "Consent
#   posture" section — those calls are aggregate-only by construction, no
#   per-author data is ever retained). `report.sh` never calls `gh` itself;
#   its `--refresh` flag only shells out to the sibling baseline-snapshot.sh,
#   which is the sole `gh`-calling process in the whole loop. Nothing else
#   in this value loop opens a network connection of any kind — no
#   telemetry beacon, no analytics ping, no third-party API call.
#
#   If a future producer or drop-in legitimately needs a new opt-in network
#   channel, it MUST be added to this list (updating this exact paragraph)
#   in the same change that adds it — not left for this check to discover
#   by accident. This check enforces the CURRENT (empty) surface; it is not
#   a general allowlist mechanism for future exceptions.
#
# WHAT THIS SCANS (the exact producers, named — not a whole-tree lint):
#   - $KERNEL_ROOT/bin/subcommands/baseline-snapshot.sh
#   - $KERNEL_ROOT/bin/subcommands/report.sh
#   - $KERNEL_ROOT/bin/foundation   (the dispatcher's 14-day report
#     auto-offer check, _foundation_check_report_offer — see that
#     function's own header comment in bin/foundation)
#   - every regular file directly inside $OVERLAY_REPORT_D, if that
#     directory is given and exists — the report.d/ drop-in seam's actual
#     overlay producers (foundation's own `tokens` / `interventions` /
#     `improvement` today). A glob, not a hardcoded name list, so a future
#     drop-in is covered automatically with zero maintenance here.
#
#   A missing file or absent overlay dir is a silent, legible skip — this
#   is a lint over whatever producers actually exist in the checkout it's
#   run from (a standalone kernel-only checkout has no
#   `.foundation/report.d/` of its own — see the OVERLAY_REPORT_D default
#   below), not a presence/coverage check (that is kernel-manifest's job).
#
# PATTERNS FLAGGED — network-call IDIOMS, deliberately not the bare word
# "http" or "network" (these files' own header comments discuss networking
# in prose — e.g. "no egress beyond gh itself" — which must not itself trip
# the check): curl, wget, nc/netcat, the bash `/dev/tcp/` + `/dev/udp/`
# raw-socket redirection idiom, ssh/scp/rsync/telnet/ftp, and the common
# Python egress idioms (urllib/requests/http.client imports, a
# requests.<verb>(...) call, a socket.socket/.connect/.create_connection
# call, urlopen(...)). `gh` itself is NEVER flagged — it is the one
# sanctioned channel documented above, not a violation.
#
# Usage:
#   check-producer-egress.sh [--kernel-root DIR] [--overlay-report-d DIR]
#   (called by `make test-producer-egress` — see kernel/Makefile for the
#   standalone-kernel-checkout invocation with no overlay dir, and
#   foundation's own root Makefile for the composed-tree invocation that
#   also passes --overlay-report-d so .foundation/report.d/'s real
#   drop-ins are covered there.)
#
# Env overrides (same effect as the matching flag above; flags win if both
# are given — a test seam, mirrors check-personal-token-denylist.sh's
# KERNEL_MANIFEST_ROOT convention):
#   CHECK_PRODUCER_EGRESS_KERNEL_ROOT   default: this script's own kernel/
#                                        subtree root ($SCRIPT_DIR/../../..)
#                                        — correct whether this file sits in
#                                        a standalone kernel-only checkout
#                                        or vendored at foundation/kernel/.
#   CHECK_PRODUCER_EGRESS_OVERLAY_DIR   default: unset (no overlay scanned).
#
# Exit codes: 0 = no egress-pattern hits (including "nothing found to
# scan" — a soft seam, same as the rest of this value loop's own
# scripts). 1 = at least one hit, printed as
# `<file>:<line>: [<description>] <matched line>`. 2 = invalid CLI usage.
#
# bash 3.2 compatible (no associative arrays, no `mapfile`).

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

: "${CHECK_PRODUCER_EGRESS_KERNEL_ROOT:=$(cd "$SCRIPT_DIR/../../.." && pwd)}"
: "${CHECK_PRODUCER_EGRESS_OVERLAY_DIR:=}"

kernel_root="$CHECK_PRODUCER_EGRESS_KERNEL_ROOT"
overlay_dir="$CHECK_PRODUCER_EGRESS_OVERLAY_DIR"

usage() {
  cat <<'EOF'
usage: check-producer-egress.sh [--kernel-root DIR] [--overlay-report-d DIR]
EOF
}

while [ $# -gt 0 ]; do
  case "$1" in
    --kernel-root) kernel_root="${2:?--kernel-root needs a value}"; shift 2 ;;
    --overlay-report-d) overlay_dir="${2:?--overlay-report-d needs a value}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "check-producer-egress.sh: unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

# ---------------------------------------------------------------------------
# Pattern set — parallel arrays (pattern, description), same shape as
# check-personal-token-denylist.sh's denylist loop. Small and fixed enough
# that an inline array is the right call (subtraction over mechanism) — no
# external pattern file needed for six named producers.
# ---------------------------------------------------------------------------
# Command-invocation patterns require a WHITESPACE (or end-of-line) right
# boundary, not just any non-word char — this is what a real shell
# invocation ("curl ...", bare "wget") looks like, and it's what keeps this
# check from tripping on a URL-scheme string literal ("ssh://...", parsed
# as data by baseline-snapshot.sh's own remote-URL case statement) or a
# hyphenated prose mention in a comment ("the curl-bootstrap's ... symlink",
# bin/foundation's own header) — neither of those is an actual invocation.
patterns=(
  '(^|[^A-Za-z0-9_])curl([ '"$'\t'"']|$)'
  '(^|[^A-Za-z0-9_])wget([ '"$'\t'"']|$)'
  '(^|[^A-Za-z0-9_])(nc|netcat)([ '"$'\t'"']|$)'
  '/dev/(tcp|udp)/'
  '(^|[^A-Za-z0-9_])(ssh|scp|rsync|telnet|ftp)([ '"$'\t'"']|$)'
  'import[[:space:]]+(urllib|requests|http\.client|socket)([^A-Za-z0-9_]|$)'
  'requests\.(get|post|put|delete|patch|head)\('
  'socket\.(socket|connect|create_connection)\('
  'urlopen\('
)
descriptions=(
  "curl invocation"
  "wget invocation"
  "netcat invocation"
  "bash raw-socket /dev/tcp or /dev/udp redirection"
  "remote-shell/transfer tool (ssh/scp/rsync/telnet/ftp)"
  "Python network-module import (urllib/requests/http.client/socket)"
  "Python requests.<verb>() call"
  "Python socket.socket/.connect/.create_connection() call"
  "Python urlopen() call"
)

# ---------------------------------------------------------------------------
# Build the file list.
# ---------------------------------------------------------------------------
files=()

for rel in bin/subcommands/baseline-snapshot.sh bin/subcommands/report.sh bin/foundation; do
  f="$kernel_root/$rel"
  [ -f "$f" ] && files+=("$f")
done

if [ -n "$overlay_dir" ] && [ -d "$overlay_dir" ]; then
  for f in "$overlay_dir"/*; do
    [ -e "$f" ] || continue
    [ -f "$f" ] || continue
    files+=("$f")
  done
fi

if [ "${#files[@]}" -eq 0 ]; then
  echo "check-producer-egress: no named producers found to scan (kernel-root: $kernel_root; overlay-report-d: ${overlay_dir:-<none>}) -- nothing to check"
  exit 0
fi

# ---------------------------------------------------------------------------
# Scan.
# ---------------------------------------------------------------------------
violations=0
files_checked=0

for f in "${files[@]}"; do
  files_checked=$((files_checked + 1))
  i=0
  while [ "$i" -lt "${#patterns[@]}" ]; do
    pat="${patterns[$i]}"
    desc="${descriptions[$i]}"
    while IFS= read -r hit; do
      [ -z "$hit" ] && continue
      lineno="${hit%%:*}"
      line="${hit#*:}"
      printf '%s:%s: [%s] %s\n' "$f" "$lineno" "$desc" "$line"
      violations=$((violations + 1))
    done < <(grep -nE -- "$pat" "$f" 2>/dev/null || true)
    i=$((i + 1))
  done
done

if [ "$violations" -gt 0 ]; then
  echo "---"
  echo "FAIL: $violations network-call-pattern hit(s) across $files_checked named producer(s)" >&2
  echo "  (see this script's header for the documented empty egress surface --" >&2
  echo "  gh itself is never flagged; every hit above is something ELSE reaching" >&2
  echo "  the network and needs to be either removed or explicitly documented" >&2
  echo "  as a new opt-in surface in this script's own header, in the same" >&2
  echo "  change that adds it)." >&2
  exit 1
fi

echo "OK -- 0 network-call-pattern hits across $files_checked named producer(s) (gh itself is the only sanctioned channel; see this script's header)"
