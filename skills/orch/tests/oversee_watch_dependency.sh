#!/usr/bin/env bash
# bash-runtime: 3.2
# Surface: typed dependency watch. Inputs: scripts/oversee-watch, scripts/lane-close,
# scripts/lib/*.sh, tests/fixtures/lane-host, tests/lib/oversee-watch-harness.sh.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/oversee-watch-harness.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/growth-state.sh"
DEP_WATCH_DIR="$(mutant_scripts dependency-watch/orch oversee-watch)" || exit 1
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/dependency-watch/github"
[[ -z "${2:-}" ]] || cp -- "$2" "$DEP_WATCH_DIR/oversee-watch"
WATCH_BIN="$DEP_WATCH_DIR/oversee-watch"
PROVIDER="$REPO_ROOT/skills/orch/tests/fixtures/lane-host"
for row in 'MERGED|dependency-2|ready' 'CLOSED|dependency-2|held' 'MERGED|unrelated|held'; do
  IFS='|' read -r delivered branch expected <<<"$row"
  new_case "typed-$delivered-$branch"
  jq -n --arg provider "$PROVIDER" '{triaged:[],lanes:[{item:"issue-2",tracker:"github",repo:"owner/repo",harness:"codex",account:"/lane",host:$provider,
    kind:"ssh",model:"gpt-6-astra",effort:"high",session_id:"native-2",sandbox_instance_id:"immutable-2",window:"gh-2",mail_root:"/srv/lane",
    launch:{pane:"%2",server:999},launched_at:"2026-09-20T00:00:00Z",status:"parked"}]}
    | .lanes[0] |= (.parked={at:"2026-09-20T00:01:00Z",phase:"stopped",head:"abc",repo:"owner/repo",wait:{kind:"item",reason:"held step",source:"directive-2",
      session_file:"/sessions/native-2.jsonl",launch_flags:"-m gpt-6-astra",binding:{host,harness,launch,launched_at,session_id,account,model,effort,sandbox_instance_id},
      dependencies:[{tracker:"github",id:"immutable-item-9",key:"9",repo:"owner/repo",step:"build",delivery:{kind:"pr",pr:9,branch:"dependency-2",item:"9"}}]}})' > "$STUB_DIR/workflow-state-oversee.json"
  printf '%s\n' '{"id":"immutable-item-9","number":9,"state":"CLOSED","stateReason":"COMPLETED"}' > "$STUB_DIR/dependency-issue-9.json"
  jq -n --arg state "$delivered" --arg branch "$branch" '{number:9,state:$state,headRefName:$branch,headRepositoryOwner:{login:"owner"},mergedAt:"2026-10-22T12:00:00Z",mergeCommit:{oid:"landed"}}' > "$STUB_DIR/dependency-9.json"
  rc=0
  : > "$STUB_DIR/host.log"
  out="$(run_watch ORCH_WATCH_LANE_AGE_SECS=100 OVERSEE_WATCH_LANE_CLOSE="$REPO_ROOT/skills/orch/scripts/lane-close" \
    LANE_HOST_STUB_LOG="$STUB_DIR/host.log" LANE_HOST_STUB_LIST_JSON='[{"repo":"repo","item":"issue-2","id":"immutable-2","name":"reusable"}]' \
    -- --state "$STUB_DIR/workflow-state-oversee.json" --max-loops 1 2> "$STUB_DIR/err")" || rc=$?
  assert_eq "$rc" 0 'the watch judges a typed wait through existing events' "$STUB_DIR/err"
  assert_contains "$out" "EVENT parked-$expected issue-2 wait=item" 'only the exact recorded landing reports ready' "$STUB_DIR/err"
  assert_not_contains "$out" 'EVENT parked-merged' 'legacy own-PR resume cannot clear a typed wait'
  assert_not_contains "$out" 'EVENT lane-long' 'confirmed open parked time is excluded from active lane age'
  assert_eq "$(awk '$1=="start" || $1=="stop" || $1=="close" {n++} END {print n+0}' "$STUB_DIR/host.log")" 0 'the control-side watch never starts or closes a dependency disk'
done
printf '\npass: %s   fail: %s\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
exit
