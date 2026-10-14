#!/usr/bin/env bash
# Surface: worktree-push delivery and submit-pr's publication command.
# Inputs: orch/scripts/worktree-push, orch/scripts/orch-env, workflow-state,
# orch/scripts/restack-skip, dev-validate-run, item-tier, orch/references/,
# orch/workflows/{submit-pr,merge-pr}.md, worktree/scripts/, harness-ci/scripts/, github/scripts/lib/,
# mailbox/scripts/, and orch/tests/lib/{git-env,assertions,shared-skill-libs}.sh.
# The Git transport and rebase are real. The PR service is a recorded fixture.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/assertions.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/shared-skill-libs.sh"

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
TMP_ROOT="$(mktemp -d)" || { echo 'worktree_push_delivery: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "worktree_push_delivery: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo 'worktree_push_delivery: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

unset ORCH_DELIVERY ORCH_PR_ORDER WORKTREE_DEFAULT_BRANCH BOT_REMOTE_NAME KENDEX_ENV_FILE ORCH_STATE_DIR
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null GIT_TERMINAL_PROMPT=0
export GIT_CEILING_DIRECTORIES="$TMP_ROOT"
REAL_GIT="$(command -v git)"
export REAL_GIT
mkdir -p "$TMP_ROOT/bin"
cat > "$TMP_ROOT/bin/git" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
for word in "$@"; do
  if [[ "$word" == push || "$word" == rebase ]]; then
    printf '%s\n' "$*" >> "$GIT_CALLS"
  fi
  if [[ "$word" == push && "${RACE_PUSH:-false}" == true && ! -e "$RACE_FLAG" ]]; then
    touch "$RACE_FLAG"
    "$REAL_GIT" -C "$FIXTURE_MAIN" commit -q --allow-empty -m race
    "$REAL_GIT" -C "$FIXTURE_MAIN" push -q origin trunk
  fi
done
exec "$REAL_GIT" "$@"
SH
cat > "$TMP_ROOT/bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$GH_CALLS"
if [[ "${1:-}" == pr && "${2:-}" == create ]]; then
  printf 'fixture-pr\n'
  exit 0
fi
if [[ "${1:-}" == repo && "${2:-}" == view ]]; then
  printf 'owner/repo\n'
  exit 0
fi
if [[ "$*" == 'api --paginate repos/owner/repo/activity?'* ]]; then
  head="$("$REAL_GIT" --git-dir "${FIXTURE_MAIN%/main}/remote.git" rev-parse trunk)"
  jq -cn --arg head "$head" --arg at "$ACTIVITY_AT" '[{timestamp:$at, after:$head}]'
  exit 0
fi
exit 1
SH
chmod +x "$TMP_ROOT/bin/git" "$TMP_ROOT/bin/gh"

# Read the executable publication command from its workflow fence. The fixture
# drives that command rather than implementing another publisher.
publication_command="$(awk '{ sub(/\r$/, ""); sub(/^[[:space:]]+/, "") } /^```bash$/ { fence=1; next } /^```$/ { fence=0 } fence && /worktree-push --worktree/ { print; found++ } END { if (found != 1) exit 1 }' "$REPO_ROOT/skills/orch/workflows/submit-pr.md")"
publication_command="${publication_command//\[WORKTREE_PATH\]/\$FIXTURE_LANE}"
publication_command="${publication_command//\[ISSUE_ID\]/KEN-1}"

new_world() { # NAME SETTING
  local name="$1" setting="$2" area
  area="$TMP_ROOT/$name"
  FIXTURE_MAIN="$area/main"
  FIXTURE_LANE="$area/lane"
  mkdir -p "$FIXTURE_MAIN" "$area/installed/orch" "$area/installed/worktree"
  "$REAL_GIT" init -qb trunk "$FIXTURE_MAIN"
  "$REAL_GIT" -C "$FIXTURE_MAIN" config user.name fixture
  "$REAL_GIT" -C "$FIXTURE_MAIN" config user.email fixture@example.com
  "$REAL_GIT" -C "$FIXTURE_MAIN" config gc.auto 0
  "$REAL_GIT" -C "$FIXTURE_MAIN" config maintenance.auto false
  printf 'tmp/\n.agents/\n' > "$FIXTURE_MAIN/.gitignore"
  {
    printf '[env]\nWORKTREE_DEFAULT_BRANCH = "trunk"\n'
    [[ "$setting" == unset ]] || printf 'ORCH_DELIVERY = "%s"\n' "$setting"
    printf 'DEV_VALIDATE_CMD = "printf validated"\nDEV_VALIDATE_TIMEOUT_SECS = "20"\n'
  } > "$FIXTURE_MAIN/kendex.settings.toml"
  printf 'a\n' > "$FIXTURE_MAIN/value"
  "$REAL_GIT" -C "$FIXTURE_MAIN" add .
  "$REAL_GIT" -C "$FIXTURE_MAIN" commit -qm base
  "$REAL_GIT" init -q --bare "$area/remote.git"
  "$REAL_GIT" -C "$area/remote.git" config gc.auto 0
  "$REAL_GIT" -C "$area/remote.git" config maintenance.auto false
  "$REAL_GIT" -C "$FIXTURE_MAIN" remote add origin "$area/remote.git"
  "$REAL_GIT" -C "$FIXTURE_MAIN" push -q origin trunk
  "$REAL_GIT" -C "$FIXTURE_MAIN" worktree add -qb ken-1 "$FIXTURE_LANE"
  printf 'feature\n' > "$FIXTURE_LANE/feature"
  "$REAL_GIT" -C "$FIXTURE_LANE" add feature
  "$REAL_GIT" -C "$FIXTURE_LANE" commit -qm feature
  BASE_HEAD="$("$REAL_GIT" -C "$FIXTURE_MAIN" rev-parse HEAD)"
  OLD_HEAD="$("$REAL_GIT" -C "$FIXTURE_LANE" rev-parse HEAD)"
  cp -R "$REPO_ROOT/skills/orch/scripts" "$area/installed/orch/"
  cp -R "$REPO_ROOT/skills/orch/references" "$area/installed/orch/"
  mkdir -p "$area/installed/orch/workflows" "$area/installed/linear/scripts"
  cp "$REPO_ROOT/skills/orch/workflows/submit-pr.md" "$REPO_ROOT/skills/orch/workflows/merge-pr.md" "$area/installed/orch/workflows/"
  cat > "$area/installed/linear/scripts/linear.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$COMPLETE_CALLS"
printf 'Verifying\n'
SH
  chmod +x "$area/installed/linear/scripts/linear.sh"
  mkdir -p "$area/installed/harness-ci"
  cp -R "$REPO_ROOT/skills/harness-ci/scripts" "$area/installed/harness-ci/"
  cp -R "$REPO_ROOT/skills/worktree/scripts" "$area/installed/worktree/"
  orch_fixture_shared_libs "$area/installed/orch"
  mkdir -p "$FIXTURE_LANE/.agents" "$FIXTURE_LANE/tmp"
  ln -s "$area/installed" "$FIXTURE_LANE/.agents/skills"
  PUSH="$area/installed/orch/scripts/worktree-push"
  GIT_CALLS="$area/git-calls"
  GH_CALLS="$area/gh-calls"
  RACE_FLAG="$area/race"
  COMPLETE_CALLS="$area/complete-calls"
  ACTIVITY_AT='2026-10-14T17:00:00Z'
  export FIXTURE_MAIN FIXTURE_LANE GIT_CALLS GH_CALLS RACE_FLAG COMPLETE_CALLS ACTIVITY_AT
  : > "$GIT_CALLS"
  : > "$GH_CALLS"
  : > "$COMPLETE_CALLS"
  "$REPO_ROOT/skills/orch/scripts/workflow-state" --state-dir "$FIXTURE_MAIN/tmp" init KEN-1 --worktree "$FIXTURE_LANE" --branch ken-1 >/dev/null
  "$REPO_ROOT/skills/orch/scripts/workflow-state" --state-dir "$FIXTURE_MAIN/tmp" update KEN-1 --arg sha "$OLD_HEAD" '.fixed_items=[{commit:$sha}]'
  printf '{"overseer":{"server":"7000","pane":"%%0"}}\n' > "$FIXTURE_MAIN/tmp/workflow-state-oversee.json"
}

validate_current() {
  (cd "$FIXTURE_LANE" && env -u DEV_VALIDATE_CMD -u DEV_VALIDATE_RANGE_CMD -u DEV_VALIDATE_SELECTION_CMD \
    -u DEV_VALIDATE_CI_CONTEXT -u DEV_VALIDATE_BASE -u DEV_VALIDATE_CLASS -u DEV_VALIDATE_PATHS \
    -u DEV_VALIDATE_DOCS_ONLY PATH="$TMP_ROOT/bin:$PATH" \
    "$FIXTURE_LANE/.agents/skills/orch/scripts/dev-validate-run" --worktree "$FIXTURE_LANE" --poll 1) \
    > "$FIXTURE_MAIN/tmp/validation.out" 2> "$FIXTURE_MAIN/tmp/validation.err"
}

publish() {
  RC=0
  OUT="$(cd "$FIXTURE_LANE" && PATH="$TMP_ROOT/bin:$PATH" "$BASH" -c "$publication_command" 2> "$FIXTURE_MAIN/tmp/push.err")" || RC=$?
  NOTICE=""
  [[ "$RC" == 0 ]] || return 0
  NOTICE="$(sed -n '/^delivery: mode=push-base /p' <<< "$OUT")"
  if [[ -n "$NOTICE" ]]; then
    # Execute the existing completion owner's fence only when submit routes
    # to it. The service fixture records the exact command, not a publisher.
    if grep -Fq 'Complete the item through [merge-pr.md § 5 step 2]' "$FIXTURE_LANE/.agents/skills/orch/workflows/submit-pr.md"; then
      pushed_at="$(sed -n 's/^direct-push-time: at=//p' <<< "$OUT")"
      completion_command="$(awk '{ sub(/\r$/, ""); sub(/^[[:space:]]+/, "") } /^```bash$/ { fence=1; next } /^```$/ { fence=0 } fence && /linear.sh issues complete/ { print; found++ } END { if (found != 1) exit 1 }' "$FIXTURE_LANE/.agents/skills/orch/workflows/merge-pr.md")"
      completion_command="${completion_command//\[MAIN_REPO_ROOT\]/\$FIXTURE_LANE}"
      completion_command="${completion_command//\[ISSUE\]/KEN-1}"
      completion_command="${completion_command//\[MERGED_AT\]/\$pushed_at}"
      completion_command="${completion_command//\[MET_BOXES\]/1}"
      (cd "$FIXTURE_LANE" && pushed_at="$pushed_at" "$BASH" -c "$completion_command") > "$FIXTURE_MAIN/tmp/completion.out" || { RC=$?; NOTICE=''; return 0; }
    fi
    printf '%s\n' "$NOTICE" > "$FIXTURE_LANE/tmp/direct-push-KEN-1.md"
    (cd "$FIXTURE_LANE" && "$REPO_ROOT/skills/mailbox/scripts/lane-mail" notice --item KEN-1 --file "$FIXTURE_LANE/tmp/direct-push-KEN-1.md") > "$FIXTURE_MAIN/tmp/notice.out"
  else
    PATH="$TMP_ROOT/bin:$PATH" gh pr create > "$FIXTURE_MAIN/tmp/pr.out"
  fi
}

for row in 'direct|push-base|trunk' 'advanced|push-base|trunk' 'queue|push-base|trunk' 'two|push-base|trunk' 'fold-control|push-base|multi' 'guard-refusal|push-base|guard-refused' 'guard-change|push-base|content-changed' 'unset|unset|ken-1' 'explicit-pr|pr|ken-1' 'pr-multi|pr|ken-1' 'unread-control|push-base|ken-1' 'race|push-base|refused'; do
  IFS='|' read -r name setting target <<< "$row"
  new_world "$name" "$setting"
  RACE_PUSH=false
  export RACE_PUSH
  FOLD_CALLS="$TMP_ROOT/$name/fold-calls"
  GUARD_REFUSE=false
  GUARD_CHANGE=false
  export FOLD_CALLS GUARD_REFUSE GUARD_CHANGE
  : > "$FOLD_CALLS"
  case "$name" in
    two|fold-control|guard-refusal|guard-change|pr-multi)
      printf 'fix\n' > "$FIXTURE_LANE/fix"
      "$REAL_GIT" -C "$FIXTURE_LANE" add fix
      "$REAL_GIT" -C "$FIXTURE_LANE" commit -qm fix
      FIX_HEAD="$("$REAL_GIT" -C "$FIXTURE_LANE" rev-parse HEAD)"
      "$REPO_ROOT/skills/orch/scripts/workflow-state" --state-dir "$FIXTURE_MAIN/tmp" update KEN-1 --arg sha "$FIX_HEAD" '.fixed_items += [{commit:$sha}]'
      mkdir -p "$TMP_ROOT/$name/hooks"
      cat > "$TMP_ROOT/$name/hooks/pre-commit" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'guard\n' >> "$FOLD_CALLS"
