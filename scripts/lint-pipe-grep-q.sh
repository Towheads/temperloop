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
#   * PRINTED TEXT that merely SHOWS the shape: the contents of a quoted string
#     literal, or of a heredoc body, whose consuming command is not a shell —
#     `echo "  <writer> | grep -Fxq …"`, a `cat <<'EOF'` usage block, a
#     `die "usage: … | grep -q …"` message. That text is emitted, never
#     executed: there is no pipeline, so there is no writer to take SIGPIPE.
#     Same temperloop#1152 class as the comment case above, and it is what
#     blocked the v0.29.0 vendor (temperloop#1420) — this script's OWN help
#     text, and an overlay script that merely echoes a `curl … | grep -q …`
#     instruction, were both read as executable code.
#
#     THE EXEMPTION IS BY PARSE POSITION, NEVER BY FILENAME. A filename
#     allowlist would only move the problem to the next file that documents the
#     shape. What decides is the simple command CONSUMING the string: if it
#     hands the string to a shell — `bash -c`/`sh -c`, `eval`, `ssh`, `env`,
#     `xargs`, `timeout`, a `bash <<EOF` heredoc — the string IS code and is
#     still scanned, which is why the real in-a-string sites the temperloop#1050
#     sweep found (`bash -c "jq … | grep -qx 1175"`) stay flagged.
#
#     Both strips err in the same direction, deliberately: an unrecognised
#     executor (some `run_remote "cmd | grep -q x"` wrapper) yields a MISSED
#     site, never a false alarm on prose. That is the safe direction for a guard
#     whose false positives land on documentation and block a release.
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

