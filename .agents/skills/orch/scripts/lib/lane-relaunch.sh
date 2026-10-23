# shellcheck shell=bash
#
# Owner: open-terminal, which sources this file locally and runs it on a host.
#
# The relaunch session lookup: which harness transcript a --relaunch or --wake
# resumes, and the id the harness resumes it by. It reads open-terminal's
# globals (LANE_ENV, LAUNCH_FLAGS, LANES_CLI) and calls its
# launch_ambient_codex_home and copilot_launch_home on the local path.
#
# Hosted entry point: bash lane-relaunch.sh HARNESS ITEM LAUNCH_FLAGS.
# open-terminal's rendered command consumes stdout as the resume id. Exit 1
# means no session; exit 2 means lookup failed, never permission to start fresh.

# open-terminal records the choices it can repeat in `recovery`. Older records
# and custom commands cannot recover their original permissions, so the watch
# must refuse before stopping a lane. The host and tracker retain their existing
# lane-record meanings, including null host meaning local.
# The request is supplied by the overseer from the current launch record.
# Costs, pauses and mailbox cursors are deliberately outside this identity.
LANE_ATTEMPT_JQ='def lane_attempt: {host,harness,launch,launched_at,session_id,account,model,effort,sandbox_instance_id};'
# Only a live owning process can pass ownership to a nested lifecycle call.
# A stale inherited environment from an ended launcher grants no ownership.
lane_lifecycle_owned() { # LOCK_PATH
  local identity pid start actual owners="${ORCH_LANE_LIFECYCLE:-}"
  [[ -n "$owners" ]] || owners='{}'
  identity="$(jq -er --arg key "$1" '.[$key] | select(.pid != null and .start != null) | [.pid,.start] | join("\u001f")' <<<"$owners")" || return 1
  IFS=$'\x1f' read -r pid start <<<"$identity"
  actual="$(lane_process_start "$pid")" || return 1
  [[ -n "$actual" && "$actual" == "$start" ]]
}

LANE_WAIT_CAUSE=""
LANE_WAIT_EVIDENCE=null
lane_wait_validate() { # WAIT CURRENT_RECORD [resume]
  LANE_WAIT_CAUSE=wait-invalid
  jq -e --argjson record "$2" --arg mode "${3:-park}" "$LANE_ATTEMPT_JQ"'
    def text: type == "string" and length > 0;
    def repo: text and test("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$");
    (.reason | text) and (.source | text) and (.binding == ($record | lane_attempt))
    and (.binding.host | text) and (.binding.session_id | text) and (.binding.sandbox_instance_id | text)
    and (.binding.launch | type == "object") and (.session_file | text) and (.launch_flags | type == "string") and ($mode == "resume" or $record.prepare == null)
    and (if .kind == "item" then
      (.dependencies | type == "array" and length > 0 and all(.[];
        (.tracker == "linear" or .tracker == "github") and (.id | text) and (.key | text)
        and (.repo | repo) and (.step | text)
        and (.delivery.kind == "pr" or .delivery.kind == "commit" or .delivery.kind == "artifact")
        and (if .delivery.kind == "pr" then
          (.delivery.pr == null or (.delivery.pr | type == "number" and . > 0 and floor == .))
          and (.delivery.branch | text) and .delivery.item == .key
        elif .delivery.kind == "commit" then (.delivery.branch | text) and (.delivery.commit | text and test("^[0-9A-Fa-f]{40}$"))
        else (.delivery.artifact | text) and (.delivery.verification | text) end)))
    elif .kind == "account" then
      .account == $record.account and .host == $record.host and .harness == $record.harness
      and .model == $record.model and (.bucket | text) and .no_reset == true
    else false end)' <<<"$1" >/dev/null || return 1
  if [[ "$(jq -r .kind <<<"$1")" == item ]]; then
    local dep
    while IFS= read -r dep; do lane_wait_item_identity "$dep" || return 1; done < <(jq -c '.dependencies[]' <<<"$1")
  fi
  LANE_WAIT_CAUSE=""
}