[[ "$GUARD_REFUSE" != true ]] || exit 1
if [[ "$GUARD_CHANGE" == true ]]; then
  printf 'hook change\n' >> feature
  git add feature
fi
SH
      chmod +x "$TMP_ROOT/$name/hooks/pre-commit"
      "$REAL_GIT" -C "$FIXTURE_MAIN" config core.hooksPath "$TMP_ROOT/$name/hooks"
      ;;
  esac
  case "$name" in
    advanced|queue|two)
      "$REAL_GIT" -C "$FIXTURE_MAIN" commit -q --allow-empty -m advanced
      "$REAL_GIT" -C "$FIXTURE_MAIN" push -q origin trunk
      if [[ "$name" == queue ]]; then
        printf 'trunk queue\n' > "$("$REAL_GIT" -C "$FIXTURE_LANE" rev-parse --git-path kendex-base-policy)"
      fi
      ;;
    guard-refusal) GUARD_REFUSE=true; export GUARD_REFUSE ;;
    guard-change) GUARD_CHANGE=true; export GUARD_CHANGE ;;
    fold-control)
      python3 - "$TMP_ROOT/$name/installed/worktree/scripts/worktree" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
old = 'if (( BASE_PUSH_COUNT > 1 )) || [[ "$PUSH_PUBLICATION_TIER" == micro ]]; then'
text = path.read_text()
assert text.count(old) == 1
updated = text.replace(old, 'if { (( BASE_PUSH_COUNT > 1 )) || [[ "$PUSH_PUBLICATION_TIER" == micro ]]; } && false; then')
assert updated != text
path.write_text(updated)
PY
      ;;
    unread-control)
      python3 - "$PUSH" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
