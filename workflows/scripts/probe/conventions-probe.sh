#!/usr/bin/env bash
#
# conventions-probe.sh — read-only detector of a target repo's conventions.
#
# foundation #765. PURE STDOUT, zero writes, always: this script never
# creates, modifies, or deletes a file anywhere (not `.foundation/config`,
# not a cache, not a scratch temp file that outlives the run) — it only
# reads the target checkout and (best-effort, network-gated) the GitHub
# API, and prints one JSON document to stdout. Persistence of a probe
# result is a LATER item's job (the tracker/init item that consumes this
# script's stdout); this script does not know that item exists.
#
# Output schema is versioned — see the `schema` field in the emitted
# document (currently 1) and the full field-by-field contract at
# workflows/scripts/lib/conventions_probe.contract.md (also rendered by
# `make docs`, so the schema ships as generated documentation, not just a
# comment in this file).
#
# Usage:
#   conventions-probe.sh [--dir DIR] [--gh-repo OWNER/REPO] [--no-network]
#                         [--commit-sample N] [--timeout SECS]
#
#   --dir DIR           Git checkout to probe. Default: current directory.
#                        Must be inside a git working tree.
#   --gh-repo OWNER/REPO
#                        GitHub repo slug for the two network-gated checks
#                        (branch protection, label taxonomy). Default:
#                        inferred from `git remote get-url origin` in DIR
#                        (github.com http(s)/ssh remotes only). If neither
#                        is available, those two sections report
#                        unavailable rather than guessing.
#   --no-network         Skip both network-gated checks unconditionally
#                        (offline mode) — same output shape, `available:
#                        false` with a `reason`. Useful in CI/tests where a
#                        `gh` call would otherwise attempt (and fail slowly
#                        on) a real network round-trip.
#   --commit-sample N    How many recent commits on the default branch to
#                        sample for commit-style detection. Default: 50.
#   --timeout SECS       Per-network-call watchdog timeout. Default: 10.
#
# Exit codes:
#   0   probe ran to completion; JSON document on stdout (even if every
#       network-gated section reports unavailable — that is a successful,
#       fully-legible probe result, not a script failure).
#   1   fatal usage/environment error (DIR is not a git repo, a required
#       tool is missing) — nothing on stdout, a message on stderr.
#   2   invalid CLI usage — nothing on stdout, a message on stderr.
#
# Dependencies: bash (3.2+), git, jq. `gh` is optional — its absence only
# degrades the two network-gated sections (see above), it never fails the
# whole run.
#
# shellcheck shell=bash

set -uo pipefail

# run_with_timeout SECS cmd... — portable bounded-subprocess watchdog, the
# ONE shared shim every such call site sources rather than re-deriving
# (temperloop#256). Path resolved via pure bash parameter expansion
# (${x%/*}), never `dirname` — this script's own gh-absent degrade path is
# exercised under an intentionally minimal PATH (see
# workflows/scripts/probe/tests/test_conventions_probe.sh's NOGHBIN
# allowlist) that does not include `dirname`.
_pt_here="${BASH_SOURCE[0]%/*}"; [ "$_pt_here" = "${BASH_SOURCE[0]}" ] && _pt_here="."
# shellcheck source=../lib/portable-timeout.sh
source "$(cd "$_pt_here/../lib" && pwd)/portable-timeout.sh"
unset _pt_here

# ---------------------------------------------------------------------------
# CLI parsing
# ---------------------------------------------------------------------------
usage() {
  cat <<'EOF'
usage: conventions-probe.sh [--dir DIR] [--gh-repo OWNER/REPO] [--no-network]
                             [--commit-sample N] [--timeout SECS]
EOF
}

case "${1:-}" in
  -h|--help) usage; exit 0 ;;
esac

probe_dir="."
gh_repo=""
no_network=0
commit_sample=50
probe_timeout=10

