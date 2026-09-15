- **`/build`, `/sweep` and `/fix` now run the orchestrator from your checkout
  instead of a stale copy in `~/.claude`** (#2027). All three commands used to
  name `~/.claude/workflows/build-level.mjs` as the script to run. That path
  had two problems. The Workflow tool refuses any script outside the working
  directory, so the path was never usable as written and each run quietly
  depended on whoever launched it noticing and substituting the in-repo copy.
  And when it was usable, nothing in this repo ever installed or refreshed
  that file — it was a plain copy with no owner, so it fell further behind on
  every merge (347 lines behind on the host that reported this, and six days
  behind during an overnight run in which every invocation executed superseded
  machinery and reported success). All three commands now resolve
  `claude/workflows/build-level.mjs` from the checkout you are working in, via
  the new `workflows/scripts/build/workflow-path.sh`, so there is only one
  copy to be right about. If something still points at an installed copy — a
  repo that vendors only the install, or an explicit path you pass — that same
  script checks it against your checkout first (reusing the existing
  `workflows/scripts/install/doctor.sh` drift check) and **refuses to hand
  back a path that differs**, rather than letting superseded machinery run and
  report success. A copy it cannot check is reported as unchecked, never as
  clean. Nothing installs `claude/workflows/*.mjs` and nothing should: the
  checkout copy is the only one these commands need.