old = 'delivery="$(cd -- "$worktree_abs" && "$SCRIPT_DIR/orch-env" ORCH_DELIVERY pr)" || exit 1'
text = path.read_text()
assert text.count(old) == 1
updated = text.replace(old, 'delivery=pr')
assert updated != text
path.write_text(updated)
PY
      ;;
    race) RACE_PUSH=true; export RACE_PUSH ;;
  esac
  BEFORE_PUSH="$("$REAL_GIT" --git-dir "$TMP_ROOT/$name/remote.git" rev-parse trunk)"
  BEFORE_TREE="$("$REAL_GIT" -C "$FIXTURE_LANE" rev-parse HEAD^{tree})"
  : > "$FOLD_CALLS"
  validate_current
  : > "$GH_CALLS"
  publish
  head="$("$REAL_GIT" -C "$FIXTURE_LANE" rev-parse HEAD)"
  if [[ "$target" == refused ]]; then
    assert_eq "$RC" 1 'concurrent base divergence refuses publication' "$FIXTURE_MAIN/tmp/push.err"
    assert_eq "$(sed -n '/^worktree-push-base-non-fast-forward:/p' "$FIXTURE_MAIN/tmp/push.err")" 'worktree-push-base-non-fast-forward: origin/trunk' 'non-fast-forward names the restack refusal'
    assert_eq "$NOTICE|$(cat "$GH_CALLS")" '|' 'refusal sends no completion and opens no PR'
    assert_not_contains "$(cat "$GIT_CALLS")" '--force' 'base divergence attempts no force option'
    remote="$("$REAL_GIT" -C "$FIXTURE_MAIN" rev-parse refs/heads/trunk)"
    assert_eq "$("$REAL_GIT" --git-dir "$TMP_ROOT/$name/remote.git" rev-parse trunk)" "$remote" 'refusal preserves concurrent remote commit'
    continue
  fi
  if [[ "$target" == guard-refused ]]; then
    assert_eq "$RC|$(sed -n '/^worktree-push-base-fold-failed:/p' "$FIXTURE_MAIN/tmp/push.err")" "1|worktree-push-base-fold-failed: $FIXTURE_LANE" 'a normal commit guard refuses the fold without pushing'
    assert_eq "$head|$("$REAL_GIT" --git-dir "$TMP_ROOT/$name/remote.git" rev-parse trunk)|$(cat "$FOLD_CALLS")" "$FIX_HEAD|$BASE_HEAD|guard" 'guard refusal restores item history and leaves base unchanged'
    assert_eq "$NOTICE|$(cat "$GH_CALLS")" '|' 'guard refusal sends no completion and opens no PR'
    continue
  fi
  if [[ "$target" == content-changed ]]; then
    assert_eq "$RC|$(sed -n '/^worktree-push-base-fold-content-changed:/p' "$FIXTURE_MAIN/tmp/push.err")" "1|worktree-push-base-fold-content-changed: $head" 'a hook content change refuses publication for local validation'
    assert_eq "$("$REAL_GIT" --git-dir "$TMP_ROOT/$name/remote.git" rev-parse trunk)|$NOTICE" "$BASE_HEAD|" 'unvalidated hook content stays off the base'
    assert_eq "$(jq -r --arg head "$head" 'all(.fixed_items[]; .commit == $head)' "$FIXTURE_MAIN/tmp/workflow-state-KEN-1.json")" true 'hook-content refusal preserves reconciled fix history'
    GUARD_CHANGE=false
    export GUARD_CHANGE
    publish
    assert_eq "$RC|$(sed -n '/^worktree-push-base-validation-required:/p' "$FIXTURE_MAIN/tmp/push.err")" "1|worktree-push-base-validation-required: $head" 'a hook-content retry without new local validation remains refused'
    assert_eq "$(awk '/ push / { n++ } END { print n+0 }' "$GIT_CALLS")" 0 'hook-content retries attempt no transport before validation'
    validate_current
    publish
    assert_eq "$RC|$("$REAL_GIT" --git-dir "$TMP_ROOT/$name/remote.git" rev-parse trunk)" "0|$head" 'a passing local full run permits the changed hook tree'
    continue
  fi
  if [[ "$target" == multi ]]; then
    assert_eq "$RC" 0 'control: disabling the fold publishes both commits' "$FIXTURE_MAIN/tmp/push.err"
    published_count="$("$REAL_GIT" --git-dir "$TMP_ROOT/$name/remote.git" rev-list --count "$BEFORE_PUSH..trunk")"
    # oversee-cycle --commit has no push-before input. Its caller owns this
    # documented precondition and refuses a real range with multiple commits.
    cycle_caller=permitted
    [[ "$published_count" == 1 ]] || cycle_caller=refused
    assert_eq "$published_count|$cycle_caller" '2|refused' 'control: the published range fails the existing direct-cycle caller contract'
    continue
  fi
  assert_eq "$RC" 0 "$name publication succeeds" "$FIXTURE_MAIN/tmp/push.err"
  assert_eq "$("$REAL_GIT" --git-dir "$TMP_ROOT/$name/remote.git" rev-parse "$target")" "$head" "$name publishes the actual commit to $target"
  if [[ "$target" == trunk ]]; then
    assert_eq "$NOTICE" "delivery: mode=push-base base=trunk commit=$head" "$name completion notice names the pushed remote commit"
    assert_not_contains "$(cat "$GH_CALLS")" 'pr create' "$name makes no PR call"
    assert_not_contains "$(cat "$GIT_CALLS")" '--force' "$name uses no force option"
    assert_eq "$(awk '/ push / { n++ } END { print n+0 }' "$GIT_CALLS")" 1 "$name pushes once"
    assert_eq "$("$REAL_GIT" -C "$FIXTURE_LANE" branch --show-current)" ken-1 "$name keeps the item branch"
    assert_eq "$(jq -r --arg head "$head" 'all(.fixed_items[]; .commit == $head)' "$FIXTURE_MAIN/tmp/workflow-state-KEN-1.json")" true "$name reconciliation precedes completion"
    mail="$(jq -r '.text' "$FIXTURE_LANE/tmp/lane-mail/KEN-1/to-overseer.jsonl")"
    assert_eq "$mail" "$NOTICE" "$name actual mailbox notice carries the pushed SHA"
    assert_eq "$("$REAL_GIT" --git-dir "$TMP_ROOT/$name/remote.git" rev-list --count "$BEFORE_PUSH..trunk")" 1 "$name publishes one item commit for the direct cycle"
    if [[ "$name" == two ]]; then
      assert_eq "$(cat "$FOLD_CALLS")" guard 'the folded item runs the normal commit guard'
      assert_eq "$("$REAL_GIT" -C "$FIXTURE_LANE" log -1 --format=%s)" feature 'the folded commit retains the item subject'
      assert_eq "$("$REAL_GIT" -C "$FIXTURE_LANE" rev-parse HEAD^{tree})" "$BEFORE_TREE" 'folding retains the validated content'
    fi
    if [[ "$name" != direct ]]; then
      assert_not_contains "$head" "$OLD_HEAD" "$name rebase rewrites the feature commit"
      assert_eq "$(awk '/ rebase / { n++ } END { print n+0 }' "$GIT_CALLS")" 1 "$name rebases onto the advanced base once"
    fi
  else
    assert_eq "$NOTICE|$(cat "$GH_CALLS")" '|pr create' "$name keeps PR creation"
    assert_eq "$("$REAL_GIT" --git-dir "$TMP_ROOT/$name/remote.git" rev-parse trunk)" "$BASE_HEAD" "$name leaves the base unchanged"
    if [[ "$name" == pr-multi ]]; then
      assert_eq "$("$REAL_GIT" --git-dir "$TMP_ROOT/$name/remote.git" rev-list --count "$BASE_HEAD..ken-1")|$(cat "$FOLD_CALLS")" '2|' 'PR delivery keeps both item commits and runs no fold guard'
    fi
  fi