while [ $# -gt 0 ]; do
  case "$1" in
    --dir) probe_dir="${2:?--dir needs a value}"; shift 2 ;;
    --gh-repo) gh_repo="${2:?--gh-repo needs a value}"; shift 2 ;;
    --no-network) no_network=1; shift ;;
    --commit-sample) commit_sample="${2:?--commit-sample needs a value}"; shift 2 ;;
    --timeout) probe_timeout="${2:?--timeout needs a value}"; shift 2 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "conventions-probe.sh: unknown arg: $1" >&2; usage >&2; exit 2 ;;
  esac
done

if ! command -v git >/dev/null 2>&1; then
  echo "conventions-probe.sh: git not found on PATH" >&2
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  echo "conventions-probe.sh: jq not found on PATH" >&2
  exit 1
fi

probe_dir="$(cd "$probe_dir" 2>/dev/null && pwd)"
if [ -z "$probe_dir" ]; then
  echo "conventions-probe.sh: --dir does not exist" >&2
  exit 1
fi
if ! git -C "$probe_dir" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  echo "conventions-probe.sh: $probe_dir is not a git working tree" >&2
  exit 1
fi
# Repo root, not just the given dir (e.g. --dir pointed at a subdirectory).
probe_dir="$(git -C "$probe_dir" rev-parse --show-toplevel)"

have_gh=0
if command -v gh >/dev/null 2>&1; then
  have_gh=1
fi

# ---------------------------------------------------------------------------
# slug_from_remote URL — best-effort github.com owner/repo extraction from a
# `git remote get-url` value. Handles the two common forms; anything else
# yields empty (caller treats that as "could not infer").
# ---------------------------------------------------------------------------
slug_from_remote() {
  local url="$1" slug=""
  case "$url" in
    git@github.com:*) slug="${url#git@github.com:}" ;;
    ssh://git@github.com/*) slug="${url#ssh://git@github.com/}" ;;
    https://github.com/*) slug="${url#https://github.com/}" ;;
    http://github.com/*) slug="${url#http://github.com/}" ;;
    *) slug="" ;;
  esac
  slug="${slug%.git}"
  slug="${slug%/}"
  printf '%s' "$slug"
}

# ---------------------------------------------------------------------------
# 1. Repo info
# ---------------------------------------------------------------------------
remote_url="$(git -C "$probe_dir" remote get-url origin 2>/dev/null || true)"
if [ -z "$gh_repo" ]; then
  gh_repo="$(slug_from_remote "$remote_url")"
fi

default_branch="$(git -C "$probe_dir" symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed -e 's#^refs/remotes/origin/##')"
if [ -z "$default_branch" ]; then
  default_branch="$(git -C "$probe_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || true)"
fi
if [ "$default_branch" = "HEAD" ]; then
  default_branch=""
fi

repo_json="$(jq -n \
  --arg dir "$probe_dir" \
  --arg remote_url "$remote_url" \
  --arg gh_repo "$gh_repo" \
  --arg default_branch "$default_branch" \
  '{
    dir: $dir,
    remote_url: (if $remote_url == "" then null else $remote_url end),
    gh_repo: (if $gh_repo == "" then null else $gh_repo end),
    default_branch: (if $default_branch == "" then null else $default_branch end)
  }')"

# ---------------------------------------------------------------------------
# 2. Branch naming convention (local-only — no network needed)
# ---------------------------------------------------------------------------
detect_branch_naming() {
  local names total matched prefixes sample
  # Use the FULL refname and strip known prefixes ourselves, rather than
  # %(refname:short) — git collapses the origin/HEAD symref's short name to
  # the bare string "origin" (no slash), which would otherwise slip through
  # as a bogus free-form branch name. Excluding the literal ref
  # refs/remotes/origin/HEAD up front sidesteps that collapse entirely.
  names="$(git -C "$probe_dir" for-each-ref \
      --format='%(refname)' refs/heads refs/remotes/origin 2>/dev/null \
    | grep -v -x 'refs/remotes/origin/HEAD' \
    | sed -e 's#^refs/heads/##' -e 's#^refs/remotes/origin/##' \
    | sort -u)"
  if [ -n "$default_branch" ]; then
    names="$(printf '%s\n' "$names" | grep -v -F -x "$default_branch")"
  fi
  names="$(printf '%s\n' "$names" | grep -v '^$' || true)"

  total=0
  matched=0
  prefixes=""
  sample=""
  local n i=0
  while IFS= read -r n; do
    [ -z "$n" ] && continue
    total=$((total + 1))
    if [ $i -lt 15 ]; then
      sample="${sample}${n}"$'\n'
      i=$((i + 1))
    fi
    # "type/slug"-shaped: one path segment, alnum/._- body, non-empty slug.
    case "$n" in
      */*)
        local rest="${n#*/}"
        case "$rest" in
          "") ;; # trailing slash only, not a real slug
          *)
            matched=$((matched + 1))
            prefixes="${prefixes}${n%%/*}"$'\n'
            ;;
        esac
        ;;
    esac
  done <<EOF
