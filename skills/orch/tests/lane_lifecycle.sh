#!/usr/bin/env bash
# bash-runtime: 3.2
# Surface: workflow-state lane-run. Inputs: scripts/workflow-state,
# scripts/lib/lane-state.sh, scripts/lib/lane-relaunch.sh, mailbox file-lock.sh.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/assertions.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/growth-state.sh"
TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
TMP_ROOT="$(mktemp -d)" || { echo 'lane-lifecycle: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo 'lane-lifecycle: scratch=not-a-directory' >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || exit 1
HOLDER=""
cleanup() {
  : > "$TMP_ROOT/release"
  [[ -z "$HOLDER" ]] || wait "$HOLDER" 2>/dev/null || true
  rm -rf -- "${TMP_ROOT:?}"
}
trap cleanup EXIT
SCRIPTS="$(mutant_scripts lifecycle/orch workflow-state)" || exit 1
[[ -z "${2:-}" ]] || cp -- "$2" "$SCRIPTS/workflow-state"
WS="$SCRIPTS/workflow-state"
cat > "$TMP_ROOT/hold.sh" <<'HOLD'
set -euo pipefail
ws=$1 root=$2
"$ws" --no-private-env --state-dir "$root/state" lane-run TEST-1 -- "$BASH" -c ': > "$1/nested"' _ "$root"
: > "$root/entered"
deadline=$((SECONDS + 10))
while [[ ! -f "$root/release" && "$SECONDS" -lt "$deadline" ]]; do sleep 0.05; done
[[ -f "$root/release" ]]
HOLD
"$WS" --no-private-env --state-dir "$TMP_ROOT/state" lane-run TEST-1 -- "$BASH" "$TMP_ROOT/hold.sh" "$WS" "$TMP_ROOT" > "$TMP_ROOT/holder.log" 2>&1 &
HOLDER=$!
deadline=$((SECONDS + 4))
while [[ ! -f "$TMP_ROOT/entered" && "$SECONDS" -lt "$deadline" ]]; do sleep 0.05; done
assert_eq "$([[ -f "$TMP_ROOT/entered" && -f "$TMP_ROOT/nested" ]] && echo entered || echo missing)" entered 'nested continuation keeps the live lifecycle owner' "$TMP_ROOT/holder.log"
rc=0
"$WS" --no-private-env --state-dir "$TMP_ROOT/state" lane-run TEST-1 -- "$BASH" -c ': > "$1/duplicate"' _ "$TMP_ROOT" > "$TMP_ROOT/duplicate.log" 2>&1 || rc=$?
assert_eq "$rc:$([[ -e "$TMP_ROOT/duplicate" ]] && echo changed || echo untouched)" '75:untouched' 'a concurrent same-item owner cannot enter irreversible work' "$TMP_ROOT/duplicate.log"
rc=0
"$WS" --no-private-env --state-dir "$TMP_ROOT/state" lane-run TEST-2 -- "$BASH" -c ': > "$1/other"' _ "$TMP_ROOT" > "$TMP_ROOT/other.log" 2>&1 || rc=$?
assert_eq "$rc:$([[ -e "$TMP_ROOT/other" ]] && echo changed || echo untouched)" '0:changed' 'another item has an independent lifecycle owner' "$TMP_ROOT/other.log"
: > "$TMP_ROOT/release"
rc=0
wait "$HOLDER" || rc=$?
HOLDER=""
assert_eq "$rc" 0 'the first owner completes its accepted work before releasing' "$TMP_ROOT/holder.log"
printf '\npass: %s   fail: %s\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
