---
title: Quality gates — one script both CI and a local run execute
slug: quality-gates
---

## Problem

A repository's continuous-integration job and a contributor's local
pre-merge check are, in principle, supposed to run the exact same tests
before anything lands on the default branch. In practice, that guarantee
tends to erode the moment the gate list is typed out more than once — once
in a CI workflow file, once in a project's own dev-workflow instructions,
maybe a third time in an automated build tool's own acceptance step. Each
copy drifts independently: a gate added to CI but not to the local list
means a contributor's "it passes locally" is not actually predictive of
what CI will do, and a gate added locally but never wired into CI means it
silently stops mattering. The failure is invisible until the day CI catches
something a local run swore was clean, and by then nobody can say which
copy was stale.

## How it works

`scripts/quality-gates.sh` is the single source of truth for the repository's
static, zero-network, repo-wide gate set. There is exactly one place the
list of gates is typed — every consumer runs *this script*, never a
hand-copied list of its contents, so "local gates mirror CI" is true by
construction rather than by three copies kept in sync through discipline.
Each entry is one full command line (almost always a `make` target); the
script runs every gate unconditionally — never stopping at the first
failure — and only exits non-zero at the end if anything failed, which
surfaces every broken gate in one run instead of one per CI restart.

**The kernel/overlay layering.** The gate set is two arrays unioned at run
time:

- `KERNEL_GATES` is typed directly in the script and covers exactly the
  suites a stranger's kernel-only install would have: board, build,
  install, hooks, PR-hygiene, and tidy mechanical-owner suites, none of
  which reference anything specific to a downstream fork's own private
  subject matter.
- `OVERLAY_GATES` starts empty and is populated only by sourcing every
  `scripts/quality-gates.d/*.sh` file present, in glob order. Each drop-in's
  only job is to **append** its own entries onto the array — never replace
  or reorder a sibling drop-in's entries — so more than one downstream
  contributor can extend the gate set without fighting over one shared
  file. An absent or empty `quality-gates.d/` directory (a genuine
  kernel-only checkout with no overlay) degrades to zero overlay gates with
  no conditional logic required anywhere in the script.

Gates run in `KERNEL_GATES` order followed by `OVERLAY_GATES` order, from
the repository root regardless of the caller's own working directory (a
build worker running from a throwaway worktree still resolves every `make`
target correctly). `--list` prints every gate's full command line prefixed
`[kernel]` or `[overlay]`, without running anything — useful for auditing
exactly what a run will execute before it executes it.

**Diff-scoped gates.** Most gates read the working tree as it stands. Two
read the *change* instead — the added lines of a pull request's diff (the
public-repo leak guard) and the set of files it touches (the changelog
gate). Both resolve a base ref the same way (an explicitly supplied base,
else `origin/main`, else `main`, else a clean skip with a notice), and both
ride this same gate set rather than a second CI job, so they gate on the
already-required status with no branch-protection change.

The changelog gate answers one question: does this change touch **contract
surface** — the seams a downstream adopter couples to — and if so, does it
add anything under `## [Unreleased]`? That matters because pre-1.0 the
breaking signal rides the changelog rather than the version number: the
kernel updater decides whether a downstream pull needs explicit
acknowledgment by scanning changelog sections for a `BREAKING` marker, and
an entry that was never written cannot carry one. The definition of
"contract surface" is not typed a second time here — it is parsed at run
time out of the versioning policy's own table, so extending that table
extends the gate, and a table the gate cannot parse fails the run loudly
instead of quietly enforcing nothing. Genuinely non-shipping work (a prose
chore, a comment rewording) opts out by *recording* the choice — a label on
the pull request, a marker line in its body, or the same marker as a commit
trailer — with a reason required in the marker forms, so a skip is always a
decision someone made rather than something nobody noticed.

**Diff-scoped gate *selection*.** The gates above describe *what* runs; a
second layer decides *which of them* runs. Running every suite on every pull
request charged each one a flat several minutes, and because a merged change is
validated twice — once on the pull request and again in the merge queue — every
merge paid that bill twice, even when the diff was a single documentation file
no suite could possibly be affected by. So on a pull-request event with a
resolvable base commit, the run is narrowed to the gates the changed paths can
actually reach, using a registry that maps each gate to the path globs that
affect it. Everywhere else — the merge queue, a push to the default branch, the
nightly run, the build pipeline's acceptance step, any local run — the full set
runs exactly as before. **The run that gates the default branch is never
scoped**, so a narrowing bug can at worst let a pull request go green early; it
cannot let an unproven commit land.

That is only safe if the map cannot quietly fall behind, which is the whole
design problem: a map that misses a dependency runs a smaller set and still
reports green. Four properties prevent it, and all four resolve *toward* more
coverage:

- A changed path matching no glob anywhere in the map escalates the run to the
  full set. Narrowing is opt-in per path; the fallback is never a smaller run.
- Any resolution failure — no base commit, a base the repository cannot
  resolve, an empty diff, a missing or malformed map — falls back to the full
  set and says so on stdout, next to the verdict as well as at the top, since
  "all gates passed" means something different on a scoped run.
