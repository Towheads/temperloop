#!/usr/bin/env bash
#
# lint-bash32-cmdsubst-comment.sh — mechanical guard against the temperloop#1098
# footgun: an apostrophe hidden inside a `$( … )` command substitution.
#
# THE BUG (bash < 4.0, i.e. every macOS system /bin/bash — 3.2.57). When bash 3.2
# lexes `$( … )` it scans forward for the matching `)` while tracking quotes, but
# it does NOT understand that a `#` starts a comment, nor that a here-document
# body is literal text. So an apostrophe in either place is read as an OPENING
# single quote: everything after it — including the `)` that was supposed to close
# the substitution — is swallowed into a "string" that never ends. The reported
# error is an `unexpected EOF while looking for matching ')'` at the line the
# substitution OPENED on, plus a bogus `syntax error: unexpected end of file` at
# the bottom of the file — the real culprit line is named nowhere.
#
#   x="$(
#     # it's a comment      <-- bash 3.2: the ' opens a string
#     echo hi
#   )"                      <-- ...that swallows this ), and the rest of the file
#
# Bash 4.0+ lexes this correctly, so the file is perfectly valid on any modern
# bash. That asymmetry is the whole reason this lint exists — see WHY A LINT below.
#
# WHY A LINT AND NOT A PARSER. All three of the obvious detectors are BLIND here;
# each was measured on the known-bad input (temperloop#1098):
#   - `shellcheck`             exits 0 (one unrelated SC2116 style note).
#   - `bash -n` under bash 5.x exits 0 — the bug was fixed in bash 4.0.
#   - `bash -n` under bash 3.2 exits 2 — it DOES catch it, but pre-merge CI runs
#                              ubuntu-only (temperloop#963), ubuntu-latest ships
#                              bash 5.2, and bash 3.2 is not installable from apt.
# So a `bash -n` gate would pass unconditionally on the only leg CI actually runs:
# it would READ as coverage while never firing. This lint instead recognises the
# pattern TEXTUALLY — a small shell lexer that tracks `$(` nesting depth through
# quotes, escapes, nested substitutions and here-docs — so it fires identically on
# ubuntu bash 5.2 and on macOS bash 3.2.
#
# WHAT IS FLAGGED. Inside a `$( … )` region (depth > 0), an apostrophe appearing
# where bash 3.2 cannot see that it is inert. There are exactly two such places,
# and they get DIFFERENT rules — deliberately, see below:
#
#   1. a `#` comment (whole-line or trailing)  STRICT: any apostrophe fails.
#   2. a here-document body                    PARITY: the enclosing region fails
#      only if its here-doc bodies contribute an ODD number of apostrophes.
#
# Both were confirmed to break bash 3.2; a plain subshell `( … )`, a function
# body, a backtick substitution, a top-level comment, and a `#` inside a quoted
# string were all confirmed NOT to break it, and are not flagged.
#
# WHY THE TWO RULES DIFFER. Parity is the literal breakage condition — bash 3.2
# counts apostrophes, so an even number re-balances and the file parses. Applying
# that lenient rule everywhere would be the accurate model but a bad guard: an
# even-parity comment pair is only ACCIDENTALLY valid, and deleting one of the two
# comments later silently breaks the file — action at a distance. Comments are
# also trivially rewordable (`env-reconcile.sh's` -> `the env-reconcile.sh`), so
# the strict rule costs nothing. Here-doc bodies are the opposite case: in this
# repo they carry English prose destined for an LLM (bin/subcommands/try.sh,
# bin/subcommands/configure.sh) alongside embedded snippets like `jq -r '.[] | …'`.
# Mangling that prose to dodge an apostrophe would damage a legitimate construct
# to satisfy a lint, so there the lint narrows to the real condition instead.
# Parity is accumulated across the whole OUTERMOST `$( … )` region and reported
# when that region closes — exactly the span bash 3.2's own scan covers.
#
# USAGE
#   scripts/lint-bash32-cmdsubst-comment.sh                # lint the tracked shell set
#   scripts/lint-bash32-cmdsubst-comment.sh FILE [FILE...]  # lint explicit files
#
# Exit 0 = clean; exit 1 = at least one hidden apostrophe found. Runs fully
# offline and shells out to nothing but `awk` and `git ls-files`.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# ---------------------------------------------------------------------------
# File set. Explicit arguments win (that is the mode the regression test and the
# known-bad-input demo use). Otherwise: every tracked shell script — `*.sh` plus
# any extensionless tracked file carrying a sh/bash shebang. Note this INCLUDES
# `*/tests/*`, which `make shellcheck` deliberately excludes: the second file the
# temperloop#1098 sweep found broken was
# workflows/scripts/board/tests/test_boards_conf.sh, so excluding tests here
# would have left half the known breakage ungated.
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
        # Extensionless tracked script: keep it only if it declares a sh/bash
        # interpreter. `head -1` on a binary is harmless (grep just won't match).
        if head -n 1 "$REPO_ROOT/$f" 2>/dev/null | grep -E '^#!.*[ /](ba)?sh( |$)' >/dev/null; then
          files+=("$REPO_ROOT/$f")
        fi
        ;;
    esac
  done < <(git -C "$REPO_ROOT" ls-files 2>/dev/null)
