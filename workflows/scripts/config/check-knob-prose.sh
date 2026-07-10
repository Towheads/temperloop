#!/usr/bin/env bash
#
# check-knob-prose.sh — "prose names knobs, never values" lint (D3,
# temperloop#164/#169, item registry-config-lints).
#
# Fails when running prose in the kernel's command specs (claude/commands/
# *.md) or claude/CLAUDE.kernel.md restates a REGISTERED knob's literal
# default VALUE near the knob's NAME — e.g. "BUILD_MERGE_GATE_WINDOW,
# default 300" — instead of just naming the knob and letting the registry
# (or the shell literal itself) be the single source of truth for the
# current value. A doc that repeats "default 300" drifts silently the next
# time someone changes the shell literal; a doc that only names the knob
# never can.
#
# ── The heuristic (documented per this lint's own acceptance bar: "keep the
#    matching conservative enough to avoid false positives") ────────────────
# For each REGISTERED knob whose `default` is a SIMPLE literal (no
# `$`/`(`/`)`/`{`/`}`/`` ` `` — i.e. no variable/command-substitution syntax;
# a value like `$HOME/.claude/funnel/log` or `$(hostname -s)` could never appear
# verbatim as prose anyway, so there's nothing there to false-positive on)
# and non-empty, a line is a violation iff BOTH:
#   1. the knob's bare NAME appears anywhere on the line (inside or outside
#      backtick code spans — naming the knob, even in code font, is exactly
#      what D3 wants, so this half is deliberately permissive); AND
#   2. the knob's exact `default` VALUE appears in the line's PROSE portion
#      — i.e. with all backtick-delimited code spans stripped first, since a
#      value shown inside a code span (`` `${VAR:-300}` ``) is a legitimate
#      code demonstration of the real seam, not a prose restatement — with a
#      word boundary on the left always, and on the right too UNLESS the
#      knob's `type` is int/seconds/pct, in which case the right boundary
#      only excludes a following DIGIT (so "300s"/"300ms"/"10%"-style unit
#      suffixes immediately after a numeric value still count as the same
#      restatement, matching how these docs actually write durations/
#      percentages) rather than any following character.
# A fenced code block (a line whose trimmed text starts with `` ``` ``
# toggles the state) is skipped entirely, same rationale as code spans.
# Requiring the co-occurring NAME first is the primary precision lever — a
# short generic default (`0`, `1`, `gh`, `auto`) only ever gets checked on
# lines that ALREADY name that exact knob, not the whole file.
#
# ── Allow-marker ────────────────────────────────────────────────────────
# A line carrying the literal substring `<!-- knob-prose:allow` anywhere on
# it (an HTML comment — renders invisibly in Markdown, so it's safe to leave
# in published docs) is never scanned. Mirrors check-personal-token-
# denylist.sh's `# denylist:allow` convention, adapted to Markdown's comment
# syntax (a `#` prefix in a `.md` file would render as a heading, not a
# comment — the House convention this lint otherwise mirrors doesn't
# transplant verbatim, hence the different marker syntax).
#
# ── Burn-down baseline ──────────────────────────────────────────────────
# knob-prose-baseline.tsv (sibling file) lists (file, name, default, exact
# line content) rows for pre-existing violations — this lint's registered
# knobs were already used in prose before this lint existed, so day one
# isn't green without a baseline (contrast check-knob-registry.sh, which IS
# baseline-free because the registry was populated to already match the
# tree). A hit matching a baseline row is suppressed once per row (same
# consumed-once semantics as personal-token-denylist-baseline.tsv); a NEW
# violation — anywhere, including a new duplicate of an already-listed line
# — still fails. The follow-up item (prose-tunables-migration) rewrites each
# baselined line to name-only and empties this file.
#
# Usage:
#   check-knob-prose.sh
#
# Env overrides (fixture-driven tests):
#   KNOB_REGISTRY_FILE, KNOB_REGISTRY_OVERLAY_FILE   (knob-registry-lib.sh's
#     own seams)
#   KNOB_PROSE_SCAN_ROOT   root that claude/commands/*.md and
#     claude/CLAUDE.kernel.md are resolved against (default: this repo)
#   KNOB_PROSE_BASELINE_FILE   path to the burn-down baseline TSV (default:
#     sibling knob-prose-baseline.tsv)
#
# Kept bash-3.2-portable (no associative arrays, no mapfile) so it runs on
# the macOS dev shell as well as Linux CI, matching every other
# workflows/scripts/kernel/*.sh and workflows/scripts/config/*.sh checker.

