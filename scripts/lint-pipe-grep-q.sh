#!/usr/bin/env bash
#
# lint-pipe-grep-q.sh — mechanical guard against the temperloop#1050 footgun:
# a `<writer> | grep -q <pattern>` pipeline.
#
# THE BUG. `grep -q` is specified to exit ZERO IMMEDIATELY on its first match —
# it does not read the rest of its input. When grep is the tail of a pipeline,
# that early exit closes the read end of the pipe while the writer upstream is
# still writing, so the writer takes SIGPIPE and dies with status 141. Under
# `set -o pipefail` the pipeline's status is the RIGHTMOST NON-ZERO one, so the
# pipeline reports 141 — a FAILURE — even though grep matched and returned 0.
#
#   printf '%s\n' "$haystack" | grep -Fxq "$needle"   # pipefail: 0 on a match…
#                                                     # …or 141, nondeterministically
#
# It is nondeterministic because it is a RACE: whether the writer has already
# finished (short input, or its output fit in the 64 KiB pipe buffer) or is still
# mid-write when grep exits. So the same line passes for months and then fails
# once under a longer input — the worst possible failure shape for CI.
#
# THE FIX, and the ONLY sanctioned one. Drop `q` from grep's flag set and send
# grep's stdout to /dev/null instead:
#
#   printf '%s\n' "$haystack" | grep -Fx "$needle" >/dev/null
#
# grep now DRAINS ITS INPUT TO EOF, so the writer is never signalled, while the
# exit status is bit-for-bit what `-q` gave: 0 on a match, 1 on none, 2 on error.
# Nothing reaches the terminal either way. Two rewrites this repo deliberately
# does NOT accept, because both change per-site behaviour that cannot be reviewed
# at sweep scale: a `<<<` herestring (adds a trailing newline the writer may not
# have emitted) and an intermediate variable (`$(…)` strips trailing newlines and
# the unquoted form word-splits).
#
# WHAT IS FLAGGED. A `grep` — or `egrep`/`fgrep`/`zgrep`, optionally via
# `command` — appearing immediately after a `|`, with a `q` ANYWHERE in its flag
# cluster. The cluster form matters: `q` is not always first, and this tree
# carried `-q`, `-qv`, `-qx`, `-qE`, `-qF`, `-qiE`, `-qxF`, `-Eq`, `-Eqi`,
# `-Eiq`, `-Fxq` and `-qF` alike. A naive `s/ -q / /` sweep silently no-ops on
# every clustered site, which is exactly how a partial sweep looks green.
#
# WHAT IS NOT FLAGGED, and why:
#   * an UNPIPED `grep -q pattern file` — grep reads a file, there is no writer
#     to signal, and the early exit is a pure win. Only the piped form is a bug.
#   * a `#` COMMENT that merely NAMES the shape. Several files explain in prose
#     why they avoid `| grep -q`; flagging those would be the temperloop#1152
#     defect class (a guard that fires on documentation of the thing it guards).
#     The comment strip is quote-aware, so a `#` inside a quoted grep PATTERN —
#     `grep -vE '^[0-9]+:[[:space:]]*#' | grep -q .` — is NOT mistaken for one.
#   * this script and its own regression test, which necessarily contain the
#     shape as data.
#
# WHY A LINT AND NOT A TEST. The bug is a race, so a test can only observe it
# when the race happens to lose; the shape is statically recognisable and always
# wrong, so recognising it textually is both cheaper and strictly more reliable.
# `shellcheck` has no check for it (SC2143 is the adjacent, different `$(… | grep
# -c)` smell), so nothing already in the gate set covers this class.
#
# USAGE
#   scripts/lint-pipe-grep-q.sh                # lint the tracked shell set
#   scripts/lint-pipe-grep-q.sh FILE [FILE...] # lint explicit files
#   scripts/lint-pipe-grep-q.sh --list         # print the resolved file set
#
# Exit 0 = clean; exit 1 = at least one piped `grep -q` found. Runs fully offline
# and shells out to nothing but `awk` and `git ls-files`.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Files that necessarily CONTAIN the shape as data. Self-exemption is by resolved
# path, not basename, so a fixture that happens to share a name is still linted.
SELF="$REPO_ROOT/scripts/lint-pipe-grep-q.sh"
SELF_TEST="$REPO_ROOT/scripts/tests/test_lint_pipe_grep_q.sh"

LIST_ONLY=0
if [ "${1:-}" = "--list" ]; then
  LIST_ONLY=1
  shift
fi

# ---------------------------------------------------------------------------
# File set. Explicit arguments win (the mode the regression test uses).
# Otherwise: EVERY tracked shell file — `*.sh` plus any tracked file carrying an
# sh/bash shebang, regardless of extension.
#
# DELIBERATELY NO pipefail PREDICATE. It is tempting to lint only files that set
# `-o pipefail`, since that is the option under which the race becomes a failure.
# That predicate has a hole big enough to have hidden a live site: a sourced lib
# sets no `set` line of its own and INHERITS pipefail from whatever sourced it —
# workflows/scripts/lib/issue-marker-probe.sh is exactly that shape. A blanket
# rule has no such hole and costs nothing, because a piped `grep -q` is WRONG
# under pipefail and merely pointless-but-harmless without it. The extensionless
# half matters for the same reason in the other direction: bin/temperloop,
# bin/foundation, .temperloop/report.d/tokens and
# workflows/scripts/report-producers/tokens all DO set pipefail and none of them
# ends in `.sh`.
# ---------------------------------------------------------------------------
files=()
if [ "$#" -gt 0 ]; then
  files=("$@")