done

echo '=== the optional publication checker is required only for direct transport ==='
for delivery in push-base pr; do
  new_world "missing-$delivery" "$delivery"
  RACE_PUSH=false
  export RACE_PUSH
  rm -- "${TMP_ROOT:?}/missing-$delivery/installed/orch/scripts/restack-skip"
  publish
  remote="$("$REAL_GIT" --git-dir "$TMP_ROOT/missing-$delivery/remote.git" rev-parse trunk)"
  if [[ "$delivery" == push-base ]]; then
    assert_eq "$RC|$(sed -n 's/^worktree-push-base-check-missing:.*/missing/p' "$FIXTURE_MAIN/tmp/push.err")|$(awk '/ push / { n++ } END { print n+0 }' "$GIT_CALLS")|$remote" "1|missing|0|$BASE_HEAD" 'the absent optional checker refuses direct transport'
  else
    assert_eq "$RC|$(cat "$GH_CALLS")|$remote" "0|pr create|$BASE_HEAD" 'PR transport remains independent of the optional checker'
  fi
done

echo '=== direct micro classification and normal commit-chain proof ==='
for row in 'micro|ready' 'micro-standard|refused' 'micro-unreadable|refused'; do
  IFS='|' read -r name want <<< "$row"
  new_world "$name" push-base
  RACE_PUSH=false
  export RACE_PUSH
  "$REPO_ROOT/skills/orch/scripts/workflow-state" --state-dir "$FIXTURE_MAIN/tmp" set KEN-1 tier micro >/dev/null
  mkdir -p "$TMP_ROOT/$name/hooks"
  FOLD_CALLS="$TMP_ROOT/$name/fold-calls"
  export FOLD_CALLS
  : > "$FOLD_CALLS"
  cat > "$TMP_ROOT/$name/hooks/pre-commit" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'guard\n' >> "$FOLD_CALLS"
