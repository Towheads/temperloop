#!/usr/bin/env bash
#
# lint-argloop-shift2.sh — mechanical guard against the temperloop#1342 footgun:
# an option loop that INFINITE-LOOPS when a value-taking flag is the final
# argument.
#
# THE BUG. Bash's `shift n` FAILS (`shift count out of range`) when n > $#, and
# a FAILED shift DOES NOT SHIFT — the positional parameters are left completely
# untouched. So in the ubiquitous shape
#
#   while [ $# -gt 0 ]; do
#     case "$1" in
#       --format) format="${2:-brief}"; shift 2 ;;   # <-- flagged
#       *) shift ;;
#     esac
#   done
#
# invoking the script as `… --format` (flag last, no value) leaves `$#` at 1
# forever: the same case arm re-matches, `shift 2` fails again, and the loop
# spins at 100% CPU until something kills it. `${2:-brief}` is what makes it a
# HANG rather than a crash — it removes the `set -u` unset-variable error that
# would otherwise have terminated the loop.
#
# MEASURED, not assumed (bash 5, `--flag` as the sole argument, 3s watchdog):
#
#   v="${2:-}";  shift 2                    rc=137  HANG   (killed by watchdog)
#   v="$2";      shift 2   (no `set -u`)    rc=137  HANG   (killed by watchdog)
#   v="${2:?needs a value}"; shift 2        rc=1    "2: needs a value"
#   v="$2";      shift 2   (with `set -u`)  rc=1    "$2: unbound variable"
#   v="${2:-}";  shift; [ $# -gt 0 ] && shift   rc=0  clean exit   <-- the fix
#
# THE FIX, in one line — shift the FLAG first, then the value only if one is
# actually there, so no shift can ever be out of range:
#
#   --format) format="${2:-brief}"; shift; if [ $# -gt 0 ]; then shift; fi ;;
#
# BLAST RADIUS (why this is a gate and not a style nit). Two shapes, both live:
#   (a) A hung script that IS a KERNEL_GATES entry does not FAIL the gate — it
#       burns the CI runner until the job timeout, so the signal is "slow" and
#       not "broken".
#   (b) Worse for the `emit-*.sh` telemetry family, whose own headers promise
#       "a telemetry emit must never fail or block the calling spawn site". A
#       hang is strictly worse than the failure that contract exists to
#       prevent, and the conventional `emit-… || true` call shape cannot save a
#       caller from it: an unset trailing variable at a spawn site hangs the
#       SPAWN SITE forever.
#
# WHY A LINT AND NOT (ONLY) A SWEEP. The known instances were swept with this
# change. The reason the class also needs a mechanical detector is recorded on
# temperloop#1342 itself: the identical defect was INDEPENDENTLY RE-DERIVED in
# brand-new code (workflows/scripts/async-workflow-health.sh, temperloop#1297)
# by a worker that had never seen the `emit-*.sh` sites. A sweep closes the
# instances; only a lint closes the class. And nothing else in the gate set
# catches it:
#   - `shellcheck`  exits 0 — every affected file is shellcheck-clean.
#   - `bash -n`     exits 0 — the line is syntactically perfect.
#   - a RUNTIME test catches it only for the one script it covers, and only if
#     that test is BOUNDED; an unbounded assertion for this defect HANGS the
#     suite instead of failing it, which is worse than no test at all.
#
# ── WHAT IS FLAGGED ────────────────────────────────────────────────────────
# A `shift N` (N >= 2) that is ALL of:
#   1. inside a `while`/`until` loop whose CONDITION references `$#` (the
#      option-loop shape — `[ $# -gt 0 ]`, `[[ $# -gt 0 ]]`, `(( $# ))`);
#   2. reached with NO preceding `$#` guard anywhere in that loop body, AND
#      not covered by the loop CONDITION's own guaranteed arity — a
#      `while [ "$#" -ge 2 ]` loop provably has two arguments in hand, so its
#      `shift 2` is safe and is not flagged; and
#   3. carrying a NON-FATAL `$2` expansion (see the exclusions below).
#
# ── WHAT IS NOT FLAGGED, and why ───────────────────────────────────────────
#   * `${2:?msg}` — a fatal expansion. Measured above: it EXITS (rc=1) with its
#     own message rather than looping. This was the first cut of the rule and
#     it was WRONG: it would have flagged ~58 live, correct sites across
#     bin/subcommands/ that provably cannot hang, i.e. a mass false positive on
#     files with no defect. The narrow rule fires on the shape that actually
#     spins.
#   * a bare `$2` / `"$2"` in a file that sets `-u` (or `-o nounset`) — same
#     reasoning, same measurement: `$2: unbound variable` terminates the shell.
#     A bare `$2` in a file WITHOUT `set -u` IS flagged; that one hangs.
#   * a `shift N` in a loop that already guards on `$#` in its body — the
#     `if [ $# -lt 2 ]; then … continue; fi` preflight
#     (workflows/scripts/emit-session-context.sh) is a correct, different fix
#     for the same defect, and flagging it would punish the fix.
#   * a `shift N` OUTSIDE any `$#`-conditioned loop — a function unpacking its
#     own arguments (`local a="$1" b="$2"; shift 2`) is not this defect: there
#     is no loop to spin.
#   * a `shift N` whose loop condition already guarantees N arguments —
#     `while [ "$#" -ge 2 ]; do url="$1"; num="$2"; shift 2; done`
#     (workflows/scripts/board/lib/board.sh's pair-consumer) cannot spin,
#     because the condition that admits the body is itself the arity check.
#     The condition's guaranteed minimum is parsed (`-ge N` -> N, `-gt N` ->
#     N+1, anything unparseable -> 1) and compared against the shift count.
#   * `shift "$n"` and other non-literal counts — not textually decidable.
#   * a `#` COMMENT that merely names the shape. Several files (including this
#     one and the two already-fixed sites) carry headers explaining exactly why
#     `shift 2` was wrong, and a guard that fires on the documentation of the
#     thing it guards is the temperloop#1152 defect class. The comment strip is
#     quote-aware, shared with lint-pipe-grep-q.sh / lint-bash32-ctlesc-ifs.sh.
#   * this script and its own regression test, which contain the shape as data.
#
#   * a value captured through a FATAL expansion earlier in the SAME case arm,
#     even when the `shift 2` is several lines below it and a NESTED `case`
#     sits in between (bin/subcommands/configure.sh's `--set` arm). Case-arm
#     attribution tracks `case`/`esac` nesting, so a nested arm's `;;` does not
#     end the OUTER arm.
#
# KNOWN LIMITS, stated rather than papered over. The scanner is textual, so:
# a `do`/`done` keyword reached through an alias or an `eval` is not tracked;
# a `$#` guard that lives in a FUNCTION the loop calls reads as unguarded; and
# a loop body guard anywhere before the shift exempts the WHOLE remaining body,
# not just the arm it protects (chosen deliberately — false negatives are
# cheaper than a gate that cries wolf, and the guarded shape is itself a fix).
#
# USAGE
#   scripts/lint-argloop-shift2.sh                # lint the tracked shell set
#   scripts/lint-argloop-shift2.sh FILE [FILE...] # lint explicit files
#   scripts/lint-argloop-shift2.sh --list         # print the resolved file set
#
# Exit 0 = clean; exit 1 = at least one unguarded `shift N` found; exit 2 =
# CANNOT EVALUATE (an absent or unreadable named path, an empty resolved file
# set, or a scanner that failed) — never a vacuous `OK`, per the fail-closed
# rule workflows/scripts/validate-check-surface-degenerate-coverage.sh enforces.
# Runs fully offline and shells out to nothing but `awk` and `git ls-files`.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# _resolve_symlinks <path> — canonicalize a path by following every symlink,
# both a symlinked LEAF file and any symlinked directory COMPONENT, without
# relying on GNU `readlink -f` or `realpath` (neither is guaranteed on the
# macOS/BSD userland this repo also runs on). Same helper, and same reason, as
# lint-bash32-ctlesc-ifs.sh: the self-exemption below must recognize this file
# through a vendoring overlay's compat symlink as well as its vendored original.
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