# _resolve_symlinks <path> — canonicalize a path by following every symlink,
# both a symlinked LEAF file and any symlinked directory COMPONENT, without
# relying on GNU `readlink -f` or `realpath` (neither is guaranteed on the
# macOS/BSD userland this repo also runs on — see CLAUDE.md's dialect-check
# rule). Portable: `dirname`/`basename`/`readlink`/`cd -P`/`pwd -P` only.
_resolve_symlinks() {
  local p="$1" dir target hops=0
  while [ -L "$p" ]; do
    hops=$((hops + 1))
    [ "$hops" -gt 40 ] && break  # symlink-loop guard; give up and use what we have
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

# Files that necessarily CONTAIN the shape as data. Self-exemption is by
# RESOLVED path (symlinks followed on both sides of the comparison — see
# _resolve_symlinks above), not basename and not a literal string match, so
# (a) a fixture that happens to share a name is still linted, and (b) in a
# vendoring overlay that reaches this script through a compat symlink
# (foundation: scripts/lint-pipe-grep-q.sh -> ../kernel/scripts/lint-pipe-
# grep-q.sh) REPO_ROOT above resolves to the OVERLAY root, so a literal
# `$REPO_ROOT/scripts/...` comparison would never match the vendored copies
# at kernel/scripts/lint-pipe-grep-q.sh / kernel/scripts/tests/test_lint_
# pipe_grep_q.sh that git ls-files also lists — those are the SAME physical
# files the entry-point symlink points at, so resolving both sides to their
# real path makes the comparison recognize them as self regardless of which
# path (compat-symlink or vendored-original) reached them. Only these two
# files are exempt this way — every OTHER file under a vendored kernel/
# tree is still linted normally (temperloop#1490).
SELF="$REPO_ROOT/scripts/lint-pipe-grep-q.sh"
SELF_TEST="$REPO_ROOT/scripts/tests/test_lint_pipe_grep_q.sh"
SELF_RESOLVED="$(_resolve_symlinks "$SELF")"
SELF_TEST_RESOLVED="$(_resolve_symlinks "$SELF_TEST")"

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

# Drop the two self-exempt files (by resolved path — see _resolve_symlinks above).
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
# The scanner. Per line, reduce the line to its EXECUTABLE part — drop any `#`
# comment, and blank the CONTENTS of every quoted string literal that is not
# handed to a shell — then match the piped `grep -<cluster containing q>` shape
# against what is left. A heredoc body is subject to the same test at the level
# of the whole body (a `cat <<EOF` block is text; a `bash <<EOF` block is code).
#
# WHY THE QUOTE STRIP IS CONTENT-ONLY. The opening and closing quote CHARACTERS
# are preserved, only the bytes between them are dropped, so the pipeline
# structure around a string survives intact: `echo "x" | grep -q y` still reads
# as `echo "" | grep -q y` and still fires. Only text that lives INSIDE the
# quotes disappears — which is exactly the printed-help case (temperloop#1420).
#
# WHY IT IS PER-LINE. Comment and quote tracking both reset at each newline: a
# `#` or a quote inside an unterminated multi-line string could truncate early,
# which can only ever cause a MISSED site, never a false alarm — the safe
# direction for a guard whose false positives would land on prose. Heredoc
# tracking is the one deliberately multi-line piece of state, because a heredoc
# body has no other way to be recognised; it resets at every file boundary.
#
# THE HEREDOC TRADE-OFF, STATED. Treating every non-executor heredoc body as
# text also un-scans a body that is being WRITTEN somewhere rather than printed
# — `cat > "$f" <<EOF` generating a script. Measured on this tree that is ~3.8%
# of the shell corpus (6169 of 160264 lines), almost all of it test fixtures,
# and it hides no site that exists today: the tree lints clean either way. The
# alternative — scanning a heredoc that is redirected to a file — buys that
# coverage back and immediately re-opens this very defect one file over, on a
# generated MARKDOWN doc that merely documents the shape. Given a guard whose
# false positives land on prose and blocked a release, the deliberate choice is
# the missed-site direction, consistent with the per-line rule above. Two
# things keep the loss bounded: a heredoc handed to a shell (`bash <<EOF`) is
# still scanned, and a generated script that is itself tracked is still linted
# as a file in its own right.
# ---------------------------------------------------------------------------
report="$(
  awk '
    # The executor allowlist: commands that take a STRING (or a heredoc body)
    # and hand it to a shell. Text consumed by one of these is CODE and stays
    # scanned; everything else is printed text. See the header block.
    BEGIN {
      split("eval bash sh zsh ksh dash ash ssh env xargs timeout gtimeout " \
            "nohup flock watch su sudo docker podman kubectl", _x, " ")
      for (_i in _x) EXEC[_x[_i]] = 1
      # A bracket class matching the three characters that may quote a heredoc
      # word: backslash, single quote, double quote. Built as a STRING (\047 is
      # a portable octal escape there) because a literal single quote cannot
      # appear inside this single-quoted awk program.
      QCH = "[\\\\\047\"]"
    }

    # is_executor(prefix) — does the simple command that consumes the upcoming
    # string invoke a shell? Any token of the command (basename-normalised, so
    # `/bin/sh` counts) matching the allowlist answers yes. Token-wise rather
    # than first-word-only so `if bash -c "…"`, `VAR=1 eval "…"` and
    # `find . -exec sh -c "…" \;` are all recognised.
    function is_executor(prefix,   n, i, parts, w) {
      n = split(prefix, parts, /[^A-Za-z0-9_.\/-]+/)
      for (i = 1; i <= n; i++) {
        w = parts[i]
        sub(/^.*\//, "", w)
        if (w in EXEC) return 1
      }
      return 0
    }

    # strip_text(s) — return s reduced to its executable part: any real `#`
    # comment removed, and the CONTENTS of every non-executed quoted string
    # blanked (delimiters kept).
    function strip_text(s,   n, i, c, q, out, cmd, keep, prev, body) {
      n = length(s); i = 1; out = ""; cmd = ""
      while (i <= n) {
        c = substr(s, i, 1)
        if (c == "\\") { out = out c substr(s, i + 1, 1); i += 2; continue }
        if (c == "\047" || c == "\"") {
          q = c
          # A quoted HEREDOC WORD (`<<EOF` written as `<<\047EOF\047` or
          # `<<"EOF"`) is not a string literal at all — the quotes only suppress
          # expansion of the delimiter. Keep it, or heredoc_open below could
          # never see the terminator and every quoted-delimiter heredoc (the
          # commonest usage-block form) would go undetected.
          keep = is_executor(cmd) || cmd ~ /<<-?[[:space:]]*$/
          out = out q; cmd = cmd q
          i++
          body = ""
          while (i <= n) {
            c = substr(s, i, 1)
            # Inside single quotes a backslash is literal; inside double quotes
            # it escapes, so a \" does not close the string.
            if (q == "\"" && c == "\\") { body = body c substr(s, i + 1, 1); i += 2; continue }
            if (c == q) break
            body = body c; i++
          }
          if (keep) { out = out body; cmd = cmd body }
          if (i <= n) { out = out q; cmd = cmd q; i++ }
          continue
        }
        if (c == "#") {
          # `#` opens a comment only at a word boundary — this is what keeps
          # `${#arr}`, `$#` and `a#b` from truncating the line.
          prev = (i == 1) ? "" : substr(s, i - 1, 1)
          if (i == 1 || prev == " " || prev == "\t" || prev == ";" ||
              prev == "|" || prev == "&" || prev == "(" || prev == ")" ||
              prev == "<" || prev == ">") {
            return out
          }
        }
        # A simple-command boundary: the command word consuming the NEXT string
        # starts here. Redirections deliberately do not reset it.
        if (c == "|" || c == ";" || c == "&" || c == "(" || c == ")" ||
            c == "{" || c == "}" || c == "\140") {
          out = out c; cmd = ""; i++; continue
        }
        out = out c; cmd = cmd c; i++
      }
      return out
    }

    # heredoc_open(code) — if `code` opens a heredoc, set HD_DELIM (terminator),
    # HD_DASH (`<<-` strips leading tabs from the terminator) and HD_SCAN (the
    # body is code, not text). Otherwise leave HD_DELIM empty.
    #
    # Detection is deliberately TIGHT, because a false heredoc would swallow the
    # rest of the file and cost real sites: `<<<` (a herestring) is rejected by
    # the preceding-character check, and the delimiter must be quoted or
    # SHOUT_CASE, which is what keeps an arithmetic `$(( a << b ))` shift out.
    function heredoc_open(code,   tok, delim, quoted) {
      HD_DELIM = ""; HD_DASH = 0; HD_SCAN = 0
      # Dynamic (string) regexes, not /…/ constants: a single quote cannot be
      # written literally inside this single-quoted awk program, and \047 is
      # only reliably an octal escape in a STRING, not in a regex constant.
      if (!match(code, "<<-?[[:space:]]*" QCH "?[A-Za-z_][A-Za-z0-9_]*" QCH "?")) return
      if (RSTART > 1 && substr(code, RSTART - 1, 1) == "<") return   # `<<<` herestring
      if (substr(code, 1, RSTART) ~ /\$\(\(/) return                 # `$(( a << B ))` shift
      tok = substr(code, RSTART, RLENGTH)
      HD_DASH = (substr(tok, 3, 1) == "-")
      quoted = (tok ~ QCH)
      delim = tok
      sub(/^<<-?[[:space:]]*/, "", delim)
      gsub(QCH, "", delim)
      # SHOUT_CASE or explicitly quoted, else it is not a heredoc word — this is
      # what keeps an arithmetic `$(( a << b ))` shift from swallowing the file.
      if (!quoted && delim !~ /^[A-Z_][A-Z0-9_]*$/) return
      HD_DELIM = delim
      HD_SCAN = is_executor(code)
    }

    FNR == 1 { HD_DELIM = ""; HD_DASH = 0; HD_SCAN = 0 }

    {
      if (HD_DELIM != "") {
        term = $0
        if (HD_DASH) sub(/^\t+/, "", term)
        sub(/[[:space:]]+$/, "", term)
        if (term == HD_DELIM) { HD_DELIM = ""; next }
        if (!HD_SCAN) next
        code = $0
      } else {
        code = strip_text($0)
        heredoc_open(code)
      }
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
