# Clean-host validation: the stranger's first `ks_search`

**Verdict: PASS, after one defect found and fixed.** Run 2026-08-19 on
`linux/aarch64` (Apple Silicon, colima 29.5.2), Debian 13 trixie,
`uv 0.12.5`, pin `basic-memory==0.22.1 python=3.13`. 30 of 30 assertions
passed with the fix in place; the same probe against the pre-fix adapter
fails 6 of 30.

Re-run it with `make validate-clean-host-ks-search`. It is **opt-in and
manually invoked** — never a gate, never CI.

## Why this run exists

[temperloop#1113](https://github.com/Towheads/temperloop/issues/1113) changed
a kernel default that a stranger's very first `ks_search` depends on: the
backend stopped resolving its pin per run with `uvx` and started invoking a
stably-installed `uv tool` entry point. The ratified design kept zero-setup
working by having the availability gate install the pin lazily on first use.

Every arm of that switch is covered by tests — pin absent, pin present, pin
changed, install fails, XDG exported, `--probe` — and **every one of them
stubs `uv`**, deliberately: kernel principle 3 forbids a live-network install
inside the gated suite, and a `KERNEL_GATES` entry firing a real install from
a hermetic sandbox was the HIGH review finding that blocked #1113's first
attempt.

So the one path never executed was the real one: a genuinely clean host, no
prior install, only `uv` on `PATH`, no `doctor` run, issuing its first
`ks_search` and getting an answer.
[temperloop#1635](https://github.com/Towheads/temperloop/issues/1635) is that
gap. This document is its recorded verdict.

## What the defect was

**The install worked perfectly and the search still could not answer.**

`basic-memory project add` registers a project; it does **not** scan it.
Nothing else on the search path indexed the corpus either. So the clean-host
chain ran to completion and stopped one step short:

1. availability gate: pin absent, `uv` present → install it (worked);
2. search: project not registered → miss;
3. `project add` → registered;
4. retry the search — **against an empty index**;
5. return zero results, **exit 0**.

Nothing had failed, so nothing was reported. Legible degradation had nothing
to be legible about. A stranger would have got "no matches" for every query
they ever ran, indefinitely, until something else happened to call
`ks_search_reindex` — and on this container, with `ripgrep` deliberately
absent, not even the score-0 lexical fallback could paper over it.

This is precisely the class #1635 predicted: *"the suite cannot see it, and
the failure lands on a stranger's first contact with the tool."* It was
invisible to the stubbed suite because a stub of `uv` says nothing about
whether a real corpus ends up in a real index.

### Observed, pre-fix

```
=== 4. ACCEPTANCE 1 — the FIRST ks_search returns results ===
--- OBSERVED: run 1 stdout ---
--- OBSERVED: run 1 stderr ---
knowledge_search: installing basic-memory==0.22.1 python=3.13 as a uv tool under /clean/bm-home/uv-tools (one-time; a cold install downloads an interpreter and can take minutes)
run1_exit=0 run1_seconds=25
PASS  first ks_search exits 0 (got 0)
FAIL  first ks_search returns a NON-EMPTY result stream
FAIL  the top hit is the note the query is about (got '<none>')
...
RESULT: FAIL (6 assertion(s) failed)     # passed=24 failed=6
```

Empty stdout. Exit 0. That combination is the whole finding.

## The fix

`_ks_bm_initial_index` in `workflows/scripts/lib/knowledge_search.sh`, called
from the search path's project-not-found miss branch, immediately after the
registration that branch already performs.

That branch is the one place that knows a cold start just happened. It fires
on first use and on a post-`basic-memory reset` DB drop — both of which mean
"the index is empty" — and never on a warm query, so the cost is paid once
and no per-query overhead is added (the warm path does not even call
`project add`, per foundation#996).

Three properties, each with its own test in
`workflows/scripts/lib/tests/test_knowledge_search.sh`:

- **Order is the assertion** (`5b`): miss → register → index → retry. An
  index before registration would index an unregistered project; an index
  after the retry would be one search too late.
- **Best-effort, never fatal, never silent** (`5d`): a failed index warns on
  stderr, surfaces the subprocess's own cause, and lets the retry proceed —
  the retry may still be answerable, and a zero-result search that reaches
  the ripgrep fallback beats exit 4. What it must never be is silent, since
  a silent failure recreates the invisible-empty state the index removes.
- **Bounded** (`5e`): by `KNOWLEDGE_SEARCH_BM_INDEX_TIMEOUT` (900s), applied
  when the caller has already sourced `portable-timeout.sh` — the same
  probe-don't-depend posture as the install bound. This index runs *inside* a
  search call, so an unbounded one turns "my first search is slow" into "my
  first search never returns".

`5c` asserts the converse: neither a warm hit nor a warm no-match ever
triggers it.

## The recorded run

Verbatim from the post-fix execution on 2026-08-19.

```
=== 1. the host really is clean ===
PASS  uv is on PATH
PASS  no basic-memory on PATH (nothing pre-installed to fall back on)
PASS  no ~/.local/share before the run
PASS  no ~/.local/bin before the run
PASS  no shared uv cache at ~/.cache/uv before the run
PASS  the adapter's bm home does not exist yet (/clean/bm-home)
--- OBSERVED: $HOME before the run ---
/root
/root/.bashrc
/root/.profile

=== 3. the zero-side-effect probe reports NOT READY ===
PASS  ks_search_available --probe exits 3 on a clean host (got 3)
PASS  --probe wrote nothing — still no bm home

=== 4. ACCEPTANCE 1 — the FIRST ks_search returns results ===
--- OBSERVED: run 1 stdout ---
{"doc_id":"kestrel-migration.md","title":"Kestrel migration plan","score":0.789851473475137,"snippet":"# Kestrel migration plan\n\nWe are migrating the kestrel ingest service off the legacy queue and onto a\ndurable log. The rollout is staged: shadow reads first, then dual writes,\nthen a cutover once replay lag is under one second."}
--- OBSERVED: run 1 stderr ---
knowledge_search: installing basic-memory==0.22.1 python=3.13 as a uv tool under /clean/bm-home/uv-tools (one-time; a cold install downloads an interpreter and can take minutes)
knowledge_search: first use of project "foundation-knowledge" — indexing the corpus once (a large store can take minutes)
run1_exit=0 run1_seconds=54
PASS  first ks_search exits 0 (got 0)
PASS  first ks_search returns a NON-EMPTY result stream
PASS  the top hit is the note the query is about (got 'kestrel-migration.md')
PASS  the hit carries a real backend score, not the score-0 fallback sentinel (score=0.789851473475137)
PASS  the ripgrep fallback never fired (rg is deliberately absent from this image)
PASS  the lazy install fired on THIS run (the adapter said so on stderr)
PASS  the cold-start index fired on THIS run (temperloop#1635)

=== 5. ACCEPTANCE 2 — every byte written stays under the pinned bm home ===
PASS  nothing in ~/.local/share
PASS  nothing in ~/.local/bin
PASS  no shared uv cache at ~/.cache/uv
PASS  no uv state under ~/.local/state/uv
PASS  the entry point landed where the adapter looks for it
PASS  the pin stamp matches the configured pin (got 'basic-memory==0.22.1 python=3.13')
--- OBSERVED: $HOME after the run ---
/root
/root/.bashrc
/root/.local
/root/.local/state
/root/.local/state/foundation
/root/.local/state/foundation/knowledge-reads.log
/root/.profile
--- OBSERVED: unexpected $HOME entries (should be empty) ---
<none>
PASS  the only thing written outside the bm home is the knowledge read log
--- OBSERVED: bm home footprint ---
707M	/clean/bm-home
1.8M	/clean/bm-home/.basic-memory
132K	/clean/bm-home/.cache
4.0K	/clean/bm-home/basic-memory
65M	/clean/bm-home/embedding-cache
496M	/clean/bm-home/uv-cache
91M	/clean/bm-home/uv-python
8.0K	/clean/bm-home/uv-tool-bin
55M	/clean/bm-home/uv-tools
--- OBSERVED: uv source-built wheels (empty = every dependency had a prebuilt wheel) ---
<none>

=== 6. ACCEPTANCE 3 — a SECOND ks_search installs nothing ===
--- OBSERVED: run 2 stderr ---
run2_exit=0 run2_seconds=2 (run1 was 54s)
PASS  second ks_search exits 0 (got 0)
PASS  second ks_search still returns results
--- OBSERVED: uv invocations during run 2 (should be empty) ---
PASS  the second search invoked uv ZERO times
PASS  no install notice on the second search
PASS  no cold-start index on the second search
PASS  the entry point, the pin stamp and the tool dir are untouched (before='1787165565 1787165565 1787165530 ' after='1787165565 1787165565 1787165530 ')

=== 7. a warm search does not need uv on PATH at all ===
PASS  a warm ks_search still answers with uv removed from PATH (exit 0)
PASS  run 3 returned results

=== VERDICT ===
arch=aarch64 pin=basic-memory==0.22.1 python=3.13
first-run seconds=54 (install + index + search), warm-run seconds=2
bm home footprint=707M
passed=30 failed=0
RESULT: PASS (30 assertions)
```

## What the numbers say about a stranger's first contact

| | observed |
|---|---|
| architecture | `linux/aarch64`, **native** — no `--platform` emulation |
| source builds | **none** — no `built-wheels-v*` in uv's cache; every dependency had a prebuilt arm64 wheel |
| first run, cold | **54s** — uv-tool install (incl. a downloaded CPython), corpus index, and the search itself |
| second run, warm | **2s** |
| disk written | **707 MB**, all under the adapter's isolated bm home |
| escaping that home | one file: the knowledge read log at `~/.local/state/foundation/knowledge-reads.log` |

Two things worth naming rather than burying.

**The 707 MB is mostly uv's cache (496 MB), and it is *private* to the
adapter.** `KNOWLEDGE_SEARCH_BM_HOME` pins `UV_CACHE_DIR` inside itself, which
is exactly the isolation #1113 wanted — nothing lands in the operator's tree —
but it also means a plain `uv cache prune` in the operator's shell never
touches it. The interpreter (91 MB) and the embedding model (65 MB) are
one-time downloads shared by every later search. This is the *shape* of the
cost, not a defect; it is recorded here so a future reclaim item starts from
a measurement.

**54 seconds is the honest cold-start number on a warm image.** The container
image was already pulled and the `uv` package index reachable; a stranger
pulling `ghcr.io/astral-sh/uv:debian-slim` for the first time pays that on top.

## How the validation is built

Two files, both under `workflows/scripts/dev/`:

- `validate-clean-host-ks-search.sh` — the host-side driver. Preflights
  Docker (a missing daemon is **exit 2**, loudly — never a skip), builds the
  image from a stdin Dockerfile, `docker cp`s the adapter's `lib/` and the
  probe into a fresh container, and streams the transcript.
- `clean-host-ks-search-probe.sh` — the in-container probe. Collects
  assertions rather than aborting, so one run surfaces every failure, and
  prints every observation verbatim under `--- OBSERVED ---`.

Design choices that make the verdict falsifiable rather than self-confirming:

- **A real, tiny corpus.** Three notes with disjoint subjects; the query names
  one of them, and the assertion is that *that note* comes back top. An empty
  store would satisfy a bare "non-empty stream" check vacuously — and the
  defect above proves the difference is not academic.
- **No `ripgrep` in the image.** `ks_search`'s score-0 lexical fallback
  therefore cannot fire; a hit is provably a real backend hit, and the probe
  asserts the fallback notice never appeared.
- **"No further install" asserted four ways.** A PATH shim that logs every
  `uv` invocation (run 2 must produce zero), the absence of the adapter's own
  install/index notices, unchanged mtimes on the entry point / pin stamp /
  tool dir, and a third run with `uv` removed from `PATH` entirely that must
  still answer.
- **`docker cp`, not a bind mount.** A VM-backed Docker (colima, Docker
  Desktop) only mounts a configured subset of the host filesystem; a bind
  mount of a checkout outside that subset silently mounts an *empty*
  directory. `docker cp` streams a tar over the daemon socket and works from
  any path — this was observed during development, not theorised.

## Why it is not, and must not become, a gate

It performs a real network install. Kernel principle 3 — *deterministic tests
over recorded fixtures, never live-network* — puts that out of bounds for the
gated suite, and #1113's own history shows the cost of ignoring it. The
script is absent from `scripts/quality-gates.sh`, from `KERNEL_GATES`, and
from every `.github/workflows/` job; only a hand-typed `make
validate-clean-host-ks-search` runs it.

The stubbed suite is not thereby excused. The fix carries four new stubbed
tests (`5b`–`5e`) so the *behaviour* this run discovered is now defended
deterministically on every PR. This validation defends the *seam between the
stub and reality*, which is the one thing a stub can never check — run it
when the pin or the install path changes.

---

*Written by claude-opus-5 on 2026-08-19.*
