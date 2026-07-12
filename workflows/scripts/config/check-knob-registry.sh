#!/usr/bin/env bash
#
# check-knob-registry.sh — equality + unregistered-knob lint for the kernel
# knob registry (temperloop#164/#169 D2, item registry-config-lints).
#
# Two independent checks, both NO-BASELINE (the registry was populated to
# match the tree exactly when it was built — see knob-registry.tsv's own
# header — so this lint must be strictly green on the committed tree from
# day one; a failure here is either real drift or a registry-maintenance
# gap, never debt to grandfather in):
#
#   1. EQUALITY — for every row in the registry (kernel table always; the
#      overlay extension table too, when present), every `${NAME:=default}`
#      / `${NAME:-default}` / `${NAME=default}` / `${NAME-default}` shell
#      seam for that exact NAME in the row's own `owning-script` must carry
#      EXACTLY the row's `default` literal. A row whose owning-script has NO
#      such seam at all is also a failure (a stale owning-script pointer),
#      except a row whose `doc` column starts with the literal word
#      `RESERVED` (knob-registry.tsv's own "Reserved" convention — a row
#      that intentionally has no live shell seam yet).
#
#      LAYER-AWARE: the kernel table's rows are checked against their own
#      (kernel) owning-scripts using the kernel table's OWN recorded
#      default — never the unioned/redefaulted view. An overlay `redefault`
#      row overrides a kernel knob's default for a DIFFERENT (overlay-owned)
#      call site; it does not change what the ORIGINAL kernel file's own
#      literal must say. So each table is walked independently: the kernel
#      row's default is checked against the kernel owning-script's literal,
#      and (when an overlay extension TSV is present) each overlay `add`/
#      `redefault` row's default is checked against ITS OWN (overlay-owned)
#      owning-script's literal — which, since an add/redefault row's 6
#      columns already ARE the final entry for that name/owning-script pair
#      in the unioned view (knob_registry_rows), is equivalent to "checked
#      against the unioned view" without needing to compute that union here.
#      A standalone kernel checkout (this repo, today) carries no overlay
#      extension TSV, so only the kernel-table pass ever runs in production;
#      the overlay pass is exercised by this lint's own test suite via a
#      synthetic fixture (KNOB_REGISTRY_OVERLAY_FILE + KNOB_REGISTRY_SCAN_ROOT
#      pointed at a throwaway tree), proving the seam works without this
#      repo needing a real overlay to prove it.
#
#   2. UNREGISTERED — every kernel-classified `*.sh` file (per
#      list-kernel-set.sh --class kernel, matching the same file-set
#      convention as check-personal-token-denylist.sh) is swept for
#      ALL-CAPS `${NAME:=...}` / `${NAME:-...}` / `${NAME=...}` /
#      `${NAME-...}` seams (a lowercase-containing name, e.g. `${ttl:-90}`,
#      is an ordinary local-variable default, not an operator knob — every
#      registered knob name in the tree is SCREAMING_SNAKE_CASE; this is the
#      mechanical proxy for "operator-tunable", see the header note below).
#      Every NAME found must be one of:
#        a. a registered knob name (present in the unioned kernel+overlay
#           registry, any owning-script — the EQUALITY check above already
#           pins a name to its specific owning-script; this membership test
#           is deliberately name-only, so a byte-identical duplicate seam in
#           a NON-owning file, e.g. FUNNEL_OPERATOR's documented duplicate
#           fallback in funnel-drive.sh/funnel-tick.sh per the registry's
#           own header, is correctly NOT flagged as unregistered);
#        b. `_`-prefixed private state (auto-excluded, mechanical);
#        c. in the hardcoded GENERIC_ALLOWLIST below (generic OS/XDG
#           passthrough, harness-injected runtime values, environment-
#           detection predicates — knob-registry.tsv's own "Inclusion rule"
#           section names these exact categories with these exact examples;
#           this list transcribes that prose into a mechanical check rather
#           than re-deciding it per PR);
#        d. matching the `*_NOW` / `*_NOW_*` pattern (the registry's own
#           inclusion rule names `BUILD_QUOTA_NOW` / `FUNNEL_NOW_*` as the
#           closed "test/reproducibility-only, documented as such in their
#           own script" category — a naming convention already in force
#           before this lint existed, so it's encoded as a pattern rather
#           than an ever-growing exact-name list); or
#        e. marked on ITS OWN LINE with a trailing `# knob:exempt — <reason>`
#           comment (mirrors check-personal-token-denylist.sh's
#           `# denylist:allow` convention exactly) — for a genuinely
#           internal/computed/dynamic-default seam that doesn't fit any
#           closed category above (a cached value re-read with a defensive
#           `:-` empty-string fallback, a per-call attribution tag computed
#           from `$FUNCNAME`, etc. — the "internal/derived/computed values
#           ... dynamic call-site defaults" categories from the registry's
#           inclusion rule, which are open-ended by nature and can't be
#           reduced to a fixed list).
#      A comment-only line (first non-space char `#`) is never scanned by
#      either check — prose that merely MENTIONS `${VAR:-default}` as a doc
#      example (this file's own header, knob-registry.tsv's header,
#      knob-registry-lib.sh's header) is not a seam.
#      One additional wholesale escape hatch, mirroring
#      personal-token-denylist-exempt-files.txt: a file listed in the
#      sibling knob-registry-exempt-files.txt is skipped by the sweep
#      entirely — for the rare case (a heredoc payload emitting shell text
#      for ANOTHER file) where a trailing same-line marker would itself
#      corrupt the emitted content. See that file's own header for today's
#      one entry (seed-kernel-repo.sh).
#
# Usage:
#   check-knob-registry.sh
#
# Env overrides (fixture-driven tests, mirroring the rest of
# workflows/scripts/kernel/*'s KERNEL_MANIFEST_ROOT/FILE convention):
#   KNOB_REGISTRY_FILE, KNOB_REGISTRY_OVERLAY_FILE   (knob-registry-lib.sh's
#     own seams — which file to read for the kernel/overlay TABLES)
#   KNOB_REGISTRY_SCAN_ROOT   root that owning-script paths (and the
#     unregistered-sweep's kernel-manifest file set) are resolved against.
#     Defaults to this repo's root. Also passed as --root to
#     list-kernel-set.sh, so a fixture test can point BOTH the registry
#     tables and the scanned file tree at the same throwaway checkout.
#   KNOB_REGISTRY_MANIFEST_FILE   passed as --manifest to list-kernel-set.sh
#     (defaults to that script's own default, the real kernel-manifest.txt)
#   KNOB_REGISTRY_EXEMPT_FILE   path to the wholesale file-exemption list
#     (default: sibling knob-registry-exempt-files.txt)
#
# Kept bash-3.2-portable (no associative arrays, no mapfile, no `${v: -1}`
# negative-offset substring) so it runs on the macOS dev shell as well as
# Linux CI, matching every other workflows/scripts/kernel/*.sh checker.

