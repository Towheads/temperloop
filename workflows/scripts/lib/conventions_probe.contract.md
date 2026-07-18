# conventions-probe output contract

`conventions-probe` (foundation #765) is a **read-only detector** of a
target repository's conventions: branch naming, default-branch protection,
CI provider + job names, test/lint commands, commit/PR style, existing
`AGENTS.md`/`CLAUDE.md`/`CONVENTIONS.md` files, and label taxonomy. It
prints exactly one JSON document to stdout and does **nothing else** — no
file is ever created, modified, or deleted, not even a cache or a scratch
temp file that outlives the run. Persisting a probe result (e.g. into a
`.temperloop/config`) is a **separate, later item's** job — this seam only
produces the reading; it has no opinion on where a caller stores it.

Implementation: `workflows/scripts/probe/conventions-probe.sh` (bash,
3.2-compatible, no non-POSIX bashisms beyond what bash 3.2 supports —
no `declare -A`, no `mapfile`/`readarray`, no `${var,,}`). Depends on
`git` and `jq` (hard requirement — exit 1 if either is missing); `gh` is
optional and only gates two sections (see below) — its absence degrades
those two sections, never the whole run.

## Invocation

```
conventions-probe.sh [--dir DIR] [--gh-repo OWNER/REPO] [--no-network]
                      [--commit-sample N] [--timeout SECS]
```

| Flag | Default | Meaning |
|---|---|---|
| `--dir DIR` | `.` | Git checkout to probe. Resolved to the repo root (`git rev-parse --show-toplevel`), so a subdirectory is accepted. |
| `--gh-repo OWNER/REPO` | inferred | GitHub slug used by the two network-gated sections. If omitted, inferred from `git remote get-url origin` (github.com http(s)/ssh forms only). |
| `--no-network` | off | Force both network-gated sections to report unavailable, without attempting a `gh` call. |
| `--commit-sample N` | `50` | How many recent commits (on the checked-out `HEAD`) to sample for commit-style detection. |
| `--timeout SECS` | `10` | Per-network-call watchdog (portable bash-3.2 timeout, no `timeout` binary assumed). |

Exit codes: `0` — probe ran to completion (even if every network-gated
section reports unavailable — that is a successful, fully-legible result,
not a failure). `1` — fatal usage/environment error (`--dir` not a git
working tree, `git`/`jq` missing) — nothing on stdout. `2` — invalid CLI
usage — nothing on stdout.

## Output schema

The emitted document always carries a `schema` field, currently `1`. A
future breaking change to this shape bumps that integer; a caller that
parses this output should check `schema` before trusting field shapes
below it, rather than assuming the current version. There is deliberately
no separate schema file to keep in sync — this document IS the schema
contract, and `workflows/scripts/probe/tests/test_conventions_probe.sh`
pins the shape against a fixture repo so drift between this prose and the
script's real output is caught mechanically.

```json
{
  "schema": 1,
  "probe": "conventions-probe",
  "generated_at": "2026-07-03T15:13:43Z",
  "repo": { "...": "..." },
  "branch_naming": { "...": "..." },
  "branch_protection": { "...": "..." },
  "ci": { "...": "..." },
  "commands": { "...": "..." },
  "commit_style": { "...": "..." },
  "docs": { "...": "..." },
  "labels": { "...": "..." }
}
```

`generated_at` is a UTC ISO-8601 timestamp (`date -u +%Y-%m-%dT%H:%M:%SZ`)
— the one piece of non-deterministic output; every other field is a pure
function of the target repo's current state (and, for the two
network-gated sections, the GitHub API's current state).

### `repo`

| Field | Type | Meaning |
|---|---|---|
| `dir` | `null` (always) | Deliberately never populated (temperloop#416). This field previously carried the absolute local filesystem path to the probed repo's root — but this document's stdout is folded verbatim into a target repo's **committed** `.temperloop/config` by `foundation init`, so an absolute path here leaked the operator's local machine layout (home-directory username, a consultant's client-naming checkout path, ...) into someone else's repo history via a real reviewable PR. No caller in this tree ever read `.repo.dir`, so it is kept present-but-`null` (not removed) to preserve the field's schema shape rather than emit a private path. |
| `remote_url` | string \| null | `origin`'s remote URL, or `null` if there is no `origin` remote. |
| `gh_repo` | string \| null | `OWNER/REPO`, from `--gh-repo` or inferred from `remote_url` (github.com only); `null` if neither resolves. |
| `default_branch` | string \| null | `origin/HEAD`'s target branch name, falling back to the current checked-out branch; `null` if neither resolves (e.g. detached HEAD with no origin). |

### `branch_naming` (local-only, no network)

Derived from every local + `origin`-tracked branch name **except**
`default_branch` itself and the `origin/HEAD` symref.

| Field | Type | Meaning |
|---|---|---|
| `detected` | bool | `true` iff at least one non-default branch was found. |
| `pattern` | string | `"type/slug"` (≥60% of sampled branch names contain a `/` with a non-empty segment after it), `"free-form"` (≤20%), `"mixed"` (between), or `"unknown"` (zero branches sampled). |
| `prefixes` | array\<string\> | Distinct first path-segments of every slash-shaped branch name (e.g. `["feat","fix"]`), sorted. |
| `sample` | array\<string\> | Up to 15 branch names, in the order encountered, for eyeballing. |
| `sample_size` | int | Total branch count this section's ratio was computed over. |

This is a **heuristic over branch names that currently exist**, not a
policy read from a CONTRIBUTING doc — a repo that deletes merged branches
promptly will show a smaller, more head-branch-biased sample than one that
keeps history around.

### `branch_protection` (network-gated)

| Field | Type | Meaning |
|---|---|---|
| `available` | bool | `true` iff the section below reflects a real API read (including the legitimate "not protected" result). `false` means "could not determine" — see `reason`. |
| `reason` | string \| null | Non-null iff `available` is `false`. One of: `"skipped — network disabled (--no-network)"`, `"skipped — gh CLI not found on PATH"`, `"skipped — could not determine a GitHub owner/repo …"`, `"skipped — could not determine the default branch"`, `"skipped — gh api call timed out after Ns"`, or `"skipped — gh api call failed (auth, network, or permissions; …)"`. |
| `protected` | bool \| null | `true`/`false` when `available`; `null` when not. |
| `required_status_checks` | array\<string\> \| null | Context/check names required to merge, `[]` if protected with none required, `null` when unavailable. |
| `required_reviews` | int \| null | `required_approving_review_count`, or `null` if the branch is protected but that rule isn't set, or unavailable. |

A `404` from the GitHub branches-protection endpoint is a **legitimate,
available result** (`available: true, protected: false`) — it means the
branch genuinely has no protection ruleset, which is distinct from "could
not reach the API to find out."

### `ci` (local-only)

| Field | Type | Meaning |
|---|---|---|
| `providers` | array\<string\> | Distinct provider names detected, e.g. `["github-actions"]`. |
| `workflows` | array\<object\> | One entry per detected config file: `{"provider": "...", "file": "<repo-relative path>", "jobs": ["..."]}`. |

Providers detected by file presence: `github-actions`
(`.github/workflows/*.{yml,yaml}`), `circleci` (`.circleci/config.yml`),
`gitlab-ci` (`.gitlab-ci.yml`), `jenkins` (`Jenkinsfile`), `travis-ci`
(`.travis.yml`), `azure-pipelines` (`azure-pipelines.yml`),
`bitbucket-pipelines` (`bitbucket-pipelines.yml`). Job-name extraction is
implemented (non-empty `jobs`) only for `github-actions`, `circleci`, and
`gitlab-ci` — the other providers always report `"jobs": []` (presence
detected, job names not parsed).

**Job-name extraction is a heuristic, not a YAML parser.** For
`github-actions`/`circleci` it collects keys indented exactly two spaces
under the first `jobs:` line, stopping at the next line indented less; for
`gitlab-ci` it collects top-level (column-0) keys excluding a fixed
reserved-word list (`stages`, `variables`, `include`, `image`,
`before_script`, `after_script`, `workflow`, `default`, `cache`) and
hidden/template jobs (a leading `.` never matches the column-0 key
pattern this heuristic looks for). A config using flow-style YAML,
anchors/aliases, or unusual indentation may yield an empty or partial job
list — never a *wrong* one, by construction (the heuristic only ever adds
a key it directly matched at the expected indent, never infers one).

### `commands` (local-only)

| Field | Type | Meaning |
|---|---|---|
| `test` | array\<string\> | Detected test-invocation commands, e.g. `"make test"`, `"npm test"`, `"pytest"`, `"tox"`, `"cargo test"`, `"go test ./..."`. |
| `lint` | array\<string\> | Detected lint-invocation commands, e.g. `"make lint"`, `"npm run lint"`, `"ruff check ."`, `"flake8"`, `"cargo clippy"`, `"go vet ./..."`, `"pre-commit run --all-files"`. |
| `sources` | array\<string\> | Which convention files were consulted and matched something (e.g. `["Makefile","package.json"]`) — present even if it contributed zero commands, so a caller can tell "checked, found nothing" from "never checked." |

Sources consulted, in this order: `package.json` (`.scripts.test`, and any
script key containing `lint`), `Makefile`/`makefile`/`GNUmakefile` (targets
literally named `test`, `check`, or `lint`), `pyproject.toml` (presence of
a `[tool.pytest...]`/`[tool.ruff]`/`[tool.flake8]` section header),
`tox.ini`, `Cargo.toml`, `go.mod`, `.pre-commit-config.yaml`. This is a
**fixed, conservative set of common conventions** — a repo whose test
command lives behind a target name this heuristic doesn't recognize (e.g.
a bespoke `verify` target, this repo's own `quality-gates`) legitimately
reports empty `test`/`lint` arrays rather than guessing.

### `commit_style` (local-only)

| Field | Type | Meaning |
|---|---|---|
| `convention` | string | `"conventional-commits"` (≥60% of the sampled subjects match `^(feat\|fix\|chore\|docs\|refactor\|test\|style\|perf\|build\|ci\|revert)(\(scope\))?!?: `), `"free-form"` (≤20%), `"mixed"` (between), `"unknown"` (zero commits sampled — an empty repo). |
| `conventional_commits_pct` | int | The matched/total percentage (0–100) the classification above was computed from. |
| `sample_size` | int | How many commit subjects were actually sampled (≤ `--commit-sample`, fewer if the repo has less history). |
| `pr_template` | string \| null | Repo-relative path to the first PR template found (checked in order: `.github/PULL_REQUEST_TEMPLATE.md`, `.github/pull_request_template.md`, `docs/pull_request_template.md`, `PULL_REQUEST_TEMPLATE.md`, then the `.github/PULL_REQUEST_TEMPLATE/` multi-template directory), or `null`. |

### `docs` (local-only)

Root-level file presence only (no recursive search — a nested
`docs/CONVENTIONS.md` is not detected; this is a deliberate, documented
scope limit, not a bug).

| Field | Type | Meaning |
|---|---|---|
| `agents_md` | bool | `AGENTS.md` present at repo root. |
| `claude_md` | bool | `CLAUDE.md` present at repo root. |
| `conventions_md` | bool | `CONVENTIONS.md` present at repo root. |
| `found` | array\<string\> | Which of the three were actually found, e.g. `["CLAUDE.md"]`. |

### `labels` (network-gated)

| Field | Type | Meaning |
|---|---|---|
| `available` | bool | `true` iff `taxonomy`/`prefixes` reflect a real API read. |
| `reason` | string \| null | Non-null iff `available` is `false`; same shape of messages as `branch_protection.reason` (network disabled / gh missing / slug unresolved / timeout / call failed). |
| `taxonomy` | array\<object\> \| null | Every repo label as `{"name": "...", "color": "...", "description": "..." \| null}`, or `null` when unavailable. |
| `prefixes` | array\<string\> \| null | Distinct namespace prefixes (the part before a `:` or `/` in a label name, e.g. `fnd` from `fnd:status:ready`) that appear on **two or more** labels — a single one-off `foo:bar` label doesn't count as an established taxonomy prefix. `null` when unavailable, `[]` when available but no prefix meets the threshold. |

## Non-goals of this seam (deliberately out of scope)

- **No writes, ever.** Not `.temperloop/config`, not a cache, not a log
  file. A tracker/init item that wants to persist a probe result reads
  this script's stdout and owns its own write path — this script has no
  opinion on where or how.
- **No opinionated recommendation.** The probe reports what it *found*,
  not what a repo *should* do — no "you should adopt conventional
  commits" field. A consumer (a proposal generator, per the tracker/init
  item this feeds) makes that call from the raw signal.
- **No deep YAML/TOML parsing.** Every local-file section above is a
  grep/awk-level heuristic over common layouts, not a real parser for any
  of the formats it reads. A config in an unusual shape degrades to an
  empty/partial result, never a wrong one, and every heuristic's limits
  are documented in this file rather than left to be discovered by a
  caller.
- **No non-GitHub remotes.** `branch_protection` and `labels` are
  GitHub-API-shaped; a GitLab/Bitbucket/self-hosted-Git remote always
  reports those two sections unavailable (slug inference only recognizes
  `github.com` URLs).
