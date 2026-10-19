#!/usr/bin/env bash
# Private bridge to the existing lock, launch, history and pane owners.
set -euo pipefail
SCRIPT_DIR="$(cd -- "${BASH_SOURCE[0]%/*}/.." && pwd -P)"
ROOT="$(cd -- "$SCRIPT_DIR/../.." && pwd -P)"
for package in mailbox; do
  if [[ ! -d "$ROOT/$package/scripts" ]]; then
    printf 'jarvis-session: dependency=%s\n' "$package" >&2
    exit 1
  fi
done
verb="$1"
shift
case "$verb" in
  assert-record)
    source "$SCRIPT_DIR/lib/overseer-launch.sh"
    jq -e --argjson expected "$2" --argjson request "$3" "$OL_JQ_DEFS"'
      (.overseer | ol_succession_owned($expected))
      and ($request == null or (.overseer | ol_recovery_bound($request)))' -- "$1" >/dev/null
    exit ;;
  pane-process)
    source "$SCRIPT_DIR/lib/lane-state.sh"
    pid="$(tmux -S "$1" display-message -p -t "$2" '#{pane_pid}')" || exit 1
    at="$(lane_process_start "$pid")" || exit 1
    [[ -n "$at" ]] || exit 1
    jq -cn --argjson pid "$pid" --arg at "$at" '{pid:$pid,started_at:$at}'
    exit ;;
  state-path) exec "$SCRIPT_DIR/workflow-state" path oversee ;;
  state-init)
    if ! "$SCRIPT_DIR/workflow-state" exists oversee >/dev/null; then
      "$SCRIPT_DIR/workflow-state" init oversee >/dev/null
    fi
    exit ;;
  lock)
    source "$ROOT/mailbox/scripts/lib/file-lock.sh"
    exec 200>>"$1.lock"
    orch_take_lock 200 "$1.lock" 10
    printf 'locked\n'
    cat >/dev/null
    orch_release_lock
    exit ;;
esac
source "$SCRIPT_DIR/lib/lane-launch.sh"
source "$SCRIPT_DIR/lib/lane-state.sh"
source "$SCRIPT_DIR/lib/pane-write.sh"
source "$SCRIPT_DIR/lib/copilot-session.sh"
source "$SCRIPT_DIR/lib/lane-relaunch.sh"
source "$SCRIPT_DIR/lib/tmux-server.sh"
# task_window_live SOCKET SERVER START PANE: tmux_pane_live's answer for a
# task window on the home's socket. The recorded server serves that socket
# until it exits, so another server answering it proves the window gone (1),
# whatever process now holds the recorded pid.
task_window_live() {
  local rc=0 serving
  export TMUX="$1,0,0"
  tmux_pane_live "$2" "$3" "$4" "$1" || rc=$?
  if [[ "$rc" == 2 ]] && serving="$(tmux display-message -p '#{pid}' 2>/dev/null)" \
    && [[ -n "$serving" && "$serving" != "$2" ]]; then
    rc=1
  fi
  return "$rc"
}
controller_flags() { # JSON_ARGV
  controller_flags_file="$(mktemp)" || return 1
  trap 'rm -f -- "${controller_flags_file:?}"' EXIT
  jq -j 'if type == "array" and all(.[]; type == "string" and (contains("\u0000") | not))
    then .[] | . + "\u0000" else error("controller-flags-invalid") end' <<<"$1" >"$controller_flags_file" || return 1
  flags=()
  while IFS= read -r -d '' flag; do flags+=("$flag"); done <"$controller_flags_file"
  rm -f -- "${controller_flags_file:?}" || return 1
  trap - EXIT
}
case "$verb" in
  worker-launch)
    source "$SCRIPT_DIR/lib/job-unit.sh"
    controller_flags "$4" || exit 1
    job_unit_main launch controller-worker "$1" -- "$BASH" -c '
      set -euo pipefail
      backend=$1 acknowledgement=$2 log=$3; shift 3
      identity="$("$BASH" "$backend" process "$$")" || exit 1
      [[ -f "$acknowledgement" && ! -L "$acknowledgement" ]] || exit 1
      printf "%s\n" "$identity" > "$acknowledgement" || exit 1
      exec "$@" >>"$log" 2>&1' controller-worker "${BASH_SOURCE[0]}" "$2" "$3" "${flags[@]}" ;;
  worker-cancel)
    source "$SCRIPT_DIR/lib/job-unit.sh"
    job_unit_main stop-job "$1" "$2" '*controller-session.py*' ;;
  select)
    source "$ROOT/mailbox/scripts/lib/kendex-env.sh"
    kendex_load_project_env "$3"
    DEP_ERR="$(mktemp)" || exit 1
    trap 'rm -f -- "$DEP_ERR"' EXIT
    source "$SCRIPT_DIR/lib/lane-context.sh"
    source "$SCRIPT_DIR/lib/overseer-launch.sh"
    harness="$1" account="$2" model="$4" effort="$5"
    trigger="${ORCH_OVERSEER_HEADROOM_PCT:-5}"
    ol_account "$harness" "$model"
    rc=4
    if ol_account_measured "$OL_ACCOUNT_HARNESS"; then
      # The source account and the walk both serve an overseer, so neither
      # takes the seat reserve that lanes keeps for ordinary work-item picks.
      rc=0
      ol_lanes "$OL_ACCOUNT_HARNESS" pick --lane "$account" --harness "$OL_ACCOUNT_HARNESS" --for-overseer \
        --min-headroom-pct "$trigger" ${OL_ACCOUNT_MODEL:+--native-model "$OL_ACCOUNT_MODEL"} --json >/dev/null || rc=$?
    fi
    case "$rc" in
      0|4|5) ;; # An unmeasured account keeps the existing context-only route.
      3)
        ol_preference_entries "$(ol_preference)" || { printf 'jarvis-session: invalid-preference entry=%s\n' "$OL_BAD_ENTRY" >&2; exit 1; }
        OL_WALK_CALLER_HARNESS="$harness" OL_WALK_CALLER_LANE="$account"
        OL_WALK_CALLER_MODEL="$model" OL_WALK_CALLER_PICK_MODEL="$model" OL_WALK_CALLER_EFFORT="$effort"
        # Select only. Jarvis launches native permission defaults and transfers
        # no predecessor flags, so this asks the walk about harness rows alone.
        OL_WALK_SOURCE_HARNESS="$harness" OL_WALK_SOURCE_ROWS=1
        OL_WALK_REFUSE_ID="$(ol_account_id "$account")"
        ol_walk "$trigger" "$account" ${OL_ENTRIES[@]+"${OL_ENTRIES[@]}"} caller || {
          printf 'jarvis-session: selection-failed account=%s reason=%s\n' "$account" "${OL_REASON:-no-lane-qualifies}" >&2
          [[ ! -s "$DEP_ERR" ]] || cat -- "$DEP_ERR" >&2
          exit 1
        }
        harness="$OL_HARNESS" account="$OL_LANE_DIR" model="$OL_MODEL" effort="$OL_EFFORT"
        ;;
      *) printf 'jarvis-session: selection-failed account=%s exit=%s\n' "$account" "$rc" >&2
         [[ ! -s "$DEP_ERR" ]] || cat -- "$DEP_ERR" >&2
         exit 1 ;;
    esac
    jq -cn --arg harness "$harness" --arg account "$account" --arg model "$model" --arg effort "$effort" \
      '{harness:$harness,account:$account,model:$model,effort:$effort}' ;;
  task-prepare)
    source "$ROOT/jarvis/scripts/lib/jarvis-env.sh"
    jarvis_load "$5"
    source "$SCRIPT_DIR/lib/overseer-launch.sh"
    DEP_ERR=/dev/stderr
    ol_entry_model "$1:$2:$3" || { printf 'jarvis-task: selection=model-unread\n%s\n' "$OL_CLASS_ERR" >&2; exit 1; }
    harness="$OL_ENTRY_HARNESS" model="$OL_ENTRY_MODEL" effort="$OL_ENTRY_EFFORT"
    pick_args=(pick --harness "$harness" --json)
    [[ -z "$model" ]] || pick_args+=(--native-model "$model")
    [[ -z "$4" ]] || pick_args+=(--lane "$4")
    picked="$("$SCRIPT_DIR/lanes" "${pick_args[@]}")" || exit "$?"
    account="$(jq -er '.config_dir | strings | select(length > 0)' <<<"$picked")" || exit 1
    ol_model_line "$OL_ENTRY_WARNING"
    ol_launch_flags --question-off "$harness" "$model" "$effort" "$model" "" || exit 1
    ol_command_line --brief "$6" "$harness" "" "$account" "$5" "${OL_FLAGS[@]}" || exit 1
    jq -cn --arg line "$OL_CMD" --arg harness "$harness" --arg model "${model:-native-default}" \
      --arg account "$account" --arg effort "$effort" \
      '{line:$line,harness:$harness,model:$model,account:$account,effort:$effort}' ;;
  task-live)
    rc=0
    task_window_live "$1" "$2" "$3" "$4" || rc=$?
    [[ "$rc" != 2 ]] || printf 'jarvis-task: terminal=unread\n%s\n' "$TMUX_PANE_DETAIL" >&2
    exit "$rc" ;;
  task-close)
    rc=0
    task_window_live "$1" "$2" "$3" "$4" || rc=$?
    [[ "$rc" != 1 ]] || exit 0
    [[ "$rc" == 0 ]] || { printf 'jarvis-task: terminal=unread\n%s\n' "$TMUX_PANE_DETAIL" >&2; exit 1; }
    actual="$(tmux display-message -p -t "$4" '#{@jarvis-task}')" || exit 1
    [[ "$actual" == "$6" || ( "$7" == true && -z "$actual" ) ]] || { printf 'jarvis-task: terminal=identity-changed\n' >&2; exit 1; }
    binding="#{==:#{@jarvis-task},$6}"
    [[ "$7" != true ]] || binding="#{||:$binding,#{==:#{@jarvis-task},}}"
    tmux if-shell -F -t "$4" "#{&&:$binding,#{==:#{pid},$2}}" "kill-window -t $5" ;;
  rows)
    source "$SCRIPT_DIR/lib/lane-context.sh"
    source "$SCRIPT_DIR/lib/session-rows.sh"
    session_rows_overseer_file "$1" "$2" "$3" ;;
  command-plan)
    harness="$1"
    launch_choice_shell_words "$2" || exit 1
    end=$((${#LAUNCH_CHOICE_ARGV[@]} - 1))
    [[ "$end" -ge 0 ]] || exit 1
    brief="${LAUNCH_CHOICE_ARGV[end]}"
    start=-1
    for ((i=0; i<end; i++)); do
      word="${LAUNCH_CHOICE_ARGV[i]}"
      if [[ "${word##*/}" == "$harness" ]]; then start=$((i + 1)); break; fi
    done
    [[ "$start" -ge 0 ]] || exit 1
    if [[ "$harness" == claude && "${LAUNCH_CHOICE_ARGV[start]:-}" == -n ]]; then start=$((start + 2)); fi
    case "${LAUNCH_CHOICE_ARGV[end-1]:-}" in -i|--interactive|--) end=$((end - 1)) ;; esac
    flags=()
    for ((i=start; i<end; i++)); do flags+=("${LAUNCH_CHOICE_ARGV[i]}"); done
    flags_json="$(jq -cn --args '$ARGS.positional' -- ${flags[@]+"${flags[@]}"})" || exit 1
    handoff=""
    if [[ "$harness" == claude ]]; then
      source "$SCRIPT_DIR/lib/overseer-launch.sh"
      if ol_command_read "$harness" "$2"; then handoff="$OL_COMMAND_HANDOFF"; fi
    fi
    jq -cn --arg brief "$brief" --arg handoff "$handoff" --argjson flags "$flags_json" '{brief:$brief,flags:$flags,handoff:$handoff}' ;;
  open)
    placement=(--session "$3")
    [[ -z "$2" ]] || placement=(--after "$2")
    result="$("$SCRIPT_DIR/overseer-host" create --cwd "$4" --name overseer "${placement[@]}" --line "$1")" || exit 1
    pane="" window=""
    for word in $result; do case "$word" in session=*) pane="${word#session=}" ;; window=*) window="${word#window=}" ;; esac; done
    [[ -n "$pane" && -n "$window" ]] || exit 1
    tmux display-message -p -t "$pane" '#{socket_path}	#{pid}	#{start_time}	#{session_name}	#{window_id}	#{pane_id}' ;;
  watch)
    source "$SCRIPT_DIR/lib/overseer-launch.sh"
    source "$SCRIPT_DIR/lib/watch-pid.sh"
    source "$SCRIPT_DIR/lib/job-unit.sh"
    source "$SCRIPT_DIR/lib/watch-handover.sh"
    HANDOFF="$6"
    export TMUX="$8,0,0"
    controller_flags "$7" || exit 1
    DEP_ERR="$(mktemp)" || exit 1
    trap 'rm -f -- "${DEP_ERR:?}"' EXIT
    cd -- "$9" || exit 1
    watch_handover "$1" "$2" "$3" "$4" "$5" ${flags[@]+"${flags[@]}"} || { cat -- "$DEP_ERR" >&2; exit 1; }
    printf '%s\n' "$WATCH_HANDOVER_KEY" "${WATCH_HANDOVER_FIELDS[@]}" ;;
  live)
    export TMUX="$1,0,0"
    tmux_pane_live "$2" "$3" "$4" || exit "$?"
    actual="$(tmux display-message -p -t "$4" '#{@jarvis-generation}')" || exit 2
    # Staging ownership precedes the native generation mark.
    [[ "$7" == registered || "$actual" == "$5" || ( "$7" == staging && -z "$actual" ) ]] || exit 1
    session="$(tmux display-message -p -t "$4" '#{session_name}')" || exit 2
    window="$(tmux display-message -p -t "$4" '#{window_id}')" || exit 2
    [[ ( "$7" == registered || "$session" == jarvis ) && "$window" == "$6" ]] || exit 1
    jq -cn --arg socket "$1" --arg session "$session" --arg window "$window" --arg pane "$4" \
      '{server:$socket,session:$session,window:$window,pane:$pane}' ;;
  process)
    at="$(lane_process_start "$1")" || exit 1
    [[ -n "$at" ]] || exit 1
    jq -cn --argjson pid "$1" --arg at "$at" '{pid:$pid,started_at:$at}' ;;
  worker-live)
    state="$(lane_process_state "$1")" || exit 2
    [[ -n "$state" && "$state" != Z ]] || exit 1
    at="$(lane_process_start "$1")" || exit 2
    [[ "$at" == "$2" ]] || exit 1 ;;
  stop-process)
    lane_stop_identity "$1" "$2" "$3" ;;
  history) recorded_session_file "$@" ;;
  prepare)
    harness="$1" account="$2" home="$3" id="$4" file="$5"
    lane_trust_prepare "$harness" "$account" "$home" || exit 1
    controller_flags "${8:-[]}" || exit 1
    lane_session_command "$harness" "$id" "$file" "${12:-jarvis}" ${flags[@]+"${flags[@]}"} || exit 1
    cmd="$LANE_SESSION_CMD" var="$LANE_SESSION_ACCOUNT_VAR"
    if [[ -n "${13:-}${14:-}" ]]; then
      flags="$(launch_choice_write "$harness" "${13:-}" "${14:-}")" || exit 1
      launch_choice_shell_words "$flags" || exit 1
      flags="$(printf ' %q' ${LAUNCH_CHOICE_ARGV[@]+"${LAUNCH_CHOICE_ARGV[@]}"})" || exit 1
      cmd="$harness$flags${cmd#"$harness"}"
    fi
    form="$(lane_launch_form "$cmd" "$harness" "$LANE_TRUST_HOME" "")"
    if [[ "${9:-jarvis}" == external ]]; then
      model="$(launch_choice_launch_model "$harness" "$cmd")"
      var="$(lane_env_prefix "$harness" - "$model")"
      var="${var%%=*}"
    fi
    [[ -z "${10:-}" ]] || var="${10}"
    child_env="JARVIS_RECORD=$(lane_single_quote "$6") JARVIS_GENERATION=$(lane_single_quote "$7")"
    if [[ "$harness" == pi && "$var" != PI_CODING_AGENT_DIR && -n "${11:-}" ]]; then
      child_env+=" PI_CODING_AGENT_DIR=$(lane_single_quote "${11}")"
    fi
    # Jarvis acts on the owner's desktop, so its session keeps the live display.
    lane_launch_keep_live_session
    line="$(lane_launch_line "$cmd" "$harness" "$var" "$LANE_TRUST_HOME" "$form" "" "$child_env")" || exit 1
    jq -cn --arg line "$line" --arg var "$var" --arg home "$LANE_TRUST_HOME" --argjson kickoff "$LANE_SESSION_PROMPTED" \
      '{line:$line, var:$var, effective_home:$home, kickoff:$kickoff}' ;;
  inspect)
    socket="$1" pane="$2" harness="$3" var="$4" account="$5" brief="$8"
    export TMUX="$socket,0,0"
    screen="$(tmux -S "$socket" capture-pane -p -t "$pane")" || exit 1
    pid="$(tmux -S "$socket" display-message -p -t "$pane" '#{pane_pid}')" || exit 1
    cmd="$(tmux -S "$socket" display-message -p -t "$pane" '#{pane_current_command}')" || exit 1
    if [[ "$harness" == pi && "$6" == confirmed && "$brief" == undelivered ]]; then
      # A Pi session whose start is recorded and that has had no brief has run
      # no turn: the record is the idle rows verdict lane_input_ready demands,
      # beside Pi's live-editor proof. Pi alone, since that verdict passes
      # over every pane rung; its refusal is an answer, not a failure.
      rc=0
      lane_input_ready state listed "$cmd" "$pid" "$screen" "" "" idle "" pi || rc=$?
      [[ "$rc" -le 1 ]] || exit 1
    else
      lane_state state listed "$cmd" "$pid" "$screen" || exit 1
    fi
    if [[ "$LANE_WALL_KIND" == auth ]]; then printf 'auth\n'; exit; fi
    if [[ ( "$harness" == copilot || "$harness" == claude ) && "$6" == pending ]]; then
      # A folder-trust question holds the harness until its owner answers it
      # natively; Jarvis never answers a native security request. Preserve
      # orch's Claude launch verdict when a wrapper bypasses prepared trust;
      # Copilot can ask before its SessionStart. Read below the
      # last turn, since a resumed session redraws its history. The pane
      # stands in for Copilot's documented `trustedFolders` config list
      # (`copilot help config`), which says what is listed but not how a
      # listed folder matches HOME: unlike `allowedUrls` beside it, the help
      # gives no rule for subfolders or path spelling, so a config read
      # cannot tell whether the dialog will show, and a wrong guess either
      # refuses a trusted home or launches into an untrusted one.
      slice="$(pane_below_last_turn "$screen")" || exit 1
      rc=0
      dialog="$(pane_trust_dialog "$slice")" || rc=$?
      case "$rc" in
        0) printf 'trust\n%s\n' "$dialog"; exit ;;
        1) ;;
        *) exit 1 ;;
      esac
    fi
    # The account is judged once SessionStart confirmed the start. Copilot and
    # Codex draw their kickoff turn before their stamp lands, and a pending
    # record holds no observed account to compare.
    if [[ "$6" == confirmed ]]; then
      lane_account_equivalent "${7:-}" "$account" || { printf 'wrong-account\n'; exit; }
      lane_account_check "$pane" "$var" "$account" prefix 2 || { printf 'wrong-account\n'; exit; }
      case "$LANE_ACCOUNT_RESULT" in
        verified|unobserved:*) ;;
        *) printf 'unjudged\n'; exit ;;
      esac
    fi
    printf '%s\n' "$state" ;;
  deliver)
    export TMUX="$1,0,0"
    pane_write pane "$2" "$3" file "$4" ;;
  *) printf 'jarvis-session: backend=%s\n' "$verb" >&2; exit 2 ;;
esac