set -uo pipefail

# Force the C locale for this whole script: several bracket-range checks
# below (`case "$name" in *[a-z]*)`, the `[A-Za-z_]`/`[0-9]` char-class scans,
# and the `grep -E` seam pattern) rely on `[a-z]`/`[A-Z]` meaning exactly the
# 26 ASCII letters. Under a collation locale (e.g. en_US.UTF-8, the macOS dev
# shell default), bracket ranges are COLLATION-ORDER-based, not codepoint-
# based, and `[a-z]` can match some uppercase letters too — silently
# breaking the ALL-CAPS knob-name filter (mirrors board.sh's / test_board_
# cache.sh's own per-call `LC_ALL=C` use for the same reason, applied here
# script-wide since case-statement glob matching can't take a per-call
# prefix).
export LC_ALL=C

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"

: "${KNOB_REGISTRY_SCAN_ROOT:=$REPO_ROOT}"
: "${KNOB_REGISTRY_EXEMPT_FILE:=$SCRIPT_DIR/knob-registry-exempt-files.txt}"
: "${KNOB_REGISTRY_MANIFEST_FILE:=}"

# shellcheck source=workflows/scripts/config/knob-registry-lib.sh
source "$SCRIPT_DIR/knob-registry-lib.sh"

# The registry's own "Inclusion rule" section (knob-registry.tsv header)
# names these exact categories with these exact example names — transcribed
# here as a closed allowlist rather than re-litigated per PR. Space-
# separated, matched via the same linear-scan idiom as the rest of this
# repo's bash-3.2 checkers (_knob_registry_in_list, sourced above).
KNOB_REGISTRY_GENERIC_ALLOWLIST="HOME PATH SHELL TMPDIR TMUX TMUX_PANE CMUX_WORKSPACE_ID CLAUDE_PROJECT_DIR CLAUDE_CODE_SESSION_ID XDG_CONFIG_HOME XDG_DATA_HOME XDG_CACHE_HOME XDG_STATE_HOME HOSTNAME"

