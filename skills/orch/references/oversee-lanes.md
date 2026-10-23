# Oversee lanes

Load from [oversee.md § 4](../workflows/oversee.md#4-watch-and-advance) to park a hosted lane's merge wait, or to answer, direct, wake, paste into or resume a lane.

## Parking a merge wait

A hosted lane can wait for its own queued PR or for another PR in a watched repository. Park it to stop sandbox billing while keeping its disk and session. The overseer runs `lane-close --park --pr [PR_NUMBER] [ITEM_KEY]` for the lane's queue wait. It runs `lane-close --park --until-pr [BLOCKING_PR] [ITEM_KEY]` for a dependency wait. Use a bare number for the same repository or `OWNER/REPO#N` for a named repository. The named repository must be the lane repository or listed in `ORCH_CONNECTED_REPOS`. Add `--pr [OWN_PR]` only when the dependency lane also has its own PR. Add `--state-dir [OVERSEE_STATE_DIR]` as for every close.

Before requesting either park, the lane commits its work. In its worktree, it reads `git status --porcelain`, `git rev-parse HEAD`, `git branch --show-current`, and `date -u +%Y-%m-%dT%H:%M:%SZ`. A nonempty status prevents the request. With the harness file-write tool, it writes `tmp/park-status.json` as `{ "head": "[SHA]", "branch": "[BRANCH]", "porcelain": "", "at": "[UTC_TIME]" }` from those readings. It writes a notice to `tmp/park-request.md` naming the repository, its own PR if any, the blocking PR, and the next step held by that PR. It sends that notice with `.agents/skills/mailbox/scripts/lane-mail notice --item [ITEM_KEY] --file tmp/park-request.md`. The lane makes no further file changes while it waits for the overseer to park it.

`lane-close` is the park judge. It first asks `lane-host stop-sandbox --check` whether the disk can be stopped and started again. A provider without that pair refuses before any signal or GitHub read. It reads the checked-out branch and head through the provider's file interface, then checks that the clean-status record names that branch and head and carries an empty status. Missing, unreadable or mismatched evidence refuses. File reads cannot prove current cleanliness; the lane owns the status reading and its quiet wait after the notice. When the remote Git read fails on a queue park, the item's workflow-state `branch` may name its PR branch instead. Admission and refusal name this fallback as `branch-source=workflow-state`.

A queue park requires an OPEN PR whose head branch and commit match the lane. This includes a second branch of the same item. GitHub must queue the PR, or arm auto-merge with `mergeStateStatus=CLEAN`. The github skill's reducer must print no attention line. The queue and CLEAN prove the base's required approval; reducer silence alone does not. A dependency park requires the blocking PR to be OPEN. It does not apply the lane's queue, branch or review checks to that other PR.

The provider's `stop-sandbox` follows the harness stop and window close. Its `sandbox-stopped` line records `parked` with `{head, repo, at}`, an own `pr` when supplied, and `until_pr` for a dependency wait. A qualified dependency also records `until_repo`. The own `repo` stays the lane repository. A failed sandbox stop leaves `stopped`. Recovery relaunch or a second park retries that stop (`lane-close --help`).

Run the park when the lane's notice names a dependency hold or its queue wait. A `heartbeat` also identifies queue waits from the lane's status file ([oversee.md § Bounded lane reads](../workflows/oversee.md#bounded-lane-reads)). The lane must supply its clean-status record before that park. The verb's own reads decide admission.

What a parked lane keeps: its record, its `mail_root` and PR-watch rows, and its disk, with the harness transcript, the mailbox and its `tmp`. What it gives up: its window, its pane reads and its mail pass, since the disk is stopped. It keeps its fleet slot: `open-terminal` counts `running`, `preparing` and `parked` records against the cap their declared kind uses, so the cap bounds items in flight and a resume never adds a lane ([lane-directive.md § Caps](lane-directive.md#caps)). The [oversee.md § 4](../workflows/oversee.md#4-watch-and-advance) watch carries a parked record for its merged check, terminal close and `lane-long` age and names the count as `parked=` in its `fleet-read` note; `oversee-report` lists it under Running with its recorded own pull request, when present and reads nothing from its disk.

What ends a park, each per [oversee-events.md § Event kinds](oversee-events.md#event-kinds):

- Merge of the wait PR in that repository: `until_pr` selects it for a dependency park; `pr` selects it for a queue park. The watch prints `parked-merged` for an item with work left. The lane's own PR merge does not clear a dependency wait. The watch repeats the resume hand at a heartbeat while the record still reads parked. Recovery relaunch changes that record before creating the harness, so a replay cannot launch another copy. A dependency merge earns no cycle for the waiting item. The resumed lane rebases and continues its held step.
- `parked-closed`: the dependency PR closed without merging. The watch reports it once. The overseer resolves the hold or resumes the lane through Recovery relaunch.
- A `pr-watch` line on the parked pull request, `threads-open`, `changes-requested`, `ci-failed`, `disarmed`, `awaiting-stale`, `head-moved` or `error`: the lane is needed again. `disarmed` is also how a dequeue nothing else reported reads, since the reducer prints it for an approved pull request neither queued nor armed, so the queue needs no other reading, and a parked pull request the heartbeat still lists open with no reducer line stays parked. Resume it through [lane-directive.md § Recovery relaunch](lane-directive.md#recovery-relaunch): the launcher starts the sandbox first, rewrites the record `stopped` once the provider confirms the start, and resumes the harness on its kept disk; a start the provider does not confirm is `host-start-failed` with the record still parked, never a resumed lane, and a create that fails after the start leaves the stopped record, which a plain relaunch recovers. The unpark owner retains the PR identity as `pending_pr`, per [workflow-state.md](../schemas/workflow-state.md#oversee-state), so an OPEN PR still prevents terminal close after this failure. A resumed lane that opens on no transcript to continue is a blocker to report, not a resume.

## Parking an item or account wait

Use this route when an overseer-recorded hold, a live blocked-by relation or a lane notice names the outside outcome holding the next step. Resolve the dependency identity and required delivery first. Record every blocker the step requires. An account wait needs a fresh walled judgment for the recorded account, no admitted replacement and no reset in hand. Keep known-reset waits on their existing route.

Write the tagged wait in [workflow-state.md](../schemas/workflow-state.md#oversee-state) to a file. Take its native launch flags and session path from the original launch evidence. Keep the source directive or mail identity. Read the provider's existing `list --json` and bind the unique item/repository row's immutable `id`; its reusable name is insufficient. Run `lane-close --park --wait-file [PATH] [ITEM_KEY] --state-dir [OVERSEE_STATE_DIR]`. Add `--pr [OWN_PR]` when the lane has an own PR. This input is separate from the legacy `--until-pr` route above.

The executor keeps the current preservation boundary. It requires the lane's matching clean-status record, readable Git branch/head and that head on the repository's published branch. Dirty or unpublished work refuses before harness retirement. Never commit, push, stash or reset work to manufacture park admission. A provider without readable immutable identity or preservation evidence reports a gap. The parked record is no authority to delete a retained disk. Fleet must adopt the producer contract in its reaper, retention close and archive owners before operating this route; do not use a deletion-safe label to mark retained work.

`workflow-state lane-run` holds per-item lifecycle ownership across the current-record read, stop/start and state writes. A stale binding or concurrent owner cannot stop a replacement. The executor saves the wait and pending ask identities before retirement. Pending asks and mailbox cursors stay intact. A confirmed harness stop leaves `stopped` if disk stop fails. Only `sandbox-stopped item=ID` earns `parked.at`. Failed or missing validation receipts stay failed or missing; suspension never proves a validation pass.

Only `parked-ready` permits a resume request. The launcher rereads every dependency identity and the saved hold. A qualified PR must match its recorded branch/item and have both merge time and merge commit. A direct delivery uses the cycle owner's successful-push/containment judgment for its recorded branch and commit. Unbound deliveries, canceled items and unread evidence stay held. An artifact without its existing verification reader stays held as `delivery-verifier-unavailable`; tracker Done cannot replace that proof. An account wait needs a fresh successful `lanes pick --no-cache` for the same host, account, model and bucket. Another account's room and elapsed time do not clear it.

Resume through the existing terminal command with `--relaunch --continue-resume`, preserving the recorded native choices. This continues the same work and neither spends nor resets death recovery. The launcher keeps the existing recovery object unchanged. It checks the immutable provider id before start and after create. Only `sandbox-started item=ID` closes the confirmed pause. A failed start stays parked; a failed create or missing native transcript after start leaves `stopped` with the accepted wait and failure. Busy preparation continues its saved step. A ready harness earns `dependency_wait.outcome=running`; replay cannot start it twice.

Own-PR attention and an unmerged PR close remain diagnostic while a typed wait holds. They cannot clear it. A stopped or parked typed wait cannot be auto-deleted because its tracker became Done or Canceled. Keep answers in the existing mailbox while compute is stopped. After resume, the native continuation reads inbox and the original ask wait reads its answer.

Confirmed parked intervals stay in the lane record and prune archives. Long-lane age subtracts their union from the original launch time. The report clips open and completed intervals to UTC calendar days. It labels unread archives and idle-stop evidence. A pre-stop `reaped` mailbox note, including one followed by `reap-not-stopped`, is not a confirmed stop or a dollar saving. Missing acknowledgments make timing unavailable.

## Talking to a lane

A mailbox lane whose host declares `files=verb` needs `--root [MAIL_ROOT] --host` on the sends below. Use the lane record's `mail_root` as `[MAIL_ROOT]`. The send uses the record's `host` instead of the configured provider. A different root refuses as `host-root-mismatch`. A send that reads such a record without `--host` refuses as `host-root-required` before it writes mail or prints a sent receipt.

Answering and directing are the same two commands on every harness and every surface, inside tmux or not. Add `--root [MAIL_ROOT] --host` for a lane whose record puts it on another host, and `--root [MAIL_ROOT]` alone, run from a checkout of that repository, for a local lane whose `mail_root` is another repository's worktree.

```bash
.agents/skills/mailbox/scripts/lane-mail send --item [ISSUE_ID] --re [MESSAGE_ID] --file [PATH] --state-dir [OVERSEE_STATE_DIR]
```

```bash
.agents/skills/mailbox/scripts/lane-mail send --item [ISSUE_ID] --directive --file [PATH] --state-dir [OVERSEE_STATE_DIR]
```

Text crosses `--file` ([SKILL.md](../SKILL.md) § Harness-Safe Shell). The `--state-dir` send reads the lane's record and matches the `channel` its host kind declares, and refuses as `lane-unrecorded` where that state holds no record for the lane; a lane with no record, one the watch carries from `--item` alone, takes the same send with no `--state-dir`. A `session` lane, a Claude cloud session, takes a directive alone, queued into its session; the receipt is `{ok: true}` and no `directive-read` follows, so the lane's next push or `## Lane status` shows it acted, and a session that does not act shows as `lane-stalled`. `--re` and `--halt` refuse there, `session-archived` is a session the operator archived, and `session-send-failed` carries the CLI's own words. A directive answers no ask and `--halt` in place of `--directive` halts the lane; the Lane mail rule in [skill-rules.md](skill-rules.md) says when each reaches it. Wake the lane after the send where [watch-delivery.md](watch-delivery.md#lane-mailbox-monitor) says. Keep the lane's tracker, repository, harness, item, `--lane` and `--launch-flags` arguments; the wake reads `live_display` from the lane record and needs no `--live-display`. The wake resumes the lane's own session with one line that runs `lane-mail inbox`, and reaches only lanes on this host, run from the checkout the send used, because the wake resolves the lane's tree from the caller's own project; it wakes a lane only when the shared judge calls it `idle`, and refuses any other state as `wake-refused reason=[STATE]`. Never send a lane text by keystroke.

```bash
.agents/skills/orch/scripts/open-terminal --wake --harness [HARNESS] --state-dir [OVERSEE_STATE_DIR] [ISSUE_ID]
```

After a directive, wait for the watch's `directive-read` for its id: the lane's own mailbox cursor passing it, whichever read path moved it, on every harness and on a hosted lane. Never read a pane to confirm a delivery. `directive-unread` is the directive still unread past `ORCH_DIRECTIVE_UNREAD_SECS`: wake the lane, reach it by Pane paste, or relaunch it, by the lane's state and [lane-reach.md](lane-reach.md).

**A refusal is a state, not a remedy.** A halt or an answer to a lane with no monitor that the wake refuses lands only where the Lane mail rule above says. Send where the reason allows it; mail that cannot wait takes [lane-reach.md](lane-reach.md#mail-the-wake-cannot-deliver).

[lane-reach.md](lane-reach.md) holds what each wake refusal reason licenses and, per harness, how a lane is launched, how its state is read and how its harness dialogs are answered.

**Pane paste.** Write harness input to a file with the harness file tool, then type it with the one pane writer. `[WINDOW]` is the lane record's `window`, and `[PROCESS]` is the record's `harness`, or `ssh` for a record carrying `host`:

```bash
.agents/skills/orch/scripts/pane-write --window [WINDOW] --expect [PROCESS] --file [PATH] --state-dir [OVERSEE_STATE_DIR]
```

It sends input through the provider when the recorded host declares `pane=verb`, under [lane-host.md](../schemas/lane-host.md#provider-protocol). Otherwise it cancels local copy mode, pastes the file and presses `Enter`. A dialog key takes `--key [KEY]` in place of `--file`. A refusal, exit 1, types nothing, and its `fix=` line names the remedy (`pane-write --help`). Exit 2, `write-failed`, may have typed part of the input: read the pane before a retry. Never paste a shell command into a lane pane. Stop a process inside a hosted sandbox through `lane-host stop --item [ITEM] --harness [HARNESS]`. Never type a process-name kill at a prompt that can belong to the control host.

A lane under a session limit still needs its one-line continuation nudge pasted into its pane at the reset through Pane paste above, since a walled harness runs no turn and so reads no mail; the launch brief and a harness dialog's answer reach a pane the same way, and nothing else does.

A lane never arms the shared git hooks from its worktree; a guard-script PR whose new chain refuses the branch under main's installed scripts is a one-time transition the overseer sequences.

**Resuming a dead or walled lane.** Use [lane-directive.md § Recovery relaunch](lane-directive.md#recovery-relaunch) without `--cmd` for automatic session selection or the fresh start brief. Only a hosted Codex relaunch that reports `resume-lineless` needs its continuation through Pane paste afterwards. A fresh start needs no paste.
