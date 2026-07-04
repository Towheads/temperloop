#!/usr/bin/env bash
#
# seed-demo-repo.sh — idempotent, script-generated seeder for the PRIVATE
# scratch demo repo (default: Towheads/temperloop-demo) that  # denylist:allow — the demo repo's own default slug (its identity, same category-1 rationale as bootstrap.sh's kernel-repo URL)
# `foundation try --demo` runs one real safe-tier funnel tick against
# (foundation #765 Epic D, item `demo-repo-seed` / foundation #851).
#
# WHAT IT DOES
#   1. Ensures the target repo exists (creates it PRIVATE if missing; never
#      flips visibility on an existing repo — that's a deliberate later
#      opt-in, Epic F launch work, not this script's job).
#   2. Ensures a small, fixed set of starter files exist in the repo (via
#      the Contents API — no local clone/push needed). Each file carries
#      exactly one small, deliberate, self-contained defect.
#   3. Ensures a matching fixed set of GitHub issues exists, one per
#      defect, each with a falsifiable acceptance check in its body. Every
#      seeded issue carries the `demo-seed` label (created on the repo if
#      missing) so this script can always find "its own" issues again.
#
# The demo repo itself carries NO custom automation (no .github/workflows,
# no bots) — a plain repo a stranger can freely inspect. Nothing in it is
# ever hand-edited; every file and every issue is reproducible from this
# script.
#
# IDEMPOTENCE (default mode, no --reset)
#   Safe to re-run at any time. Existing starter files are left untouched
#   (a demo tick may have legitimately "fixed" one — re-running the seeder
#   must not stomp real work). Existing `demo-seed`-labeled issues matching
#   a fixed-set title (open OR closed) are left alone; only missing titles
#   are created.
#
# --reset MODE
#   Returns the repo to a known baseline for repeated demo ticks:
#     - every `demo-seed`-labeled OPEN issue is closed (stale — this
#       includes issues from a fixed set that has since changed, not just
#       the current one; GitHub has no issue-delete API short of
#       `delete_repo` scope, so "recreate" means "close old, open fresh")
#     - every starter file is overwritten back to its canonical
#       (defect-containing) content
#     - the full current fixed set of issues is then created fresh (new
#       issue numbers every reset — this is expected and fine, nothing
#       downstream pins an issue number)
#
# Usage:
#   seed-demo-repo.sh [--repo OWNER/NAME] [--reset] [--dry-run]
#
# --repo OWNER/NAME   target repo (default: Towheads/temperloop-demo)  # denylist:allow — the demo repo's own default slug (its identity, same category-1 rationale as bootstrap.sh's kernel-repo URL)
# --reset             close stale demo-seed issues + recreate the fixed set;
#                      also overwrites starter files back to baseline
# --dry-run           print every `gh` call this run would make without
#                      executing any of them (no network writes)
#
# Requires: gh (authenticated, `repo` scope), base64, printf. bash 3.2
# compatible (no associative arrays, no `mapfile`/`readarray`).

set -euo pipefail

REPO="Towheads/temperloop-demo"  # denylist:allow — the demo repo's own default slug (its identity, same category-1 rationale as bootstrap.sh's kernel-repo URL)
RESET=0
DRY_RUN=0
SEED_LABEL="demo-seed"

usage() {
  cat <<'EOF'
usage: seed-demo-repo.sh [--repo OWNER/NAME] [--reset] [--dry-run]

  --repo OWNER/NAME   target repo (default: Towheads/temperloop-demo)  # denylist:allow — the demo repo's own default slug (its identity, same category-1 rationale as bootstrap.sh's kernel-repo URL)
  --reset             close stale demo-seed issues + recreate the fixed set;
                       also overwrites starter files back to baseline
  --dry-run           print gh calls without executing them
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --repo)
      REPO="${2:-}"
      shift 2
      ;;
    --reset)
      RESET=1
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      echo "seed-demo-repo: unknown argument '$1'" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ -z "$REPO" ]]; then
  echo "seed-demo-repo: --repo OWNER/NAME must not be empty" >&2
  exit 2
fi

for bin in gh base64; do
  if ! command -v "$bin" >/dev/null 2>&1; then
    echo "seed-demo-repo: required tool '$bin' not found on PATH" >&2
    exit 1
  fi
done

# run_gh CMD... — execute a gh invocation, or print it under --dry-run. The
# dry-run trace goes to stderr (not stdout) so it survives call sites that
# redirect the (real) gh call's own stdout to /dev/null to discard its JSON
# response body — dry-run's whole point is to stay visible regardless.
run_gh() {
  if [[ "$DRY_RUN" -eq 1 ]]; then
    printf '[dry-run] gh' >&2
    for a in "$@"; do
      printf ' %q' "$a" >&2
    done
    printf '\n' >&2
    return 0
  fi
  gh "$@"
}