fail=0
issues=0

_kr_trim_leading_ws() {
  local s="$1"
  case "$s" in
    [[:space:]]*) printf '%s' "${s#"${s%%[![:space:]]*}"}" ;;
    *) printf '%s' "$s" ;;
  esac
}

_kr_is_comment_line() {
  # Strip leading whitespace inline (parameter expansion only) rather than via
  # a `$(_kr_trim_leading_ws …)` subshell: this runs once per line of every
  # owning-script scanned, once per registry row, so a per-call fork here cost
  # tens of thousands of process spawns and dominated the equality check's
  # runtime (K306).
  local trimmed="${1#"${1%%[![:space:]]*}"}"
  case "$trimmed" in
    '#'*) return 0 ;;
    *) return 1 ;;
  esac
}

# _knob_extract_default <text> -> walks <text> from its start, balancing
# `{`/`}` depth (starting at 1, for the already-consumed enclosing `${`),
# and prints the substring up to (excluding) the matching close-brace.
# Strips one layer of whole-value double quotes (`"x"` -> `x`) — the
# BOARD_ITEM_QUERY-style case where a value starting with `-` is quoted in
# shell (`${BOARD_ITEM_QUERY-"-status:Done"}`) but recorded unquoted in the
# registry (the quoting is shell syntax, not part of the value).
_knob_extract_default() {
  local text="$1" i=0 depth=1 len ch out=""
  len=${#text}
  while [ "$i" -lt "$len" ]; do
    ch="${text:$i:1}"
    if [ "$ch" = "{" ]; then
      depth=$((depth + 1))
    elif [ "$ch" = "}" ]; then
      depth=$((depth - 1))
      if [ "$depth" -eq 0 ]; then
        break
      fi
    fi
    out="$out$ch"
    i=$((i + 1))
  done
  if [ "${#out}" -ge 2 ]; then
    local last=$((${#out} - 1))
    if [ "${out:0:1}" = '"' ] && [ "${out:$last:1}" = '"' ]; then
      out="${out:1:$((${#out} - 2))}"
    fi
  fi
  printf '%s' "$out"
}

# _knob_seam_defaults_for <name> <file> -> prints EACH occurrence's
# extracted default, one per line, for every non-comment-line
# `${NAME:=...}` / `${NAME:-...}` / `${NAME=...}` / `${NAME-...}` seam for
# the exact <name> in <file>. rc 1 if the file is absent or has no such seam.
_knob_seam_defaults_for() {
  local name="$1" file="$2" line marker="\${${1}" tail op found=1
  [ -f "$file" ] || return 1
  while IFS= read -r line || [ -n "$line" ]; do
    _kr_is_comment_line "$line" && continue
    tail="$line"
    while true; do
      case "$tail" in
        *"$marker"*) ;;
        *) break ;;
      esac
      tail="${tail#*"$marker"}"
      case "$tail" in
        ":="*) op=":=" ;;
        ":-"*) op=":-" ;;
        "="*) op="=" ;;
        "-"*) op="-" ;;
        *) continue ;;
      esac
      tail="${tail#"$op"}"
      _knob_extract_default "$tail"
      printf '\n'
      found=0
    done
  done <"$file"
  return "$found"
}

# _knob_check_row <name> <default> <type> <layer> <owning_script> <doc> <table-label>
_knob_check_row() {
  local name="$1" default="$2" owning_script="$5" doc="$6" table="$7"
  case "$doc" in
    RESERVED*)
      return 0
      ;;
  esac
  local path="$KNOB_REGISTRY_SCAN_ROOT/$owning_script"
  local found_defaults rc
  found_defaults="$(_knob_seam_defaults_for "$name" "$path")"
  rc=$?
  if [ "$rc" -ne 0 ]; then
    printf 'EQUALITY: no shell seam found for %s (%s row) in owning-script %s (registry default: %s)\n' \
      "$name" "$table" "$owning_script" "$default"
    issues=$((issues + 1))
    fail=1
    return
  fi
  local d
  while IFS= read -r d; do
    if [ "$d" != "$default" ]; then
      printf 'EQUALITY: mismatch for %s (%s row) in %s — registry says %q, shell literal says %q\n' \
        "$name" "$table" "$owning_script" "$default" "$d"
      issues=$((issues + 1))
      fail=1
    fi
  done <<EOF