else
  while IFS= read -r f; do
    [ -f "$REPO_ROOT/$f" ] || continue
    case "$f" in
      *.sh) files+=("$REPO_ROOT/$f") ;;
      *)
        if head -n 1 "$REPO_ROOT/$f" 2>/dev/null \
             | grep -E '^#!.*[ /](ba)?sh( |$)' >/dev/null; then
          files+=("$REPO_ROOT/$f")
        fi
        ;;
    esac
  done < <(git -C "$REPO_ROOT" ls-files 2>/dev/null)
fi

# Drop the two self-exempt files (by resolved path).
kept=()
if [ "${#files[@]}" -gt 0 ]; then
  for f in "${files[@]}"; do
    abs="$f"
    case "$abs" in /*) ;; *) abs="$PWD/$abs" ;; esac
    [ "$abs" = "$SELF" ] && continue
    [ "$abs" = "$SELF_TEST" ] && continue
    kept+=("$f")
  done
fi

if [ "${#kept[@]}" -eq 0 ]; then
  [ "$LIST_ONLY" -eq 1 ] && exit 0
  echo "lint-pipe-grep-q: no files to lint" >&2
  exit 0
fi
files=("${kept[@]}")

if [ "$LIST_ONLY" -eq 1 ]; then
  for f in "${files[@]}"; do
    printf '%s\n' "${f#"$REPO_ROOT"/}"
  done
  exit 0
fi

# ---------------------------------------------------------------------------
# The scanner. Per line: strip any `#` comment that is genuinely a comment (a
# `#` at a word boundary, outside single/double quotes), then match the piped
# `grep -<cluster containing q>` shape against what is left.
#
# The quote tracking is what separates a real comment from a `#` inside a grep
# PATTERN. It is intentionally per-line: a `#` inside an unterminated multi-line
# string could truncate early, which can only ever cause a MISSED site, never a
# false alarm — the safe direction for a guard whose false positives would land
# on prose.
# ---------------------------------------------------------------------------
report="$(
  awk '
    # Return the line with any trailing `#` comment removed.
    function strip_comment(s,   n, i, c, sq, dq, prev) {
      n = length(s); i = 1; sq = 0; dq = 0
      while (i <= n) {
        c = substr(s, i, 1)
        if (sq) { if (c == "\047") sq = 0; i++; continue }
        if (c == "\\") { i += 2; continue }
        if (dq) { if (c == "\"") dq = 0; i++; continue }
        if (c == "\047") { sq = 1; i++; continue }
        if (c == "\"")   { dq = 1; i++; continue }
        if (c == "#") {
          # `#` opens a comment only at a word boundary — this is what keeps
          # `${#arr}`, `$#` and `a#b` from truncating the line.
          prev = (i == 1) ? "" : substr(s, i - 1, 1)
          if (i == 1 || prev == " " || prev == "\t" || prev == ";" ||
              prev == "|" || prev == "&" || prev == "(" || prev == ")" ||
              prev == "<" || prev == ">") {
            return substr(s, 1, i - 1)
          }
        }
        i++
      }
      return s
    }

    {
      code = strip_comment($0)
      if (code ~ /\|[[:space:]]*(command[[:space:]]+)?(e|f|z)?grep[[:space:]]+-[a-zA-Z]*q/) {
        printf "%s:%d: piped `grep -q` — SIGPIPEs the writer; drop the q and redirect instead\n", FILENAME, FNR
        printf "%s:%d:     %s\n", FILENAME, FNR, $0
      }
    }
  ' "${files[@]}"
)"

if [ -n "$report" ]; then
  echo "lint-pipe-grep-q: FAIL — a piped \`grep -q\` was found:" >&2
  echo "  (grep -q exits at the FIRST match, so the writer upstream takes SIGPIPE and the" >&2
  echo "   pipeline reports 141 under \`set -o pipefail\` — nondeterministically, as a race." >&2
  echo "   Fix: remove \`q\` from the flag cluster and append \`>/dev/null\`, e.g." >&2
  echo "     <writer> | grep -Fxq \"\$needle\"" >&2
  echo "  -> <writer> | grep -Fx \"\$needle\" >/dev/null" >&2
  echo "   Do NOT rewrite to a <<< herestring or an intermediate variable. See temperloop#1050.)" >&2
  printf '%s\n' "$report" | sed "s|^${REPO_ROOT}/||; s|^|  |" >&2
  exit 1
fi

echo "lint-pipe-grep-q: OK — no piped \`grep -q\` in the tracked shell set"
