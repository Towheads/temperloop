---
title: TemperLoop CLI install ladder
slug: install-cli
---

## Problem

Without a CLI entrypoint, a stranger evaluating this kernel would have to
hand-clone the repo, wire up symlinks, and run raw scripts before seeing any
real behavior — with no natural on-ramp from "look, read-only" to "opt my own
repo in." That is a large trust ask to make of someone still deciding
whether the tool is worth adopting, and a partial or wrong-flag install can
leave a repo half-configured with no easy way to check what actually landed.

## How it works

**Install.** A short bootstrap script (`bin/bootstrap.sh`, fetched over
`curl` or inspected first) shallow-clones this repo into
`~/.local/share/temperloop` (fast-forwarding it in place on re-run) and
symlinks `~/.local/bin/temperloop` to the entrypoint inside that checkout.
No shell-rc edits, no `sudo`. Uninstalling means removing those two paths;
that is the installer's entire footprint. (Through the v0.15.0 → v0.19.0
rename window it also symlinked a `foundation` compat shim, since the CLI was
named `foundation` before its rename. That symlink is no longer created; an
install that predates v0.19.0 may still carry one, and `temperloop uninstall`
removes it.)

**Update.** `temperloop update` (ADR 0002 "Managed-clone state ownership") is
the sole sanctioned way to move that managed clone's `HEAD` forward once it
exists. It fetches release tags (auto-converting a tagless `--depth 1` clone
via `git fetch --unshallow` on first run), prints the full CHANGELOG delta
for the jump — any `BREAKING`-marked section called out — BEFORE asking for
consent (an explicit `--yes`, an interactive `y/N`, or a legible refusal on a
non-interactive run; there is no timeout-as-consent), checks the on-disk
install manifest's schema against the target tag's own `manifest.sh` before
touching `HEAD` at all, then checks out the tag and re-runs `install` +
`doctor`. It takes no `--dir`/`--repo` argument — its entire write surface is
the managed clone's own git state plus the machine surface `install.sh`
already owns, never a repo-tracked path in any other repo.

**The adoption path: sandbox -> first epic -> adopt.** The reader makes a
private *duplicate* of a real repo of their own (not a fork — a fork of a
public repo is forcibly public, and carries an upstream that PR tooling
offers as a base), copies a handful of their open issues into it since
GitHub never copies issues to a fork, runs `temperloop init` there, and
takes the resulting first epic through `/assess` -> `/build`. The evaluation
is therefore the real pipeline doing real work on the reader's own code, in
a repo they delete afterwards. `README.md` § 3 is the canonical command
sequence.

**Legacy rungs: `try` and `try --demo`.** These were the first two steps of
the former ladder (`try` -> `try --demo` -> `init`) and are **no longer part
of the adoption path** — `try`'s shadow-triage runs with almost no context
so its output undersells the pipeline, and `--demo` exercises a canned repo
of synthetic defects rather than the reader's own code (temperloop#1115;
disposition tracked in temperloop#1117). Both still work, both still carry
their hard USD caps, and their contracts are unchanged:

1. `temperloop try` is zero-config and zero-writes. It runs a read-only
   conventions probe, lists the current repo's open issues with a
   directional cost estimate printed before anything else happens, then
   drives a real `claude -p` shadow-triage classification pass over those
   issues — invoked with `--tools ""` (every built-in tool disabled), a
   *structural* zero-write guarantee independent of the model's own
   behavior. No `gh` mutation is ever issued. A missing `gh`/network/auth
   degrades to a legible `skipped — <reason>` line per step rather than a
   hard failure, and the command exits 0 either way.
2. `temperloop try --demo` is the one deliberate, isolated mutating
   exception. It clones a disposable, already-seeded demo repo and drives
   one real safe-tier pipeline tick (issue -> PR) against it: claims one open
   demo-seed issue, gets a real (still `--tools ""`) judgment call for the
   fix, and opens a PR via the tree-only proposal-PR generator — never a
   direct push, never a merge. If every seeded issue is already claimed or
   closed, it exits 0 with "no tick run" instead of failing.