$found_defaults
EOF
}

# _kr_split_row <tab-row> -> sets name/default/type/layer/owning_script/doc
# from a 6-column TSV row using parameter expansion only (no forks). Replaces
# six `$(cut -f<n> <<<"$row")` subshells per row (K306). NOT `IFS=$'\t' read`:
# tab is IFS-whitespace, so `read` collapses consecutive tabs and would
# mis-align rows with an empty field (field 2 `default` is legitimately empty
# for many knobs, e.g. EVAL_RUN). Parameter expansion preserves empty fields,
# matching `cut -f` exactly. Trailing columns beyond field 6 are dropped, as
# `cut -f6` did.
_kr_split_row() {
  local r="$1"
  name="${r%%$'\t'*}";          r="${r#*$'\t'}"
  default="${r%%$'\t'*}";       r="${r#*$'\t'}"
  type="${r%%$'\t'*}";          r="${r#*$'\t'}"
  layer="${r%%$'\t'*}";         r="${r#*$'\t'}"
  owning_script="${r%%$'\t'*}"; r="${r#*$'\t'}"
  doc="${r%%$'\t'*}"
}

echo "=== check-knob-registry: equality (kernel table) ==="
kfile="$(knob_registry_kernel_file)"
kernel_rows="$(_knob_registry_data_rows "$kfile")"
if [ -z "$kernel_rows" ]; then
  echo "check-knob-registry: kernel registry has zero rows — nothing to check" >&2
  exit 1
fi
kernel_row_count=0
while IFS= read -r row; do
  [ -z "$row" ] && continue
  kernel_row_count=$((kernel_row_count + 1))
  _kr_split_row "$row"
  _knob_check_row "$name" "$default" "$type" "$layer" "$owning_script" "$doc" "kernel"
done <<EOF
$kernel_rows
EOF
echo "checked $kernel_row_count kernel row(s)"

ofile="$(knob_registry_overlay_file)"
overlay_row_count=0
if [ -f "$ofile" ]; then
  echo "=== check-knob-registry: equality (overlay extension table) ==="
  overlay_rows="$(_knob_registry_data_rows "$ofile")"
  while IFS= read -r row; do
    [ -z "$row" ] && continue
    overlay_row_count=$((overlay_row_count + 1))
    _kr_split_row "$row"
    _knob_check_row "$name" "$default" "$type" "$layer" "$owning_script" "$doc" "overlay"
  done <<EOF
$overlay_rows
EOF
  echo "checked $overlay_row_count overlay row(s)"
fi

# ---------------------------------------------------------------------------
# 2. Unregistered-knob sweep
# ---------------------------------------------------------------------------
echo "=== check-knob-registry: unregistered-knob sweep ==="

registered_names="$(knob_registry_rows | cut -f1 | sort -u | tr '\n' ' ')"

