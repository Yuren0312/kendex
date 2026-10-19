"""Reject the absent succession verb and a removed process identity check."""
import argparse
import io
import tarfile
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
from fixtures.harness import native_launcher


ROOT = Path(__file__).resolve().parents[3]


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--main-ref", help="Also prove each succession case fails on this pre-change revision")
    parser.add_argument("--main-case", action="append", default=[],
                        help="Run only named main controls and their current stability cases")
    args = parser.parse_args()
    if args.main_case and not args.main_ref:
        parser.error("--main-case requires --main-ref")
    completed = 0
    with native_launcher() as native, tempfile.TemporaryDirectory() as allocation:
        scratch = Path(allocation).resolve()
        skills = scratch / "skills"
        for package in ("jarvis", "orch", "mailbox", "github"):
            shutil.copytree(ROOT / "skills" / package / "scripts", skills / package / "scripts")
        controls = [("absent verb", "orch/scripts/lib/controller-session.py", 'for verb in ("start", "status", "stop", "succeed", "report-due"):',
                     'for verb in ("start", "status", "stop"):', "test_succession_contract"),
                    ("process identity", "orch/scripts/lib/session-backend.sh", '    lane_stop_identity "$1" "$2" "$3" ;;',
                     '    lane_stop_identity "$1" "$(lane_process_start "$1")" "$3" ;;', "test_succession_identity"),
                    ("walled account reused", "orch/scripts/lib/controller-session.py",
                     'choice = json.loads(self.backend("select", record["harness"], record["account"], self.home,\n                                             choice.get("model", ""), choice.get("effort", "")).stdout)',
                     'choice = {"harness": record["harness"], "account": record["account"], "model": "", "effort": ""}', "test_account_succession"),
                    ("missing dependency status", "orch/scripts/lib/controller-session.py",
                     'if not (BACKEND.parents[3] / "orch/scripts").is_dir():',
                     'if False:', "test_missing_orch_keeps_predecessor"),
                    ("model context helper missing", "orch/scripts/lib/session-backend.sh",
                     '    source "$SCRIPT_DIR/lib/lane-context.sh"',
                     '    : source "$SCRIPT_DIR/lib/lane-context.sh"', "test_account_succession"),
                    ("selected launch words dropped", "orch/scripts/lib/session-backend.sh",
                     'if [[ -n "${13:-}${14:-}" ]]; then',
                     'if false && [[ -n "${13:-}${14:-}" ]]; then', "test_account_succession"),
                    ("native launch posture changed", "orch/scripts/lib/session-backend.sh",
                     '      flags="$(printf \' %q\' ${LAUNCH_CHOICE_ARGV[@]+"${LAUNCH_CHOICE_ARGV[@]}"})" || exit 1',
                     '      launch_choice_lead_settings --model "${13:-}" "$harness" ${LAUNCH_CHOICE_ARGV[@]+"${LAUNCH_CHOICE_ARGV[@]}"} || exit 1\n'
                     '      LAUNCH_CHOICE_ARGV=("${LAUNCH_CHOICE_KEPT[@]}")\n'
                     '      flags="$(printf \' %q\' ${LAUNCH_CHOICE_ARGV[@]+"${LAUNCH_CHOICE_ARGV[@]}"})" || exit 1', "test_account_succession"),
                    ("duplicate native boolean", "orch/scripts/lib/session-backend.sh",
                     '      cmd="$harness$flags${cmd#"$harness"}"',
                     '      cmd="$harness$flags${cmd#"$harness"}"\n'
                     '      [[ "$harness" != codex ]] || cmd="$cmd --dangerously-bypass-hook-trust"', "test_account_succession"),
                    ("recorded account seat reserve", "orch/scripts/lib/session-backend.sh",
                     '--harness "$OL_ACCOUNT_HARNESS" --for-overseer',
                     '--harness "$OL_ACCOUNT_HARNESS"', "test_account_succession"),
                    ("missing selected app", "orch/scripts/lib/controller-session.py",
                     'if not shutil.which(choice["harness"]):',
                     'if False and not shutil.which(choice["harness"]):', "test_account_succession")]
        controls.extend([
            ("sole controller", "orch/scripts/lib/controller-session.py", '        state["overseer"] = owner',
             '        owner = {"lifecycle": record}\n        state["overseer"] = owner', "test_shared_controller_mail"),
            ("retirement before native work", "orch/scripts/lib/controller-session.py", '                    self.end_owned(record.get("predecessor"), window=True)',
             '                    if False:\n                        self.end_owned(record.get("predecessor"), window=True)', "test_orch_retirement_order"),
            ("legacy authority", "orch/scripts/lib/controller-session.py", '        if self.legacy.exists():',
             '        if False and self.legacy.exists():', "test_legacy_controller_refuses_replacement"),
            ("legacy worker retirement", "orch/scripts/lib/controller-session.py", '            if legacy.get("worker") and self.worker_live(legacy):',
             '            if False and legacy.get("worker") and self.worker_live(legacy):', "test_legacy_controller_refuses_replacement"),
        ])
        cases = ("test_shared_first_launch", "test_shared_registration", "test_shared_orch_launch_and_recovery",
                 "test_shared_recovery_harnesses", "test_shared_controller_mail", "test_orch_retirement_order",
                 "test_legacy_controller_refuses_replacement", "test_watch_publication_keeps_controller")
        if not set(args.main_case) <= set(cases):
            parser.error("--main-case names an unknown case")
        env = os.environ | {"JARVIS_TEST_SKILLS": str(skills), "JARVIS_TEST_NATIVE": str(native),
                            "JARVIS_TEST_SCRIPT": str(skills / "jarvis/scripts/jarvis-session")}

        def rejected(name, case):
            nonlocal completed
            result = subprocess.run([os.environ["JARVIS_TEST_BASH"], str(ROOT / "skills/jarvis/tests/succession.test.sh"),
                                     "--failfast", "SuccessionContract." + case], env=env, capture_output=True, text=True, timeout=180)
            assert result.returncode != 0, name + " passed its planted defect"
            assert "FAILED (failures=" in result.stderr, result.stdout + result.stderr
            if name.startswith("main=") and case == "test_shared_recovery_harnesses":
                assert "shared-controller-record" in result.stderr, result.stdout + result.stderr
            completed += 1
            print("control: rejected=" + name + " case=" + case, flush=True)

        clean_cases = set()
        for name, relative, old, new, case in ([] if args.main_case else controls):
            if case not in clean_cases:
                result = subprocess.run([os.environ["JARVIS_TEST_BASH"], str(ROOT / "skills/jarvis/tests/succession.test.sh"),
                    "--failfast", "SuccessionContract." + case], env=env, capture_output=True, text=True, timeout=180)
                assert result.returncode == 0, "clean case failed: " + case + "\n" + result.stdout + result.stderr
                clean_cases.add(case)
            target = skills / relative
            clean = target.read_text()
            assert clean.count(old) == 1, name
            mutant = clean.replace(old, new)
            assert mutant != clean
            target.write_text(mutant)
            try:
                rejected(name, case)
            finally:
                target.write_text(clean)
            stable = subprocess.run([os.environ["JARVIS_TEST_BASH"], str(ROOT / "skills/jarvis/tests/succession.test.sh"),
                "--failfast", "SuccessionContract." + case], env=env, capture_output=True, text=True, timeout=180)
            assert stable.returncode == 0, "stability failed: " + case + "\n" + stable.stdout + stable.stderr
            print("control: stable=" + case, flush=True)
        if args.main_ref:
            clean_env = {k: v for k, v in os.environ.items() if k not in ("GIT_DIR", "GIT_COMMON_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE")}
            result = subprocess.run(["git", "-C", str(ROOT), "archive", args.main_ref,
                *["skills/" + package + "/scripts" for package in ("jarvis", "orch", "mailbox", "github")]],
                capture_output=True, check=True, timeout=30, env=clean_env)
            baseline = scratch / "main"
            baseline.mkdir()
            with tarfile.open(fileobj=io.BytesIO(result.stdout)) as archive:
                archive.extractall(baseline, filter="data")
            current_env = dict(env)
            env.update(JARVIS_TEST_SKILLS=str(baseline / "skills"),
                       JARVIS_TEST_SCRIPT=str(baseline / "skills/jarvis/scripts/jarvis-session"))
            for case in (args.main_case or cases):
                rejected("main=" + args.main_ref, case)
                stable = subprocess.run([os.environ["JARVIS_TEST_BASH"], str(ROOT / "skills/jarvis/tests/succession.test.sh"),
                    "--failfast", "SuccessionContract." + case], env=current_env, capture_output=True, text=True, timeout=180)
                assert stable.returncode == 0, "main control stability failed: " + case + "\n" + stable.stdout + stable.stderr
                print("control: stable=" + case, flush=True)
    print(f"pass: {completed} fail: 0")


if __name__ == "__main__":
    main()