- Paths whose blast radius is the gate machinery itself (the gate script, the
  selector, the map, the build file, the CI workflows, the tree-classification
  manifest) are listed explicitly and force the full set outright.
- A gate the map does not mention runs unconditionally, so a stale map
  over-runs rather than under-runs.

The map ships with its own gate. It fails the build if any gate lacks a row, if
a row names a gate that no longer exists, if a literal path in a row is not in
the tree, or — the one that matters most — if a row's globs match *nothing*,
because a gate orphaned behind an unmatchable glob would otherwise be skipped
on every scoped run forever with nothing else in the repository noticing. The
validator and the selector share one glob matcher rather than each carrying
their own, so the patterns that are validated are byte-for-byte the patterns
that are consumed. `--list-selected` prints the set a given invocation would
run, with its one-line reason, without running anything.

**The per-gate retry policy** lives in `workflows/scripts/lib/gate-retry.sh`,
sourced by the script (the same seam it already uses for the checkout-freshness
guard) so the policy can be tested without running the whole gate list. A gate
that fails is retried up to `GATE_MAX_ATTEMPTS` times, because the hosted macOS
runner intermittently fails unrelated hermetic gates under load — but a retry
only ever helps a *transient* failure, so the policy classifies before it
retries:

- **Deterministic signature.** The failed attempt's output matches
  `GATE_DETERMINISTIC_PATTERN` (an ERE; the shipped default names a static-lint
  finding code). The gate is not retried at all — it fails straight to
  escalation on the first attempt.
- **Byte-identical output.** The attempt printed exactly what the previous
  failed attempt printed. Nothing about the run changed, so nothing about the
  next one will either. This is the general net beneath the signature
  classifier: it needs no per-lint pattern and caps *every* deterministic gate
  at two attempts regardless of what it prints.
- **Otherwise** the failure is presumed transient and the retry fires — spaced
  by a graduated `GATE_RETRY_BACKOFF`-per-attempt sleep, so a slow-clearing
  transient actually gets time to clear rather than having the whole budget
  burned back-to-back inside a fraction of a second.

Every attempt, retry, and deterministic short-circuit is logged as it happens
and again in an end-of-run summary beside the pass/fail verdict, so neither a
masked flake nor a saved retry is invisible. All three settings are declared
with their defaults in `workflows/scripts/build/build.config.sh`; the script
keeps byte-identical fallbacks so it still runs standalone in a consuming repo
that never sources that file.

## Integration

The CI workflow's `checks` job (`.github/workflows/ci.yml`) runs one step:
`bash scripts/quality-gates.sh`, on `ubuntu-latest` only — that is the
required status check merges gate on. macOS coverage runs the *identical*
step on a nightly schedule against the default branch instead
(`.github/workflows/nightly-macos.yml`, plus a manual `workflow_dispatch`
trigger), a deliberate trade of gate-time BSD-dialect safety for pre-merge
latency: a macOS-only regression can land and is caught within a day rather
than blocked at the gate, and it surfaces only as a red run in the Actions
tab plus GitHub's built-in scheduled-failure email to the repository's
default recipients. A contributor's local pre-merge check runs
the identical invocation. The automated build pipeline's own parent-side
acceptance step, before it will consider a plan item's changes ready to
merge, also shells out to this same script rather than re-implementing any
part of the gate list. Adding, removing, or changing a gate is a one-line
edit to this file (or to an overlay drop-in) and every one of those three
callers picks it up on their very next invocation, with nothing else to
update.

## Resource impact

Every gate is a fast, zero-network, repo-local check — test suites, static
lints, and validator scripts that read only the working tree, never call
out to a remote API, and never require a package install beyond what the
repository already vendors. Total runtime scales linearly with the number
of gates (today several dozen), each one independently isolated with no
shared fixture or generated artifact a later gate depends on, so gates can
be reordered or run in any order without changing which ones pass.
Overlay drop-ins add to this linearly as well — an overlay carrying no
drop-ins costs nothing beyond the one directory-existence check.

Pull-request runs no longer pay that full linear cost: the selection layer
above reduces them to the affected subset, which for a documentation-only
change is a small fraction of the whole set (the handful of whole-tree
scanners, plus the documentation-site build and its coverage validator). The
selection itself costs one `git diff --name-only` and a linear scan of the map,
both negligible against any single gate. Merge-queue and nightly runs are
unaffected and still pay the full cost, by design.

## Telemetry

None as a dedicated stream. The script's own stdout is the observable
surface: the run opens by naming which set it is about to execute and why
(diff-scoped with a count, or full with the reason it declined to narrow), each
gate prints a `=== <command> ===` banner as it runs, a scoped run repeats its
scope beside the verdict, and a failing run ends with an explicit
`FAILED N/M quality gate(s)` summary
naming every gate that failed (not just the first) — that summary, and CI's
own red `checks` status derived from the script's non-zero exit, are how a
broken gate is noticed.
