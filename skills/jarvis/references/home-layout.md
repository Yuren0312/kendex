# Home layout

Read when setting up an assistant home, choosing a home path or starting a continuing session.

## Paths

| Path | Git status | Reason |
|---|---|---|
| `AGENTS.md` | Committed | Your standing instructions travel with you. |
| `skills/own/` | Committed | You are the source. kendex installs your skills from here. |
| `memory/` | Committed | Durable facts and rulings travel with you under [Memory](memory.md). |
| `state/handoff.md` | Committed | The session model writes the current handoff under [Handoff](long-session.md#handoff). |
| `state/archive/` | Committed | The session model writes archived handoffs and progress logs under [Handoff](long-session.md#handoff). |
| Other files under `state/` | Committed | A consumer's file and shell tools write its work here. An app-managed home limits model file and shell writes to this folder. |
| The path orch’s `workflow-state path oversee` resolves | Local | Orch keeps the sole controller record under `.overseer`. Jarvis calls orch’s lifecycle operations. No controller record is written under `state/`. |
| `.agents/skills/` and each harness's skill and agent directories, such as `.claude/skills/`, `.claude/agents/` and `.codex/agents/` | Committed | kendex renders or links installed skills and agents here so a clone has them. In a home where kendex did not install Jarvis, an assistant app such as VGS can copy a kendex-rendered package to these same paths. |
| `tmp/` | Local | Scratch files stay on this machine under [Scratch files](computer-use.md#scratch-files). |
| `.env.local`, or the private env file selected by `KENDEX_ENV_FILE` | Local | Secrets stay on this machine; kendex creates the file with mode 600. |

`kendex add` writes the managed local-state ignore block. When kendex saves a secret into a new private env file, it adds that file's ignore line. These lines keep scratch and secrets out of Git. You do not need to add them yourself.

## Copilot folder trust

Before the first Jarvis Start with Copilot CLI, open this home in native Copilot with the selected account. Approve its folder-trust request once. Jarvis does not approve native security requests. Without this setup, Start ends the native session and reports Blocked with reason `trust-required`, naming the dialog's question in its detail.

## Session record

The [session command](../workflows/session.md#session-command) calls orch’s controller lifecycle for one canonical home. Orch resolves the local record through `workflow-state path oversee`. The record retains Off and unfinished transfers across logins and restarts. Jarvis’s explicit first launch uses the home’s tmux socket. An orch launch or registration can use an existing fleet server. Status returns the owned socket, session, window and pane.

Moving a running home requires retiring its controller before the move. A new clone starts without a live controller. Committed handoff text grants no runtime identity. A record for a different canonical home refuses reuse.

A package refresh can leave the former XDG `kendex/jarvis/<canonical-home-key>/jarvis-session.json` record and its controller alive. Its presence refuses new launches and registrations with `record-unreadable`. Use orch’s `controller-session retire-legacy --home HOME` to stop the exact recorded controller identities, preserve Off and the boot marker in orch, and remove the retired record. If the old Start, Stop or succession worker is still running, retirement refuses; wait for that bounded command to settle, then run retirement again. A failed identity or stop check leaves that record in place. Removing the old file by hand does not prove the controller ended and is not a retirement route.