SELF="$REPO_ROOT/scripts/lint-argloop-shift2.sh"
SELF_TEST="$REPO_ROOT/scripts/tests/test_lint_argloop_shift2.sh"
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
# for the same reason its two siblings give: several of this repo's live
# scripts (bin/temperloop, .temperloop/report.d/tokens) do not end in `.sh`,
# and this defect is not specific to the `emit-*` family that surfaced it.
# ---------------------------------------------------------------------------
files=()
if [ "$#" -gt 0 ]; then
  # DEGENERATE INPUT FAILS CLOSED (temperloop#1409's class, enforced by
  # workflows/scripts/validate-check-surface-degenerate-coverage.sh). Without
  # this preflight an ABSENT or UNREADABLE named path made `awk` write
  # "can't open file" to stderr, leave the captured report EMPTY, and the
  # script print `OK` and exit 0 — a check that could not run reporting
  # success, which is exactly the shape that class exists to close.
  for f in "$@"; do
    if [ ! -e "$f" ]; then
      echo "lint-argloop-shift2: CANNOT EVALUATE — input path does not exist: $f" >&2
      exit 2
    fi
    if [ ! -r "$f" ]; then
      echo "lint-argloop-shift2: CANNOT EVALUATE — input path is not readable: $f" >&2
      exit 2
    fi
  done
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

