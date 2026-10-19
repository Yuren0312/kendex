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
    --arg gate "$TMP_ROOT/native-gate" --arg idle "$TMP_ROOT/idle" --arg process "${HARNESS_PIDS:-}" --arg home "$home" \
    '{skills:$skills,bash:$bash,rows:$rows,gate:$gate,idle_marker:$idle,process_markers:$process,home:$home}' > "$home/.fixture.json" || return 1
  local harness
  for harness in claude codex copilot pi; do
    if ! cmp -s -- "$ORCH_TEST_NATIVE" "$bin/$harness"; then
      cp -- "$ORCH_TEST_NATIVE" "$bin/$harness" || return 1
      chmod +x "$bin/$harness" || return 1
    fi
  done
}

# Policy cases supply a native event row; launch/receipt assertions use
# harness.py's real child callback.
controller_fixture_start() { # SCRIPTS HOME PANE HARNESS ACCOUNT TMUX
  local scripts="$1" home="$2" pane="$3" harness="$4" account="$5" address="$6" skills payload
  skills="$(cd -- "$scripts/../.." && pwd -P)" || return 1
  payload="$(jq -cn --arg cwd "$home" --arg harness "$harness" --arg account "$account" \
    '{at:now,event:"SessionStart",harness:$harness,account:$account,session_id:"s1",cwd:$cwd}')" || return 1
  (cd -- "$home" && export TMUX="$address" TMUX_PANE="$pane" \
      CLAUDE_CONFIG_DIR="$account" CODEX_HOME="$account" COPILOT_HOME="$account" PI_CODING_AGENT_DIR="$account"
    "$BASH" -c 'source "$1/mailbox/scripts/lib/file-lock.sh"; source "$1/mailbox/scripts/lib/mailbox-append.sh";
      source "$1/orch/scripts/lib/lane-context.sh"; source "$1/orch/scripts/lib/session-rows.sh";
      key="$(lane_context_caller_key)"; file="$(session_rows_overseer_file "$PWD" "${key%% *}" "${key#* }")";
      mkdir -p "${file%/*}"; mailbox_append_locked "$file" 2' fixture "$skills" <<<"$payload")
}

# Register the fixture's hand-opened predecessor through the surviving owner.
controller_fixture_register() { # SCRIPTS HOME PANE HARNESS ACCOUNT TMUX
  controller_fixture_start "$@" || return
  (cd -- "$2" && export TMUX="$6" TMUX_PANE="$3" CLAUDE_CONFIG_DIR="$5" \
    CODEX_HOME="$5" COPILOT_HOME="$5" PI_CODING_AGENT_DIR="$5"
    local output rc=0
    output="$("$1/oversee" register --account "$5" 2>&1)" || rc=$?
    if [[ "$rc" != 0 ]]; then
      printf '%s\n' "$output" >&2
      exit "$rc"
    fi)
}

# tmux can acknowledge window removal before its native supervisor exits.
controller_fixture_await_ended() { # SCRIPTS STATE
  local fields pid start rc deadline=$((SECONDS + 12))
  fields="$(jq -er '[.overseer.lifecycle.process,.overseer.lifecycle.native_process]
    | map(select(.pid != null and .started_at != null)) | unique_by(.pid,.started_at)
    | .[] | [.pid,.started_at] | @tsv' "$2")" || return 1
  while IFS=$'\t' read -r pid start; do
    while (( SECONDS < deadline )); do
      rc=0
      "$BASH" "$1/lib/session-backend.sh" worker-live "$pid" "$start" || rc=$?
      case "$rc" in 1) break ;; 0) sleep 0.05 ;; *) return 1 ;; esac
    done
    [[ "$rc" == 1 ]] || return 1
  done <<<"$fields"
}

# A caller retired from its own pane cannot print the successor's receipt.
controller_fixture_await_running() { # STATE PREDECESSOR_PANE
  local deadline=$((SECONDS + 45))
  while (( SECONDS < deadline )); do
    if jq -e --arg prior "$2" '.overseer | .pane != null and .pane != $prior
      and .session_id != null and .lifecycle.state == "running"
      and .lifecycle.pending.brief_taken != null' "$1" >/dev/null 2>&1; then
      return 0
    fi
    sleep 0.05
  done
  jq -c '.overseer | {pane,generation,lifecycle:(.lifecycle | {state,reason,transfer,worker,terminal,pending,native_process,native_exit})}' "$1" >&2
  tail -n 40 "${1%/*}/session.log" >&2
  return 1
}

# Policy assertions observe the real argv and the real pasted brief. Native
# identity/kickoff fields have separate coverage in the shared lifecycle suite.
controller_fixture_argv() { # FILE [policy]
  python3 - "$1" "$TMP_ROOT/native-events.jsonl" "${2:-words}" <<'PY'
import json
from pathlib import Path
import sys
path, events = Path(sys.argv[1]), Path(sys.argv[2])
if not path.exists():
    print("none", end="")
    sys.exit(0)
words = [word for word in path.read_text().splitlines() if not word.startswith("argv0=")]
prefix = words[:1] if words and words[0].startswith(("lane=", "home=")) else []
args = words[len(prefix):]
rows = [json.loads(line) for line in events.read_text().splitlines()] if events.exists() else []
started = next((row for row in reversed(rows) if row.get("argv") == args), None)
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
if sys.argv[3] == "policy":
    groups = []
    words = iter(args)
    for word in words:
        if word in ("-m", "--model"):
            groups.append(["model", next(words)])
        elif word in ("-c", "--config"):
            key, separator, value = next(words).partition("=")
            assert separator
            groups.append(["setting", key, value])
        elif word in ("--context", "--max-autopilot-continues", "--reasoning-effort"):
            groups.append([word, next(words)])
        else:
            groups.append(["word", word])
    print(json.dumps({"prefix": prefix, "policy": sorted(groups)}, separators=(",", ":"), sort_keys=True), end="")
else:
    print("".join(word + ";" for word in prefix + args), end="")
PY
}

# Expected native policy is independent of the launch table and argv parser.
controller_fixture_codex_expected() { # PREFIX MODEL BRIEF [off|keep]
  jq -cnS --arg prefix "$1" --arg model "$2" --arg brief "$3" --arg question "${4:-keep}" '
    {prefix:[$prefix],policy:([
      ["model",$model], ["setting","model_reasoning_effort","high"],
      ["setting","check_for_update_on_startup","false"],
      ["setting","features.daemon_auto_start","false"],
      ["setting","notice.hide_rate_limit_model_nudge","true"],
      ["setting","model_auto_compact_token_limit","9223372036854775807"],
      ["setting","model_auto_compact_token_limit_scope","body_after_prefix"],
      ["setting","model_post_turn_compact_threshold_percent","0"],
      ["word","--dangerously-bypass-approvals-and-sandbox"],
      ["word","--dangerously-bypass-hook-trust"], ["word",$brief]
    ] + (if $question == "off" then [["setting","features.default_mode_request_user_input","false"]] else [] end) | sort)}'
}