set -uo pipefail
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

: "${KNOB_PROSE_SCAN_ROOT:=$REPO_ROOT}"
: "${KNOB_PROSE_BASELINE_FILE:=$SCRIPT_DIR/knob-prose-baseline.tsv}"

# shellcheck source=workflows/scripts/config/knob-registry-lib.sh
source "$SCRIPT_DIR/knob-registry-lib.sh"

_kp_ere_escape() {
  # Bracket-expression char order matters here: `]` first (literal close-
  # bracket) and `[` last-before-close (so it's never followed by `.`/`:`/
  # `=`, which BSD/macOS sed's stricter POSIX bracket-expression parser
  # reads as the start of a collating-symbol/class/equivalence token —
  # `[][.^$*+?(){}\|\\]` fails with "unbalanced brackets" on macOS for
  # exactly this reason, even though GNU sed accepts it).
  printf '%s' "$1" | sed -E 's/[]\.^$*+?(){}|[]/\\&/g'
}

# --- load candidates: name, default, type — RESERVED / empty-default /
#     shell-interpolation-syntax defaults are excluded (see header) --------
cand_names=()
cand_defaults=()
cand_types=()
while IFS=$'\t' read -r name default type _layer _owning doc; do
  [ -z "$name" ] && continue
  case "$doc" in
    RESERVED*) continue ;;
  esac
  [ -z "$default" ] && continue
  case "$default" in
    *'$'* | *'('* | *')'* | *'{'* | *'}'* | *'`'*) continue ;;
  esac
  cand_names+=("$name")
  cand_defaults+=("$default")
  cand_types+=("$type")
done <<EOF
$(knob_registry_rows)
EOF

if [ "${#cand_names[@]}" -eq 0 ]; then
  echo "check-knob-prose: zero restatable candidate knobs — nothing to check" >&2
  exit 1
fi

# --- load burn-down baseline ------------------------------------------------
baseline_files=()
baseline_names=()
baseline_defaults=()
baseline_lines=()
baseline_used=()
if [ -f "$KNOB_PROSE_BASELINE_FILE" ]; then
  while IFS=$'\t' read -r bfile bname bdefault bline || [ -n "${bfile:-}" ]; do
    [ -z "${bfile:-}" ] && continue
    case "$bfile" in \#*) continue ;; esac
    baseline_files+=("$bfile")
    baseline_names+=("$bname")
    baseline_defaults+=("$bdefault")
    baseline_lines+=("$bline")
    baseline_used+=(0)
  done <"$KNOB_PROSE_BASELINE_FILE"
fi

_kp_take_baseline() {
  local tf="$1" tn="$2" td="$3" tl="$4" j
  for j in "${!baseline_files[@]}"; do
    [ "${baseline_used[$j]}" = "0" ] || continue
    [ "${baseline_files[$j]}" = "$tf" ] || continue
    [ "${baseline_names[$j]}" = "$tn" ] || continue
    [ "${baseline_defaults[$j]}" = "$td" ] || continue
    [ "${baseline_lines[$j]}" = "$tl" ] || continue
    baseline_used[j]=1
    return 0
  done
  return 1
}

# --- target files ------------------------------------------------------------
targets=()
if [ -d "$KNOB_PROSE_SCAN_ROOT/claude/commands" ]; then
  while IFS= read -r f; do
    [ -n "$f" ] && targets+=("$f")
  done < <(find "$KNOB_PROSE_SCAN_ROOT/claude/commands" -maxdepth 1 -name '*.md' | sort)
fi
if [ -f "$KNOB_PROSE_SCAN_ROOT/claude/CLAUDE.kernel.md" ]; then
  targets+=("$KNOB_PROSE_SCAN_ROOT/claude/CLAUDE.kernel.md")
fi

if [ "${#targets[@]}" -eq 0 ]; then
  echo "check-knob-prose: no target files found under $KNOB_PROSE_SCAN_ROOT" >&2
  exit 1
fi

violations=0
baselined=0
name_hits=0