# ---------------------------------------------------------------------------
# 1. Ensure the repo exists (PRIVATE). Never touches visibility of an
#    already-existing repo.
# ---------------------------------------------------------------------------
ensure_repo() {
  if gh repo view "$REPO" >/dev/null 2>&1; then
    echo "==> $REPO already exists"
    return 0
  fi
  echo "==> Creating $REPO (private)"
  run_gh repo create "$REPO" --private \
    --description "Scratch demo repo, script-generated and resettable by seed-demo-repo.sh (temperloop). No custom automation. Reset baseline, not a real project."
}

# ---------------------------------------------------------------------------
# 2. Starter files — each a fixed relative path + exact canonical content,
#    each carrying exactly one small, falsifiable defect.
# ---------------------------------------------------------------------------

# The fixed set of starter file paths, in seed order.
FILE_PATHS="greet.sh add_one.sh CONTRIBUTING.md README.md"

# file_content PATH — print the canonical (defect-containing) content for a
# given starter file path. bash-3.2-safe: a case statement standing in for
# an associative array.
file_content() {
  case "$1" in
    greet.sh)
      cat <<'EOF'
#!/usr/bin/env bash
# greet.sh — print a friendly greeting for the given name.
# Usage: ./greet.sh <name>
set -euo pipefail
name="${1:-World}"
echo "Helllo, ${name}!"
EOF
      ;;
    add_one.sh)
      cat <<'EOF'
#!/usr/bin/env bash
# add_one.sh — increment the given integer by one.
# Usage: ./add_one.sh <integer>
set -euo pipefail
n="${1:?usage: add_one.sh <integer>}"
echo $(( n + 2 ))
EOF
      ;;
    CONTRIBUTING.md)
      cat <<'EOF'
# Contributing

Thanks for your interest in this demo repository! It is script-generated
and reset on demand — contributions here are for demo/testing purposes
only, not a real open-source project.

If you'd like to recieve updates about the real project this demo
supports, see the temperloop repository instead.
EOF
      ;;
    README.md)
      cat <<'EOF'
# temperloop-demo

This is a **scratch demo repository**, script-generated and reset on
demand by `seed-demo-repo.sh` in the
[temperloop](https://github.com/Towheads/temperloop) repo.  # denylist:allow — the kernel repo's own public URL (its identity, same category-1 rationale as bootstrap.sh's kernel-repo URL)

It exists so the `temperloop` CLI's `try --demo` command has a real,
disposable repo to run one safe-tier issue -> PR tick against. Nothing
here is hand-edited — every file and every seeded issue is produced by
the seed script, and its `--reset` mode returns the repo to a known
baseline. This repo carries **no custom automation** of its own (no
GitHub Actions, no bots) — a plain repo you can freely inspect.

Small utilities live here purely as fix-it fodder for the demo tick:

- `greet.sh` — prints a greeting for a name
- `add_one.sh` — increments an integer

See the [Contributing Guide](./CONTRIBUTE.md) before opening a PR here.
EOF
      ;;
    *)
      echo "seed-demo-repo: internal error: no content defined for '$1'" >&2
      return 1
      ;;
  esac
}

# remote_file_sha PATH — print the blob sha of PATH in $REPO if it exists,
# nothing (and exit 0) if it does not. Guards on gh's own exit status
# (not stdout content) — `gh api ... -q` prints the raw error JSON body to
# stdout on a non-2xx response (e.g. 404), which would otherwise be
# mistaken for a real sha.
remote_file_sha() {
  sha_out=""
  sha_out="$(gh api "repos/$REPO/contents/$1" -q '.sha' 2>/dev/null)" && printf '%s' "$sha_out"
  return 0
}

# seed_file PATH FORCE — ensure PATH exists in $REPO with canonical content.
# FORCE=1 (reset mode) always overwrites; FORCE=0 only creates if missing.
seed_file() {
  path="$1"
  force="$2"
  sha="$(remote_file_sha "$path")"
  if [[ -n "$sha" && "$force" -ne 1 ]]; then
    echo "  -> $path already present, leaving as-is"
    return 0
  fi
  content="$(file_content "$path")"
  # Strip any trailing `# denylist:allow — ...` annotation a heredoc line may
  # carry — that marker exists solely to satisfy
  # check-personal-token-denylist.sh's per-line exemption on THIS script's
  # own source text; it must never leak into the payload actually pushed to
  # the seeded repo (a stranger reading README.md should never see it).
  content="$(printf '%s\n' "$content" | sed -E 's/[[:space:]]+# denylist:allow.*$//')"
  b64="$(printf '%s\n' "$content" | base64 | tr -d '\n')"
  if [[ -n "$sha" ]]; then
    echo "  -> resetting $path to baseline"
    run_gh api "repos/$REPO/contents/$path" -X PUT \
      -f "message=chore(demo): reset $path to seed baseline" \
      -f "content=$b64" \
      -f "sha=$sha" >/dev/null
  else
    echo "  -> creating $path"
    run_gh api "repos/$REPO/contents/$path" -X PUT \
      -f "message=chore(demo): seed $path" \
      -f "content=$b64" >/dev/null
  fi
}

seed_files() {
  echo "==> Seeding starter files"
  for p in $FILE_PATHS; do
    seed_file "$p" "$RESET"
  done
}