$names
EOF

  local pattern ratio_x100
  if [ "$total" -eq 0 ]; then
    pattern="unknown"
  else
    ratio_x100=$((matched * 100 / total))
    if [ "$ratio_x100" -ge 60 ]; then
      pattern="type/slug"
    elif [ "$ratio_x100" -le 20 ]; then
      pattern="free-form"
    else
      pattern="mixed"
    fi
  fi

  local prefixes_json sample_json
  prefixes_json="$(printf '%s' "$prefixes" | grep -v '^$' | sort -u | jq -R -s 'split("\n") | map(select(length > 0))')"
  sample_json="$(printf '%s' "$sample" | grep -v '^$' | jq -R -s 'split("\n") | map(select(length > 0))')"

  jq -n \
    --argjson detected "$([ "$total" -gt 0 ] && echo true || echo false)" \
    --arg pattern "$pattern" \
    --argjson prefixes "$prefixes_json" \
    --argjson sample "$sample_json" \
    --argjson sample_size "$total" \
    '{detected: $detected, pattern: $pattern, prefixes: $prefixes, sample: $sample, sample_size: $sample_size}'
}
branch_naming_json="$(detect_branch_naming)"

# ---------------------------------------------------------------------------
# 3. Default-branch protection (network-gated)
# ---------------------------------------------------------------------------
detect_branch_protection() {
  local reason=""
  if [ "$no_network" -eq 1 ]; then
    reason="skipped — network disabled (--no-network)"
  elif [ "$have_gh" -ne 1 ]; then
    reason="skipped — gh CLI not found on PATH"
  elif [ -z "$gh_repo" ]; then
    reason="skipped — could not determine a GitHub owner/repo (no --gh-repo, no github.com origin remote)"
  elif [ -z "$default_branch" ]; then
    reason="skipped — could not determine the default branch"
  fi
  if [ -n "$reason" ]; then
    jq -n --arg reason "$reason" \
      '{available: false, reason: $reason, protected: null, required_status_checks: null, required_reviews: null}'
    return
  fi

  local out err_file status
  err_file="$(mktemp)"
  if out="$(run_with_timeout "$probe_timeout" \
      gh api "repos/${gh_repo}/branches/${default_branch}/protection" 2>"$err_file")"; then
    printf '%s' "$out" | jq '{
      available: true,
      reason: null,
      protected: true,
      required_status_checks: ((.required_status_checks.contexts // [])
        + (.required_status_checks.checks // [] | map(.context))
        | unique),
      required_reviews: (.required_pull_request_reviews.required_approving_review_count // null)
    }'
    rm -f "$err_file"
    return
  fi
  status=$?
  if [ "$status" -eq 137 ]; then
    reason="skipped — gh api call timed out after ${probe_timeout}s"
  elif grep -q 'HTTP 404' "$err_file" 2>/dev/null; then
    # A clean 404 means the branch genuinely has no protection ruleset —
    # this IS a real, available result, not an unreachable-API failure.
    rm -f "$err_file"
    jq -n '{available: true, reason: null, protected: false, required_status_checks: [], required_reviews: null}'
    return
  else
    reason="skipped — gh api call failed (auth, network, or permissions; run 'gh api repos/${gh_repo}/branches/${default_branch}/protection' by hand to see why)"
  fi
  rm -f "$err_file"
  jq -n --arg reason "$reason" \
    '{available: false, reason: $reason, protected: null, required_status_checks: null, required_reviews: null}'
}
branch_protection_json="$(detect_branch_protection)"

# ---------------------------------------------------------------------------
# 4. CI provider + job names (local-only)
# ---------------------------------------------------------------------------

# yaml_top_level_keys_under FILE HEADING_REGEX INDENT
# Crude, dependency-free "job name" extractor: finds the first line matching
# HEADING_REGEX (e.g. ^jobs:), then collects subsequent lines indented
# exactly INDENT spaces of the shape `<name>:` until indentation returns to
# <= the heading's own indent (0) or EOF. This is a heuristic over common
# GitHub Actions / CircleCI layouts, not a YAML parser — a file using flow
# style or unusual indentation may yield an empty or partial job list rather
# than a wrong one (best-effort, documented in the contract file).
yaml_top_level_keys_under() {
  local file="$1" heading_regex="$2" indent="$3"
  awk -v heading="$heading_regex" -v indent="$indent" '
    BEGIN { in_block = 0 }
    {
      line = $0
      if (!in_block) {
        if (line ~ heading) { in_block = 1 }
        next
      }
      # Blank or comment-only lines do not end the block.
      if (line ~ /^[[:space:]]*$/ || line ~ /^[[:space:]]*#/) { next }
      # Count leading spaces.
      n = match(line, /[^ ]/) - 1
      if (n < 0) { n = length(line) }
      if (n < indent) { in_block = 0; next }
      if (n == indent) {
        rest = substr(line, indent + 1)
        if (rest ~ /^[A-Za-z0-9_.-]+:/) {
          key = rest
          sub(/:.*/, "", key)
          print key
        }
      }
    }
  ' "$file"
}

detect_ci() {
  local workflows="[]"
  local f jobs_json jobs_raw provider

  if [ -d "$probe_dir/.github/workflows" ]; then
    while IFS= read -r f; do
      [ -z "$f" ] && continue
      jobs_raw="$(yaml_top_level_keys_under "$f" '^jobs:' 2)"
      jobs_json="$(printf '%s' "$jobs_raw" | grep -v '^$' | jq -R -s 'split("\n") | map(select(length > 0))')"
      workflows="$(jq -n --argjson acc "$workflows" --arg provider "github-actions" \
        --arg file "${f#"$probe_dir"/}" --argjson jobs "$jobs_json" \
        '$acc + [{provider: $provider, file: $file, jobs: $jobs}]')"
    done <<EOF
$(find "$probe_dir/.github/workflows" -maxdepth 1 -type f \( -name '*.yml' -o -name '*.yaml' \) 2>/dev/null | sort)
EOF
  fi

  if [ -f "$probe_dir/.circleci/config.yml" ]; then
    f="$probe_dir/.circleci/config.yml"
    jobs_raw="$(yaml_top_level_keys_under "$f" '^jobs:' 2)"
    jobs_json="$(printf '%s' "$jobs_raw" | grep -v '^$' | jq -R -s 'split("\n") | map(select(length > 0))')"
    workflows="$(jq -n --argjson acc "$workflows" --arg provider "circleci" \
      --arg file "${f#"$probe_dir"/}" --argjson jobs "$jobs_json" \
      '$acc + [{provider: $provider, file: $file, jobs: $jobs}]')"
  fi

  if [ -f "$probe_dir/.gitlab-ci.yml" ]; then
    f="$probe_dir/.gitlab-ci.yml"
    # GitLab jobs are top-level keys (indent 0) that don't start with `.`
    # (hidden/template jobs) and aren't one of the reserved pipeline keys.
    jobs_raw="$(awk '
      /^[A-Za-z0-9_-]+:/ {
        key = $0
        sub(/:.*/, "", key)
        reserved = (key == "stages" || key == "variables" || key == "include" || \
          key == "image" || key == "before_script" || key == "after_script" || \
          key == "workflow" || key == "default" || key == "cache")
        if (!reserved) print key
      }
    ' "$f")"
    jobs_json="$(printf '%s' "$jobs_raw" | grep -v '^$' | jq -R -s 'split("\n") | map(select(length > 0))')"
    workflows="$(jq -n --argjson acc "$workflows" --arg provider "gitlab-ci" \
      --arg file "${f#"$probe_dir"/}" --argjson jobs "$jobs_json" \
      '$acc + [{provider: $provider, file: $file, jobs: $jobs}]')"
  fi

  for pair in \
    "Jenkinsfile:jenkins" \
    ".travis.yml:travis-ci" \
    "azure-pipelines.yml:azure-pipelines" \
    "bitbucket-pipelines.yml:bitbucket-pipelines"
  do
    f="${pair%%:*}"
    provider="${pair##*:}"
    if [ -f "$probe_dir/$f" ]; then
      workflows="$(jq -n --argjson acc "$workflows" --arg provider "$provider" --arg file "$f" \
        '$acc + [{provider: $provider, file: $file, jobs: []}]')"
    fi
  done

  local providers_json
  providers_json="$(printf '%s' "$workflows" | jq '[.[].provider] | unique')"
  jq -n --argjson providers "$providers_json" --argjson workflows "$workflows" \
    '{providers: $providers, workflows: $workflows}'
}
ci_json="$(detect_ci)"

# ---------------------------------------------------------------------------
# 5. Test / lint commands (local-only, best-effort across common ecosystems)
# ---------------------------------------------------------------------------
detect_commands() {
  local test_cmds="" lint_cmds="" sources=""

  if [ -f "$probe_dir/package.json" ] && jq -e '.scripts' "$probe_dir/package.json" >/dev/null 2>&1; then
    sources="${sources}package.json"$'\n'
    if jq -e '.scripts.test' "$probe_dir/package.json" >/dev/null 2>&1; then
      test_cmds="${test_cmds}npm test"$'\n'
    fi
    local script_name
    while IFS= read -r script_name; do
      [ -z "$script_name" ] && continue
      case "$script_name" in
        lint|lint:*|*:lint) lint_cmds="${lint_cmds}npm run ${script_name}"$'\n' ;;
      esac
    done <<EOF
$(jq -r '.scripts | keys[]?' "$probe_dir/package.json" 2>/dev/null)
EOF
  fi

  local mk
  for mk in Makefile makefile GNUmakefile; do
    if [ -f "$probe_dir/$mk" ]; then
      sources="${sources}${mk}"$'\n'
      local target
      while IFS= read -r target; do
        [ -z "$target" ] && continue
        case "$target" in
          test|check) test_cmds="${test_cmds}make ${target}"$'\n' ;;
          lint) lint_cmds="${lint_cmds}make ${target}"$'\n' ;;
        esac
      done <<EOF
$(grep -E '^[A-Za-z0-9_.-]+:([^=]|$)' "$probe_dir/$mk" 2>/dev/null | sed -e 's/:.*$//' | sort -u)
EOF
      break
    fi
  done

  if [ -f "$probe_dir/pyproject.toml" ]; then
    sources="${sources}pyproject.toml"$'\n'
    grep -q '^\[tool\.pytest' "$probe_dir/pyproject.toml" 2>/dev/null && test_cmds="${test_cmds}pytest"$'\n'
    grep -q '^\[tool\.ruff' "$probe_dir/pyproject.toml" 2>/dev/null && lint_cmds="${lint_cmds}ruff check ."$'\n'
    grep -q '^\[tool\.flake8' "$probe_dir/pyproject.toml" 2>/dev/null && lint_cmds="${lint_cmds}flake8"$'\n'
  fi
  if [ -f "$probe_dir/tox.ini" ]; then
    sources="${sources}tox.ini"$'\n'
    test_cmds="${test_cmds}tox"$'\n'
  fi
  if [ -f "$probe_dir/Cargo.toml" ]; then
    sources="${sources}Cargo.toml"$'\n'
    test_cmds="${test_cmds}cargo test"$'\n'
    lint_cmds="${lint_cmds}cargo clippy"$'\n'
  fi
  if [ -f "$probe_dir/go.mod" ]; then
    sources="${sources}go.mod"$'\n'
    test_cmds="${test_cmds}go test ./..."$'\n'
    lint_cmds="${lint_cmds}go vet ./..."$'\n'
  fi
  if [ -f "$probe_dir/.pre-commit-config.yaml" ]; then
    sources="${sources}.pre-commit-config.yaml"$'\n'
    lint_cmds="${lint_cmds}pre-commit run --all-files"$'\n'
  fi

  local test_json lint_json sources_json
  test_json="$(printf '%s' "$test_cmds" | grep -v '^$' | sort -u | jq -R -s 'split("\n") | map(select(length > 0))')"
  lint_json="$(printf '%s' "$lint_cmds" | grep -v '^$' | sort -u | jq -R -s 'split("\n") | map(select(length > 0))')"
  sources_json="$(printf '%s' "$sources" | grep -v '^$' | sort -u | jq -R -s 'split("\n") | map(select(length > 0))')"

  jq -n --argjson test "$test_json" --argjson lint "$lint_json" --argjson sources "$sources_json" \
    '{test: $test, lint: $lint, sources: $sources}'
}
commands_json="$(detect_commands)"

