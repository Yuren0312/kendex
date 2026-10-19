# shellcheck shell=bash
# The overseer's checkout as a launch finds it, for the suites whose launches
# fast-forward it (scripts/lib/overseer-launch.sh § ol_checkout_sync). Sourced
# after TMP_ROOT is made; requires git.
#
#   checkout_world DIR   DIR, an existing directory, made a checkout of main
#                        tracking the bare origin $TMP_ROOT/origin.git at its
#                        head, its own files left untracked. Also lays the
#                        github skill's git wrapper and its libs beside every
#                        mutant_scripts copy (growth-state.sh), where
#                        sync-base reads them from, so a mutant launch syncs
#                        as a real one.
#   checkout_advance     one more commit on origin's main, its sha printed:
#                        origin's main one commit further ahead.
#   checkout_commit DIR  one local commit on DIR's branch, its sha printed.
#
# The tree a harness starts on, which a sync run after the session opens
# would leave behind while the checkout's HEAD reads synced once the launcher
# returns:
#
#   checkout_stub_line   the sh line a harness stub runs first: the HEAD of
#                        the directory it starts in, or none outside a
#                        checkout, written whole to CHECKOUT_STARTED.
#   checkout_started     what the last harness to start recorded, or none
#                        since checkout_started_clear.
#   checkout_late_sync NAME
#                        a mutant_scripts copy (growth-state.sh) whose
#                        ol_session_open syncs after `create`, its scripts
#                        directory printed.

checkout_git() { git -c user.name=fixture -c user.email=fixture@example.com -c commit.gpgsign=false "$@"; }
# Git's background maintenance is off in each repository the suite's exit
# removes, so the removal cannot race its writer.
checkout_quiet() { # REPO
  git -C "$1" config gc.auto 0 && git -C "$1" config maintenance.auto false
}

checkout_world() { # DIR
  local origin="$TMP_ROOT/origin.git" seed="$TMP_ROOT/origin-seed" lib
  lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || return 1
  # shellcheck source=shared-skill-libs.sh
  source "$lib/shared-skill-libs.sh" || return 1
  orch_fixture_shared_libs "$TMP_ROOT/checkout" || return 1
  cp -p -- "$lib/../../../github/scripts/git-https-auth" "$TMP_ROOT/github/scripts/" || return 1
  if [[ ! -d "$origin" ]]; then
    git init -q --bare -b main "$origin" && checkout_quiet "$origin" || return 1
    git init -q -b main "$seed" && checkout_quiet "$seed" || return 1
    printf 'seed\n' > "$seed/README" || return 1
    checkout_git -C "$seed" add README || return 1
    checkout_git -C "$seed" commit -q -m seed || return 1
    git -C "$seed" push -q "$origin" main || return 1
  fi
  git -C "$1" init -q -b main && checkout_quiet "$1" || return 1
  git -C "$1" remote add origin "$origin" || return 1
  git -C "$1" fetch -q origin || return 1
  git -C "$1" reset -q origin/main || return 1
  git -C "$1" checkout -q -- . || return 1
  git -C "$1" branch -q --set-upstream-to=origin/main main || return 1
  git -C "$1" remote set-head origin main || return 1
}

checkout_advance() {
  local seed="$TMP_ROOT/origin-seed"
  printf 'advance %s\n' "$(date +%s%N)" >> "$seed/README" || return 1
  checkout_git -C "$seed" commit -q -am advance || return 1
  git -C "$seed" push -q "$TMP_ROOT/origin.git" main || return 1
  git -C "$seed" rev-parse HEAD
}

checkout_commit() { # DIR
  checkout_git -C "$1" commit -q --allow-empty -m local || return 1
  git -C "$1" rev-parse HEAD
}

CHECKOUT_STARTED="$TMP_ROOT/checkout-started"
checkout_stub_line() {
  printf '{ git rev-parse HEAD 2>/dev/null || echo none; } > %q && mv -f -- %q %q\n' \
    "$CHECKOUT_STARTED.tmp" "$CHECKOUT_STARTED.tmp" "$CHECKOUT_STARTED"
}
checkout_started() { cat -- "$CHECKOUT_STARTED" 2>/dev/null || echo none; }
checkout_started_clear() { rm -f -- "${CHECKOUT_STARTED:?}"; }

# The sync moved after `create` first waits, up to 5 seconds, for the harness
# to record its tree, so the harness reads the checkout before the sync moves
# it on every run rather than by a race.
checkout_late_sync() { # NAME
  local dir lib
  dir="$(mutant_scripts "$1" lib/overseer-launch.sh)" || return 1
  lib="$dir/lib/overseer-launch.sh"
  mutate_file "$lib" '  ol_checkout_sync "$1" || ol_checkout_notice
' ''
  mutate_file "$lib" '    || { OL_REASON=create-failed; return 1; }
  ol_session_from_out
' "    || { OL_REASON=create-failed; return 1; }
  local waited=0
  until [[ -f $(printf %q "$CHECKOUT_STARTED") ]] || (( waited++ >= 50 )); do sleep 0.1; done
  ol_checkout_sync \"\$1\" || ol_checkout_notice
  ol_session_from_out
"
  printf '%s\n' "$dir"
}

