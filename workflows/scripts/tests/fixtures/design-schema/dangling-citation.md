# Fixture — schema table with a dangling gate citation

Purpose-built failing fixture for
workflows/scripts/tests/test_validate_design_brief.sh's schema-citation
check (A). A trimmed two-row dimension table mirroring
claude/design-schema.md's real shape: row 1 cites a real, resolvable path;
row 2 cites a path that does not exist anywhere in this repo, exercising the
DANGLING-CITATION failure this lint exists to catch.

## Kernel dimension list

| # | Dimension | What it answers | Enforcing gate |
|---|---|---|---|
| 1 | **Fixture dimension one** | Fixture question one. | `workflows/scripts/validate-live-drain.sh` — a real, tracked path; must resolve clean. |
| 2 | **Fixture dimension two** | Fixture question two. | `workflows/scripts/validate-nonexistent-thing.sh` — deliberately fake; must fail as DANGLING-CITATION. |
