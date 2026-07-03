# Board Test Contracts

Three versioned contracts governing the replay infrastructure for the board-adapter
test suite. Consumers (board tests, CI validator assertions, eval scoring) depend on
these contracts' stability; breaking changes require a version bump.

---

## Contract 1 — argv-log format  (version: argv-log-v1)

**Owner:** `fake_gh.sh` — both access points converge on the same logic.

**What it is:**  
One shell-quoted line per `gh` invocation, written to the caller's log file.
The single canonical implementation lives in `_fake_gh_log_argv` inside `fake_gh.sh`.

**Format:**

```
gh <arg1-quoted> <arg2-quoted> ... <argN-quoted>\n
```

- First token is always the literal string `gh`.
- Each subsequent argument is separated by a single space and shell-quoted via
  bash's `%q` format specifier (i.e. `printf ' %q' "$arg"`). This ensures special
  characters (spaces, `?`, `\`, `<`, `>`) are escaped exactly as bash would require
  to round-trip the argument safely through `eval`.
- The line ends with a single `\n` (newline).
- Multiple invocations are appended to the same file; each occupies exactly one line.

**Access points:**

1. **PATH-binary** (`GH_LOG` + `GH_FIXTURES` env vars set, file on `PATH` as `gh`):
   The script records argv via `_fake_gh_log_argv "$@" >>"$LOG"` automatically on
   every invocation.

2. **In-process sourced** (`FAKE_GH_SOURCE=1 source fake_gh.sh`):
   Defines `_fake_gh_log_argv` for use in `_board_gh` overrides. Callers write:
   ```bash
   _fake_gh_log_argv "$@" >>"$CALLS"
   ```

**Consumers:**  
`test_board_replay.sh`, `test_milestone.sh` (in-process seam), any future
CI-validator assertion that diffs call logs.

**Stability note:**  
The `%q` quoting is bash-specific. Scripts that need to match recorded lines (e.g.
`grep -q 'gh project view ...'`) must account for `%q`'s escaping of `?` to `\?`
and similar characters (see `test_board_replay.sh` assertions against
`milestones\?state=open`).

---

## Contract 2 — scenario-directory layout  (version: scenario-dir-v1)

**What it is:**  
A scenario directory is the unit of test coverage for one board-workflow behavior.
It bundles all inputs, expected outputs, and metadata a replay runner needs to
execute the scenario without network access or human input.

**Directory layout:**

```
<scenario-name>/
  scenario.yaml          # (required) scenario manifest — see schema below
  fixtures/              # (required) board/API fixture files consumed by fake_gh.sh
    project_view.json
    field_list.json
    item_list.json
    issue_project_item.json   # optional; needed for board_resolve_item tests
    item_list_with_pr.json    # optional; for PR-card-drop tests
    <other>.json              # any additional fixtures declared in scenario.yaml
  goldens/               # (required) expected output files for diff-based assertions
    stdout.txt            # expected stdout of the command under test
    stderr.txt            # expected stderr (may be empty)
    calls.txt             # expected argv-log lines (argv-log-v1 format)
  invariants/            # (optional) machine-checked postconditions
    check_<id>.sh         # one per check_id listed in scenario.yaml
```

**`scenario.yaml` schema:**

```yaml
version: scenario-dir-v1       # required; must match this contract version

name: <slug>                   # required; matches the directory name
description: <free text>       # required; one sentence on what this tests

# Required-shims containment matrix.
# Declares every write channel this scenario exercises. A scenario that writes
# through a channel not listed here violates the containment boundary and MUST
# be updated to declare it (or the eval runner will refuse to execute it).
# See: mechanically detectable via the 'required_shims' field alone — no
# runtime inspection needed.
required_shims:
  gh: true | false             # required; true if this scenario calls any gh write
                               #   subcommand (project item-edit, issue create, etc.)
  git_remote: true | false     # required; true if this scenario pushes/fetches
  vault: true | false          # required; true if this scenario writes vault notes

# check_ids: list of invariant ids this scenario asserts.
# NAMESPACE NOTE: this field versions the check_id SYNTAX and LOCATION only.
# The check_id SEMANTICS (what each id means, the full registry) are owned
# by the validator-library item (separate from this component). Do not define
# new check_id semantics here.
check_ids:
  - <check-id-string>          # e.g. "board_item_status_in_progress"

# Fixture files beyond the defaults (project_view.json / field_list.json /
# item_list.json) that fake_gh.sh must serve for this scenario.
extra_fixtures: []             # list of filenames under fixtures/
```

**Mechanical detectability of unshimmed write channels:**

A scenario declaring `required_shims.gh: false` but exercising a `gh project
item-edit` (or any write subcommand) has an unshimmed write channel. This is
mechanically detectable: an eval runner reads `scenario.yaml`, checks the
`required_shims` matrix, and refuses to execute a scenario whose declared shims
don't cover all write subcommands observed in the fixture route-table. No runtime
inspection needed — the contract field alone enables the refusal.

**Eval-only note:**  
The `scenario.yaml` manifest and `invariants/` directory are eval-runner artifacts.
Board tests (`test_board_replay.sh` and siblings) use the `fixtures/` and `goldens/`
subtree directly without parsing `scenario.yaml`. The eval-only additions ship into
stageFind's vendored copy via `make sync-board` even though stageFind never runs
evals — accepted coupling; `fake_gh.sh` is the shared component and cannot be split.

---

## Contract 3 — run-artifact-bundle layout  (version: artifact-bundle-v1)

**What it is:**  
The validator-input contract: the set of files produced by one eval run that a
CI validator (or human reviewer) consumes to check correctness. This contract is
defined **independently of fake_gh.sh** — the bundle includes artifacts that
fake_gh.sh never produces (the plan note, the summary text).

**Bundle layout:**

```
<run-id>/
  summary.txt            # free-text summary of what the run did (required)
  plan_note.md           # the plan note the run consumed (required; may be the
                         #   input plan note, unchanged, or an annotated copy)
  mutation_log.txt       # argv-log-v1 format: all write-channel calls recorded
                         #   during the run, one per line (required; may be empty
                         #   if the run made no writes)
  <scenario-name>/       # per-scenario sub-bundle (zero or more)
    stdout.txt           # actual stdout
    stderr.txt           # actual stderr
    calls.txt            # argv-log-v1 lines for this scenario's invocations
```

**Key properties:**

- `mutation_log.txt` uses argv-log-v1 format (Contract 1). A CI validator that
  diffs against a golden log must account for the same `%q` quoting rules.
- `plan_note.md` is the human-readable input; its format is governed by
  `claude/plan-schema.md`, not this contract.
- `summary.txt` is unstructured free text; no schema is imposed here.
- Per-scenario `calls.txt` is a subset of `mutation_log.txt` — only the calls
  attributable to that scenario's execution window.

**Relation to scenario-dir-v1:**  
The `goldens/` directory inside a scenario directory (Contract 2) declares the
*expected* bundle for that scenario. A CI fixture is a scenario directory whose
actual run output matches its goldens — making it a declared instance of this
contract. Future fixtures from `#291` are declared instances of this layout.

**Namespace boundary:**  
This contract does not govern check_id semantics or the validator's pass/fail
logic. Those belong to the validator-library item.
