---
slug: configure-config-cli
---

# Configure wizard + `config list`

## Problem

The six-rung config precedence ladder (`docs/config-precedence.md`) and the
knob registry (`workflows/scripts/config/knob-registry.tsv`) give this repo
a documented, machine-readable set of ~150 tunable knobs — but before this
item, an operator had no CLI surface onto either half of that system.
Setting a machine-level override meant hand-writing a
`$XDG_CONFIG_HOME/temperloop/build.config.sh` file from scratch, copying
the `: "${VAR:=default}"` idiom correctly (and knowing it MUST be `:=`, not
a plain assignment, or the ladder silently breaks — see that doc's own
"before this ladder existed" postmortem). And once written, there was no
way to ask "what value is actually winning for knob X on this machine right
now, and why" without manually re-deriving the ladder by eye across up to
four candidate files. `temperloop configure` and `temperloop config list`
close both gaps: one write-side wizard, one read-side introspection
command, sharing the same ladder the rest of the repo already depends on.

## How it works

**`temperloop configure`** (`bin/subcommands/configure.sh`) is a short
wizard over a small, hardcoded starter set of four operator-facing knobs
(`FUNNEL_OPERATOR`, `FUNNEL_WIP_CAP`, `BUILD_MERGE_GATE_WINDOW`,
`BUILD_QUOTA_PAUSE_PCT` — chosen for type diversity and first-install
relevance, not an attempt to cover the full registry). It resolves each
knob's value from one of three sources, in order: an explicit
`--set NAME=VALUE` flag; one non-interactive `claude -p` call
(`--tools ""` — structurally zero tool access, so the model can only
return text and this script is what ever touches the filesystem) when
`claude` is on PATH; or a plain interactive/non-interactive shell prompt
otherwise. Every candidate value is validated against a type-appropriate
charset before it is ever considered resolved (closing off shell-metachar
injection into the file it writes). The final set is shown in a summary
and gated behind the same consent idiom `init.sh`/`eject.sh` use
(`--yes` / an interactive y/N / non-interactive default-deny) before
anything is written. The one file it ever touches is the machine-conf
file at precedence rung 3
(`${BUILD_CONFIG_MACHINE:-$XDG_CONFIG_HOME/temperloop/build.config.sh}`),
upserted line-by-line: an existing `: "${NAME:=...}"` line for a knob this
run touches is replaced in place (via `awk -v`, never `sed` interpolation),
every other line is left byte-identical, so re-running the wizard edits
rather than duplicates or clobbers.

**`temperloop config list`** (`bin/subcommands/config.sh list`) prints,
for every row in the unioned registry (kernel table + optional overlay
extension, via `knob-registry-lib.sh`), the resolved value and the rung
that produced it. The ladder itself deliberately tracks no live "winner"
bookkeeping (`docs/config-precedence.md` is pure source-order + `:=`), so
this command RE-DERIVES the answer via clean-subshell rung probes,
cheapest first: is the var already exported in this process's real
environment (rung 2, "env")? Else, does sourcing the machine-conf file set
it (rung 3)? Else the repo-local file (`BUILD_CONFIG_LOCAL`, rung 4)? Else
`build.config.sh` itself (rung 5/6's one physical file)? Else the
registry's own recorded default, reported under that row's own `layer`
column. Probes 3-5 each source their candidate file exactly ONCE for the
whole run (not once per knob) and cache every registry-known variable's
resulting value, so the command stays fast despite the registry's size.
Rung 1 (CLI flag) can never win here — there is no live invocation to
inspect at list-time — and the output says so once, up front, rather than
per row.

## Integration

Both subcommands are plain discovered files under `bin/subcommands/` —
`bin/temperloop`'s dispatch model (that script's own header) makes
`configure.sh`/`config.sh` into `temperloop configure` / `temperloop
config <subcommand>` automatically, with zero dispatcher changes. `config
list` reads `workflows/scripts/config/knob-registry-lib.sh` (the
`knob_registry_rows`/`knob_registry_validate` union API) and
`workflows/scripts/build/build.config.sh` directly; `configure` reads the
same registry lib for its curated knobs' default/type/doc metadata and
writes to the exact discovery path `build.config.sh` itself resolves at
rung 3 (via the already-registered `BUILD_CONFIG_MACHINE` knob), so a
`configure` write takes effect the next time any spine script sources
`build.config.sh` — no further wiring. Neither subcommand introduces a new
knob-registry row: `CLAUDE_BIN`'s existing row (owned by
`funnel-drive.sh`) already covers this item's identical-literal
`claude`-binary test-double seam per the registry's own
"byte-identical duplicate fallback" convention, and `configure`'s curated
knob list / validation charsets are plain hardcoded script constants, not
operator-overridable `${VAR:-default}` seams.

Note: `bin/temperloop`'s dispatcher requires `claude` + authenticated `gh`
on PATH before invoking ANY subcommand (a pre-existing, subcommand-agnostic
gate — see that script's own header) — this item does not touch that gate.
In practice, `configure`'s plain-prompt degradation and `config list`'s
zero-dependency operation are both exercised today by invoking the
subcommand scripts directly, exactly like the existing
`eject.sh`/`init.sh`/`try.sh` test suites already do.

## Resource impact

`config list` is pure local shell-state introspection: no network call, no
`gh`, no `claude`, bounded by sourcing three small/medium shell files a
handful of times total (not once per registry row) plus one pass over the
registry — a sub-second local operation. `configure`'s plain-prompt path is
equally free. Its AI-guided path costs exactly one `claude -p` call per
invocation, `--tools ""` and capped at `--max-budget-usd 0.25`
(`CONFIGURE_CLAUDE_MAX_BUDGET_USD`, a fixed script constant — not a
per-run-configurable knob, mirroring `try.sh`'s identical rationale for its
own shadow-triage cap), with a 60s watchdog
(`CONFIGURE_CLAUDE_TIMEOUT_SECS`); a failed or slow call degrades to the
zero-cost plain-prompt path rather than blocking or erroring the run.

## Telemetry

None. Both subcommands are local, interactive/scripted CLI tools with no
raw-lake emit site — consistent with the rest of the `bin/subcommands/*`
newcomer/adoption surface (`init.sh`, `eject.sh`, `try.sh`), none of which
emit telemetry either.