fi

if [ "${#files[@]}" -eq 0 ]; then
  echo "lint-bash32-cmdsubst-comment: no files to lint" >&2
  exit 0
fi

# ---------------------------------------------------------------------------
# The lexer. One pass, character by character, with an explicit context stack so
# that quoting and `$(` nesting compose the way bash's own lexer composes them
# (`"$( … "inner" … )"` has to work). Contexts:
#
#   SQ   single-quoted string   — ends only at the next `'`; nothing else is special
#   DQ   double-quoted string   — `$(` may still open inside it; `\` escapes a few chars
#   BQ   backtick substitution  — tracked for state hygiene only (bash 3.2 lexes
#                                 backticks correctly, so it is never flagged)
#   CS   `$( … )`               — the context this lint is about; `csn` counts them
#   AR   `$(( … ))`             — arithmetic, closed by `))`, never a comment host
#   PAR  plain `( … )`          — subshell/grouping; balances parens but is SAFE
#
# An unmatched `)` at stack depth 0 (a `case` pattern such as `a) echo a ;;`) is
# ignored rather than treated as an error — which mirrors what bash 3.2 itself
# does when it meets one inside a substitution.
# ---------------------------------------------------------------------------
report="$(
  awk '
    function push(x) {
      st[++sp] = x
      if (x == "CS") { csn++; if (csn == 1) { hd_apos = 0; hd_n = 0; cs_line = FNR } }
    }
    function pop(   x) {
      x = st[sp]
      if (x == "CS") { csn--; if (csn == 0) region_close(FILENAME) }
      if (sp > 0) sp--
    }
    function top() { return (sp > 0) ? st[sp] : "" }

    function apos_count(s,   n, i) {
      n = 0
      for (i = index(s, "\047"); i > 0; i = index(s, "\047")) { n++; s = substr(s, i + 1) }
      return n
    }

    # Comment rule — STRICT: any apostrophe in a comment inside $( ... ) fails.
    function flag_comment(text) {
      if (index(text, "\047") == 0) return
      printf "%s:%d: apostrophe in a # comment inside $( ... ) — breaks bash 3.2\n", FILENAME, FNR
      printf "%s:%d:     %s\n", FILENAME, FNR, text
    }

    # Here-doc rule — PARITY: remember the apostrophe-bearing body lines and the
    # running count; the verdict is deferred to region_close() below.
    function note_heredoc(text,   c) {
      c = apos_count(text)
      if (c == 0) return
      hd_apos += c
      hd_n++
      hd_at[hd_n] = FNR
      hd_txt[hd_n] = text
    }

    # An outermost $( ... ) just closed. If its here-doc bodies contributed an odd
    # number of apostrophes, bash 3.2 is left mid-string when it reaches the `)`.
    function region_close(fname,   i) {
      if (hd_apos % 2 == 0) return
      printf "%s:%d: here-doc body inside this $( ... ) carries an ODD number (%d) of apostrophes — breaks bash 3.2\n", fname, cs_line, hd_apos
      for (i = 1; i <= hd_n; i++) printf "%s:%d:     %s\n", fname, hd_at[i], hd_txt[i]
      hd_apos = 0; hd_n = 0
    }

    # Parse a here-doc redirection operator starting at position i (s[i]=="<",
    # s[i+1]=="<"). Queues the delimiter and returns the index just past the word.
    function heredoc(s, i,   n, j, c, strip, word, q) {
      n = length(s)
      j = i + 2
      if (substr(s, j, 1) == "<") return j + 1     # `<<<` herestring, not a here-doc
      strip = 0
      if (substr(s, j, 1) == "-") { strip = 1; j++ }
      while (j <= n && (substr(s, j, 1) == " " || substr(s, j, 1) == "\t")) j++
      word = ""
      while (j <= n) {
        c = substr(s, j, 1)
        if (c == "\047" || c == "\"") {           # quoted delimiter: <<'"'"'EOF'"'"' / <<"EOF"
          q = c; j++
          while (j <= n && substr(s, j, 1) != q) { word = word substr(s, j, 1); j++ }
          j++
          continue
        }
        if (c == "\\") { j++; word = word substr(s, j, 1); j++; continue }
        if (c == " " || c == "\t" || c == ";" || c == "&" || c == "|" ||
            c == "<" || c == ">" || c == ")" || c == "(") break
        word = word c; j++
      }
      if (word != "") { hq_n++; hq_delim[hq_n] = word; hq_strip[hq_n] = strip }
      return j
    }

    function scan(s,   n, i, c, c2, t, prev) {
      n = length(s)
      i = 1
      while (i <= n) {
        c = substr(s, i, 1)
        t = top()

        if (t == "SQ") { if (c == "\047") pop(); i++; continue }

        if (c == "\\") {
          if (t == "DQ") {
            # Inside double quotes a backslash only escapes these four.
            c2 = substr(s, i + 1, 1)
            if (c2 == "$" || c2 == "`" || c2 == "\"" || c2 == "\\") i += 2; else i++
          } else i += 2
          continue
        }

        # `$(` opens a substitution from inside double quotes too — check before
        # the DQ branch below, or `x="$( … )"` would never be seen.
        if (c == "$" && substr(s, i + 1, 1) == "(") {
          if (substr(s, i + 2, 1) == "(") { push("AR"); i += 3 } else { push("CS"); i += 2 }
          continue
        }

        if (t == "DQ") { if (c == "\"") pop(); i++; continue }

        if (c == "\047") { push("SQ"); i++; continue }
        if (c == "\"")   { push("DQ"); i++; continue }
        if (c == "`")    { if (t == "BQ") pop(); else push("BQ"); i++; continue }
        if (c == "(")    { push("PAR"); i++; continue }
        if (c == ")") {
          if (t == "AR" && substr(s, i + 1, 1) == ")") { pop(); i += 2; continue }
          if (t == "CS" || t == "PAR" || t == "AR") pop()
          i++; continue                            # else: bare `)` — a case pattern
        }

        if (c == "#") {
          # `#` only opens a comment at a word boundary. This is what keeps
          # `${#arr}`, `$#` and `a#b` from being misread as comments.
          prev = (i == 1) ? "" : substr(s, i - 1, 1)
          if (i == 1 || prev == " " || prev == "\t" || prev == ";" || prev == "|" ||
              prev == "&" || prev == "(" || prev == ")" || prev == "<" || prev == ">") {
            if (csn > 0) flag_comment(substr(s, i))
            return                                 # rest of the line is comment
          }
          i++; continue
        }

        if (c == "<" && substr(s, i + 1, 1) == "<" && t != "AR") { i = heredoc(s, i); continue }

        i++
      }
    }

    # Per-file reset. `ENDFILE` is a gawk extension (macOS ships the one-true-awk),
    # so a still-open region left over from the PREVIOUS file is settled here,
    # against the remembered prior FILENAME, rather than in a per-file END rule.
    FNR == 1 {
      if (prevfile != "" && csn > 0) region_close(prevfile)
      sp = 0; csn = 0; hq_n = 0; hq_i = 0; inhd = 0; hd_apos = 0; hd_n = 0
      prevfile = FILENAME
    }

    {
      if (inhd) {
        line = $0
        if (hd_strip) sub(/^\t+/, "", line)
        if (line == hd_delim) {
          inhd = 0
          if (hq_i < hq_n) { hq_i++; hd_delim = hq_delim[hq_i]; hd_strip = hq_strip[hq_i]; inhd = 1 }
        } else if (csn > 0) {
          note_heredoc($0)
        }
        next
      }

      scan($0)

      if (hq_n > hq_i) { hq_i++; hd_delim = hq_delim[hq_i]; hd_strip = hq_strip[hq_i]; inhd = 1 }
    }

    # A `$( ... )` still open at EOF means either a genuinely unterminated
    # substitution or a construct this lexer mis-tracked; either way, settle the
    # pending parity verdict rather than dropping it silently.
    END { if (prevfile != "" && csn > 0) region_close(prevfile) }
  ' "${files[@]}"
)"

if [ -n "$report" ]; then
  echo "lint-bash32-cmdsubst-comment: FAIL — apostrophe hidden inside a \$( ... ) command substitution:" >&2
  echo "  (bash 3.2 — every macOS /bin/bash — reads it as an opening quote and swallows the closing ')'." >&2
  echo "   Reword to drop the apostrophe, e.g. \"env-reconcile.sh's own\" -> \"the env-reconcile.sh\". See temperloop#1098.)" >&2
  printf '%s\n' "$report" | sed "s|^${REPO_ROOT}/||; s|^|  |" >&2
  exit 1
fi

echo "lint-bash32-cmdsubst-comment: OK — no hidden apostrophes inside \$( ... ) in the tracked shell set"
