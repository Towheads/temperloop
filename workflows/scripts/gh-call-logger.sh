#!/usr/bin/env bash
# Transparent gh / git-bug call-logger shim (TIMED, schema v2).
# SOURCE OF TRUTH: foundation/workflows/scripts/gh-call-logger.sh
#   Install   : make install-gh-logger    (copies this to ~/.local/bin/gh)
#   Remove    : make uninstall-gh-logger
#   DO NOT hand-edit the installed copy at ~/.local/bin/gh — edit this file and re-install.
#
# WHY THIS EXISTS
#   The shared Projects-v2 GraphQL budget (5,000 pts/hr) has repeatedly drained with
#   no per-call attribution (foundation #53/#93/#141). An earlier ad-hoc shim was
#   removed by #62 on the premise usage had flattened; it hadn't, the budget
#   re-drained the SAME day, and the removal took the only forward log with it.
#   This is the durable, tracked replacement: a `make` target installs it and a
#   matching target removes it, so it can never silently vanish again.
#
#   v2 (F#988) adds DURATION + ATTRIBUTION so the before/after measurement round
#   for the git-bug tracker evaluation has a real "before" window. The suspicion
#   that gh queries are very time-consuming (F#983's budget-exhaustion retro) now
#   has an instrument behind it, not just a hunch.
#
# BEHAVIOR
#   TIME the real tool, then append one TSV row, then exit with its verbatim code.
#     columns:  start_ms \t dur_ms \t exit \t pid \t ppid \t tool \t context \t op \t cwd \t args
#   Timing is millisecond-resolution via system perl (Time::HiRes) — bash here is
#   3.2 (no $EPOCHREALTIME) and darwin `date` has no %N; perl ships on macOS + CI.
#   If perl is absent the row still lands with whole-second-resolution timing
#   (never fatal). The wrapper runs the real tool as a CHILD (not exec) so it can
#   measure the wall time; fds are inherited untouched and the exit code — incl.
#   128+N signal deaths (Ctrl-C -> 130) — is propagated verbatim.
#
#   BASENAME-GENERIC: `tool` is this shim's own install name (basename of $0), and
#   the real binary it resolves + execs is that same name. So the identical script
#   installed as ~/.local/bin/git-bug logs (and dispatches) git-bug with zero new
#   code — the after-side instrument for the tracker migration for free.
#
#   Attribution comes from two optional env vars set by callers:
#     GH_CALL_CONTEXT  outermost command (worklist / reconcile / funnel-tick / ...)
#     GH_CALL_OP       fine-grained op — the board adapter auto-tags its calling
#                      function at the _board_gh seam.
#   GraphQL/REST/porcelain CLASSIFICATION is derived at REPORT time from `args`;
#   the shim stays dumb (a classifier here would distort the very timing it logs).
#
#   Logging is ON by default — "capture-forward", so the NEXT surprise drain is
#   already being recorded before anyone notices it. Disable per-call with
#   GH_CALL_LOG=0 (the real tool still runs, via a zero-overhead exec — no timing,
#   no perl spawn). The log self-rotates to one prior generation (<log>.1) once it
#   passes a size cap, so it can't grow unbounded.
#
# ANALYSE (top op by call-count + total ms in the last hour):
#   awk -F'\t' -v cut=$(( $(date +%s)*1000 - 3600000 )) \
#     '$1>cut{c[$8]++; d[$8]+=$2} END{for(k in c) printf "%6d  %9d ms  %s\n", c[k], d[k], k}' \
#     ~/.cache/gh-calls-v2.tsv | sort -rn | head
set -u

# v2 uses a NEW file so old-schema (5-col) rows never mix with new (10-col) ones.
LOG="${GH_CALL_LOG_FILE:-$HOME/.cache/gh-calls-v2.tsv}"
MAX_BYTES="${GH_CALL_LOG_MAX_BYTES:-16777216}"   # 16 MiB

# Resolve THIS shim's own absolute path so we never exec ourselves (infinite loop).
# When invoked as `gh` via PATH, $0 may be bare "gh"; command -v then yields this
# shim's full path (it is the first gh on PATH). With a slash, $0 is already a path.
self="$0"
case "$self" in
  */*) : ;;
  *)   self="$(command -v -- "$self" 2>/dev/null || printf '%s' "$self")" ;;
esac

# The tool this shim stands in for = its own install name. Everything below is
# generic in this name: gh when installed as gh, git-bug when installed as git-bug.
tool="$(basename -- "$self")"

# The real tool: the first executable of the same basename on PATH that is NOT this
# shim (compared by inode via -ef, so symlinks / trailing slashes / ~ expansion
# can't fool it). Falls back to the usual install locations. No hardcoded
# interpreter path — portable.
_real_tool() {
  local p cand
  local IFS=:
  # shellcheck disable=SC2086  # intentional word-split of PATH on ':'
  for p in $PATH; do
    [ -n "$p" ] || continue
    cand="$p/$tool"
    [ -x "$cand" ] || continue
    [ "$cand" -ef "$self" ] && continue
    printf '%s\n' "$cand"
    return 0
  done
  for cand in "/opt/homebrew/bin/$tool" "/usr/local/bin/$tool" "/usr/bin/$tool"; do
    [ -x "$cand" ] && ! [ "$cand" -ef "$self" ] && { printf '%s\n' "$cand"; return 0; }
  done
  return 1
}

# Epoch milliseconds. Prefer perl's Time::HiRes (ms resolution); degrade to
# whole-second precision (×1000) if perl is unavailable — coarse but never fatal.
_now_ms() {
  local ms
  if ms="$(/usr/bin/perl -MTime::HiRes=time -e 'printf "%d", time()*1000' 2>/dev/null)" \
     && [ -n "$ms" ]; then
    printf '%s' "$ms"
  else
    printf '%s000' "$(date +%s 2>/dev/null || echo 0)"
  fi
}

real="$(_real_tool)" || {
  echo "gh-call-logger: cannot locate the real $tool on PATH (only this shim found)" >&2
  exit 127
}

# Opt-out: zero-overhead passthrough, no timing, no perl spawn, no row.
if [ "${GH_CALL_LOG:-1}" = 0 ]; then
  exec "$real" "$@"
fi

# TIME the real tool as a child so we can measure wall time. fds inherited
# untouched; exit code (incl. 128+N signal deaths) captured verbatim.
start_ms="$(_now_ms)"
"$real" "$@"
code=$?
end_ms="$(_now_ms)"
dur_ms=$(( end_ms - start_ms ))
[ "$dur_ms" -ge 0 ] || dur_ms=0   # guard against clock skew / fallback rounding

# Log best-effort — a logging or rotation failure must never change the exit code.
{
  if [ -f "$LOG" ]; then
    sz="$(wc -c <"$LOG" 2>/dev/null || echo 0)"
    sz="${sz//[^0-9]/}"; [ -n "$sz" ] || sz=0
    [ "$sz" -gt "$MAX_BYTES" ] && mv -f "$LOG" "$LOG.1"
  fi
  mkdir -p "$(dirname "$LOG")"
  # args is the LAST column and is sanitized (tabs/newlines -> space) so a
  # GraphQL query arg can never split or corrupt the row (a latent v1 bug).
  args_clean="$(printf '%s' "$*" | tr '\t\n' '  ')"
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$start_ms" "$dur_ms" "$code" "$$" "$PPID" \
    "$tool" "${GH_CALL_CONTEXT:-}" "${GH_CALL_OP:-}" "$PWD" "$args_clean" >>"$LOG"
} 2>/dev/null || true

exit "$code"
