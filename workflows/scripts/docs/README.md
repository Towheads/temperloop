# workflows/scripts/docs/ — docs-site generator (skeleton)

Foundation #764 (Epic C, "kernel split: docs generated from source in CI").
`make docs` (`generate.py`) renders a self-contained static site from three
already-structured sources — no hand-maintained docs, no drift between what
the code does and what the site says it does:

| Page | Source | Renderer |
|---|---|---|
| Command reference | `claude/commands/*.md` (kernel-manifest filtered) | `sources/commands.py` |
| Plan-note contract | `claude/plan-schema.md` | `sources/plan_schema.py` |
| Quality gates | `scripts/quality-gates.sh --list` | `sources/gates.py` |
| Adapter contracts | `workflows/scripts/lib/*.contract.md` | `sources/adapter_contracts.py` |

Run it:

```sh
make docs                                    # writes to workflows/scripts/docs/_site/
python3 workflows/scripts/docs/generate.py --out /tmp/somewhere  # or point elsewhere
```

Output is **never committed** — `_site/` is gitignored (mirrors the
`dashboard/index.html` precedent; only `_site/.gitkeep` is tracked so the
directory exists in a fresh clone). Publishing it (GitHub Pages, on every
merge to main) is a separate, not-yet-built item in the epic — until then,
preview locally with a static file server (root-relative links assume a
server root, e.g. `python3 -m http.server -d workflows/scripts/docs/_site`),
not by opening `_site/index.html` via `file://`.

## Adapter-contract page

`sources/adapter_contracts.py` scans the pinned glob **`workflows/scripts/
lib/*.contract.md`** (repo-root-relative) and renders one page per file
found, sorted by filename — same pinned-glob shape as the chapters
convention below. Today that glob matches exactly `knowledge_store.contract.md`,
so exactly one adapter-contract page renders. There is deliberately **no
tracker-contract page**: no stub, no hand-written prose standing in for the
real interface file — the tracker adapter's own contract file is foundation
#814, separate scope. Once that item lands a similarly-suffixed
`workflows/scripts/lib/*.contract.md` file, this same glob picks it up on
the next `make docs` run with zero code change here.

## Telemetry metrics (overlay drop-in, not a kernel `sources/*.py` module)

Telemetry metric-definition rendering — the four rollup producers'
per-metric docstrings (`workflows/scripts/build_funnel_rollup.py`,
`build_rollups.py`, `build_eval_rollup.py`, `build_findings_rollup.py`) —
is deliberately **not** a `sources/*.py` module in this kernel directory:
those producers are themselves `overlay`-classified in
`kernel-manifest.txt` (Travis's personal telemetry pipeline), so a renderer
that reads them belongs in the overlay layer too. It ships as
`workflows/scripts/docs.d/metrics.py`, an instance of the overlay renderer
drop-in convention documented below — see that file's own docstring for the
`## Metrics: <output-file>` docstring convention it extracts verbatim (no
paraphrase, no structural parsing of free-form prose: a fixed heading marker
delimits a literal Markdown bullet block, which is handed to
`lib/markdown_lite.py`'s existing generic renderer unchanged).

## Kernel-manifest include filter

`sources/commands.py` is handed the parsed
`workflows/scripts/kernel/kernel-manifest.txt` entries and calls
`lib.kernel_manifest.is_kernel()` per candidate file — only paths the
manifest classifies `kernel` render. This is why the command reference shows
`assess` / `build` / `drain-mind` / `init` / `next` / `sweep` / `triage` /
`funnel-drive` / `funnel-drive-merge` but never `plan-morning` /
`plan-evening` / `telemetry` / `signal-intake` (all `overlay` in the
manifest, Travis's personal rituals). The filter is the manifest itself, not
a hardcoded list in this generator — reclassify a command in
`kernel-manifest.txt` and the site follows on the next `make docs`, no code
change required.

## Overlay renderer drop-in convention

Analogous to `scripts/quality-gates.d/` (a sibling `.d` directory next to
the script it extends — see that script's own header for the rationale this
mirrors): this generator sources extra pages from
**`workflows/scripts/docs.d/*.py`**, a sibling of this `workflows/scripts/docs/`
directory. Each file there must define:

```python
def build_pages(repo_root: Path) -> list[Page]:
    ...
```

`generate.py` globs `workflows/scripts/docs.d/*.py` in sorted order, imports
each module, and calls `build_pages(repo_root)`; every page returned is
unioned onto the kernel site's pages (added to the shared nav). A module
that doesn't define `build_pages` is a hard error (fail loud, not silently
skip a broken drop-in).

**Absent directory → zero extra pages, no conditionals** — `workflows/scripts/docs.d/`
does not exist in this (still-unsplit) checkout today, so a kernel-only
build produces exactly the three kernel pages above. A private overlay repo
(post kernel/overlay split) drops its own renderer modules there — e.g. a
page rendering Travis's personal `plan-morning` / `plan-evening` /
`telemetry` / `signal-intake` commands, or anything else overlay-only — with
zero changes to this generator.

## Chapters ingestion (pinned glob, content not yet built)

`sources/chapters.py` scans the pinned glob **`docs/failure-modes/*.md`**
(repo-root-relative) and renders one page per file found, sorted by
filename. The epic contract describes these as "3–4 curated failure-mode
chapters ... harvested from `kernel-candidate`-tagged Decisions/Mistakes
notes, scrubbed" — that harvest-and-scrub pipeline is a **separate item**.
Pinning the glob here, now, lets the two items land in either order: this
generator already knows where to look, so the chapters item's only job is to
write scrubbed Markdown files into `docs/failure-modes/`. `docs/failure-modes/`
does not exist yet in this repo; `glob()` on a missing directory returns
empty, so today's `make docs` run produces zero chapter pages and no error —
the same degrade-for-free shape as the overlay drop-in above.

## Design notes

- **Stdlib-python, zero-network, zero-install** (`lib/markdown_lite.py` is a
  hand-rolled Markdown-subset renderer, not a pip dependency, precisely so
  `make docs` can run as a `checks` gate on a stock CI runner with no
  install step — see that module's docstring for what subset it covers and
  why it deliberately isn't a full CommonMark implementation). The one
  subprocess call (`sources/gates.py`, to run `scripts/quality-gates.sh
  --list`) executes a script already checked into this repo — no network
  fetch, no package install.
- **Idempotent.** No wall-clock timestamp is embedded in any rendered page
  (see `lib/page.py`'s `render_page()` docstring) — re-running `make docs`
  on an unchanged tree produces byte-identical output. `_write_site()` wipes
  and rewrites the output directory on every run rather than merging, so a
  page whose source was deleted doesn't leave a stale orphan file behind.
- **Self-contained.** Every page inlines its own CSS (no CDN, no webfont, no
  shared asset file); no page makes an external fetch.
