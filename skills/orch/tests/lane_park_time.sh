#!/usr/bin/env bash
# bash-runtime: 3.2
# Surface: shared parked interval accounting and check_lane_long.
# Inputs: scripts/lib/watch-host-kinds.sh, tests/lib/assertions.sh.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/assertions.sh"
TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "${2:-$TEST_DIR/../scripts/lib/watch-host-kinds.sh}"

FLEET_STATE='{"lanes":[{"item":"test","launched_at":"2026-10-22T22:00:00Z","parked":{"at":"2026-10-22T22:30:00Z"}}]}'
PASS_NOW=1792717200
# All times are injected. The cutoff is 2026-10-23 01:00 UTC.
LAUNCH=1792706400
if [[ "${1:-}" != --long-only ]]; then
for row in \
  '{"parked":{"at":"2026-10-22T22:30:00Z"}}|9000' \
  '{"pauses":[{"cause":"parked","from":"2026-10-22T22:30:00Z","to":"2026-10-22T23:30:00Z"},{"cause":"parked","from":"2026-10-22T23:00:00Z","to":"2026-10-23T00:00:00Z"}],"parked":{"at":"2026-10-23T00:00:00Z"}}|9000' \
  '{"parked":{"at":"invalid"}}|unavailable' \
  '{"parked":{"at":"2026-10-24T00:00:00Z"}}|unavailable' \
  '{"parked":{"at":"2026-10-22T22:30:00Z","timing_unread":true}}|unavailable'; do
  IFS='|' read -r record expected <<<"$row"
  got="$(jq -er --argjson from "$LAUNCH" --argjson to "$PASS_NOW" "$LANE_INTERVALS_JQ"'lane_parked_seconds($from;$to)' <<<"$record" 2>/dev/null)" || got=unavailable
  assert_eq "$got" "$expected" 'parked intervals union open/completed pauses and reject unread timings'
done
split="$(jq -r "$LANE_INTERVALS_JQ"'
  .lanes[0] | lane_pauses(true) as $spans
  | [covered_seconds($spans;1792706400;1792713600),covered_seconds($spans;1792713600;1792717200)] | @tsv' <<<"$FLEET_STATE")"
assert_eq "$split" $'5400\t3600' 'calendar-day clipping splits a confirmed pause at midnight'

fi

# Keep the state and stage readers at their ordinary dependency boundary.
lane_row_get() { :; }
lane_row_set() { printf '%s' "$4"; }
lane_row_prune() { printf '%s' "$2"; }
lane_row_commit() { :; }
lane_step() { LANE_STEP=parked; }
lane_long_rounds() {
  LANE_REVIEW_ROUNDS=0 LANE_FIX_RECEIPTS=0 LANE_VALIDATION_RUNS=0 LANE_RESTACKS=0 LANE_REPEATED_CLASS_ROUNDS=0
}
ow_message() { printf '%s\n' "$1" >&2; }
PW_SEEN=('')
LANE_AGES=("test=$LAUNCH")
RECORDED_ITEMS=(test)
LANE_AGE_SECS=2000
assert_eq "$(check_lane_long)" '' 'parked compute time alone cannot trigger a long-lane event'
LANE_AGE_SECS=1000
assert_contains "$(check_lane_long)" 'EVENT lane-long test age=1800 ' 'the long-lane event retains work before the park'
printf '\npass: %s   fail: %s\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