# ---------------------------------------------------------------------------
# 3. Issues — one per starter-file defect, titled uniquely, each carrying
#    the demo-seed label and a falsifiable acceptance check.
# ---------------------------------------------------------------------------

# The fixed set of issue titles, in seed order (parallel to issue_body()).
ISSUE_TITLES="greet.sh misspells its own greeting ('Helllo' instead of 'Hello')
add_one.sh adds 2 instead of 1
CONTRIBUTING.md has the typo 'recieve' (should be 'receive')
README.md links to a nonexistent CONTRIBUTE.md (should be CONTRIBUTING.md)"

# issue_body TITLE — print the body for a given fixed-set issue title.
# bash-3.2-safe: a case statement standing in for an associative array.
issue_body() {
  case "$1" in
    "greet.sh misspells its own greeting ('Helllo' instead of 'Hello')")
      cat <<'EOF'
`greet.sh` prints the wrong greeting text.

Repro:

    ./greet.sh World
    # => Helllo, World!   (extra "l")

Expected:

    Hello, World!

Acceptance (falsifiable):
- `./greet.sh World` outputs exactly `Hello, World!`
- `grep -c Helllo greet.sh` returns `0`
EOF
      ;;
    "add_one.sh adds 2 instead of 1")
      cat <<'EOF'
`add_one.sh` is supposed to increment its argument by one, but it adds
two instead.

Repro:

    ./add_one.sh 5
    # => 7   (expected 6)

Acceptance (falsifiable):
- `./add_one.sh 5` outputs `6`
- `./add_one.sh 0` outputs `1`
EOF
      ;;
    "CONTRIBUTING.md has the typo 'recieve' (should be 'receive')")
      cat <<'EOF'
`CONTRIBUTING.md` misspells "receive" as "recieve".

Acceptance (falsifiable):
- `grep -c recieve CONTRIBUTING.md` returns `0`
- `grep -c receive CONTRIBUTING.md` returns `1` or more
EOF
      ;;
    "README.md links to a nonexistent CONTRIBUTE.md (should be CONTRIBUTING.md)")
      cat <<'EOF'
The "Contributing Guide" link in `README.md` points at `./CONTRIBUTE.md`,
which does not exist in this repo. `CONTRIBUTING.md` (with the `-ING`)
does exist and is the intended target.

Acceptance (falsifiable):
- `README.md`'s Contributing Guide link resolves to a file that actually
  exists in the repo (i.e. points at `./CONTRIBUTING.md`, not
  `./CONTRIBUTE.md`)
EOF
      ;;
    *)
      echo "seed-demo-repo: internal error: no body defined for '$1'" >&2
      return 1
      ;;
  esac
}

ensure_seed_label() {
  if gh label list --repo "$REPO" --json name -q '.[].name' 2>/dev/null | grep -Fxq "$SEED_LABEL"; then
    return 0
  fi
  echo "==> Creating '$SEED_LABEL' label on $REPO"
  run_gh label create "$SEED_LABEL" --repo "$REPO" \
    --color "5319e7" \
    --description "Seeded by seed-demo-repo.sh - script-generated, never hand-edited" \
    --force
}

# existing_seed_titles — print every title (open or closed) currently
# carrying the demo-seed label, one per line.
existing_seed_titles() {
  gh issue list --repo "$REPO" --label "$SEED_LABEL" --state all \
    --json title -q '.[].title' 2>/dev/null || true
}

create_issue() {
  title="$1"
  echo "  -> creating issue: $title"
  body="$(issue_body "$title")"
  run_gh issue create --repo "$REPO" \
    --title "$title" \
    --body "$body" \
    --label "$SEED_LABEL" >/dev/null
}

close_stale_issues() {
  echo "==> --reset: closing stale $SEED_LABEL issues"
  numbers="$(gh issue list --repo "$REPO" --label "$SEED_LABEL" --state open --json number -q '.[].number' 2>/dev/null || true)"
  if [[ -z "$numbers" ]]; then
    echo "  -> none open"
    return 0
  fi
  for n in $numbers; do
    echo "  -> closing #$n"
    run_gh issue close "$n" --repo "$REPO" --reason "not planned" \
      --comment "Closed by seed-demo-repo.sh --reset (stale demo-seed issue)." >/dev/null
  done
}

seed_issues() {
  ensure_seed_label
  if [[ "$RESET" -eq 1 ]]; then
    close_stale_issues
    echo "==> --reset: recreating the fixed issue set"
    printf '%s\n' "$ISSUE_TITLES" | while IFS= read -r title; do
      [[ -z "$title" ]] && continue
      create_issue "$title"
    done
    return 0
  fi

  echo "==> Seeding issues"
  have="$(existing_seed_titles)"
  printf '%s\n' "$ISSUE_TITLES" | while IFS= read -r title; do
    [[ -z "$title" ]] && continue
    if printf '%s\n' "$have" | grep -Fxq "$title"; then
      echo "  -> issue already exists: $title"
      continue
    fi
    create_issue "$title"
  done
}

main() {
  ensure_repo
  seed_files
  seed_issues
  echo "==> Done ($REPO)"
}

main
