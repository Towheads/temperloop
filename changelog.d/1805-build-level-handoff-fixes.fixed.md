- **The `/build` worker hand-off no longer fails silently toward a plausible
  value.** Five defects in the workflow that drives one dependency level of a
  build (`claude/workflows/build-level.mjs`), all one class: a hand-off point
  that degrades to a believable answer instead of admitting it does not know.
  - **A finished item is no longer discarded because its closing report could
    not be read** (#1805, an unreadable worker report aborted the pull request).
    When the report a worker returns at the end of its task was unparseable,
    opening the pull request was refused and the whole item was recorded as a
    failed build — even with a clean commit on the branch and a full
    verification write-up already on disk. The pull request is now re-opened
    from the commit's own title plus that write-up, and when even that cannot
    land, the failure report states whether any work exists (the commit, the
    uncommitted files, whether the write-up is present), so "nothing was built"
    reads differently from "it was built and the reporting broke".
  - **A worker that starts its quality-gate run in the background is now
    visible** (#865, a backgrounded gate was indistinguishable from a slow one).
    Each worker is handed one exact gate command that always leaves a small
    result file behind — a status file it writes when the run starts and
    rewrites with the exit code when the run ends — and is told to poll that
    file rather than a process id, which a sub-task cannot wait on. The driver
    reads that same file after the worker hands back, so a run still marked as
    in progress produces a named notice instead of looking like a gate that is
    merely taking a long time. That command now refuses outright rather than
    starting the gate somewhere it should not: if the worker's own directory has
    gone, if the shell running it has no `pipefail`, or if the repository has no
    gate script at all, it stops before writing any result file and exits with a
    named reason. Previously a directory that had gone missing was stepped over
    and the gate ran wherever the shell happened to be — a failing suite in the
    wrong repository, recorded as a pass; and a repository with no gate script
    wrote a finished result with a non-zero code, which the worker was told to
    report as a gate failure.
  - **An item whose text contains a single quote no longer breaks the command
    built from it** (#1806, the nested-quote idiom was refused at parse time).
    Such a value is now wrapped in double quotes instead of the nested `'\''`
    idiom, whose nesting the shell that runs the composed command rejected
    before it ran anything at all.
  - **A gate run's wall-clock time is reported honestly** (#1698, a passing gate
    was logged as taking no time). Two spellings of the same duration field
    meant a gate whose own log said it passed in 215s could be recorded as `0s`,
    which silently blinded the one signal that exists to make a growing test
    suite visible *before* it runs out of budget. The two spellings are now
    reconciled once, where the result enters the workflow; a figure that is
    genuinely unreadable renders as `?` and says so, rather than reporting a
    plausible zero.
  - **Plan items are accepted under the spellings `claude/plan-schema.md`
    documents** (#1700, the documented `gh_issue:` key was dropped in silence).
    `gh_issue:`, `also_closes:` and `depends-on:` used to be read by nothing, so
    an item written the documented way lost its issue link without a word: no
    `Closes` line in the pull request, which then merged green and left the
    issue open. Any item field the workflow does not read is now named in the
    run log, which catches the next such key rather than only these three.