exempt_files=()
if [ -f "$KNOB_REGISTRY_EXEMPT_FILE" ]; then
  while IFS= read -r ex || [ -n "$ex" ]; do
    ex="${ex%%#*}"
    ex="$(_kr_trim_leading_ws "$ex")"
    ex="${ex%"${ex##*[![:space:]]}"}"
    [ -z "$ex" ] && continue
    exempt_files+=("$ex")
  done <"$KNOB_REGISTRY_EXEMPT_FILE"
fi

_kr_file_is_exempt() {
  local target="$1" ex
  for ex in "${exempt_files[@]+"${exempt_files[@]}"}"; do
    [ "$target" = "$ex" ] && return 0
  done
  return 1
}

list_kernel_set_args=(--class kernel --root "$KNOB_REGISTRY_SCAN_ROOT")
if [ -n "$KNOB_REGISTRY_MANIFEST_FILE" ]; then
  list_kernel_set_args+=(--manifest "$KNOB_REGISTRY_MANIFEST_FILE")
fi

files_scanned=0
seams_scanned=0
while IFS= read -r f; do
  [ -z "$f" ] && continue
  case "$f" in
    *.sh) ;;
    *) continue ;;
  esac
  # A file under a `tests/` directory is test-harness plumbing, not an
  # operator config surface — its env-var seams are mock/fixture injection
  # points (FAKE_*, GH_MOCK_*, LAUNCHCTL_MOCK_*, etc.), definitionally not
  # something "an OPERATOR could meaningfully override via the config
  # precedence ladder" (knob-registry.tsv's own Inclusion rule). No
  # registered knob's owning-script lives under `tests/` today, so this
  # exclusion can't hide a real drift. Path-pattern exclusion (not a per-file
  # exempt-files entry) because the volume of test files with mock seams is
  # large and unbounded — see knob-registry-exempt-files.txt for the
  # narrower, per-file mechanism this deliberately does NOT use here.
  case "$f" in
    */tests/* | tests/*) continue ;;
  esac
  _kr_file_is_exempt "$f" && continue
  path="$KNOB_REGISTRY_SCAN_ROOT/$f"
  [ -f "$path" ] || continue
  files_scanned=$((files_scanned + 1))

  # `grep -noE` yields one hit per MATCH, not per line — a line with two
  # seams (e.g. a nested `${A:-${B:-x}}`) produces two hits at the same
  # lineno. The inner loop below already walks the WHOLE line and finds
  # every occurrence on it in one pass, so re-running that walk for a
  # second hit on an already-processed line would double-report. Dedup on
  # lineno per file (space-separated, linear-scan — same bash-3.2 idiom as
  # _knob_registry_in_list).
  seen_linenos=""
  while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    lineno="${hit%%:*}"
    case " $seen_linenos " in
      *" $lineno "*) continue ;;
    esac
    seen_linenos="$seen_linenos $lineno"
    lncontent="$(sed -n "${lineno}p" "$path")"
    _kr_is_comment_line "$lncontent" && continue

    tail="$lncontent"
    while true; do
      case "$tail" in
        *"\${"*) ;;
        *) break ;;
      esac
      tail="${tail#*"\${"}"
      # candidate NAME is the run of [A-Za-z_][A-Za-z0-9_]* at the start of $tail
      name=""
      j=0
      tlen=${#tail}
      while [ "$j" -lt "$tlen" ]; do
        c="${tail:$j:1}"
        case "$c" in
          [A-Za-z_]) ;;
          [0-9]) [ -z "$name" ] && break ;;
          *) break ;;
        esac
        name="$name$c"
        j=$((j + 1))
      done
      if [ -z "$name" ]; then
        continue
      fi
      rest="${tail:$j}"
      case "$rest" in
        ":="* | ":-"* | "="* | "-"*) ;;
        *)
          tail="$rest"
          continue
          ;;
      esac
      seams_scanned=$((seams_scanned + 1))
      tail="$rest"

      # only ALL-CAPS (SCREAMING_SNAKE_CASE) names are candidate knobs —
      # a lowercase-containing name is an ordinary local-variable default.
      case "$name" in
        *[a-z]*) continue ;;
      esac
      # private (`_`-prefixed) implementation state — auto-excluded.
      case "$name" in
        _*) continue ;;
      esac
      # closed generic-passthrough / harness-injected / env-predicate list.
      if _knob_registry_in_list "$name" "$KNOB_REGISTRY_GENERIC_ALLOWLIST"; then
        continue
      fi
      # test/reproducibility-only clock-override pattern (BUILD_QUOTA_NOW,
      # FUNNEL_NOW_* per the registry's own inclusion rule).
      case "$name" in
        *_NOW | *_NOW_*) continue ;;
      esac
      # same-line marker.
      case "$lncontent" in
        *'# knob:exempt'*) continue ;;
      esac
      # registered anywhere in the unioned registry (name-only membership).
      if _knob_registry_in_list "$name" "$registered_names"; then
        continue
      fi

      printf 'UNREGISTERED: %s:%s: knob-shaped seam for %s has no registry row (and no exemption)\n    %s\n' \
        "$f" "$lineno" "$name" "$lncontent"
      issues=$((issues + 1))
      fail=1
    done
  done < <(grep -noE '\$\{[A-Za-z_][A-Za-z0-9_]*:?[=-]' "$path" 2>/dev/null || true)
done < <("$SCRIPT_DIR/../kernel/list-kernel-set.sh" "${list_kernel_set_args[@]}")

echo "swept $files_scanned kernel *.sh file(s), $seams_scanned knob-shaped seam(s)"

echo
if [ "$fail" -ne 0 ]; then
  echo "FAIL: $issues knob-registry issue(s) (equality mismatches + unregistered knobs)" >&2
  exit 1
fi
echo "OK — knob registry equality + unregistered-knob sweep clean (0 issues; $kernel_row_count kernel row(s)$( [ "$overlay_row_count" -gt 0 ] && printf ', %s overlay row(s)' "$overlay_row_count" ) checked, $files_scanned file(s) swept)"