# ---------------------------------------------------------------------------
# 6. Commit / PR style (local-only commit sample + template file presence)
# ---------------------------------------------------------------------------
detect_commit_style() {
  local subjects total matched ratio_x100 convention
  subjects="$(git -C "$probe_dir" log -n "$commit_sample" --pretty=%s 2>/dev/null || true)"
  total=0
  matched=0
  local s
  while IFS= read -r s; do
    [ -z "$s" ] && continue
    total=$((total + 1))
    case "$s" in
      feat*|fix*|chore*|docs*|refactor*|test*|style*|perf*|build*|ci*|revert*)
        if [[ "$s" =~ ^(feat|fix|chore|docs|refactor|test|style|perf|build|ci|revert)(\([a-zA-Z0-9_./-]+\))?\!?:\  ]]; then
          matched=$((matched + 1))
        fi
        ;;
    esac
  done <<EOF
$subjects
EOF

  if [ "$total" -eq 0 ]; then
    convention="unknown"
    ratio_x100=0
  else
    ratio_x100=$((matched * 100 / total))
    if [ "$ratio_x100" -ge 60 ]; then
      convention="conventional-commits"
    elif [ "$ratio_x100" -le 20 ]; then
      convention="free-form"
    else
      convention="mixed"
    fi
  fi

  local pr_template=""
  local candidate
  for candidate in \
    ".github/PULL_REQUEST_TEMPLATE.md" \
    ".github/pull_request_template.md" \
    "docs/pull_request_template.md" \
    "PULL_REQUEST_TEMPLATE.md"
  do
    if [ -f "$probe_dir/$candidate" ]; then
      pr_template="$candidate"
      break
    fi
  done
  if [ -z "$pr_template" ] && [ -d "$probe_dir/.github/PULL_REQUEST_TEMPLATE" ]; then
    pr_template=".github/PULL_REQUEST_TEMPLATE/"
  fi

  jq -n \
    --arg convention "$convention" \
    --argjson ratio_x100 "$ratio_x100" \
    --argjson sample_size "$total" \
    --arg pr_template "$pr_template" \
    '{
      convention: $convention,
      conventional_commits_pct: $ratio_x100,
      sample_size: $sample_size,
      pr_template: (if $pr_template == "" then null else $pr_template end)
    }'
}
commit_style_json="$(detect_commit_style)"