**`temperloop init` — the adopt step (current, not legacy).** Run it in the
sandbox to evaluate, and again in the real repo to adopt; it behaves
identically in both. It opts a repo in, then **hands off**. `init --dry-run`
previews the tree-only proposal PR with zero API writes of any kind. `init`
for real does exactly four things and stops: bootstraps `.temperloop/config`,
proposes any tree changes (e.g. a `boards.conf` entry) via a reviewable PR —
nothing ever lands without review — offers the kernel-shipped **first epic**
("Set up `<project>` with temperloop",
[ADR 0010](../adr/0010-onboarding-as-first-executed-epic.md)), and prints a
`next step:` handoff line. It applies **no API state of its own**.

**This step's handoff is the one part that needs `temperloop install`**:
`/assess` and `/build` are Claude Code slash commands, deployed into
`~/.claude/` by the install below, so unlike the legacy rungs above this one
does not end self-contained. `init` probes for the installed command and
prints an extra `prerequisite:` line when it is missing, rather than handing
the reader a pointer to something that isn't on their machine.

**Where the setup writes went.** Branch protection, head-branch auto-delete,
the merge-queue disposition, the required `checks` status context, the CI
workflow, and the adopter's review principles are all applied by that first
epic, driven through the real pipeline (`/assess --epic N` → `/build`) with
per-write consent and consequences disclosed at the moment of asking. `init`
used to apply a required check and a label set itself, under its own consent
prompt; that was retired (temperloop#796) for two reasons worth naming:
`init`'s required-check apply armed a `checks` context with no regard for
whether anything would ever post it (the self-brick the epic's structural
congruence rule makes unreachable), and the `fnd:`/pipeline labels are
already created lazily at point of use by the issues-only tracker backend,
so pre-creating them bought nothing. The flags that gated those applies
(`--yes/--no-required-check`, `--yes/--no-labels`, `--yes/--no-board`,
`--provision-board`, `--tracker-mode projects`) are **retained as deprecated
no-ops**: each still parses, prints one line naming where its step went, and
is ignored. Nothing that passes them breaks.

**Tracker mode.** Issues-only (`board.<N>.backend=issues`) is now the sole
init-time tracker mode (temperloop#793); `init` never provisions a GitHub
Projects-v2 board.

**Manual Projects-v2 recipe.** The capability is redirected, not removed —
to run a real Projects board, do it by hand, once:

1. Create the project: `gh project create --owner <owner> --title "<repo>
   board"`. Note the project number in the URL it prints
   (`.../projects/<N>`).
2. Hand-write the board's axes into `workflows/scripts/board/boards.conf`,
   replacing the `backend=issues` line `init` proposed for that board id:

   ```conf
   board.1.repo=<owner>/<repo>
   board.1.owner=<owner>
   board.1.project=<N>
   ```

3. Re-run whatever board command you were reaching for; the adapter reads
   `boards.conf` directly.

Doing it by hand is a deliberate trade. The retired automated arm rendered
its `boards.conf` entry *before* the apply step that learned the project
number, and never went back to fill it in — so even a fully consented,
successful run shipped a commented `board.<N>.project=<FILL IN …>`
placeholder. Because it was a comment, the adapter's `^board\.N\.axis=`
lookup did not see it and silently fell through to a built-in default owner
rather than failing loudly. A three-line hand edit you can read is better
than an automated one that quietly emits a broken contract.

**The safety contract.** The mutating step in the ladder is exactly one
(`try --demo`), and it is bounded three separate ways: a spend guard prints
a directional cost estimate and a hard mechanical cap (`--demo-cap-usd`,
default `$2.00` — ≈370,000 tokens at Claude Sonnet 5 list price, see
`docs/cost-and-autonomy.md` for the conversion basis) before anything runs; a non-interactive shell with no
`--yes` is refused outright, so a curious stranger cannot silently burn API
spend; and the tick itself touches only the disposable demo repo, never the
caller's own. `init` writes no API state at all, so its only mutating calls
are the tree-only proposal PR and the first-epic issue it offers to file
(plus, if you decline, the one Backlog pointer that keeps the gap tracked);
`--dry-run` skips even those.

**`doctor.sh` link states.** Every managed install path
(symlinks under `~/.claude/`, the composed `CLAUDE.md`, the `gh` logger
shim) is classified into one of five states: `OK` (symlink present and
correct, or the managed real file/shim is present), `MISSING` (target does
not exist), `DRIFT` (symlink present but points somewhere else, or a real
file exists where the wrong kind of thing is expected), `SHADOWED` (a real
file/directory sits where a symlink should be), or `DANGLING` (symlink
present but its target does not exist on disk). `bash
workflows/scripts/install/doctor.sh` exits 0 only
when every entry is `OK`, 1 otherwise (`temperloop install` also prints this
exact command at the end of its own run — see § Verify in `bin/README.md`).
It separately reports a
knowledge-store root check (does the agent-plane Obsidian MCP vault agree
with the script-plane `KNOWLEDGE_STORE_ROOT`?), a cross-checkout
install-source check (does the real, symlink-resolved location of a
representative installed surface —
`~/.claude/hooks/session-start-drain.sh` — belong to the SAME checkout
doctor is running from, or has `~/.claude` silently been bound to a
different clone entirely? A mismatch names both real paths and both
`.kernel-pin` tags), and, when a `boards.conf` is present, the per-board
issue-cache store state — all read-only, all `SKIPPED`-not-`FAIL` when the
underlying pieces simply aren't configured yet (the knowledge-store and
cross-checkout checks additionally FAIL — not just report — on a genuine
mismatch, contributing to doctor's exit code).

**Kernel/overlay compose.** `workflows/scripts/install-claude-md.sh`
composes the installed `~/.claude/CLAUDE.md` from three pieces, in order: a
generated-file banner, the kernel doc (`claude/CLAUDE.kernel.md`, with any
`{{SETTING_NAME}}` placeholder tokens substituted from config), a rendered
"Knowledge store routing" section, and the personal overlay doc
(`claude/CLAUDE.overlay.md`) verbatim. It is idempotent — composing the same
sources twice on the same machine reproduces the target byte-for-byte — and
alongside the composed file it writes a T0 inventory of every
knowledge-store note the composed rules actually reference.
An opt-in `INSTALL_CLAUDE_MD_KERNEL_ONLY=1` render-only mode emits the
rendered kernel doc alone — no banner, no knowledge-store-routing section,
no overlay, no T0-inventory write — for
`workflows/scripts/count-prose.sh`'s tier-1 prose-plane count (tier-1 = the
kernel-authored line count alone, as opposed to the full kernel+overlay
total a real install renders). `temperloop install` (this repo's own CLI;
a downstream fleet's `make install-claude` wrapper is the same story) never
sets it, so a normal compose is unaffected.

## Integration

Consumes: `gh` (authenticated) and `claude` on `PATH` — both are checked
before any subcommand does anything, and a missing tool prints exactly
what's missing and how to fix it rather than a stack trace. `doctor.sh`
consumes `workflows/scripts/install/links.sh`'s managed-path enumeration and
`workflows/scripts/build/build.config.sh` / `workflows/scripts/lib/
knowledge_store.sh` / `knowledge_store_obsidian.sh` for the vault-agreement
check. `try --demo` consumes the tree-only proposal-PR generator under
`workflows/scripts/proposal/`. `install-claude-md.sh` is invoked by
`temperloop install` (its `claude-md`-kind managed path) and is itself
verified by `doctor.sh`'s `claude-md` classification.

## Resource impact

Storage: a shallow clone into `~/.local/share/temperloop` (typically tens of
MB) plus a handful of negligible symlinks in `~/.local/bin`. API budget:
`try` issues zero `gh` mutations and one bounded `claude -p` call with tools
disabled; `try --demo` is hard-capped at `--demo-cap-usd` (default `$2.00`,
≈370,000 tokens at Claude Sonnet 5 list price), enforced before any spend,
and mechanically bounded to a single pipeline tick.
Runtime: `doctor.sh` is pure shell and sub-second; `try` and `try --demo`
each drive one `claude -p` invocation, so their wall time tracks that call.

## Telemetry

None dedicated. Each subcommand's own printed output is the observable
surface: `try`'s classification summary, `doctor`'s per-entry
`OK`/`MISSING`/`DRIFT`/`SHADOWED`/`DANGLING` table and its exit code,
`init --dry-run`'s preview diff, and `init`'s closing `next step:` handoff
line (the marker the tier-2 round-trip workflow greps to prove the live path
reached the handoff rather than degrading earlier). A failure surfaces as a
non-zero exit code plus an explicit `skipped — <reason>` or `FAIL —` line,
never a silent no-op.
