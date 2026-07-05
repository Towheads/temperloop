# Decision-queue contract

> **Source of truth: `claude/decision-queue-contract.md`** in the foundation repo,
> deployed to `~/.claude/decision-queue-contract.md` by `make install-claude`.
> All pipeline commands that park or drain decision issues reference this file.
> Rationale: `Decisions/foundation - Autonomous funnel driver + GitHub decision queue`.

This contract defines the board-agnostic convention that every funnel item consumes.
It covers four things: the **assignee-baton** (the distributed lock), the **kind
label** (the operator queue surface), the **typed reply grammar** (the answer format
and parse-miss rule), and the **race rule** (the single-flight invariant). It does
**not** provision a live GitHub saved view — provisioning is an operator action;
the convention documents what to create.

---

## 1. Assignee-baton semantics

"Needs the operator" is modeled as `assignee`, not as a Status value (which would
fight the `Blocked`/`Parked` retirement, foundation#435). Status stays = pipeline
stage. The baton has two states:

| Assignee state | Meaning | Who acts |
|---|---|---|
| Assigned to the operator | Operator's turn — the item is parked, waiting for a human reply | Operator only |
| Unassigned (or assigned to a bot user) | Driver's turn — the issue is workable by the funnel-tick | Driver |

**Handing the baton to the operator (parking).** The driver:
1. Posts a comment describing the question, the offered options, and the expected
   reply format (see § 3 below).
2. Applies the `decision` label (see § 2).
3. Assigns the issue to the operator via `gh issue edit <n> -R "$REPO" --add-assignee "$ASSIGNEE"`, where `$ASSIGNEE` is `$OPERATOR` with a leading `@` stripped for a real login but the literal `@me` preserved (`ASSIGNEE="$OPERATOR"; [ "$ASSIGNEE" = "@me" ] || ASSIGNEE="${ASSIGNEE#@}"`). `--add-assignee` needs a **bare** login (`example-operator`) or `@me`; an `@`-prefixed real login (`@example-operator`) fails GitHub's `replaceActorsForAssignable` (foundation #977).
4. Stops processing this item for this tick.

**Handing the baton back (answering).** The operator:
1. Posts a reply comment in the typed reply grammar (see § 3).
2. **Unassigns themselves** via `gh issue edit <n> -R "$REPO" --remove-assignee "$OPERATOR"`
   — the unassign is the baton handback; the driver recognizes an unassigned
   `decision`-labeled issue as "answered, drain me."

The driver MUST NOT re-assign the issue to itself. The two states (assigned-to-op /
unassigned) are the only states that matter; a bot assignee is treated as unassigned.

---

## 2. The `decision` kind label

A `decision` label on an open issue signals: this issue is in the decision queue.
The driver uses this as its drain filter:

```
gh issue list -R "$REPO" \
  --label decision \
  --state open \
  --assignee "" \
  --json number,title,body,comments
```

(No assignee = unassigned = operator has replied and handed back; `--label decision`
scopes to the queue.)

### Label provisioning

Create once per repo:

```sh
gh label create decision \
  --repo "$REPO" \
  --color "FBCA04" \
  --description "Parked in the decision queue — awaiting operator reply"
```

### Saved board view (operator surface)

The operator's queue surface is a GitHub Issues saved search — not a Projects-v2
field or Status column:

```
is:open assignee:@me label:decision
```

**Provisioning mechanism:** create this saved search manually in the GitHub Issues
UI (Filters → Save) once per repo. The driver does not provision it automatically.
The saved view is purely informational — the board automation does not depend on it.

---

## 3. Typed reply grammar

The operator's answer lives in a **reply comment** on the decision issue. The driver
reads the **most recent comment on the issue at drain time** (the comment posted
after the baton handback = after the unassign).

### Preferred form: fenced `decision` block

~~~markdown
```decision
chosen: <option-label>
reason: <optional free-form rationale>
```
~~~

`chosen:` MUST be one of the option labels offered in the question comment. The
`reason:` field is optional and advisory — the driver captures it in the item's
`notes:` but does not parse it.

### Shorthand commands

For simple decisions the operator may use a one-line command instead. Each must
appear at the **start of a line** (no leading whitespace) in the comment body:

| Command | Meaning | Constraint |
|---|---|---|
| `/approve` | Approve as-is (valid only when the offered options include an `approve` or `accept` choice) | Only when offered |
| `/choose <label>` | Choose the named option | `<label>` must match an offered option (case-insensitive, whitespace-trimmed) |
| `/hold #N` | Defer; mark this decision blocked by issue #N | `#N` must be an open issue in the same repo |

### Parse-miss rule (closed-enum-or-escalate)

If the driver cannot parse the operator's comment as either a valid `decision` block
or a recognized `/` command — OR if `chosen:` / `/choose` names a label not in the
offered set — it **does not guess**:

1. **Re-assigns to the operator** with a "couldn't parse" comment:
   ```
   Couldn't parse your reply as a decision. Expected one of:
     - A ```decision``` block with `chosen: <option>` where <option> is one of: <list>
     - `/choose <option>` with one of the above labels
     - `/approve` (if "approve" is an offered option)
   Please re-reply and unassign yourself when done.
   ```
2. The item remains in the decision queue (`decision` label stays, assignee = operator).
3. The driver skips this item for the current tick and re-checks next tick.

A parse-miss never silently defaults to any option. Closed-enum-or-escalate.

---

## 4. Race rule (single-flight + contention pre-check)

### Single-flight lockfile

Only one `funnel-tick` run may be active at a time per host. The driver acquires a
lockfile before processing any board:

```sh
LOCK_DIR="/tmp/funnel-tick"
LOCK_FILE="$LOCK_DIR/tick.lock"
mkdir -p "$LOCK_DIR"
exec 200>"$LOCK_FILE"
flock -n 200 || { echo "funnel-tick already running — exiting" >&2; exit 0; }
```

On exit (clean or crash) the lock is released automatically because the fd is
closed with the process. Do NOT use `rm` to release — use `flock` so a crashed
run's lock is cleaned up by the OS when the process exits, not by a manual delete
that could race a new run.

### Contention pre-check (assignee-changed-since-read)

Before the driver acts on a decision issue (drains an answer, re-assigns to the
operator, etc.), it MUST re-read the issue's current assignee list. If the assignee
changed between the drain-list read and the act, another tick may have raced it:

```sh
# Re-check before acting
CURRENT_ASSIGNEES=$(gh issue view "$ISSUE_N" -R "$REPO" --json assignees --jq '.assignees | length')
if [ "$CURRENT_ASSIGNEES" -gt 0 ]; then
  echo "issue #$ISSUE_N assignee changed since drain-list — skipping this tick" >&2
  continue
fi
```

If the assignee count is non-zero (someone — operator or another tick — reassigned
since the list was fetched), skip this issue for this tick and re-drain on the next
run. This is the same "assignee changed since I read it = conflict" discipline as
`build.md` Step 3a's contention pre-check.

### Reuse the existing Host/Session claim stamp

When the driver claims a workable item (not a decision issue, but a Ready board
item the driver is about to work), it uses the same stamp `claim.sh` already writes:

```sh
host="${SUBSET_HOST_LABEL:-$(hostname -s)}"
sess="${CLAUDE_CODE_SESSION_ID:-}"
if [ -n "$sess" ]; then stamp="${host}:${sess:0:8}"; else stamp="${host}:manual"; fi
```

This is the existing `Host/Session` field value on the board item — not a new field.
The funnel-tick does NOT introduce a separate claim mechanism; it calls `claim.sh`
for each item it works, exactly as `/build` does.

---

## 5. Worked example

**Scenario.** An issue in the funnel has a design fork: should the merge gate use a
timed objection window or require explicit approval? The driver can't resolve it —
it parks the item into the decision queue.

### Step 1 — Driver parks the item

The driver posts a comment on the issue (say, ssmobile#42):

```
**Decision needed: merge-gate policy for Operational items**

The driver reached a gate it cannot resolve autonomously. Please choose one option
and unassign yourself when done.

**Options:**

- `timed-objection` — auto-merge after a 2h window; operator may comment OBJECT
  to cancel. Lower friction; allows throughput.
- `explicit-approval` — always require an `/approve` reply before merging. Higher
  safety; more operator turns.

Reply with:
  ```decision
  chosen: timed-objection
  ```
or `/choose timed-objection` (or `/choose explicit-approval`).
```

The driver then:
- Applies the `decision` label to ssmobile#42.
- Assigns the issue to the operator (`@operator`).
- Stops processing ssmobile#42 for this tick.

**Board state after parking:**
- ssmobile#42 status: In Progress (unchanged — the issue stays in its real pipeline stage).
- ssmobile#42 assignee: `@operator`.
- ssmobile#42 label: `decision`.

### Step 2 — Operator answers

The operator reviews the saved view (`is:open assignee:@me label:decision`) and
finds ssmobile#42. They post:

```
```decision
chosen: timed-objection
reason: We want Operational fully hands-off; timed gate is correct for that.
```
```

Then they unassign themselves via the GitHub UI (or `gh issue edit 42 -R <org>/ssmobile --remove-assignee @me`).

**Board state after answer:**
- ssmobile#42 assignee: *(none)*
- ssmobile#42 label: `decision` (still set — the label is the drain filter).

### Step 3 — Driver drains the answer

On the next tick, the driver's drain step:
1. Queries `gh issue list -R <org>/ssmobile --label decision --state open --assignee ""`.
2. Finds ssmobile#42.
3. **Contention pre-check:** re-reads ssmobile#42's assignee. Still empty — proceed.
4. Reads the most recent comment body. Parses the fenced `decision` block:
   - `chosen: timed-objection` — matches an offered option. Valid.
5. **Applies the answer:**
   - Records `notes: merge-gate: timed-objection` on the plan item.
   - Drops the `decision` label from ssmobile#42: `gh issue edit 42 -R <org>/ssmobile --remove-label decision`.
   - Posts a confirmation comment: "Decision applied: merge-gate = timed-objection. Resuming."
6. **Advances the item:** re-queues ssmobile#42 as workable (Status stays In Progress; driver picks it up in the work phase of this tick or the next).

**Baton is now with the driver.** The issue is unassigned, label `decision` is gone, and the driver continues.

### Parse-miss path (variant)

If the operator had instead replied with just `"sounds good, do whichever"`:

- The driver cannot parse this as a `decision` block or a `/` command.
- It re-assigns to the operator with the "couldn't parse" note (see § 3).
- The item stays in the queue for the next tick.
- On the next tick the operator sees it again in their saved view, re-replies with a
  valid `decision` block, unassigns, and the drain proceeds as in Step 3 above.