# ---------------------------------------------------------------------------
# 7. Existing convention docs (AGENTS.md / CLAUDE.md / CONVENTIONS.md)
# ---------------------------------------------------------------------------
detect_docs() {
  local found="" agents=false claude=false conventions=false
  local candidate
  for candidate in AGENTS.md CLAUDE.md CONVENTIONS.md; do
    if [ -f "$probe_dir/$candidate" ]; then
      found="${found}${candidate}"$'\n'
      case "$candidate" in
        AGENTS.md) agents=true ;;
        CLAUDE.md) claude=true ;;
        CONVENTIONS.md) conventions=true ;;
      esac
    fi
  done
  local found_json
  found_json="$(printf '%s' "$found" | grep -v '^$' | jq -R -s 'split("\n") | map(select(length > 0))')"
  jq -n \
    --argjson agents_md "$agents" \
    --argjson claude_md "$claude" \
    --argjson conventions_md "$conventions" \
    --argjson found "$found_json" \
    '{agents_md: $agents_md, claude_md: $claude_md, conventions_md: $conventions_md, found: $found}'
}
docs_json="$(detect_docs)"

# ---------------------------------------------------------------------------
# 8. Label taxonomy (network-gated)
# ---------------------------------------------------------------------------
detect_labels() {
  local reason=""
  if [ "$no_network" -eq 1 ]; then
    reason="skipped — network disabled (--no-network)"
  elif [ "$have_gh" -ne 1 ]; then
    reason="skipped — gh CLI not found on PATH"
  elif [ -z "$gh_repo" ]; then
    reason="skipped — could not determine a GitHub owner/repo (no --gh-repo, no github.com origin remote)"
  fi
  if [ -n "$reason" ]; then
    jq -n --arg reason "$reason" '{available: false, reason: $reason, taxonomy: null, prefixes: null}'
    return
  fi

  local out status
  if ! out="$(run_with_timeout "$probe_timeout" \
      gh api "repos/${gh_repo}/labels" --paginate --jq '.' 2>/dev/null)"; then
    status=$?
    if [ "$status" -eq 137 ]; then
      reason="skipped — gh api call timed out after ${probe_timeout}s"
    else
      reason="skipped — gh api call failed (auth, network, or permissions; run 'gh api repos/${gh_repo}/labels' by hand to see why)"
    fi
    jq -n --arg reason "$reason" '{available: false, reason: $reason, taxonomy: null, prefixes: null}'
    return
  fi

  # --paginate emits one JSON array per page, concatenated — slurp + flatten.
  local taxonomy_json prefixes_json
  taxonomy_json="$(printf '%s' "$out" | jq -s '[.[][] | {name: .name, color: .color, description: .description}]')"
  prefixes_json="$(printf '%s' "$taxonomy_json" | jq '
    [.[].name
      | select(test("^[A-Za-z0-9_-]+[:/]"))
      | capture("^(?<p>[A-Za-z0-9_-]+)[:/]").p]
    | group_by(.) | map(select(length >= 2) | .[0]) | sort')"

  jq -n --argjson taxonomy "$taxonomy_json" --argjson prefixes "$prefixes_json" \
    '{available: true, reason: null, taxonomy: $taxonomy, prefixes: $prefixes}'
}
labels_json="$(detect_labels)"

# ---------------------------------------------------------------------------
# Assemble + emit
# ---------------------------------------------------------------------------
generated_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

jq -n \
  --argjson schema 1 \
  --arg probe "conventions-probe" \
  --arg generated_at "$generated_at" \
  --argjson repo "$repo_json" \
  --argjson branch_naming "$branch_naming_json" \
  --argjson branch_protection "$branch_protection_json" \
  --argjson ci "$ci_json" \
  --argjson commands "$commands_json" \
  --argjson commit_style "$commit_style_json" \
  --argjson docs "$docs_json" \
  --argjson labels "$labels_json" \
  '{
    schema: $schema,
    probe: $probe,
    generated_at: $generated_at,
    repo: $repo,
    branch_naming: $branch_naming,
    branch_protection: $branch_protection,
    ci: $ci,
    commands: $commands,
    commit_style: $commit_style,
    docs: $docs,
    labels: $labels
  }'