# A tracker completion is only an identity read. Landing is judged separately.
lane_wait_item_identity() { # DEPENDENCY
  local dep="$1" tracker key id repo live
  tracker="$(jq -r .tracker <<<"$dep")" && key="$(jq -r .key <<<"$dep")" \
    && id="$(jq -r .id <<<"$dep")" && repo="$(jq -r .repo <<<"$dep")" || return 1
  LANE_WAIT_CAUSE=item-unread
  case "$tracker" in
    linear)
      live="$("$SCRIPT_DIR/../../linear/scripts/linear.sh" issues get "$key" --format=safe)" || return 1
      jq -e --arg id "$id" --arg key "$key" '.uuid == $id and .identifier == $key and (.state_type | type == "string") and .state_type != "canceled"' <<<"$live" >/dev/null || return 1 ;;
    github)
      live="$(gh issue view "$key" --repo "$repo" --json id,number,state,stateReason)" || return 1
      jq -e --arg id "$id" --arg key "$key" '.id == $id and (.number | tostring) == $key and (.state == "OPEN" or (.state == "CLOSED" and .stateReason == "COMPLETED"))' <<<"$live" >/dev/null || return 1 ;;
    *) return 1 ;;
  esac
}

# The provider owns this immutable identity. Its reusable sandbox name never
# substitutes for the unique item/repository row in list --json.
lane_provider_instance() { # HOST OWN_REPO ITEM
  local listing
  LANE_PROVIDER_INSTANCE_ID="" LANE_WAIT_CAUSE=provider-instance-unread
  listing="$(ORCH_LANE_HOST="$1" "$SCRIPT_DIR/lane-host" list --json)" || return 1
  LANE_PROVIDER_INSTANCE_ID="$(jq -er --arg repo "${2##*/}" --arg item "$3" '
    if type != "array" then error("instance-list-invalid") else . end
    | map(select((.repo | ascii_downcase) == ($repo | ascii_downcase) and (.item | ascii_downcase) == ($item | ascii_downcase)))
    | select(length == 1) | .[0].id | strings | select(length > 0)' <<<"$listing")" || return 1
  LANE_WAIT_CAUSE=""
}

lane_wait_instance() { # WAIT OWN_REPO ITEM
  lane_provider_instance "$(jq -r .binding.host <<<"$1")" "$2" "$3" || return 1
  LANE_WAIT_CAUSE=provider-instance-unread
  [[ "$LANE_PROVIDER_INSTANCE_ID" == "$(jq -r .binding.sandbox_instance_id <<<"$1")" ]] || return 1
  LANE_WAIT_CAUSE=""
}

lane_wait_account() { # WAIT room|walled
  local wait="$1" expect="$2" row rc=0 account host harness model bucket
  account="$(jq -r .account <<<"$wait")" && host="$(jq -r .host <<<"$wait")" \
    && harness="$(jq -r .harness <<<"$wait")" && model="$(jq -r .model <<<"$wait")" \
    && bucket="$(jq -r .bucket <<<"$wait")" || return 1
  LANE_WAIT_CAUSE=account-unread
  row="$(ORCH_LANE_HOST="$host" "$SCRIPT_DIR/lanes" pick --lane "$account" --harness "$harness" --native-model "$model" --no-cache --json)" || rc=$?
  [[ "$expect:$rc" == room:0 || "$expect:$rc" == walled:3 ]] || { LANE_WAIT_CAUSE=account-not-admitted; return 1; }
  # The provider must answer for the stopped host itself. Local fallback cannot
  # establish that the account on the kept disk has room.
  jq -e --arg account "$account" --arg bucket "$bucket" --arg expect "$expect" '
    .config_dir == $account and .measured_through == "host" and .status == "ok"
    and .binding_bucket == $bucket and ($expect != "walled" or .binding_resets_at == null)' <<<"$row" >/dev/null || return 1
  LANE_WAIT_EVIDENCE="$row" LANE_WAIT_CAUSE=""
}

lane_wait_landed() { # CURRENT_RECORD
  local record="$1" wait dep kind view pr branch repo key evidence='[]' hit
  LANE_WAIT_EVIDENCE=null LANE_WAIT_CAUSE=wait-unread
  wait="$(jq -ce '.parked.wait // .dependency_wait.wait' <<<"$record")" || return 1
  # A resumed preparation still carries the original binding. Never replace
  # that binding with a fresh launch merely because the sandbox started.
  lane_wait_validate "$wait" "$(jq -c --argjson wait "$wait" '. + $wait.binding' <<<"$record")" resume || return 1
  lane_wait_instance "$wait" "$(jq -r .repo <<<"$record")" "$(jq -r .item <<<"$record")" || return 1
  kind="$(jq -r .kind <<<"$wait")" || return 1
  if [[ "$kind" == account ]]; then lane_wait_account "$wait" room; return; fi
  while IFS= read -r dep; do
    lane_wait_item_identity "$dep" || return 1
    kind="$(jq -r .delivery.kind <<<"$dep")" || return 1
    LANE_WAIT_CAUSE=delivery-verifier-unavailable
    # There is no generic release/deployment verifier in the provider protocol.
    # Those named deliveries remain held until their existing owner supplies
    # proof; Done and a message are never substituted for that proof.
    if [[ "$kind" == commit ]]; then
      local scratch push_at push_cause
      scratch="$(mktemp -d)" || return 1
      source "$SCRIPT_DIR/lib/watch-host-kinds.sh"
      lane_push_time "$(jq -r .repo <<<"$dep")" "$(jq -r .delivery.branch <<<"$dep")" \
        "$(jq -r .delivery.commit <<<"$dep")" "$(jq -r .binding.launched_at <<<"$wait")" "$scratch"
      push_at="$MERGED_AT" push_cause="$MERGED_CAUSE"
      [[ -z "$push_cause" ]] || cat -- "$scratch/push.err" >&2
      rm -rf -- "${scratch:?}"
      LANE_WAIT_CAUSE="delivery-${push_cause:-not-landed}"
      [[ -n "$push_at" ]] || return 1
      hit="$(jq -cn --arg at "$push_at" --argjson dependency "$dep" '{dependency:$dependency,landing:{at:$at,commit:$dependency.delivery.commit,branch:$dependency.delivery.branch}}')" || return 1
      evidence="$(jq -cn --argjson all "$evidence" --argjson hit "$hit" '$all+[$hit]')" || return 1
      continue
    fi
    [[ "$kind" == pr ]] || return 1
    pr="$(jq -r '.delivery.pr // empty' <<<"$dep")" \
      && branch="$(jq -r .delivery.branch <<<"$dep")" \
      && repo="$(jq -r .repo <<<"$dep")" && key="$(jq -r .key <<<"$dep")" || return 1
    LANE_WAIT_CAUSE=delivery-unbound
    [[ -n "$pr" ]] || return 1
    LANE_WAIT_CAUSE=delivery-unread
    view="$(gh pr view "$pr" --repo "$repo" --json number,state,headRefName,headRepositoryOwner,mergedAt,mergeCommit,title,body)" || return 1
    LANE_WAIT_CAUSE=delivery-not-landed
    hit="$(jq -ce --arg key "$key" --arg branch "$branch" --arg owner "${repo%%/*}" --argjson pr "$pr" "$LANE_MERGED_JQ"'
      select(.state == "MERGED" and .headRefName == $branch and (.mergeCommit.oid | strings | length > 0))
      | [.] | lane_merged($key; $owner; $pr; 0) | select(length == 1) | .[0]
      | {pr:.number,mergedAt,mergeCommit}' <<<"$view")" || return 1
    evidence="$(jq -cn --argjson all "$evidence" --argjson hit "$hit" --argjson dependency "$dep" '$all + [{dependency:$dependency,landing:$hit}]')" || return 1
  done < <(jq -c '.dependencies[]' <<<"$wait")
  LANE_WAIT_CAUSE="" LANE_WAIT_EVIDENCE="$evidence"
}

lane_recovery_args() { # RECORD ACCOUNT STATE_DIR LAUNCHER [model-switched]
  local fields item harness flags refresh tracker repo live rc=0 model effort choice launch_model launch_id selector_id surface terminal=--tmux
  local -a words=() choice_words=()
  LANE_RECOVERY_CAUSE=permission-choice-unrecorded
  LANE_RECOVERY_ARGS=() LANE_RECOVERY_CWD="" LANE_RECOVERY_HOST="" LANE_RECOVERY_SESSION=""
  fields="$(jq -er 'select((.recovery | type) == "object"
      and (.recovery.cwd | type) == "string" and (.recovery.cwd | length) > 0
      and (.recovery.flags | type) == "string" and (.recovery.refresh | type) == "boolean")
    | [.item, .harness, .recovery.cwd, .recovery.flags, (.recovery.refresh | tostring),
       (.host // "local"), (.recovery.session // ""), .tracker, (.repo // ""), (.surface // "tmux"),
       (.live_display == true | tostring)]
    | join("\u001f")' <<<"$1")" || return 1
  IFS=$'\x1f' read -r item harness LANE_RECOVERY_CWD flags refresh LANE_RECOVERY_HOST LANE_RECOVERY_SESSION tracker repo surface live <<<"$fields"
  # The launcher records relative provider paths without their resolution base.
  case "$LANE_RECOVERY_HOST" in
    local|claude-cloud|/*) ;;
    *) LANE_RECOVERY_CAUSE=relative-provider-deferred:KEN-3996; return 1 ;;
  esac
  if [[ "${5:-}" == model-switched ]]; then
    LANE_RECOVERY_CAUSE=model-unrecorded
    model="$(jq -er '.model | strings | select(length > 0)' <<<"$1")" || return 1
    model="$(launch_choice_model_id "$harness" "$model" recorded)" || return 1
    [[ -n "$model" ]] || return 1
    launch_model="$(launch_choice_launch_model "$harness" "$flags")" || return 1
    launch_id="$(launch_choice_model_id "$harness" "$model" recorded "$launch_model")" || return 1
    selector_id="$(launch_choice_model_id "$harness" "$launch_model" recorded)" || return 1
    # Carry the suffix only from a matching explicit ID or family selector.
    if [[ "$harness" == claude && "$launch_model" == *\[1[mM]\]
        && "$launch_id" == "$selector_id" ]]; then
      model="${model}[1m]"
    fi
    effort="$(jq -r '.effort // ""' <<<"$1")" || return 1
    [[ -n "$effort" ]] || effort="$(launch_choice_effort "$harness" "$flags")" || return 1
    read -r -a words <<<"$flags"
    launch_choice_strip "$harness" ${words[@]+"${words[@]}"} || return 1
    choice="$(launch_choice_write "$harness" "$model" "$effort")" || return 1
    # The writer emits shell words; --launch-flags takes plain tokens instead.
    eval "choice_words=($choice)" || return 1
    flags="${LAUNCH_CHOICE_KEPT[*]+${LAUNCH_CHOICE_KEPT[*]}}${LAUNCH_CHOICE_KEPT[*]:+ }${choice_words[*]+${choice_words[*]}}"
  fi
  LANE_RECOVERY_CAUSE=checkout-unavailable
  LANE_RECOVERY_CWD="$(cd -- "$LANE_RECOVERY_CWD" && pwd -P)" || return 1
  lane_capabilities_read "$SCRIPT_DIR/lane-host" "$LANE_RECOVERY_HOST" "$LANE_RECOVERY_CWD" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    LANE_RECOVERY_CAUSE="host-capabilities-unavailable exit=$rc"
    return "$rc"
  fi
  [[ "$LANE_RECOVERY_HOST" != local || "$surface" != gui ]] || terminal=--ghostty
  LANE_RECOVERY_ARGS=("$4" "$terminal" --relaunch --continue-resume --harness "$harness"
    --launch-flags "$flags" --state-dir "$3" --host "$LANE_RECOVERY_HOST" --tracker "$tracker")
  [[ -z "$repo" ]] || LANE_RECOVERY_ARGS+=(--repo "$repo")
  [[ "$refresh" != true ]] || LANE_RECOVERY_ARGS+=(--lane-refresh)
  [[ "$live" != true ]] || LANE_RECOVERY_ARGS+=(--live-display)
  # An omitted account preserves the launcher's inherited-account behavior.
  [[ -z "$2" ]] || LANE_RECOVERY_ARGS+=(--lane "$2")
  if [[ "$tracker" == github ]]; then LANE_RECOVERY_ARGS+=("${item#issue-}")
  else LANE_RECOVERY_ARGS+=("$item"); fi
  LANE_RECOVERY_CAUSE=""
}

lane_recovery_stop_confirmed() { # OUTPUT ITEM
  local out="$1" item="$2"
  [[ "$out" =~ ^stopped\ item=([^\ ]+)\ processes=([0-9]+)$ && "${BASH_REMATCH[1]}" == "$item" ]]
}

lane_model_recovery_result() { # RECORD STATE_DIR SCRIPTS SESSION RESULT
  "$3/workflow-state" --state-dir "$2" update oversee '
    (.fleet_log[]? | select(.kind == "model-switched" and .item == $record.item
      and .session_id == $session
      and .launch_identity == ($record | {launch,launched_at}))).recovery = $result
    ' --argjson record "$1" --arg session "$4" --arg result "$5" >/dev/null
}

# The detached native stop cannot return its failure to the callback. Keep it
# on the same handoff the controller already reads, bound to this launch.
lane_native_model_stop() { # RECORD STATE_DIR SCRIPTS ITEM SESSION
  local record="$1" state_dir="$2" scripts="$3" item="$4" session="$5" pid start detail rc=0
  pid="$(jq -er '.launch.pid' <<<"$record")" || return 1
  start="$(jq -er '.launch.start' <<<"$record")" || return 1
  lane_stop_identity "$pid" "$start" claude || rc=$?
  [[ "$rc" -ne 0 ]] || return 0
  printf 'lane-relaunch: native-stop=failed item=%s cause=%s pid=%s launch_pid=%s exit=%s\n' \
    "$item" "$LANE_STOP_CAUSE" "${LANE_STOP_PID:-none}" "$pid" "$rc" >&2
  detail="$("$scripts/workflow-state" --state-dir "$state_dir" update "$item" '
    if .handoff.session_id == $session
      and .model_checks[$session].launch_identity == ($record | {launch,launched_at})
    then .handoff.stop_failure = {cause:$cause,pid:(if $pid == "" then null else $pid end),
      launch:$record.launch,exit:$exit,at:(now|strftime("%Y-%m-%dT%H:%M:%SZ"))}
    else . end' --arg session "$session" --argjson record "$record" \
      --arg cause "$LANE_STOP_CAUSE" --arg pid "$LANE_STOP_PID" --argjson exit "$rc" 2>&1)" || {
    printf 'lane-relaunch: native-stop=record-failed item=%s\n' "$item" >&2
    printf '%s\n' "$detail" >&2
    return 1
  }
  return "$rc"
}

# The hook acquires one session's recovery under workflow-state's lock before
# starting this outside the predecessor's process group. Check the recovery
# arguments before stopping it; account selection and launch follow the stop.
lane_model_recovery() { # RECORD STATE_DIR SCRIPTS SESSION
  local record="$1" state_dir="$2" SCRIPT_DIR="$3" session="$4" fields item host harness pane pid start wake_pid wake_start account out claim pane_pid identity limit rc=0 result
  fields="$(jq -er '[.item, (.host // "local"), .harness, (.launch.pane // ""),
    (.launch.pid // ""), (.launch.start // ""), (.wake.pid // ""),
    (.wake.start // ""), (.account // "")] | join("\u001f")' <<<"$record")" || return 1
  IFS=$'\x1f' read -r item host harness pane pid start wake_pid wake_start account <<<"$fields"
  limit="$("$SCRIPT_DIR/orch-env" ORCH_MODEL_RECOVERY_LIMIT 3)" || return 1
  claim="$("$SCRIPT_DIR/workflow-state" --state-dir "$state_dir" update-report oversee '
    first(.lanes[]? | select(.item == $item)) as $current
    | if $current.launch != $record.launch or $current.launched_at != $record.launched_at
        or $current.session_id != $record.session_id or $current.model_check.session_id != $session
        or $current.model_check.recovery_started == true
      then {state:.,report:false}
      else (.lanes[] | select(.item == $item)).model_check.recovery_started = true
        | (reduce (.fleet_log[]? | select(.item == $item)) as $row (0;
            if $row.kind == "model-recovery-reset" then 0
            elif $row.kind == "model-switched" and ($row.recovery == "replaced"
              or ($row.recovery == "starting" and $row.launch_identity != $current.model_check.launch_identity))
            then . + 1 else . end)) as $recoveries
        | if $recoveries + 1 >= ($limit | tonumber) then
            ("lane-relaunch: model-recovery=limit item=" + $item
              + " recoveries=" + ($recoveries | tostring) + " limit=" + $limit) as $text
            | .fleet_log = ((.fleet_log // []) + [{kind:"model-recovery-limit",item:$item,
                at:(now|strftime("%Y-%m-%dT%H:%M:%SZ")),recoveries:$recoveries,
                limit:($limit|tonumber),text:$text}])
            | {state:.,report:$text}
          else {state:.,report:true} end
      end' --arg item "$item" --arg session "$session" --argjson record "$record" --arg limit "$limit")" || return 1
  if [[ "$claim" != true && "$claim" != false ]]; then
    jq -r . <<<"$claim" >&2 || return 1
    return 1
  fi
  [[ "$claim" == true ]] || return 0
  lane_recovery_args "$record" "$account" "$state_dir" "$SCRIPT_DIR/open-terminal" model-switched || {
    printf 'lane-relaunch: model-recovery=prepare-failed item=%s cause=%s\n' "$item" "$LANE_RECOVERY_CAUSE" >&2
    return 1
  }
  if [[ "$host" == local ]]; then
    # Older launches recorded the pane but no process identity. Read that
    # identity once; a stale positive recorded identity never takes this path.
    if [[ -z "$pid$start" ]]; then
      pane_pid="$(tmux display-message -p -t "$pane" '#{pane_pid}')" || return 1
      identity="$(lane_harness_identity "$pane_pid" "$harness")" || return 1
      pid=${identity%% *} start=${identity#* }
    fi
    # Never substitute a pane's new process for this predecessor's identity.
    lane_stop_local "" "$pid" "$start" "$wake_pid" "$wake_start" "$harness" || {
      printf 'lane-relaunch: model-recovery=stop-failed item=%s cause=%s\n' "$item" "$LANE_STOP_CAUSE" >&2
      return 1
    }
  else
    out="$(ORCH_LANE_HOST="$host" "$SCRIPT_DIR/lane-host" stop --item "$item" --harness "$harness")" || return 1
    lane_recovery_stop_confirmed "$out" "$item" || return 1
  fi
  "$SCRIPT_DIR/workflow-state" --state-dir "$state_dir" update oversee \
    '(.lanes[] | select(.item == $item and .launched_at == $launch)) |= (.status = "stopped")' \
    --arg item "$item" --arg launch "$(jq -r '.launched_at' <<<"$record")" >/dev/null || return 1
  export ORCH_TMUX_SESSION="$LANE_RECOVERY_SESSION"
  cd -- "$LANE_RECOVERY_CWD" || return 1
  # A new mismatch can arrive before the launcher returns. Its new launch
  # identity proves that this pending replacement reached a live harness.
  lane_model_recovery_result "$record" "$state_dir" "$SCRIPT_DIR" "$session" starting || return 1
  "${LANE_RECOVERY_ARGS[@]}" || rc=$?
  result=replaced
  [[ "$rc" -eq 0 ]] || result=failed
  lane_model_recovery_result "$record" "$state_dir" "$SCRIPT_DIR" "$session" "$result" || return 1
  return "$rc"
}

# Pi resolves a relative session directory from the process working directory,
# which is the item worktree for the command this launcher emits.
pi_relaunch_root() { # WORKTREE HOME
  local cwd="$1" home="$2" agent_dir="${PI_CODING_AGENT_DIR:-$home/.pi/agent}" root="" settings setting="" setting_rc token expect_value=false override_found=false project_trusted=false trust_override=false decision="" trust_rc
  local -a tokens=()
  cwd="$(cd "$cwd" && pwd -P)" || return 2
  case "$agent_dir" in "~") agent_dir="$home" ;; "~/"*) agent_dir="$home/${agent_dir#\~/}" ;; /*) ;; *) agent_dir="$cwd/$agent_dir" ;; esac
  if [[ -n "$LAUNCH_FLAGS" ]]; then
    read -r -a tokens <<<"$LAUNCH_FLAGS"
    for token in ${tokens[@]+"${tokens[@]}"}; do
      if [[ "$expect_value" == true ]]; then root="$token"; expect_value=false; override_found=true; continue; fi
      case "$token" in
        --session-dir) expect_value=true ;;
        --session-dir=*) root="${token#*=}"; [[ -n "$root" ]] || return 2; override_found=true ;;
        -a|--approve) project_trusted=true; trust_override=true ;;
        -na|--no-approve) project_trusted=false; trust_override=true ;;
      esac
    done
    [[ "$expect_value" == false ]] || return 2
  fi
  if [[ "$override_found" == false && -n "${PI_CODING_AGENT_SESSION_DIR:-}" ]]; then root="$PI_CODING_AGENT_SESSION_DIR"; override_found=true; fi
  if [[ "$override_found" == false ]]; then
    root="$agent_dir/sessions"
    settings="$agent_dir/settings.json"
    if [[ -e "$settings" ]]; then
      [[ -f "$settings" && -r "$settings" ]] || return 2
      setting_rc=0
      setting="$(jq -er 'if type!="object" then error("settings") elif has("sessionDir") and (.sessionDir|type)!="string" then error("sessionDir") elif has("sessionDir") then .sessionDir else empty end' "$settings")" || setting_rc=$?
      case "$setting_rc" in 0) if [[ -n "$setting" ]]; then root="$setting"; else root="$agent_dir/sessions"; fi ;; 4) ;; *) return 2 ;; esac
    fi
    settings="$cwd/.pi/settings.json"
    if [[ -e "$settings" ]]; then
      if [[ "$trust_override" == false ]]; then
        [[ ! -r "$agent_dir/settings.json" ]] || project_trusted="$(jq -r 'if .defaultProjectTrust=="always" then "true" else "false" end' "$agent_dir/settings.json")" || return 2
        if [[ -e "$agent_dir/trust.json" ]]; then
          [[ -f "$agent_dir/trust.json" && -r "$agent_dir/trust.json" ]] || return 2
          trust_rc=0
          decision="$(jq -er --arg p "$cwd" 'if type!="object" or any(.[]; .!=true and .!=false and .!=null) then error("trust") else [to_entries[]|select(.value==true or .value==false)|select(.key as $k|$k=="/" or $k==$p or ($p|startswith($k+"/")))]|sort_by(.key|length)|last|if .value==true then "true" elif .value==false then "false" else empty end end' "$agent_dir/trust.json")" || trust_rc=$?
          case "$trust_rc" in 0) project_trusted="$decision" ;; 4) ;; *) return 2 ;; esac
        fi
      fi
      if [[ "$project_trusted" == true ]]; then
        [[ -f "$settings" && -r "$settings" ]] || return 2
        setting_rc=0
        setting="$(jq -er 'if type!="object" then error("settings") elif has("sessionDir") and (.sessionDir|type)!="string" then error("sessionDir") elif has("sessionDir") then .sessionDir else empty end' "$settings")" || setting_rc=$?
        case "$setting_rc" in 0) if [[ -n "$setting" ]]; then root="$setting"; else root="$agent_dir/sessions"; fi ;; 4) ;; *) return 2 ;; esac
      fi
    fi
  fi
  case "$root" in "~") root="$home" ;; "~/"*) root="$home/${root#\~/}" ;; /*) ;; *) root="$cwd/$root" ;; esac
  printf '%s\n' "$root"
}

# Transcript fallback for Claude listSessions, Codex thread/list and Pi
# SessionManager.list: shell launches lack SDK/app-server connections; Codex
# copies across accounts. Worktree metadata owns repository/item, never prompts.
# Pi workers use kendex/sessions, outside its lead store; Pi parents are forks.
#
# Copilot is the exception: how its events.jsonl records a kickoff is not
# measured, so a copilot session is the one lib/copilot-session.sh's
# copilot_session_in_worktree names for the lane's worktree, one item's alone.
# A record quoting its path names no directory there and matches nothing, which
# renders the fresh brief. So does a record with no events beside it, which
# `copilot --resume=<id>` exits 1 on with "No session, task, or name matched",
# in `-p` and at a pane alike (1.0.88, the log naming "Cannot create session
# from empty events array"). An older resumable record in the same worktree is
# resumed in its place.
find_relaunch_session() { # HARNESS WORKTREE [HOST_CODEX_HOME]
  local harness="$1" cwd="$2" home="${LANES_HOME:-$HOME}" config roots root inventory match_filter="" files file best="" best_root="" rc relative target
  command -v jq >/dev/null 2>&1 || return 2
  cwd="$(cd -- "$cwd" && pwd -P)" || return 2
  case "$harness" in
    claude) roots="$home/.claude-shared/projects"; match_filter='first(inputs|fromjson?|select(.cwd!=null)) // {} | {cwd, lead:(.isSidechain!=true)}' ;;
    codex)
      if [[ -n "${3:-}" ]]; then config="$3"
      else
        config="$(launch_ambient_codex_home)" || return 2
        [[ "${LANE_ENV%%=*}" != CODEX_HOME ]] || config="${LANE_ENV#*=}"
      fi
      [[ -x "$LANES_CLI" ]] || return 2
      inventory="$("$LANES_CLI" list --local --harness codex --json)" || return 2
      roots="$(jq -er --arg d "$config" 'if type=="array" and all(.[]; (.config_dir|type)=="string") then ([.[]|.config_dir]+[$d]|unique[]|.+"/sessions") else error("inventory") end' <<<"$inventory")" || return 2
      # SessionMeta defaults an omitted source to vscode in Codex's protocol.
      match_filter='first(inputs|fromjson?|select(.type=="session_meta")|.payload) // {} |
        {cwd, lead:((.source=="cli" or .source=="vscode" or (has("source")|not)) and .parent_thread_id==null)}' ;;
    pi) roots="$(pi_relaunch_root "$cwd" "$home")" || return 2; match_filter='first(inputs|fromjson?|select(.type=="session")) // {} | {cwd, lead:true}' ;;
    copilot)
      config="$(copilot_launch_home)"
      copilot_session_in_worktree "$config" "$cwd"
      return ;;
  esac

  while IFS= read -r root; do
    [[ -n "$root" && -e "$root" ]] || continue
    [[ -d "$root" && -r "$root" ]] || return 2
    # A Claude child lives below a subagents directory.
    # Only direct project children are lead transcripts; other stores recurse.
    if [[ "$harness" == claude ]]; then
      files="$(find -H "$root" -mindepth 2 -maxdepth 2 -type f -name '*.jsonl' -print 2>/dev/null)" || return 2
    else
      files="$(find -H "$root" -type f -name '*.jsonl' -print 2>/dev/null)" || return 2
    fi
    while IFS= read -r file; do
      [[ -n "$file" ]] || continue
      if jq -Rne --arg cwd "$cwd" "$match_filter | .cwd==\$cwd and .lead" "$file" >/dev/null 2>&1; then
        [[ -n "$best" && ! "$file" -nt "$best" ]] || { best="$file"; best_root="$root"; }
      else rc=$?; [[ "$rc" -eq 1 ]] || return 2; fi
    done <<<"$files"
  done <<<"$roots"
  [[ -n "$best" ]] || return 1
  if [[ "$harness" == codex && "$best_root" != "$config/sessions" ]]; then
    relative="${best#"$best_root"/}"; target="$config/sessions/$relative"
    if [[ -e "$target" ]]; then cmp -s -- "$best" "$target" || return 2
    else mkdir -p -- "${target%/*}" || return 2; cp -p -- "$best" "$target" || return 2; fi
    best="$target"
  fi
  printf '%s\n' "$best"
}
# The id a harness resumes a transcript by: the file's basename for claude,
# the session_meta id inside a codex transcript, the file itself for pi,
# whose --session takes a path, and a copilot session's own id, read from its
# workspace.yaml by lib/copilot-session.sh. Empty is a transcript the harness cannot resume, and a
# failure.
session_id_of() { # HARNESS SESSION_FILE
  local id=""
  case "$1" in
    claude) id="$(basename "$2" .jsonl)" ;;
    codex) id="$(jq -Rrn 'first(inputs|fromjson?|select(.type=="session_meta")|.payload.id)//empty' "$2")" ;;
    pi) id="$2" ;;
    copilot) id="$(copilot_session_id "$2")" || return 1 ;;
  esac
  [[ -n "$id" ]] || return 1
  printf '%s\n' "$id"
}

# A recorded target is exact. Jarvis uses this instead of the newest-session
# search above. A missing target is 1; unreadable or changed identity is 2.
recorded_session_file() { # HARNESS ACCOUNT NATIVE_ID SESSION_FILE
  local harness="$1" account="$2" id="$3" file="$4" actual
  if [[ "$harness" == copilot && -z "$file" ]]; then
    case "$id" in ''|.|..|*[!A-Za-z0-9._-]*) return 2 ;; esac
    file="$account/session-state/$id/workspace.yaml"
  fi
  [[ -n "$file" ]] || return 1
  [[ -e "$file" ]] || { [[ ! -L "$file" ]] || return 2; return 1; }
  [[ -f "$file" && -r "$file" ]] || return 2
  if [[ "$harness" == copilot ]]; then
    [[ -e "${file%/*}/events.jsonl" ]] || return 1
    [[ -f "${file%/*}/events.jsonl" && -r "${file%/*}/events.jsonl" ]] || return 2
    [[ -s "${file%/*}/events.jsonl" ]] || return 1
  else
    jq -Rne '[inputs | fromjson] | length > 0' -- "$file" >/dev/null || return 2
  fi
  actual="$(session_id_of "$harness" "$file")" || return 2
  if [[ "$harness" == pi ]]; then
    actual="$(jq -Rrn 'first(inputs|fromjson|select(.type=="session")|.id)//empty' -- "$file")" || return 2
  fi
  [[ "$actual" == "$id" ]] || return 2
  printf '%s\n' "$file"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  set -euo pipefail
  if [[ "${1:-}" == model-recovery ]]; then
    scripts="$(cd -- "${BASH_SOURCE[0]%/*}/.." && pwd -P)" || exit 1
    . "$scripts/lib/lane-state.sh"
    . "$scripts/lib/lane-launch.sh"
    . "$scripts/lib/lane-capabilities.sh"
    item="$(jq -er .item <<<"$2")" || exit 1
    lifecycle_path="$("$scripts/workflow-state" --state-dir "$3" path oversee)" || exit 1
    lifecycle_key="${lifecycle_path%/*}/.lane-lifecycle/$item.lock"
    if ! lane_lifecycle_owned "$lifecycle_key"; then
      exec "$scripts/workflow-state" --state-dir "$3" lane-run "$item" -- "$BASH" "$0" "$@"
    fi
    lane_model_recovery "$2" "$3" "$scripts" "$4"
    exit
  fi
  LAUNCH_FLAGS="$3" LANE_ENV=""
  LANES_CLI="$(cd -- "${BASH_SOURCE[0]%/*}/.." && pwd -P)/lanes" || exit 2
  session_file="" lookup_rc=0
  session_file="$(find_relaunch_session "$1" "$PWD" "${CODEX_HOME:-$HOME/.codex}")" || lookup_rc=$?
  case "$lookup_rc" in
    0) session_id_of "$1" "$session_file" && exit 0 ;;
    1) exit 1 ;;
  esac
  printf 'lane-relaunch: session-scan-failed item=%s harness=%s\n' "$2" "$1" >&2
  exit 2
fi