# _kp_line_in_fence <lineno> <space-separated fence-marker linenos> -> rc 0
# if <lineno> IS a fence-delimiter line or falls inside an open fence (an
# odd number of markers precede it).
_kp_line_in_fence() {
  local target="$1" markers="$2" m count=0
  for m in $markers; do
    [ "$m" = "$target" ] && return 0
    [ "$m" -lt "$target" ] && count=$((count + 1))
  done
  [ $((count % 2)) -eq 1 ]
}

# Candidate-first scan: ONE `grep -n` per (candidate, file) pair finds the
# name-bearing lines (violations are sparse — most candidates never appear
# in most files), then only those few hit lines get the per-line fence/
# marker/code-span/default checks. The inverted per-line × per-candidate
# loop this replaces spawned a subprocess per pair per LINE (~400k for the
# real tree) and took minutes; this shape is a few hundred greps total.
for path in "${targets[@]}"; do
  rel="${path#"$KNOB_PROSE_SCAN_ROOT"/}"
  # fence-delimiter linenos, space-separated (a trimmed-leading-whitespace
  # line starting ``` toggles fence state).
  fence_markers="$(grep -nE '^[[:space:]]*```' "$path" | cut -d: -f1 | tr '\n' ' ')"

  for i in "${!cand_names[@]}"; do
    name="${cand_names[$i]}"
    default="${cand_defaults[$i]}"
    type="${cand_types[$i]}"
    name_esc="$(_kp_ere_escape "$name")"
    esc="$(_kp_ere_escape "$default")"
    case "$type" in
      int | seconds | pct)
        pat="(^|[^0-9A-Za-z_])${esc}([^0-9]|\$)"
        ;;
      *)
        pat="(^|[^0-9A-Za-z_])${esc}([^0-9A-Za-z_]|\$)"
        ;;
    esac

    # word-bounded NAME check on the FULL line (in or out of code spans —
    # naming the knob in code font is fine, see header). Word-bounded, not
    # substring, so FUNNEL_OPERATOR does not match inside
    # FUNNEL_OPERATOR_ABSENT (a different, longer identifier).
    while IFS= read -r hit; do
      [ -z "$hit" ] && continue
      lineno="${hit%%:*}"
      line="${hit#*:}"
      name_hits=$((name_hits + 1))
      _kp_line_in_fence "$lineno" "$fence_markers" && continue
      case "$line" in
        *'<!-- knob-prose:allow'*) continue ;;
      esac
      # strip backtick code spans; nothing here expands — the quoting is a
      # literal sed program, not a missed expansion.
      # shellcheck disable=SC2016
      prose="$(printf '%s' "$line" | sed -E 's/`[^`]*`//g')"
      if printf '%s' "$prose" | grep -qE -- "$pat"; then
        if _kp_take_baseline "$rel" "$name" "$default" "$line"; then
          baselined=$((baselined + 1))
          continue
        fi
        if [ "${KNOB_PROSE_EMIT_BASELINE:-0}" = "1" ]; then
          # maintenance mode: print ready-to-append baseline TSV rows
          # instead of violation text (used to seed/regenerate
          # knob-prose-baseline.tsv; still exits non-zero so it can't be
          # mistaken for a passing lint run).
          printf '%s\t%s\t%s\t%s\n' "$rel" "$name" "$default" "$line"
        else
          printf 'PROSE: %s:%s: %s ~ default %s restated in prose\n    %s\n' \
            "$rel" "$lineno" "$name" "$default" "$line"
        fi
        violations=$((violations + 1))
      fi
    done < <(grep -nE -- "(^|[^0-9A-Za-z_])${name_esc}([^0-9A-Za-z_]|\$)" "$path" 2>/dev/null || true)
  done
done

echo
if [ "$violations" -gt 0 ]; then
  echo "FAIL: $violations knob-prose violation(s) across ${#targets[@]} file(s), $name_hits knob-name-bearing line(s) checked ($baselined pre-existing hit(s) suppressed via burn-down baseline)" >&2
  exit 1
fi
echo "OK — 0 new knob-prose violations across ${#targets[@]} file(s), $name_hits knob-name-bearing line(s) checked ($baselined pre-existing hit(s) suppressed via burn-down baseline; see knob-prose-baseline.tsv)"