# shellcheck shell=bash
# Native event carrier shared with the Jarvis controller suite. Legacy policy
# fixtures keep their own argv/screen inputs; this supplies actual startup hooks.
controller_fixture_install() { # HOME SCRIPTS NATIVE_BIN
  local home="$1" scripts="$2" bin="$3" skills fixture
  skills="$(cd -- "$scripts/../.." && pwd -P)" || return 1
  fixture="${BASH_SOURCE[0]%/*}/../../../jarvis/tests/fixtures/harness.py"
  mkdir -p -- "$home" "$bin" || return 1
  cp -- "$fixture" "$home/.fixture-harness.py" || return 1
  jq -n --arg skills "$skills" --arg bash "$BASH" --arg rows "$TMP_ROOT/native-events.jsonl" \
    --arg gate "$TMP_ROOT/native-gate" --arg idle "$TMP_ROOT/idle" --arg process "${HARNESS_PIDS:-}" \
    '{skills:$skills,bash:$bash,rows:$rows,gate:$gate,idle_marker:$idle,process_markers:$process}' > "$home/.fixture.json" || return 1
  local harness
  for harness in claude codex copilot pi; do
    if ! cmp -s -- "$ORCH_TEST_NATIVE" "$bin/$harness"; then
      cp -- "$ORCH_TEST_NATIVE" "$bin/$harness" || return 1
      chmod +x "$bin/$harness" || return 1
    fi
  done
}

# Register the fixture's hand-opened predecessor through the surviving owner.
controller_fixture_register() { # SCRIPTS HOME PANE HARNESS ACCOUNT TMUX
  local scripts="$1" home="$2" pane="$3" harness="$4" account="$5" socket fields record
  socket="${6%%,*}"
  fields="$(tmux -S "$socket" display-message -p -t "$pane" '#{pid} #{start_time} #{window_id} #{session_name}')" || return 1
  local server start window session
  read -r server start window session <<<"$fields"
  record="$(jq -cn --arg server "$server" --argjson start "$start" --arg socket "$socket" --arg pane "$pane" \
    --arg window "$window" --arg session "$session" --arg harness "$harness" --arg account "$account" --arg cwd "$home" \
    '{runtime:"tmux",server:$server,server_start:$start,server_socket:$socket,pane:$pane,window:$window,tmux_session:$session,
      harness:$harness,account:$account,home:$account,cwd:$cwd,session_id:"s1",generation:1}')" || return 1
  (cd -- "$home" && "$scripts/controller-session" register --home "$home" --record "$record" >/dev/null)
}

# tmux can acknowledge window removal before its native supervisor exits.
controller_fixture_await_ended() { # SCRIPTS STATE
  local fields pid start rc deadline=$((SECONDS + 12))
  fields="$(jq -er '.overseer.lifecycle.process | [.pid,.started_at] | @tsv' "$2")" || return 1
  IFS=$'\t' read -r pid start <<<"$fields"
  while (( SECONDS < deadline )); do
    rc=0
    "$BASH" "$1/lib/session-backend.sh" worker-live "$pid" "$start" || rc=$?
    case "$rc" in 1) return 0 ;; 0) sleep 0.05 ;; *) return 1 ;; esac
  done
  return 1
}

# Policy assertions observe the real argv and the real pasted brief. Native
# identity/kickoff fields have separate coverage in the shared lifecycle suite.
controller_fixture_argv() { # FILE HARNESS
  python3 - "$1" "$TMP_ROOT/native-events.jsonl" "$2" <<'PY'
import json
from pathlib import Path
import sys
path, events, harness = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
if not path.exists():
    print("none", end="")
    sys.exit(0)
words = [word for word in path.read_text().splitlines() if not word.startswith("argv0=")]
prefix = words[:1] if words and words[0].startswith(("lane=", "home=")) else []
args = words[len(prefix):]
rows = [json.loads(line) for line in events.read_text().splitlines()] if events.exists() else []
started = next((row for row in reversed(rows) if row.get("harness") == harness and row.get("argv") == args), None)
if started:
    own = [row for row in rows if row.get("id") == started["id"]]
    kickoff = next((row["kickoff"] for row in own if "kickoff" in row), None)
    selected, skip = [], False
    for arg in args:
        if skip:
            skip = False
        elif arg in ("--session-id", "--resume", "resume"):
            skip = True
        elif arg.startswith(("--session-id=", "--resume=")):
            continue
        elif kickoff is not None and arg == kickoff:
            if selected and selected[-1] == "-i":
                selected.pop()
        else:
            selected.append(arg)
    prompt = next((row["prompt"] for row in reversed(own) if "prompt" in row), None)
    args = selected + ([prompt] if prompt is not None else [])
print("".join(word + ";" for word in prefix + args), end="")
PY
}
