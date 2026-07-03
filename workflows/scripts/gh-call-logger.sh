#!/usr/bin/env bash
# Transparent gh call-logger shim.
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
# BEHAVIOR
#   Append one TSV row per gh invocation, then exec the REAL gh untouched.
#     columns:  epoch_ts \t pid \t ppid \t cwd \t args
#   Logging is ON by default — "capture-forward", so the NEXT surprise drain is
#   already being recorded before anyone notices it. Disable per-call with
#   GH_CALL_LOG=0 (the real gh still runs). The log self-rotates to one prior
#   generation (<log>.1) once it passes a size cap, so it can't grow unbounded.
#
# ANALYSE (top caller cwd+args in the last hour):
#   awk -F'\t' -v cut=$(($(date +%s)-3600)) '$1>cut{print $4"\t"$5}' ~/.cache/gh-calls.tsv \
#     | sort | uniq -c | sort -rn | head
set -u

LOG="${GH_CALL_LOG_FILE:-$HOME/.cache/gh-calls.tsv}"
MAX_BYTES="${GH_CALL_LOG_MAX_BYTES:-2097152}"   # 2 MiB

# Resolve THIS shim's own absolute path so we never exec ourselves (infinite loop).
# When invoked as `gh` via PATH, $0 may be bare "gh"; command -v then yields this
# shim's full path (it is the first gh on PATH). With a slash, $0 is already a path.
self="$0"
case "$self" in
  */*) : ;;
  *)   self="$(command -v -- "$self" 2>/dev/null || printf '%s' "$self")" ;;
esac

# The real gh: the first executable `gh` on PATH that is NOT this shim (compared by
# inode via -ef, so symlinks / trailing slashes / ~ expansion can't fool it). Falls
# back to the usual install locations. No hardcoded interpreter path — portable.
_real_gh() {
  local p cand
  local IFS=:
  # shellcheck disable=SC2086  # intentional word-split of PATH on ':'
  for p in $PATH; do
    [ -n "$p" ] || continue
    cand="$p/gh"
    [ -x "$cand" ] || continue
    [ "$cand" -ef "$self" ] && continue
    printf '%s\n' "$cand"
    return 0
  done
  for cand in /opt/homebrew/bin/gh /usr/local/bin/gh /usr/bin/gh; do
    [ -x "$cand" ] && ! [ "$cand" -ef "$self" ] && { printf '%s\n' "$cand"; return 0; }
  done
  return 1
}

# Log best-effort — a logging or rotation failure must never break gh.
if [ "${GH_CALL_LOG:-1}" != 0 ]; then
  {
    if [ -f "$LOG" ]; then
      sz="$(wc -c <"$LOG" 2>/dev/null || echo 0)"
      sz="${sz//[^0-9]/}"; [ -n "$sz" ] || sz=0
      [ "$sz" -gt "$MAX_BYTES" ] && mv -f "$LOG" "$LOG.1"
    fi
    mkdir -p "$(dirname "$LOG")"
    printf '%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$$" "$PPID" "$PWD" "$*" >>"$LOG"
  } 2>/dev/null || true
fi

real="$(_real_gh)" || {
  echo "gh-call-logger: cannot locate the real gh on PATH (only this shim found)" >&2
  exit 127
}
exec "$real" "$@"