SH
  chmod +x "$TMP_ROOT/$name/hooks/pre-commit"
  "$REAL_GIT" -C "$FIXTURE_MAIN" config core.hooksPath "$TMP_ROOT/$name/hooks"
  case "$name" in
    micro-standard)
      printf 'HARNESS_CI_STANDARD_PATHS = "src/*.rs"\n' >> "$FIXTURE_MAIN/kendex.settings.toml"
      mkdir -p "$FIXTURE_LANE/src"
      printf 'fn main() {}\n' > "$FIXTURE_LANE/src/main.rs"
      "$REAL_GIT" -C "$FIXTURE_LANE" add src/main.rs
      "$REAL_GIT" -C "$FIXTURE_LANE" commit -qm standard
      ;;
    micro-unreadable) rm "$TMP_ROOT/$name/installed/orch/references/narrow-change.conf" ;;
  esac
  : > "$FOLD_CALLS"
  publish
  if [[ "$want" == ready ]]; then
    head="$("$REAL_GIT" -C "$FIXTURE_LANE" rev-parse HEAD)"
    assert_eq "$RC|$(cat "$FOLD_CALLS")|$("$REAL_GIT" --git-dir "$TMP_ROOT/$name/remote.git" rev-parse trunk)" "0|guard|$head" 'micro repeats its normal commit chain before direct transport'
  else
    assert_eq "$RC|$(awk '/ push / { n++ } END { print n+0 }' "$GIT_CALLS")|$("$REAL_GIT" --git-dir "$TMP_ROOT/$name/remote.git" rev-parse trunk)" "1|0|$BASE_HEAD" "$name refuses before direct transport"
    assert_contains "$OUT" 'tier=standard ' "$name uses the existing committed-path classifier"
  fi
