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
#
# LAKE STREAM (dual-write, DESIGN-FORK-avoided per the item contract: prefer
# dual-write over retire while a real consumer of the TSV exists — see below).
#   Every row above is ALSO appended, same call, as one JSONL record to the
#   per-host monthly raw-lake stream `gh-calls-<YYYY-MM>.jsonl`
#   (canonical sink spec: meta/data/raw/README.md), using the SAME
#   override-then-fallback resolution seam emit-command-run.sh /
#   emit-issue-touch.sh / emit-gh-perf.sh use for their own <STREAM>_RAW_DIR:
#   an explicit override (GH_CALLS_RAW_DIR) first, else an XDG-scoped default
#   (${XDG_STATE_HOME:-$HOME/.local/state}/temperloop/gh-calls, temperloop
#   #415). This shim can't use those scripts' BASH_SOURCE-relative trick
#   (`cd "$here/../.."`) because, unlike them, it is INSTALLED — copied to
#   ~/.local/bin/gh (`temperloop install`, bin/subcommands/install.sh) and
#   run from there, decoupled from any repo checkout on disk; the XDG
#   fallback is therefore the primary path in practice, not a rare degrade
#   case. A real downstream build-repo checkout that wants the lake to land
#   in its own meta/data/raw/ (unioned with the other in-repo emit sites)
#   sets GH_CALLS_RAW_DIR explicitly — the override always wins. The default
#   was previously a hardcoded path under one operator's personal projects
#   directory: a fresh machine's first few `gh` calls silently pre-populated
#   the exact directory this project documents as the canonical `git clone`
#   target for that downstream repo, breaking that clone on a non-empty
#   destination (temperloop#415).
#
#   CUTOVER NOTE: the TSV (`$LOG`, below) stays live because
#   workflows/scripts/probe/gh-perf-report.sh reads it directly (percentile/
#   share-of-time tables, the F#988 git-bug-tracker before/after evaluation's
#   live-window source) — a real, current consumer, so retiring it now would
#   break that in-flight measurement. Retire the TSV write once
#   gh-perf-report.sh is migrated to read the JSONL lake instead (or the
#   F#988 evaluation concludes), whichever comes first; until then this is a
#   deliberate two-sink period, not a leftover.
#
#   The lake write reuses the JSON build already needed for the TSV's args
#   sanitization (tabs/newlines already flattened to spaces) and escapes
#   in-place via bash parameter expansion — no jq spawn, no extra subshell
#   per field — to keep this per-call hot path cheap (see _gh_lake_esc_var).
#   Like the TSV write, the lake write is inside the best-effort logging
#   block: it can never change the wrapped tool's exit code, and
#   GH_CALL_LOG=0 skips both sinks via the same zero-overhead exec passthrough.
set -u

# v2 uses a NEW file so old-schema (5-col) rows never mix with new (10-col) ones.
LOG="${GH_CALL_LOG_FILE:-$HOME/.cache/gh-calls-v2.tsv}"
MAX_BYTES="${GH_CALL_LOG_MAX_BYTES:-16777216}"   # 16 MiB

# Lake stream (dual-write sibling of $LOG — see header LAKE STREAM note).
# Default is XDG-scoped (never a hardcoded personal checkout path —
# temperloop#415); GH_CALLS_RAW_DIR overrides for a real downstream
# build-repo checkout that wants the lake unioned into its own
# meta/data/raw/.
LAKE_DIR="${GH_CALLS_RAW_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/temperloop/gh-calls}"

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

# In-place JSON-string escape (no subshell, no jq): backslash- and
# quote-escape the NAMED variable's value in place, so it's safe to embed as
# a JSON string literal. bash-3.2-safe (eval-based indirection — this repo's
# dev/CI bash is 3.2 on macOS, which has no `declare -n` namerefs, those are
# bash 4.3+). Used only by the lake-stream write below.
_gh_lake_esc_var() {
  local __name="$1" __val
  eval "__val=\"\${$__name}\""
  __val="${__val//\\/\\\\}"
  __val="${__val//\"/\\\"}"
  eval "$__name=\"\$__val\""
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
  # Read the two attribution env vars ONCE into plain (lowercase, non-knob-
  # shaped) locals and reuse them for both sinks below — GH_CALL_OP has no
  # registry row (a per-call attribution tag, not a static operator default;
  # knob:exempt), so a single read here keeps check-knob-registry.sh's
  # unregistered-seam sweep to exactly one exempted occurrence instead of one
  # per sink. GH_CALL_CONTEXT is registered (owning script capture.sh; this
  # is a byte-identical duplicate seam elsewhere, allowed name-only).
  call_context="${GH_CALL_CONTEXT:-}"
  call_op="${GH_CALL_OP:-}"  # knob:exempt — per-call attribution tag, not a static operator default
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$start_ms" "$dur_ms" "$code" "$$" "$PPID" \
    "$tool" "$call_context" "$call_op" "$PWD" "$args_clean" >>"$LOG"

  # --- lake stream: gh-calls-<YYYY-MM>.jsonl (dual-write; see header note) --
  lake_month="$(date -u +%Y-%m 2>/dev/null)"
  if [ -n "$lake_month" ]; then
    lake_ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null)"
    lake_host="${SUBSET_HOST_LABEL:-}"
    if [ -z "$lake_host" ]; then
      # $HOSTNAME is bash's own automatic variable (generic OS/harness-
      # injected runtime value, KNOB_REGISTRY_GENERIC_ALLOWLIST category —
      # same class as HOME/PATH/SHELL, not an operator-tunable knob).
      if [ -n "${HOSTNAME:-}" ]; then
        lake_host="${HOSTNAME%%.*}"
      else
        lake_host="$(hostname -s 2>/dev/null || hostname 2>/dev/null || echo unknown)"
      fi
    fi
    _gh_lake_esc_var lake_host

    lake_tool="$tool"; _gh_lake_esc_var lake_tool
    lake_cwd="$PWD"; _gh_lake_esc_var lake_cwd
    lake_args="$args_clean"; _gh_lake_esc_var lake_args

    if [ -n "$call_context" ]; then
      lake_ctx="$call_context"; _gh_lake_esc_var lake_ctx; ctx_json="\"$lake_ctx\""
    else
      ctx_json="null"
    fi
    if [ -n "$call_op" ]; then
      lake_op="$call_op"; _gh_lake_esc_var lake_op; op_json="\"$lake_op\""
    else
      op_json="null"
    fi
    if [ -n "${CLAUDE_CODE_SESSION_ID:-}" ]; then
      lake_sess="$CLAUDE_CODE_SESSION_ID"; _gh_lake_esc_var lake_sess; sess_json="\"$lake_sess\""
    else
      sess_json="null"
    fi

    mkdir -p "$LAKE_DIR"
    printf '{"schema_version":"1","ts":"%s","host":"%s","start_ms":%s,"dur_ms":%s,"exit_code":%s,"pid":%s,"ppid":%s,"tool":"%s","context":%s,"op":%s,"cwd":"%s","args":"%s","session_id":%s}\n' \
      "$lake_ts" "$lake_host" "$start_ms" "$dur_ms" "$code" "$$" "$PPID" \
      "$lake_tool" "$ctx_json" "$op_json" "$lake_cwd" "$lake_args" "$sess_json" \
      >>"$LAKE_DIR/gh-calls-${lake_month}.jsonl"
  fi
} 2>/dev/null || true

exit "$code"
