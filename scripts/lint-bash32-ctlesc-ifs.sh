#!/usr/bin/env bash
#
# lint-bash32-ctlesc-ifs.sh — mechanical guard against the temperloop#1649
# footgun: splitting on one of bash's OWN internal marker bytes via IFS.
#
# THE BUG (bash < 4.x, i.e. every macOS system /bin/bash — 3.2.57). Bash reserves
# two bytes for its own internal quoting protocol: 0x01 (CTLESC) and 0x7f
# (CTLNUL). Bash 3.2's word splitting is not 8-bit clean for either, so setting
# one of them as IFS does NOT split — `read` hands the WHOLE line, marker bytes
# and all, to the FIRST variable and leaves the rest empty:
#
#   $ printf 'a\x01b\x01c\n' | { IFS=$'\x01' read -r a b c; echo "[$a][$b][$c]"; }
#   bash 3.2 -> [a<0x01>b<0x01>c][][]     # no split, bytes retained as data
#   bash 5.x -> [a][b][c]                 # splits correctly
#
# Bash 4+ handles it, so the line is perfectly correct on any modern bash. That
# asymmetry is the whole reason this lint exists — see WHY A LINT below.
#
# HOW IT SHIPPED. Two gate validators adopted `awk -F'\t' 'BEGIN{OFS="\x01"}'`
# piped into `while IFS=$'\x01' read` as their tab-safe TSV parser (a genuinely
# good idea — awk does not collapse a single-character separator the way
# IFS-whitespace tab does). On ubuntu bash 5.x it worked; on macOS bash 3.2 every
# registry row collapsed into field 1, so both validators AND both of their test
# suites went red and `nightly-macos.yml` stayed red for SEVEN consecutive nights
# against `main`. The remedy is a one-byte change: 0x1f (ASCII US) and 0x1e (RS)
# are not bash marker bytes and split correctly on 3.2 and 5.x alike.
#
# NOT A BSD-vs-GNU DIALECT BUG. Worth stating because that is the family this
# repo's macOS regressions usually belong to (temperloop#1549/#1422, BSD awk
# without `asort`, GNU-only `sed` label loops, `date -d`). It is NOT this one:
# the awk stage emits byte-identical output under BSD awk and GNU awk, and
# holding awk fixed while swapping only the bash binary flips the result. The
# variable is the SHELL VERSION, not the userland dialect.
#
# WHAT IS FLAGGED — and ONLY this. An `IFS=` assignment whose value is an escape
# naming byte 0x01 or 0x7f, in any spelling bash accepts: `\x01` `\x1` `\001`
# `\01` `\1` `\x7f` `\x7F` `\177`. That is the whole rule, because BASH doing the
# splitting is the whole bug.
#
# WHAT IS NOT FLAGGED, and why:
#   * `awk -F'\1'` / `OFS="\x01"` — the AWK side. This was the first cut of the
#     rule and it was WRONG: measured, `printf 'a\1b' | awk -F'\1' '{print $2}'`
#     is byte-identical on bash 3.2 and 5.x, and so is carrying those bytes
#     through a `$( … )` command substitution. awk is 8-bit clean; only bash's
#     own splitting is not. Widening to the producer half flagged a live,
#     CORRECT, awk-only site (workflows/scripts/validate-activation-registry.sh,
#     which passes on macOS today and was NOT among the five red gates) — a false
#     positive on a file with no defect. The narrow rule fires on the real
#     defect's real site instead.
#   * a SAFE separator byte — `\x1f`, `\x1e`, `\x02`. The match requires the
#     escape to END at the closing quote, so `\x1f` is not mistaken for `\x1`.
#   * 0x01/0x7f used for anything OTHER than IFS. The bytes are not forbidden;
#     splitting on them in bash is. Requiring the `IFS=` context is also what
#     keeps this off, e.g., a `sed` backreference `\1`.
#   * a `#` COMMENT that merely names the shape. Both fixed validators now carry
#     a header explaining exactly why `\x01` was wrong, and a guard that fires on
#     the documentation of the thing it guards is the temperloop#1152 defect
#     class. The comment strip is quote-aware (shared with lint-pipe-grep-q.sh),
#     so a `#` inside a quoted pattern does not truncate a real line.
#   * this script and its own regression test, which contain the shape as data.
#
# KNOWN LIMIT, stated rather than papered over: a marker byte reaching `read`
# through an IFS set on an EARLIER line is not textually recognisable and is not
# caught. Every site in this tree, and the idiom itself, puts IFS on the `read`
# line — so this covers the shape as it is actually written, not every shape
# expressible.
#
# WHY A LINT AND NOT A TEST. The bug is invisible on the only leg pre-merge CI
# runs. Measured against the known-bad input:
#   - `shellcheck`               exits 0 — it has no check for this.
#   - `bash -n` under any bash   exits 0 — the line is syntactically fine.
#   - a RUNTIME test under bash 5 passes — the code is correct there.
#   - a runtime test under bash 3.2 WOULD catch it, but pre-merge CI is
#     ubuntu-only (temperloop#963), ubuntu-latest ships bash 5.x, and bash 3.2 is
#     not installable from apt. nightly-macos.yml does catch it — up to ~24h
#     after the merge, which is exactly how this sat on `main` for a week.
# So the only detector that fires on BOTH legs at gate time is a textual one.
# Same reasoning, same family, and the same file-set machinery as its two
# siblings: scripts/lint-bash32-cmdsubst-comment.sh and scripts/lint-pipe-grep-q.sh.
#
# USAGE
#   scripts/lint-bash32-ctlesc-ifs.sh                # lint the tracked shell set
#   scripts/lint-bash32-ctlesc-ifs.sh FILE [FILE...] # lint explicit files
#   scripts/lint-bash32-ctlesc-ifs.sh --list         # print the resolved file set
#
# Exit 0 = clean; exit 1 = at least one marker-byte IFS found. Runs fully
# offline and shells out to nothing but `awk` and `git ls-files`.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# _resolve_symlinks <path> — canonicalize a path by following every symlink,
# both a symlinked LEAF file and any symlinked directory COMPONENT, without
# relying on GNU `readlink -f` or `realpath` (neither is guaranteed on the
# macOS/BSD userland this repo also runs on). Portable: `dirname`/`basename`/
# `readlink`/`cd -P`/`pwd -P` only. Same helper as lint-pipe-grep-q.sh, and same
# reason: the self-exemption below must recognize this file through a vendoring
# overlay's compat symlink as well as through its vendored original.
_resolve_symlinks() {
  local p="$1" dir target hops=0
  while [ -L "$p" ]; do
    hops=$((hops + 1))
    [ "$hops" -gt 40 ] && break # symlink-loop guard; give up and use what we have
    dir="$(dirname "$p")"
    target="$(readlink "$p")"
    case "$target" in
      /*) p="$target" ;;
      *) p="$dir/$target" ;;
    esac
  done
  dir="$(dirname "$p")"
  if dir="$(cd "$dir" 2>/dev/null && pwd -P)"; then
    printf '%s/%s\n' "$dir" "$(basename "$p")"
  else
    printf '%s\n' "$p"
  fi
}

SELF="$REPO_ROOT/scripts/lint-bash32-ctlesc-ifs.sh"
SELF_TEST="$REPO_ROOT/scripts/tests/test_lint_bash32_ctlesc_ifs.sh"
SELF_RESOLVED="$(_resolve_symlinks "$SELF")"
SELF_TEST_RESOLVED="$(_resolve_symlinks "$SELF_TEST")"

LIST_ONLY=0
if [ "${1:-}" = "--list" ]; then
  LIST_ONLY=1
  shift
fi

# ---------------------------------------------------------------------------
# File set. Explicit arguments win (the mode the regression test uses).
# Otherwise EVERY tracked shell file — `*.sh` plus any tracked file carrying an
# sh/bash shebang, regardless of extension. Deliberately no narrower predicate,
# for the same reason lint-pipe-grep-q.sh gives: a sourced lib sets no `set` line
# of its own and several of this repo's live scripts (bin/temperloop,
# .temperloop/report.d/tokens) do not end in `.sh`.
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

# Drop the two self-exempt files (by resolved path — see _resolve_symlinks).
kept=()
if [ "${#files[@]}" -gt 0 ]; then
  for f in "${files[@]}"; do
    abs="$f"
    case "$abs" in /*) ;; *) abs="$PWD/$abs" ;; esac
    resolved="$(_resolve_symlinks "$abs")"
    [ "$resolved" = "$SELF_RESOLVED" ] && continue
    [ "$resolved" = "$SELF_TEST_RESOLVED" ] && continue
    kept+=("$f")
  done
fi

if [ "${#kept[@]}" -eq 0 ]; then
  [ "$LIST_ONLY" -eq 1 ] && exit 0
  echo "lint-bash32-ctlesc-ifs: no files to lint" >&2
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
# `#` at a word boundary, outside single/double quotes), then match the
# separator-assignment shape against what is left.
#
# The escape alternation is anchored on BOTH sides: it must follow an `IFS=`
# (optionally through `$` and an opening quote) and must END at a closing quote.
# The trailing anchor is what makes `\x1f` — the correct replacement byte — not
# match `\x1`. The leading `[^[:alnum:]_]` keeps it off an unrelated identifier
# that merely ends in `IFS`.
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
      if (code ~ /(^|[^[:alnum:]_])IFS[[:space:]]*=[[:space:]]*\$?["\047]?\\(x0?1|x7[fF]|0?0?1|177)["\047]/) {
        printf "%s:%d: bash marker byte (0x01 CTLESC / 0x7f CTLNUL) assigned to IFS — bash 3.2 does not split on it\n", FILENAME, FNR
        printf "%s:%d:     %s\n", FILENAME, FNR, $0
      }
    }
  ' "${files[@]}"
)"

if [ -n "$report" ]; then
  echo "lint-bash32-ctlesc-ifs: FAIL — a bash marker byte is being assigned to IFS:" >&2
  echo "  (0x01 is bash's own CTLESC and 0x7f its CTLNUL. Bash 3.2 — the system /bin/bash on" >&2
  echo "   every macOS host, and what \`bash scripts/quality-gates.sh\` resolves to on the" >&2
  echo "   macos-latest runner — does NOT split on either: \`read\` returns the whole line," >&2
  echo "   marker bytes included, in the FIRST variable. Bash 4+ splits correctly, so this is" >&2
  echo "   invisible to the ubuntu-only pre-merge leg (temperloop#963)." >&2
  echo "   Fix: use 0x1f (ASCII US) or 0x1e (RS) instead — neither is a bash marker byte, e.g." >&2
  # printf, not echo: these two lines contain backslash escapes as LITERAL text
  # (they are the before/after the reader is meant to copy), and `echo`'s
  # escape-expansion is implementation-defined for them (SC2028).
  printf '%s\n' "     awk -F'\\t' 'BEGIN{OFS=\"\\x01\"} {\$1=\$1; print}'  |  while IFS=\$'\\x01' read -r a b" >&2
  printf '%s\n' "  -> awk -F'\\t' 'BEGIN{OFS=\"\\x1f\"} {\$1=\$1; print}'  |  while IFS=\$'\\x1f' read -r a b" >&2
  echo "   See temperloop#1649.)" >&2
  printf '%s\n' "$report" | sed "s|^${REPO_ROOT}/||; s|^|  |" >&2
  exit 1
fi

echo "lint-bash32-ctlesc-ifs: OK — no bash marker byte assigned to IFS in the tracked shell set"