done

echo '=== a change-and-revert rebase needs a new local full result ==='
for name in revert guarded-restack revert-control; do
  new_world "$name" push-base
  RACE_PUSH=false
  export RACE_PUSH
  printf 'b\n' > "$FIXTURE_LANE/value"
  "$REAL_GIT" -C "$FIXTURE_LANE" commit -qam change
  printf 'a\n' > "$FIXTURE_LANE/value"
  "$REAL_GIT" -C "$FIXTURE_LANE" commit -qam revert
  validate_current
  printf 'b\n' > "$FIXTURE_MAIN/value"
  "$REAL_GIT" -C "$FIXTURE_MAIN" commit -qam advance
  "$REAL_GIT" -C "$FIXTURE_MAIN" push -q origin trunk
  ADVANCED_HEAD="$("$REAL_GIT" -C "$FIXTURE_MAIN" rev-parse HEAD)"
  if [[ "$name" == guarded-restack ]]; then
    # The guarded route hands the publisher an already restacked head. Its
    # no-range consumer must still run full local validation when reuse fails.
    "$REAL_GIT" -C "$FIXTURE_LANE" fetch -q origin trunk
    "$REAL_GIT" -C "$FIXTURE_LANE" rebase origin/trunk > "$FIXTURE_MAIN/tmp/restack.out" 2>&1
    mode="$("$FIXTURE_LANE/.agents/skills/orch/scripts/dev-validate-run" --resolve-mode --worktree "$FIXTURE_LANE")"
    assert_eq "$mode" validate-mode=full 'no-range restack resolves to local full validation'
  elif [[ "$name" == revert-control ]]; then
    python3 - "$TMP_ROOT/$name/installed/worktree/scripts/worktree" <<'PY'
