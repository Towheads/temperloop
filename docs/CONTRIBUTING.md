# Contributing: failure-mode chapters

`docs/failure-modes/` holds the "why" chapters for the generated docs site:
short, curated write-ups of real engineering failures encountered while
building this project's automation, each ending in a mechanical guard that
now exists because of it. They are rendered as pages by `make docs` — see
`workflows/scripts/docs/sources/chapters.py` for the ingestion mechanism.

This file lives at `docs/CONTRIBUTING.md`, one level above
`docs/failure-modes/`, deliberately — the generator's pinned ingestion glob
is `docs/failure-modes/*.md`, so anything dropped inside that directory
renders as a chapter page. Keeping this guide a level up keeps it from
being picked up as a spurious chapter itself.

## Contributing a chapter

Chapters are **committed Markdown files, authored by hand** — never rendered
from a live data source at build time. The generator only scans
`docs/failure-modes/*.md` and renders whatever it finds there; it does not
reach out to any external notes store, and CI never could (no network, no
credentials to one). So the harvest-and-scrub step happens once, by a
human, before a file lands in that directory.

A chapter should:

1. **Name the failure** — what went wrong, concretely (a command, a tool
   call, a race), not an abstract category.
2. **Explain the mechanism** — *why* it happened. Surface-level retries or
   "just be careful" write-ups don't belong here; the value is in the causal
   chain.
3. **Describe the guard that now exists** — the mechanical fix (a hook, a
   gate, a changed ordering, a different API) that makes the failure harder
   or impossible to repeat. A chapter with no guard is an incident report,
   not a failure-mode chapter.
4. **Be scrubbed.** No personal file paths, hostnames, tokens, credentials,
   or names of private machines/services. Generalize anything
   machine- or person-specific — a chapter should read as useful to a
   stranger running their own project, not as a page from someone's private
   log.

Frontmatter is a single optional `title:` field; the filename (kebab-case)
is the fallback title and also the page's sort key, so name files so they
sort sensibly (e.g. `01-`, `02-` prefixes, or a short descriptive slug).

## The `kernel-candidate` tag convention

Chapters are harvested from a personal notes vault that also holds a lot of
project- and person-specific material that must never ship in a public
repo. To keep the harvest step deliberate rather than a bulk export, any
note that documents an **architecture-level** failure — one that would be
useful to a stranger building similar automation, not just to the author —
is marked with a `kernel-candidate` tag (alongside its normal tags) at the
point of capture. A note qualifies when its lesson survives with the
project's private specifics (usernames, board names, machine names) removed
— i.e. the *mechanism* and the *guard* are general, even if the *instance*
that surfaced it was local.

`kernel-candidate` is a **pointer for the human doing the harvest**, not a
build-time input — nothing in this repo or its CI ever reads the tag or the
notes store it lives in. Marking a note `kernel-candidate` means "a future
harvest pass should consider turning this into a chapter in
`docs/failure-modes/`"; it does not by itself add anything to that
directory. The tag stays applied to the source note after harvest, both as
a record of provenance and so a revision to the source note is easy to
find again.

## Current chapters

| File | Failure |
|---|---|
| `01-worktree-write-isolation-leak.md` | An isolated build worker's absolute-path write lands in the shared parent checkout instead of its own worktree |
| `02-graphql-budget-exhaustion.md` | A polling loop backed by the wrong API silently drains a shared, points-based rate-limit budget |
| `03-premature-status-close-on-async-merge.md` | An orchestrator marks work "done" at queue time instead of at confirmed completion, closing tracking state against code that isn't actually merged yet |
| `04-patch-api-silent-corruption.md` | A "success" response from a partial-update API hides a structural corruption of the target document |

## Contributing an adapter

TemperLoop's process machinery (board adapter, build/sweep pipeline,
install/doctor, quality gates) is generic on purpose — it stays generic by
talking to exactly two backend seams instead of hardcoding a specific
knowledge store or issue tracker. Adding support for a new backend means
implementing one of these seams; it does not mean touching the pipeline
machinery itself.

The two seams:

- **Knowledge adapter** — the document-I/O interface a caller uses to read,
  write, append to, or list a project note (context, decisions, notes)
  without hardcoding a filesystem path or a particular tool. The full
  interface — configuration, public functions, backend-registration seam,
  and the existing `plain-files` / `obsidian` backends as worked examples —
  is specified in
  [`workflows/scripts/lib/knowledge_store.contract.md`](../workflows/scripts/lib/knowledge_store.contract.md).
  Read that file rather than this one for the actual contract; it is the
  source of truth and this guide does not restate it.
- **Tracker adapter** — the issue/board backend seam (label vocabulary,
  claim lock, parent/child and dependency edges, close→Done cascade) that
  the board toolkit talks to instead of assuming a specific tracker. The
  current interface is documented alongside the reference `issues-only`
  backend in
  [`workflows/scripts/board/ISSUES-ONLY-BACKEND.md`](../workflows/scripts/board/ISSUES-ONLY-BACKEND.md).
  There is no standalone `tracker.contract.md` yet separating the general
  interface from that one backend's specifics — that split is tracked as a
  follow-up, foundation#891 — so until it lands, ISSUES-ONLY-BACKEND.md is
  the source of truth for the tracker seam's shape.

Before opening an adapter PR:

1. Read the relevant contract file above in full — implement to the
   interface it specifies, not to how an existing backend happens to work
   internally.
2. Keep the seam's existing backends working. A new backend is additive;
   it must not change the public interface functions callers already rely
   on.
3. Add tests alongside the existing backend tests in the same area, and run
   the project's quality gates before opening a PR.
4. If something in either contract file is unclear or looks stale relative
   to the code, say so in the PR rather than guessing — these contracts are
   maintained documents, not fixed specs, and a confusing passage is
   itself a useful bug report.

Community discussion, adapter questions, and show-and-tell for finished
adapters happen in this repo's Discussions tab — see the "How to contribute
an adapter" post there for a live version of this section plus links to the
seam contracts above.