# An EMPTY resolved file set is the third degenerate shape, and it fails closed
# for the same reason: a lint that scanned nothing has not established that
# anything is clean, so "OK" would be a vacuous pass. (Reachable when
# `git ls-files` returns nothing — no git, an empty checkout — or when every
# named path was self-exempt.)
if [ "${#kept[@]}" -eq 0 ]; then
  echo "lint-argloop-shift2: CANNOT EVALUATE — the resolved file set is empty; nothing was scanned" >&2
  exit 2
fi
files=("${kept[@]}")

if [ "$LIST_ONLY" -eq 1 ]; then
  for f in "${files[@]}"; do
    printf '%s\n' "${f#"$REPO_ROOT"/}"
  done
  exit 0
fi

# ---------------------------------------------------------------------------
# The scanner. Per file: pre-read once to learn whether `set -u` is in force
# (that decides whether a BARE `$2` terminates or hangs — measured above), then
# walk the lines tracking `do`/`done` nesting so a `shift N` can be attributed
# to the enclosing `$#`-conditioned loop, its guard state, and the `$2`
# expansion of the case arm it sits in.
# ---------------------------------------------------------------------------
report="$(
  awk '
    # ---- shared comment strip (quote-aware) -------------------------------
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

    # ---- count a shell KEYWORD in command position -------------------------
    # `do` / `done` are keywords only at the start of a command, so require
    # start-of-string or one of `; & | ( ) { }` (plus optional blanks) before,
    # and a non-word character or end-of-string after. This is what keeps
    # `echo done`, `$done`, and `todo` from moving the nesting depth.
    function count_kw(s, kw,   n, i, j, L, K, before, after, ok, w) {
      n = 0; L = length(s); K = length(kw); i = 1
      while (i <= L - K + 1) {
        if (substr(s, i, K) == kw) {
          after = (i + K > L) ? "" : substr(s, i + K, 1)
          ok = 1
          if (after != "" && after ~ /[[:alnum:]_]/) ok = 0
          # walk back over blanks to the first significant character
          j = i - 1
          while (j >= 1 && substr(s, j, 1) ~ /[[:blank:]]/) j--
          before = (j < 1) ? "" : substr(s, j, 1)
          if (before != "" && before !~ /[;&|(){}]/) {
            # …or a preceding shell KEYWORD, which also opens command position
            # (`; then case …`, `do while …`). Grab the word and check it.
            w = ""
            while (j >= 1 && substr(s, j, 1) ~ /[[:alnum:]_]/) { w = substr(s, j, 1) w; j-- }
            if (w != "do" && w != "then" && w != "else" && w != "elif" &&
                w != "in" && w != "fi" && w != "esac" && w != "done") ok = 0
          }
          if (ok) { n++; i += K; continue }
        }
        i++
      }
      return n
    }

    # ---- classify the `$2` reference on a line -----------------------------
    # "fatal"    -> ${2:?…} / ${2?…}          : exits, cannot spin
    # "tolerant" -> ${2:-…} / ${2-…} / ${2:=…}: no error, WILL spin
    # "bare"     -> $2 / ${2} / "${2}"        : spins unless `set -u` is on
    # ""         -> no `$2` reference on this line
    function classify2(s) {
      if (s ~ /\$\{2:?\?/)                 return "fatal"
      if (s ~ /\$\{2:?[-=+]/)              return "tolerant"
      if (s ~ /\$\{2\}/ || s ~ /\$2([^[:alnum:]_]|$)/) return "bare"
      return ""
    }

    # ---- the arity the loop CONDITION itself guarantees ---------------------
    # `[ $# -ge 2 ]` admits the body only with two arguments in hand, so its
    # `shift 2` provably cannot be out of range. `-gt N` guarantees N+1, `-ge`/
    # `-eq` guarantee N, and `(( $# ))` / anything this cannot parse falls back
    # to 1 — the `while [ $# -gt 0 ]` case, i.e. the defect shape.
    function cond_min(s,   m, op, num, rest) {
      if (match(s, /\$["\047]?#["\047]?[[:blank:]]*(-ge|-gt|-eq|>=|>|==)[[:blank:]]*["\047]?[0-9]+/)) {
        rest = substr(s, RSTART, RLENGTH)
        op = (rest ~ /-ge|>=/) ? "ge" : ((rest ~ /-eq|==/) ? "eq" : "gt")
        num = rest; sub(/^[^0-9]*/, "", num); sub(/[^0-9].*$/, "", num)
        return (op == "gt") ? num + 1 : num + 0
      }
      return 1
    }

    FNR == 1 {
      # Per-file reset, plus the `set -u` pre-read. `getline < FILENAME` reads
      # the file a second time from the top; close() makes that repeatable
      # across files and across a re-visit of the same name.
      setu = 0
      while ((getline pre < FILENAME) > 0) {
        p = strip_comment(pre)
        if (p ~ /(^|[;&|(){}[:blank:]])set[[:blank:]]+-[[:alnum:]]*u/) setu = 1
        if (p ~ /(^|[;&|(){}[:blank:]])set[[:blank:]]+-o[[:blank:]]+nounset/) setu = 1
      }
      close(FILENAME)
      in_loop = 0; depth = 0; guard = 0; arm2 = ""; pending = 0
      cmin = 1; casedepth = 0
    }

    {
      code = strip_comment($0)

      if (!in_loop) {
        # An option loop is a while/until whose CONDITION mentions `$#`.
        if (code ~ /(^|[;&|(){}[:blank:]])(while|until)([[:blank:]]|$)/ && code ~ /\$#/) {
          pending = 1
          cmin = cond_min(code)
        }
        if (pending && count_kw(code, "do") > 0) {
          in_loop = 1; depth = 1; guard = 0; arm2 = ""; pending = 0; casedepth = 0
          # a same-line `done` closes it again immediately
          depth -= count_kw(code, "done")
          if (depth <= 0) in_loop = 0
        }
        next
      }

      # ---- inside a `$#`-conditioned loop ----------------------------------
      depth += count_kw(code, "do") - count_kw(code, "done")
      if (depth <= 0) { in_loop = 0; next }

      # A `$#` reference anywhere in the body is an arity guard (or a
      # correct alternative fix); from here on this loop is exempt.
      if (code ~ /\$#/) guard = 1

      # Case-arm attribution. A `;;` ends an arm only at the OUTERMOST case
      # level inside this loop — a nested `case` (bin/subcommands/configure.sh
      # validating a `--set NAME=VALUE` before its `shift 2`) must not be read
      # as ending the arm that encloses it, or the fatal `${2:?…}` above it is
      # lost and the site reads as unguarded. The reset is applied at the END
      # of the line, so a whole arm written on ONE line still classifies.
      opened = count_kw(code, "case") - count_kw(code, "esac")
      newdepth = casedepth + opened
      armend = (code ~ /;;/) && casedepth <= 1 && newdepth <= 1
      casedepth = (newdepth < 0) ? 0 : newdepth

      c = classify2(code)
      if (c != "") arm2 = c

      if (!guard && match(code, /(^|[;&|(){}[:blank:]])shift[[:blank:]]+[0-9]+([^[:alnum:]_]|$)/)) {
        cnt = substr(code, RSTART, RLENGTH)
        sub(/^[^0-9]*/, "", cnt); sub(/[^0-9].*$/, "", cnt)
        if (cnt + 0 >= 2 && cnt + 0 > cmin) {
          cls = (c != "") ? c : arm2
          bad = 0
          if (cls == "tolerant") bad = 1
          else if (cls == "bare" && !setu) bad = 1
          else if (cls == "")    bad = 1
          if (bad) {
            printf "%s:%d: unguarded `shift %s` in a `while [ $# ]` option loop — spins forever when the flag is the final argument\n", FILENAME, FNR, cnt
            printf "%s:%d:     %s\n", FILENAME, FNR, $0
          }
        }
      }
      if (armend) arm2 = ""
    }
  ' "${files[@]}"
)"
scan_rc=$?

# The scanner failing is CANNOT EVALUATE, not "clean" — an empty report from a
# non-zero awk means the files were never read, and reporting OK there is the
# same vacuous pass the preflight above exists to prevent.
if [ "$scan_rc" -ne 0 ]; then
  echo "lint-argloop-shift2: CANNOT EVALUATE — the scanner exited $scan_rc; no verdict was produced" >&2
  exit 2
fi

if [ -n "$report" ]; then
  echo "lint-argloop-shift2: FAIL — an option loop can spin forever on a trailing value-flag:" >&2
  echo "  (Bash's \`shift n\` FAILS when n > \$#, and a FAILED shift DOES NOT SHIFT. So in a" >&2
  echo "   \`while [ \$# -gt 0 ]\` loop, \`--flag) v=\"\\\${2:-}\"; shift 2\` invoked with \`--flag\` as the" >&2
  echo "   LAST argument leaves \$# at 1 forever: the same arm re-matches and the loop pins a CPU." >&2
  echo "   The \`\\\${2:-}\` default is what makes it a HANG instead of a \`set -u\` crash. A hung" >&2
  echo "   KERNEL_GATES entry does not FAIL the gate — it burns the runner to the job timeout;" >&2
  echo "   and for an emit-*.sh telemetry script it hangs the SPAWN SITE, which no \`|| true\`" >&2
  echo "   call shape can prevent. Fix: shift the FLAG first, then the value only if it exists —" >&2
  printf '%s\n' "     --format) format=\"\${2:-brief}\"; shift 2 ;;" >&2
  printf '%s\n' "  -> --format) format=\"\${2:-brief}\"; shift; if [ \$# -gt 0 ]; then shift; fi ;;" >&2
  echo "   An arity preflight (\`if [ \$# -lt 2 ]; then …; continue; fi\`) is an accepted" >&2
  echo "   alternative and is not flagged. See temperloop#1342.)" >&2
  printf '%s\n' "$report" | sed "s|^${REPO_ROOT}/||; s|^|  |" >&2
  exit 1
fi

echo "lint-argloop-shift2: OK — no unguarded option-loop \`shift N\` in the tracked shell set"