import pathlib, sys
path = pathlib.Path(sys.argv[1])
old = 'if ! "$BASE_PUBLICATION_CHECK" --worktree "$WT_PATH" --base "origin/$DEFAULT_BRANCH" --publication-tier "$PUSH_PUBLICATION_TIER"; then'
text = path.read_text()
assert text.count(old) == 1
updated = text.replace(old, 'if ! { "$BASE_PUBLICATION_CHECK" --worktree "$WT_PATH" --base "origin/$DEFAULT_BRANCH" --publication-tier "$PUSH_PUBLICATION_TIER"; true; }; then')
assert updated != text
path.write_text(updated)
PY
  fi
  : > "$GIT_CALLS"
  publish
  if [[ "$name" == revert-control ]]; then
    assert_eq "$RC|$("$REAL_GIT" --git-dir "$TMP_ROOT/$name/remote.git" show trunk:value)" '0|a' 'control: ignoring the existing reuse proof publishes the unvalidated revert'
    continue
  fi
  assert_eq "$RC|$(awk '/ push / { n++ } END { print n+0 }' "$GIT_CALLS")|$("$REAL_GIT" --git-dir "$TMP_ROOT/$name/remote.git" rev-parse trunk)" "1|0|$ADVANCED_HEAD" "$name refuses before transport when the validated merge differs"
  assert_contains "$OUT" 'restack=retest cause=path-unconflicted path=value ' "$name uses the existing restack-skip proof"
  validate_current
  publish
  assert_eq "$RC|$(awk '/ push / { n++ } END { print n+0 }' "$GIT_CALLS")" '0|1' "$name publishes once after the new full pass"
done

echo '=== a landed commit survives post-push reconciliation failure ==='
new_world repair push-base
RACE_PUSH=false
export RACE_PUSH
printf 'fix\n' > "$FIXTURE_LANE/fix"
"$REAL_GIT" -C "$FIXTURE_LANE" add fix
"$REAL_GIT" -C "$FIXTURE_LANE" commit -qm fix
validate_current
cp "$FIXTURE_MAIN/tmp/workflow-state-KEN-1.json" "$FIXTURE_MAIN/tmp/state-kept.json"
# A real receive hook damages the dependency's state after transport. The
# production reconciliation owner still runs and reports its read failure.
cat > "$TMP_ROOT/repair/remote.git/hooks/post-receive" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'invalid-json\n' > "$FIXTURE_MAIN/tmp/workflow-state-KEN-1.json"
SH
chmod +x "$TMP_ROOT/repair/remote.git/hooks/post-receive"
publish
landed="$("$REAL_GIT" --git-dir "$TMP_ROOT/repair/remote.git" rev-parse trunk)"
landed_record="delivery: mode=push-base base=trunk commit=$landed"
assert_eq "$RC|$NOTICE" '1|' 'a landed push with failed reconciliation sends no completion notice'
assert_eq "$(sed -n '/^delivery: mode=push-base /p' <<< "$OUT")" "$landed_record" 'the failed wrapper preserves the exact landed commit'
cp "$FIXTURE_MAIN/tmp/state-kept.json" "$FIXTURE_MAIN/tmp/workflow-state-KEN-1.json"
rm "$TMP_ROOT/repair/remote.git/hooks/post-receive"
publish
assert_eq "$RC|$NOTICE|$(awk '/ push / { n++ } END { print n+0 }' "$GIT_CALLS")" "0|$landed_record|1" 'repair returns the same pushed commit with no second transport'

echo '=== direct Linear completion uses the repository push time ==='
for name in completion completion-control; do
  new_world "$name" push-base
  RACE_PUSH=false
  export RACE_PUSH
  validate_current
  if [[ "$name" == completion-control ]]; then
    python3 - "$FIXTURE_LANE/.agents/skills/orch/workflows/submit-pr.md" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
text = p.read_text()
old = 'Complete the item through [merge-pr.md § 5 step 2](merge-pr.md#5-execute-the-merge)'
assert text.count(old) == 1
p.write_text(text.replace(old, 'Omit tracker completion'))
PY
  fi
  publish
  observed="$RC|$(cat "$COMPLETE_CALLS")|$(cat "$FIXTURE_MAIN/tmp/completion.out" 2>/dev/null || true)"
  expected="0|issues complete KEN-1 --post-merge-at $ACTIVITY_AT --done-when-met 1|Verifying"
  if [[ "$name" == completion-control ]]; then
    control_rc=0
    (PASS=0; FAIL=0; assert_eq "$observed" "$expected" 'direct completion and push time'; [[ "$FAIL" == 0 ]]) > "$FIXTURE_MAIN/tmp/control.out" || control_rc=$?
    assert_eq "$control_rc" 1 'control: removing completion fails the same completion/time row'
    assert_contains "$(cat "$FIXTURE_MAIN/tmp/control.out")" 'FAIL  direct completion and push time' 'control fails for the missing completion call'
  else
    assert_eq "$observed" "$expected" 'direct completion and push time' "$FIXTURE_MAIN/tmp/push.err"
    assert_eq "$(sed -n 's/^direct-push-time: at=//p' <<< "$OUT")" "$ACTIVITY_AT" 'completion receives the repository activity time'
    assert_not_contains "$(cat "$GH_CALLS")" 'pr create' 'Linear completion creates no PR'
  fi
done

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" == 0 ]]
