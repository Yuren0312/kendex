"""Succession uses real tmux and native identity hooks with deterministic CLI fixtures."""
import json
import shlex
import hashlib
import os
from pathlib import Path
import shutil
import signal
import subprocess
import time
import unittest
from unittest.mock import patch
import session_test
from session_test import SessionContract, SKILLS
from fixtures.harness import native_hook, native_launcher


class SuccessionContract(SessionContract):
    def setUp(self):
        super().setUp()
        self.skills = self.root / "installed/skills"
        for package in ("jarvis", "orch", "mailbox"):
            shutil.copytree(SKILLS / package / "scripts", self.skills / package / "scripts")
        # The dependency answers account readings. The production walk decides
        # which entry to try, its exclusion, and the resulting launch identity.
        lanes = self.skills / "orch/scripts/lanes"
        lanes.write_text('''#!/usr/bin/env python3
import json, sys
from pathlib import Path
args = sys.argv[1:]
config = Path(".lane-fixture.json")
if not config.exists():
    print("{}")
    sys.exit(5)
row = json.loads(config.read_text())
with Path(row["calls"]).open("a") as stream:
    stream.write(json.dumps(args) + "\\n")
harness = args[args.index("--harness") + 1]
floor = float(args[args.index("--min-headroom-pct") + 1])
if row.get("shared") and "--for-overseer" not in args:
    floor = max(floor, 50)
model_wall = harness == "claude" and "--binding-floor" in args
if ("--lane" in args and row["headroom"] <= floor) or harness != row["harness"] or model_wall:
    print('{"walled":1,"unmeasured":0}')
    sys.exit(3)
print(json.dumps({"config_dir": row["account"]}))
''')
        self.script_patch = patch.object(session_test, "SCRIPT", self.skills / "jarvis/scripts/jarvis-session")
        self.script_patch.start()
        self.addCleanup(self.script_patch.stop)

    def handoff(self):
        path = self.home / "state/handoff.md"
        path.parent.mkdir(exist_ok=True)
        contents = "# Handoff\n\n## State\n\nwork: TASK-ref\n\n## Sub-agents\n\nnone\n\n## Instructions in force\n\nnone\n\n## Progress log\n"
        path.write_text(contents)
        return contents

    def test_succession_contract(self):
        # Real tmux and the native hook carrier; CLI behaviour is a fixture.
        # One table covers every launch shape, including deferred kickoff.
        for harness in ("claude", "codex", "copilot", "pi"):
            with self.subTest(harness=harness):
                self.call("start", harness=harness, mode="new")
                self.wait()
                predecessor = json.loads(self.record.read_text())
                self.assertIsInstance(predecessor.get("report_started_at"), int)
                predecessor["report_started_at"] = 1000
                self.record.write_text(json.dumps(predecessor))
                contents = self.handoff()
                self.configure(retiring=predecessor.get("native_process") or predecessor["process"])
                native_count = len(self.started())
                answer, code = self.call("succeed")
                self.assertEqual((answer["state"], answer["reason"], code), ("handing-over", "succession", 0))
                current = self.wait()
                successor = json.loads(self.record.read_text())
                self.assertEqual((current["home"], current["account"], current["harness"]),
                                 (str(self.home), str(self.account), harness))
                for field in ("server", "session"):
                    self.assertEqual(current["terminal"][field], predecessor["terminal"][field])
                self.assertNotEqual(current["terminal"]["window"], predecessor["terminal"]["window"])
                self.assertNotEqual(successor["pending"]["native_session_id"], predecessor["pending"]["native_session_id"])
                self.assertEqual(successor["transfer"]["phase"], "complete")
                self.assertEqual(successor["report_started_at"], predecessor["report_started_at"])
                self.assert_shared_controller(successor)
                acknowledgements = [json.loads(row) for row in self.rows.read_text().splitlines()
                                    if "predecessor_ended" in json.loads(row)]
                self.assertTrue(acknowledgements[-1]["predecessor_ended"])
                self.configure(retiring=None)
                self.assertEqual(Path(successor["transfer"]["handoff"]).read_text(), contents)
                self.assertEqual((self.home / "state/handoff.md").read_text(), contents)
                self.assertEqual(len(self.started()), native_count + 1)
                pid = predecessor["process"]["pid"]
                result = subprocess.run([self.env["JARVIS_TEST_BASH"], str(SKILLS / "orch/scripts/lib/session-backend.sh"),
                                         "worker-live", str(pid), predecessor["process"]["started_at"]],
                                        capture_output=True, env=self.env, timeout=10)
                self.assertEqual(result.returncode, 1)
                self.call("stop")
                self.wait("stopped", persisted_stop=True)

    def assert_shared_controller(self, record):
        shared = self.home / "tmp/workflow-state-oversee.json"
        self.assertTrue(shared.is_file(), "shared-controller-record")
        owner = json.loads(shared.read_text()).get("overseer") or {}
        self.assertIsInstance(owner.get("lifecycle"), dict, "shared-controller-record")
        self.assertEqual(owner["pane"], record["terminal"]["pane"])
        self.assertEqual(owner["session_id"], record["pending"]["native_session_id"])
        self.assertEqual(owner["account"], record["account"])
        self.assertEqual(owner["lifecycle"]["state"], "running")
        self.assertIn("native_process", record, "shared-native-process")
        self.assertEqual(owner.get("harness_pid"), str(record["native_process"]["pid"]), "shared-native-process")
        self.assertEqual(owner.get("harness_start"), record["native_process"]["started_at"], "shared-native-process")
        self.assertEqual(list((self.root / "state/kendex/jarvis").rglob("jarvis-session.json")), [], "second-controller-record")

    def configure(self, **changes):
        path = self.home / ".fixture.json"
        path.write_text(json.dumps(json.loads(path.read_text()) | changes))

    def test_shared_first_launch(self):
        for harness in ("claude", "codex", "copilot", "pi"):
            with self.subTest(harness=harness):
                self.call("start", harness=harness, mode="new")
                self.wait()
                self.assert_shared_controller(json.loads(self.record.read_text()))
                self.call("stop")
                self.wait("stopped", persisted_stop=True)

    def test_shared_registration(self):
        self.configure(hold_prompt=True)
        os.mkfifo(self.gate)
        self.call("start")
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            before = json.loads(self.record.read_text())
            if (before.get("pending") or {}).get("started_at"):
                break
            time.sleep(0.05)
        self.assertTrue((before.get("pending") or {}).get("started_at"), self.session_log())
        terminal = before["terminal"]
        env = self.env | {"TMUX": terminal["server"] + "," + str(before["server_pid"]) + ",0",
                          "TMUX_PANE": terminal["pane"], "CLAUDE_CONFIG_DIR": str(self.account)}
        try:
            pending = subprocess.run([str(SKILLS / "orch/scripts/oversee"), "register", "--account", str(self.account)],
                                     cwd=self.home, env=env, capture_output=True, text=True, timeout=60)
            self.assertEqual(pending.returncode, 1, "registration-native-pending\n" + pending.stdout + pending.stderr)
            owner = json.loads((self.home / "tmp/workflow-state-oversee.json").read_text())["overseer"]
            self.assertNotIn("pane", owner, "registration-native-pending")
            self.assertEqual(pending.stdout.split()[1], "registration-pending")
            self.assertNotIn("oversee: overseer-launched", pending.stdout, "registration-dispatch")
            self.assertNotIn("oversee: name-conflict", pending.stdout + pending.stderr, "registration-dispatch")
        finally:
            with self.gate.open("w") as stream:
                stream.write("1")
            self.gate.unlink()
            self.configure(hold_prompt=False)
        self.wait()
        before = json.loads(self.record.read_text())
        self.assert_shared_controller(before)
        terminal = before["terminal"]
        env = self.env | {"TMUX": terminal["server"] + "," + str(before["server_pid"]) + ",0",
                          "TMUX_PANE": terminal["pane"], "CLAUDE_CONFIG_DIR": str(self.account)}
        for _ in range(2):
            result = subprocess.run([str(SKILLS / "orch/scripts/oversee"), "register", "--account", str(self.account)],
                                    cwd=self.home, env=env, capture_output=True, text=True, timeout=60)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            after = json.loads(self.record.read_text())
            self.assert_shared_controller(after)
            self.assertEqual(after["pending"]["native_session_id"], before["pending"]["native_session_id"])
            self.assertEqual(after["terminal"], before["terminal"])

    def test_registration_selected_record(self):
        scripts = self.orch_world()
        session_cwd = self.root / "session cwd"
        session_cwd.mkdir()
        for name in (".fixture.json", ".fixture-harness.py"):
            shutil.copyfile(self.home / name, session_cwd / name)
        (session_cwd / "tmp/lane-mail/overseer").mkdir(parents=True)
        config = session_cwd / ".fixture.json"
        config.write_text(json.dumps(json.loads(config.read_text()) | {"manual_session": "manual-native"}))
        for index, setting in enumerate((None, "relative-state", str(self.root / "absolute-state"))):
            with self.subTest(state_dir=setting):
                label = self.label + "-register-" + str(index)
                env = dict(self.env)
                env.pop("ORCH_STATE_DIR", None)
                if setting is not None:
                    env["ORCH_STATE_DIR"] = setting
                env["CLAUDE_CONFIG_DIR"] = str(self.account)
                selected_dir = Path(setting) if setting is not None else self.home / "tmp"
                if not selected_dir.is_absolute():
                    selected_dir = self.home / selected_dir
                selected = selected_dir / "workflow-state-oversee.json"
                server = subprocess.run(["tmux", "-L", label, "new-session", "-d", "-s", "fleet", "-c", str(session_cwd),
                                         "-P", "-F", "#{socket_path},#{pid},0 #{pane_id}", self.env["JARVIS_TEST_BASH"],
                                         "--noprofile", "--norc", "-c", shlex.quote(str(self.root / "bin/claude")) + "; exec " + shlex.quote(self.env["JARVIS_TEST_BASH"])],
                                        env=env, capture_output=True, text=True, check=True, timeout=10).stdout.strip()
                address, pane = server.split()
                env.update(TMUX=address, TMUX_PANE=pane, CLAUDE_CONFIG_DIR=str(self.account))
                try:
                    native_row = session_cwd / "tmp/lane-mail/overseer" / ("session-" + address.split(",")[1] + "-" + pane[1:] + ".jsonl")
                    deadline = time.monotonic() + 10
                    native_ready = False
                    while time.monotonic() < deadline:
                        text = native_row.read_text() if native_row.exists() else ""
                        if text.endswith("\n"):
                            native_ready = any(json.loads(line).get("session_id") == "manual-native" for line in text.splitlines())
                        if native_ready:
                            break
                        time.sleep(0.05)
                    self.assertTrue(native_ready, "registration-native-row")
                    registered = subprocess.run([str(scripts / "oversee"), "register", "--account", str(self.account)],
                                                cwd=self.home, env=env, capture_output=True, text=True, timeout=60)
                    self.assertEqual(registered.returncode, 0, registered.stdout + registered.stderr)
                    self.assertTrue(selected.is_file(), "registration-selected-record")
                    owner = json.loads(selected.read_text()).get("overseer") or {}
                    self.assertEqual(owner.get("pane"), pane, "registration-selected-record")
                    self.assertIsInstance(owner.get("lifecycle"), dict, "shared-controller-record")
                    self.assertEqual(owner["lifecycle"]["home"], str(self.home))
                    self.assertEqual(owner["cwd"], str(session_cwd))
                    self.assertEqual(owner["harness"], "claude")
                    self.assertFalse((session_cwd / "tmp/workflow-state-oversee.json").exists(), "registration-second-record")
                finally:
                    self.stop_server(label=label)

    def test_legacy_controller_refuses_replacement(self):
        self.call("start")
        self.wait()
        before = self.record.read_text()
        key = hashlib.sha256(os.fsencode(str(self.home))).hexdigest()
        legacy = self.root / "state/kendex/jarvis" / key / "jarvis-session.json"
        legacy.parent.mkdir(parents=True, exist_ok=True)
        legacy.write_text(before)
        try:
            answer, code = self.call("start", mode="new")
            self.assertEqual((answer["state"], answer["reason"], code), ("blocked", "record-unreadable", 1), "legacy-controller-authority")
            self.assertEqual(len(self.started()), 1)
            self.assertEqual(self.record.read_text(), before)
            # A previous package's pending worker can acquire more native
            # resources. Retirement must wait until that exact worker ends.
            with subprocess.Popen(["sleep", "60"], env=self.env) as worker:
                identity = subprocess.run([self.env["JARVIS_TEST_BASH"], str(SKILLS / "orch/scripts/lib/session-backend.sh"),
                                           "process", str(worker.pid)], env=self.env, capture_output=True, text=True, timeout=10, check=True)
                legacy.write_text(json.dumps(json.loads(before) | {"app_off": True, "worker": json.loads(identity.stdout)}))
                held = subprocess.run([str(SKILLS / "orch/scripts/controller-session"), "retire-legacy", "--home", str(self.home)],
                                      env=self.env, capture_output=True, text=True, timeout=60)
                worker.terminate()
                worker.wait(timeout=10)
                self.assertEqual((held.returncode, json.loads(held.stdout)["reason"]), (1, "record-unreadable"))
                self.assertTrue(legacy.exists())
            legacy.write_text(json.dumps(json.loads(before) | {"app_off": True}))
            # An old desktop can issue another Start while its exact prior
            # controller retires. Its new worker remains an old authority.
            hold, events = self.root / "legacy-retire-hold", self.root / "legacy-retire-events"
            hold.touch()
            real = shutil.which("tmux")
            wrapper = self.root / "bin/tmux"
            wrapper.write_text("#!" + self.env["JARVIS_TEST_BASH"] + "\nset -euo pipefail\n"
                + "for arg in \"$@\"; do if [[ $arg == if-shell && -f " + shlex.quote(str(hold)) + " ]]; then "
                + "printf 'retiring\\n' >> " + shlex.quote(str(events)) + "; while [[ -f " + shlex.quote(str(hold))
                + " ]]; do sleep 0.05; done; fi; done\nexec " + shlex.quote(real) + ' "$@"\n')
            wrapper.chmod(0o755)
            request = subprocess.Popen([str(SKILLS / "orch/scripts/controller-session"), "retire-legacy", "--home", str(self.home)],
                                       env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                self.await_rows(events, 1)
                with subprocess.Popen(["sleep", "60"], env=self.env) as worker:
                    try:
                        identity = subprocess.run([self.env["JARVIS_TEST_BASH"], str(SKILLS / "orch/scripts/lib/session-backend.sh"),
                                                   "process", str(worker.pid)], env=self.env, capture_output=True, text=True, timeout=10, check=True)
                        renewed = json.loads(before) | {"app_off": True, "worker": json.loads(identity.stdout)}
                        renewed["generation"] += 1
                        legacy.write_text(json.dumps(renewed))
                        hold.unlink()
                        output, error = request.communicate(timeout=60)
                        self.assertEqual((request.returncode, json.loads(output)["reason"]),
                                         (1, "record-unreadable"), "legacy-retirement-generation: " + error)
                        self.assertEqual(json.loads(legacy.read_text()), renewed)
                    finally:
                        worker.terminate()
                        worker.wait(timeout=10)
            finally:
                hold.unlink(missing_ok=True)
                if request.poll() is None:
                    request.communicate(timeout=60)
                wrapper.unlink()
            legacy.write_text(json.dumps(renewed | {"worker": None}))
            retired = subprocess.run([str(SKILLS / "orch/scripts/controller-session"), "retire-legacy", "--home", str(self.home)],
                                     env=self.env, capture_output=True, text=True, timeout=60)
            self.assertEqual(retired.returncode, 0, retired.stdout + retired.stderr)
            self.assertEqual(json.loads(retired.stdout)["state"], "off")
            self.assertFalse(legacy.exists())
            answer, code = self.call("start")
            self.assertEqual((answer["reason"], code), ("app-off", 1))
            self.call("start", origin="app-on")
            self.wait()
            self.assert_shared_controller(json.loads(self.record.read_text()))
        finally:
            legacy.unlink(missing_ok=True)

    def orch_world(self):
        for args in (("init", "-q"), ("config", "gc.auto", "0"), ("config", "maintenance.auto", "false")):
            result = subprocess.run(["git", "-C", str(self.home), *args], env=self.env, capture_output=True, text=True, timeout=20)
            self.assertEqual(result.returncode, 0, result.stderr)
        skills = self.home / ".agents/skills"
        for package in ("orch", "mailbox", "github"):
            shutil.copytree(SKILLS / package / "scripts", skills / package / "scripts")
        scripts = skills / "orch/scripts"
        (scripts / "oversee-watch").unlink()
        install = 'TMP_ROOT=$1; source "$2/skills/orch/tests/lib/watch-fixture.sh"; fixture_watch_neighbor "$3/oversee"'
        result = subprocess.run([self.env["JARVIS_TEST_BASH"], "-c", install, "fixture", str(self.root), str(session_test.ROOT), str(scripts)],
                                capture_output=True, text=True, env=self.env, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        # This suite judges the lifecycle's consumption of the account picker.
        # The picker and preference policy keep their own existing suites.
        picker = scripts / "lanes"
        picker.write_text("#!" + self.env["JARVIS_TEST_BASH"] + "\nset -euo pipefail\n"
            + "account=$(jq -r '.picked' .fixture.json)\n"
            + "jq -cn --arg account \"$account\" '{config_dir:$account,walled:0,unmeasured:0}'\n")
        picker.chmod(0o755)
        self.configure(skills=str(skills), picked=str(self.account))
        operator = self.root / "operator"
        operator.mkdir(exist_ok=True)
        self.env["HOME"] = str(operator)
        (self.home / "tmp/lane-mail/overseer").mkdir(parents=True, exist_ok=True)
        pi_root = operator / ".pi/agent"
        pi_root.mkdir(parents=True, exist_ok=True)
        (pi_root / "settings.json").write_text('{"compaction":{"enabled":false}}')
        carrier = self.home / ".pi/packages/@vanillagreen/pi-hooks/extensions"
        shutil.copytree(session_test.ROOT / "pi-extensions/pi-hooks/extensions", carrier)
        self.orch_scripts = scripts
        self.watch_state = self.home / "tmp/workflow-state-oversee.json"
        self.env["PATH"] = str(session_test.ROOT / "skills/orch/tests/fixtures/tier-model") + os.pathsep + self.env["PATH"]
        return scripts

    def orch_call(self, *args):
        result = subprocess.run([str(self.orch_scripts / args[0]), *args[1:]], cwd=self.home,
                                env=self.env, capture_output=True, text=True, timeout=90)
        self.remember_worker()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr + "\n" + self.session_log())
        return result

    def tearDown(self):
        try:
            if hasattr(self, "watch_state") and self.watch_state.exists():
                shell = 'source "$1/skills/orch/tests/lib/watch-fixture.sh"; fixture_watch_stop "$2"'
                subprocess.run([self.env["JARVIS_TEST_BASH"], "-c", shell, "fixture", str(session_test.ROOT), str(self.watch_state)],
                               env=self.env, capture_output=True, timeout=30)
        finally:
            super().tearDown()

    def test_shared_orch_launch_and_recovery(self):
        scripts = self.orch_world()
        self.handoff()
        tracker = self.root / "fixture-tracker"
        tracker.write_text("#!" + self.env["JARVIS_TEST_BASH"] + "\nprintf '[]\\n'\n")
        tracker.chmod(0o755)
        self.env.update(GH_REPO="fixture/repository", LINEAR_TEAM="FIXTURE", ORCH_OVERSEER_DEAD_PASSES="1",
                        OVERSEE_WATCH_TRACKER=str(tracker))
        session_cwd = self.home / "subdir"
        (session_cwd / "state").mkdir(parents=True)
        session_handoff = "subdirectory handoff: TASK-ref\n"
        (session_cwd / "state/handoff.md").write_text(session_handoff)
        (session_cwd / ".fixture.json").symlink_to(self.home / ".fixture.json")
        shutil.copyfile(self.home / ".fixture-harness.py", session_cwd / ".fixture-harness.py")
        # Keep an unrelated window alive on the fixture-owned server. A dead
        # controller must never take that process as its replacement identity.
        server = subprocess.run(["tmux", "-L", self.label, "new-session", "-d", "-s", "fleet", "-P", "-F", "#{socket_path},#{pid},0",
                                 self.env["JARVIS_TEST_BASH"], "--noprofile", "--norc"], env=self.env, capture_output=True,
                                text=True, timeout=10, check=True).stdout.strip()
        self.env.update(TMUX=server, ORCH_TMUX_SESSION="fleet", ORCH_OVERSEER_PREFERENCE="claude:fable:high")
        self.orch_call("oversee", "launch", "--session", "fleet", "--cwd", str(session_cwd), "--handoff", "state/handoff.md", "--wait-secs", "30")
        owner = json.loads((self.home / "tmp/workflow-state-oversee.json").read_text())["overseer"]
        self.assertIsNotNone(owner.get("lifecycle"), "shared-controller-record")
        first = json.loads(self.record.read_text())
        self.assert_shared_controller(first)
        self.assertEqual(json.loads((self.root / "watch-policy.json").read_text()),
                         {"repo":"fixture/repository", "team":"FIXTURE", "dead_passes":"1", "tracker":str(tracker)},
                         "watch-policy-environment")
        self.assertEqual(first["home"], str(self.home))
        self.assertEqual(owner["cwd"], str(session_cwd))
        self.assertEqual(Path(first["transfer"]["handoff"]).read_text(), session_handoff, "session-handoff")
        self.handoff()
        self.configure(retiring=first.get("native_process") or first["process"])
        self.orch_call("oversee", "launch", "--predecessor", first["terminal"]["pane"], "--cwd", str(session_cwd),
                       "--handoff", "state/handoff.md", "--wait-secs", "30")
        second = json.loads(self.record.read_text())
        self.assert_shared_controller(second)
        self.assertEqual(Path(second["transfer"]["handoff"]).read_text(), session_handoff, "session-handoff")
        self.assertNotEqual(first["pending"]["native_session_id"], second["pending"]["native_session_id"])
        self.configure(retiring=None)
        # Stop through the shared process identity owner, leaving the recorded
        # command for the production dead-pane entry point to replay.
        stop = subprocess.run([self.env["JARVIS_TEST_BASH"], str(scripts / "lib/session-backend.sh"), "stop-process",
                               str(second["native_process"]["pid"]), second["native_process"]["started_at"], second["harness"]],
                              env=self.env, capture_output=True, text=True, timeout=30)
        self.assertEqual(stop.returncode, 0, stop.stderr)
        command = json.loads(self.watch_state.read_text())["overseer"]["launch_line"]
        line = self.root / "line.txt"
        line.write_text(command)
        self.orch_call("oversee-succeed", "--dead-pane", second["terminal"]["pane"], "--line-file", str(line), "--wait-secs", "30")
        recovered = json.loads(self.record.read_text())
        self.assert_shared_controller(recovered)
        self.assertEqual(recovered["account"], second["account"])
        fresh = self.root / "fresh-account"
        fresh.mkdir()
        self.configure(picked=str(fresh), retiring=recovered.get("native_process") or recovered["process"])
        self.orch_call("oversee-succeed", "--walled-pane", recovered["terminal"]["pane"], "--harness", "claude",
                       "--handoff", "state/handoff.md", "--wait-secs", "30", "--", "--dangerously-skip-permissions")
        walled = json.loads(self.record.read_text())
        self.assert_shared_controller(walled)
        self.assertEqual(walled["account"], str(fresh))
        acknowledgements = [json.loads(row)["predecessor_ended"] for row in self.rows.read_text().splitlines()
                            if "predecessor_ended" in json.loads(row)]
        self.assertTrue(acknowledgements)
        self.assertTrue(all(acknowledgements), "native-before-retirement")
        self.configure(idle=True, retiring=walled.get("native_process") or walled["process"])
        failed = subprocess.run([str(scripts / "oversee"), "launch", "--predecessor", walled["terminal"]["pane"],
                                 "--cwd", str(session_cwd), "--handoff", "state/handoff.md", "--wait-secs", "8"],
                                cwd=self.home, env=self.env, capture_output=True, text=True, timeout=60)
        self.assertEqual(failed.returncode, 1, failed.stdout + failed.stderr)
        stopped = json.loads(self.record.read_text())
        self.assertEqual(stopped["state"], "failed")
        self.assertTrue(stopped["transfer"]["retired"])
        self.assertNotIn("pane", json.loads(self.watch_state.read_text())["overseer"], "retired-controller")
        self.assertNotEqual((stopped.get("history") or {}).get("pending", {}).get("native_session_id"),
                            walled["pending"]["native_session_id"], "retired-history")
        self.assertEqual(Path(stopped["transfer"]["handoff"]).read_text(), session_handoff, "session-handoff")
        self.configure(idle=False, retiring=None)
        self.orch_call("oversee", "launch", "--session", "fleet", "--cwd", str(session_cwd),
                       "--handoff", "state/handoff.md", "--wait-secs", "30")
        fresh = json.loads(self.record.read_text())
        self.assert_shared_controller(fresh)
        self.assertNotEqual(fresh["pending"]["native_session_id"], walled["pending"]["native_session_id"])

    def test_shared_recovery_harnesses(self):
        scripts = self.orch_world()
        self.handoff()
        for harness in ("claude", "codex", "copilot", "pi"):
            with self.subTest(harness=harness):
                self.configure(retiring=None, picked=str(self.account))
                server_label = self.label + "-" + harness
                self.addCleanup(self.stop_server, label=server_label)
                server = subprocess.run(["tmux", "-L", server_label, "new-session", "-d", "-s", "fleet", "-P", "-F", "#{socket_path},#{pid},0",
                                         self.env["JARVIS_TEST_BASH"], "--noprofile", "--norc"], env=self.env, capture_output=True,
                                        text=True, timeout=10, check=True).stdout.strip()
                preference = {"claude":"claude:fable:high", "codex":"codex:gpt-5:high",
                              "copilot":"copilot:gpt-5:high", "pi":"pi:pi-claude/claude-fable-5-1:high"}[harness]
                self.env.update(TMUX=server, ORCH_TMUX_SESSION="fleet", ORCH_OVERSEER_PREFERENCE=preference,
                                ORCH_QUESTION_TOOL="off")
                if harness == "pi":
                    # Orch's existing permission policy refuses unattended Pi
                    # first launch; the user's explicit desktop Start can use it.
                    count = len(self.started())
                    refused = subprocess.run([str(scripts / "oversee"), "launch", "--session", "fleet", "--cwd", str(self.home),
                                              "--handoff", "state/handoff.md", "--wait-secs", "30"],
                                             env=self.env, cwd=self.home, capture_output=True, text=True, timeout=60)
                    self.assertEqual(refused.returncode, 3, refused.stdout + refused.stderr)
                    self.assertEqual(len(self.started()), count)
                    self.assertFalse(json.loads(self.watch_state.read_text())["overseer"].get("pane"))
                    self.call("start", harness="pi", mode="new")
                    self.wait()
                else:
                    self.orch_call("oversee", "launch", "--session", "fleet", "--cwd", str(self.home),
                                   "--handoff", "state/handoff.md", "--wait-secs", "30")
                owner = json.loads(self.watch_state.read_text()).get("overseer") or {}
                self.assertIsNotNone(owner.get("lifecycle"), "shared-controller-record")
                first = json.loads(self.record.read_text())
                self.assert_shared_controller(first)
                if harness == "codex":
                    self.assertIn("features.default_mode_request_user_input=false", self.started()[-1]["argv"],
                                  "native-question-policy")
                terminal = first["terminal"]
                keep = subprocess.run(["tmux", "-S", terminal["server"], "new-window", "-d", "-t", "=" + terminal["session"],
                                       "-P", "-F", "#{pane_id}", self.env["JARVIS_TEST_BASH"], "--noprofile", "--norc"],
                                      env=self.env, capture_output=True, text=True, timeout=10, check=True).stdout.strip()
                self.env.update(TMUX=terminal["server"] + "," + str(first["server_pid"]) + ",0", TMUX_PANE=terminal["pane"],
                                ORCH_TMUX_SESSION=terminal["session"])
                self.orch_call("oversee", "register", "--account", str(self.account))
                registered = json.loads(self.record.read_text())
                self.assert_shared_controller(registered)
                stop = subprocess.run([self.env["JARVIS_TEST_BASH"], str(scripts / "lib/session-backend.sh"), "stop-process",
                                       str(registered["native_process"]["pid"]), registered["native_process"]["started_at"], harness],
                                      env=self.env, capture_output=True, text=True, timeout=30)
                self.assertEqual(stop.returncode, 0, stop.stderr)
                self.wait("stopped", "ended")
                # The shipped orch record predates the lifecycle member.
                # Keep its real completed-run receipt and owned pane intact.
                self.orch_call("workflow-state", "update", "oversee", ".overseer |= del(.lifecycle)")
                legacy, _ = self.call("status")
                self.assertEqual((legacy["state"], legacy["reason"]), ("stopped", "ended"), "legacy-native-exit")
                line = self.root / "line.txt"
                line.write_text(json.loads((self.home / "tmp/workflow-state-oversee.json").read_text())["overseer"]["launch_line"])
                self.orch_call("oversee-succeed", "--dead-pane", terminal["pane"], "--line-file", str(line), "--wait-secs", "30")
                recovered = json.loads(self.record.read_text())
                self.assert_shared_controller(recovered)
                self.assertEqual((recovered["harness"], recovered["account"]), (harness, str(self.account)))
                self.env["TMUX_PANE"] = recovered["terminal"]["pane"]
                # Registration reads the native event row's observed model.
                self.orch_call("oversee", "register", "--account", str(self.account))
                recovered = json.loads(self.record.read_text())
                fresh = self.root / ("fresh-" + harness)
                fresh.mkdir()
                self.configure(retiring=recovered.get("native_process") or recovered["process"], picked=str(fresh))
                preference = "pi:pi-claude/claude-fable-5-1:high" if harness == "pi" else "claude:fable:high"
                self.env["ORCH_OVERSEER_PREFERENCE"] = preference
                flags = {"claude":["--dangerously-skip-permissions"], "codex":["--yolo"], "copilot":["--allow-all"], "pi":[]}[harness]
                self.orch_call("oversee-succeed", "--walled-pane", recovered["terminal"]["pane"], "--harness", harness,
                               "--handoff", "state/handoff.md", "--wait-secs", "30", "--", *flags)
                walled = json.loads(self.record.read_text())
                self.assert_shared_controller(walled)
                self.assertEqual(walled["account"], str(fresh))
                alive = subprocess.run(["tmux", "-S", terminal["server"], "display-message", "-p", "-t", keep, "#{pane_id}"],
                                       env=self.env, capture_output=True, text=True, timeout=10)
                self.assertEqual(alive.stdout.strip(), keep)
                self.configure(retiring=None)
                self.call("stop")
                self.wait("stopped", persisted_stop=True)
                # The unrelated window has an independent lifetime.
                self.stop_server(socket=terminal["server"])

    def test_orch_retirement_order(self):
        self.orch_world()
        self.handoff()
        self.call("start")
        self.wait()
        predecessor = json.loads(self.record.read_text())
        terminal = predecessor["terminal"]
        self.env.update(TMUX=terminal["server"] + "," + str(predecessor["server_pid"]) + ",0", TMUX_PANE=terminal["pane"],
                        ORCH_OVERSEER_PREFERENCE="claude:fable:high", ORCH_TMUX_SESSION=terminal["session"])
        self.orch_call("oversee", "register", "--account", str(self.account))
        self.assert_shared_controller(predecessor)
        # Refuse the exact predecessor stop before it can kill the native
        # controller. Cleaning the newly acquired pane must preserve it.
        refused_bash = self.root / "refuse-native-stop-bash"
        refused_bash.write_text("#!" + self.env["JARVIS_TEST_BASH"] + "\nset -euo pipefail\n"
            + 'if [[ ${1##*/} == session-backend.sh && ${2:-} == stop-process && ${3:-} == '
            + str(predecessor["process"]["pid"]) + ' ]]; then exit 1; fi\nexec '
            + shlex.quote(self.env["JARVIS_TEST_BASH"]) + ' "$@"\n')
        refused_bash.chmod(0o755)
        replacement_account = self.root / "refused-account"
        replacement_account.mkdir()
        launches = len(self.started())
        self.call("start", account=replacement_account, own_worker=True, backend_bash=str(refused_bash))
        self.await_worker_result()
        native = predecessor["native_process"]
        alive = subprocess.run([self.env["JARVIS_TEST_BASH"], str(self.orch_scripts / "lib/session-backend.sh"),
                                "worker-live", str(native["pid"]), native["started_at"]],
                               env=self.env, capture_output=True, timeout=10)
        self.assertEqual(alive.returncode, 0, "before-retirement-keeps-native")
        self.assertEqual(len(self.started()), launches, "native-before-retirement")
        self.assert_shared_controller(json.loads(self.record.read_text()))
        refused_runner = self.home / "tmp/oversee-watch.runner.part"
        refused_runner.mkdir()
        try:
            failed = subprocess.run([str(self.orch_scripts / "oversee"), "launch", "--predecessor", terminal["pane"],
                                     "--handoff", "state/handoff.md", "--wait-secs", "30"],
                                    cwd=self.home, env=self.env, capture_output=True, text=True, timeout=60)
            self.assertEqual(failed.returncode, 1, "replacement-failed-retained\n" + failed.stdout + failed.stderr)
            kept = json.loads(self.record.read_text())
            self.assert_shared_controller(kept)
            self.assertEqual(kept["terminal"], terminal, "replacement-failed-retained")
            self.assertEqual(kept["pending"]["native_session_id"], predecessor["pending"]["native_session_id"])
            owner = json.loads(self.watch_state.read_text())["overseer"]
            rows = Path(owner["session_rows"])
            count = len(rows.read_text().splitlines())
            callback = ('source "$1/mailbox/scripts/lib/file-lock.sh"; source "$1/mailbox/scripts/lib/mailbox-append.sh"; '
                        'source "$1/orch/scripts/lib/lane-state.sh"; source "$1/orch/scripts/lib/lane-context.sh"; '
                        'source "$1/orch/scripts/lib/session-rows.sh"; session_rows_write "$PWD" claude Stop')
            relay = Path(session_test.HARNESS).parent / ("hook-" + str(kept["native_process"]["pid"]) + ".sock")
            with patch.dict(os.environ, {"JARVIS_TEST_HOOK_SOCKET": str(relay)}):
                native_hook([self.env["JARVIS_TEST_BASH"], "-c", callback, "fixture", str(self.skills)],
                            {"session_id": kept["pending"]["native_session_id"]})
            self.assertEqual(len(rows.read_text().splitlines()), count + 1, "retained-native-row")
            # Two refused operations retain waiting resources above the live
            # controller. Its real callbacks still belong to the sole record.
            with self.refuse_teardown():
                failed = subprocess.run([str(self.orch_scripts / "oversee"), "launch", "--predecessor", terminal["pane"],
                                         "--handoff", "state/handoff.md", "--wait-secs", "30"],
                                        cwd=self.home, env=self.env, capture_output=True, text=True, timeout=60)
                self.assertEqual(failed.returncode, 1, failed.stdout + failed.stderr)
                self.call("start", mode="new")
                held = self.await_worker_result()
                generation = held["generation"]
                failed = subprocess.run([str(self.orch_scripts / "oversee"), "launch", "--predecessor", terminal["pane"],
                                         "--handoff", "state/handoff.md", "--wait-secs", "30"],
                                        cwd=self.home, env=self.env, capture_output=True, text=True, timeout=60)
                self.assertEqual(failed.returncode, 1, failed.stdout + failed.stderr)
                held = self.await_worker_result()
                self.assertEqual(held["generation"], generation + 1, "retained-retry-controller")
                owner = json.loads(self.watch_state.read_text())["overseer"]
                self.assertEqual(owner.get("pane"), terminal["pane"], "native-before-retirement")
                resources = []
                node = held
                while node:
                    resources.extend(node[key] for key in ("process", "native_process") if node.get(key))
                    node = node.get("predecessor")
                count = len(rows.read_text().splitlines())
                with patch.dict(os.environ, {"JARVIS_TEST_HOOK_SOCKET": str(relay)}):
                    native_hook([self.env["JARVIS_TEST_BASH"], "-c", callback, "fixture", str(self.skills)],
                                {"session_id": predecessor["pending"]["native_session_id"]})
                self.assertEqual(len(rows.read_text().splitlines()), count + 1, "retained-native-chain")
                native = predecessor["native_process"]
                stopped = subprocess.run([self.env["JARVIS_TEST_BASH"], str(self.orch_scripts / "lib/session-backend.sh"),
                                          "stop-process", str(native["pid"]), native["started_at"], "claude"],
                                         env=self.env, capture_output=True, text=True, timeout=30)
                self.assertEqual(stopped.returncode, 0, stopped.stderr)
                deadline = time.monotonic() + 10
                while time.monotonic() < deadline:
                    exited = (json.loads(self.watch_state.read_text()).get("overseer") or {}).get("exit") or {}
                    if (exited.get("run") or {}).get("harness_pid") == str(native["pid"]):
                        break
                    time.sleep(0.05)
                self.assertEqual((exited.get("run") or {}).get("harness_pid"), str(native["pid"]), "retained-native-exit-chain")
            self.call("start", mode="new")
            self.wait()
            for resource in resources:
                ended = subprocess.run([self.env["JARVIS_TEST_BASH"], str(self.orch_scripts / "lib/session-backend.sh"),
                                        "worker-live", str(resource["pid"]), resource["started_at"]],
                                       env=self.env, capture_output=True, timeout=10)
                self.assertEqual(ended.returncode, 1, "native-before-retirement")
            predecessor = json.loads(self.record.read_text())
            self.assert_shared_controller(predecessor)
            terminal = predecessor["terminal"]
            self.env["TMUX_PANE"] = terminal["pane"]
        finally:
            refused_runner.rmdir()
        self.configure(retiring=predecessor.get("native_process") or predecessor["process"])
        result = subprocess.run([str(self.orch_scripts / "oversee"), "launch", "--predecessor", terminal["pane"],
                                 "--cwd", str(self.home), "--handoff", "state/handoff.md", "--wait-secs", "10"],
                                cwd=self.home, env=self.env, capture_output=True, text=True, timeout=60)
        acknowledgements = [json.loads(row)["predecessor_ended"] for row in self.rows.read_text().splitlines()
                            if "predecessor_ended" in json.loads(row)]
        self.assertTrue(acknowledgements, result.stdout + result.stderr)
        self.assertTrue(all(acknowledgements), "native-before-retirement")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr + self.session_log())
        self.configure(retiring=None)

    def test_shared_controller_mail(self):
        scripts = self.orch_world()
        self.handoff()
        hook = self.home / ".claude/hooks/lane-mail-check.sh"
        hook.parent.mkdir(parents=True)
        shutil.copyfile(session_test.ROOT / "hooks/lane-mail-check.sh", hook)
        hook.chmod(0o755)
        self.call("start")
        self.wait()
        current = json.loads(self.record.read_text())
        self.assert_shared_controller(current)
        terminal = current["terminal"]
        unrelated = subprocess.run(["tmux", "-S", terminal["server"], "new-window", "-d", "-t", "=" + terminal["session"],
                                    "-P", "-F", "#{pane_id}", self.env["JARVIS_TEST_BASH"], "--noprofile", "--norc"],
                                   env=self.env, capture_output=True, text=True, timeout=10, check=True).stdout.strip()
        text = self.root / "directive.txt"
        text.write_text("shared-controller-directive")
        sent = subprocess.run([str(scripts.parent.parent / "mailbox/scripts/lane-mail"), "send", "--item", "overseer",
                               "--directive", "--file", str(text), "--root", str(self.home)],
                              cwd=self.home, env=self.env, capture_output=True, text=True, timeout=30)
        self.assertEqual(sent.returncode, 0, sent.stdout + sent.stderr)
        env = self.env | {"TMUX": terminal["server"] + "," + str(current["server_pid"]) + ",0",
                          "CLAUDE_PROJECT_DIR": str(self.home), "CLAUDE_CONFIG_DIR": str(self.account)}
        payload = json.dumps({"session_id": current["pending"]["native_session_id"],
                              "transcript_path": current["pending"].get("session_file", "")})
        observed = []
        for pane, identity in ((unrelated, "unrelated-native"), (terminal["pane"], current["pending"]["native_session_id"]),
                               (terminal["pane"], current["pending"]["native_session_id"])):
            message = json.loads(payload) | {"session_id": identity}
            result = subprocess.run([str(hook), "deliver"], cwd=self.home, env=env | {"TMUX_PANE": pane},
                                    input=json.dumps(message), capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            observed.append("shared-controller-directive" in result.stdout + result.stderr)
        self.assertEqual(observed, [False, True, False], "controller-mail-owner")
        os.mkfifo(self.gate)
        self.call("succeed")
        self.await_launches(2)
        pending = json.loads(self.record.read_text())
        owner = json.loads((self.home / "tmp/workflow-state-oversee.json").read_text())["overseer"]
        self.assertNotIn("pane", owner, "pending-controller-mail")
        text.write_text("shared-controller-directive-queued")
        sent = subprocess.run([str(scripts.parent.parent / "mailbox/scripts/lane-mail"), "send", "--item", "overseer",
                               "--directive", "--file", str(text), "--root", str(self.home)],
                              cwd=self.home, env=self.env, capture_output=True, text=True, timeout=30)
        self.assertEqual(sent.returncode, 0, sent.stdout + sent.stderr)
        waiting = subprocess.run([str(hook), "deliver"], cwd=self.home,
                                 env=env | {"TMUX_PANE": pending["terminal"]["pane"]},
                                 input=json.dumps({"session_id": pending["pending"]["native_session_id"]}),
                                 capture_output=True, text=True, timeout=30)
        self.assertNotIn("shared-controller-directive", waiting.stdout + waiting.stderr)
        with self.gate.open("w") as stream:
            stream.write("1")
        self.gate.unlink()
        self.wait()
        successor = json.loads(self.record.read_text())
        self.assert_shared_controller(successor)
        self.assertNotEqual(successor["terminal"]["pane"], terminal["pane"])
        delivered = subprocess.run([str(hook), "deliver"], cwd=self.home,
                                   env=env | {"TMUX_PANE": successor["terminal"]["pane"]},
                                   input=json.dumps({"session_id": successor["pending"]["native_session_id"],
                                       "transcript_path": successor["pending"].get("session_file", "")}),
                                   capture_output=True, text=True, timeout=30)
        self.assertIn("shared-controller-directive", delivered.stdout + delivered.stderr)

    def test_watch_publication_keeps_controller(self):
        scripts = self.orch_world()
        self.handoff()
        self.call("start")
        self.wait()
        before = json.loads(self.record.read_text())
        terminal = before["terminal"]
        self.env.update(TMUX=terminal["server"] + "," + str(before["server_pid"]) + ",0", TMUX_PANE=terminal["pane"])
        self.orch_call("oversee", "register", "--account", str(self.account))
        # The watch consumes a known native binding. Populate it through the
        # same owner the native hook calls, using this fixture's actual id.
        bind = ('SCRIPT_DIR=$1; source "$1/lib/lane-context.sh"; source "$1/lib/overseer-launch.sh"; '
                'DEP_ERR=$(mktemp); trap \'rm -f -- "${DEP_ERR:?}"\' EXIT; '
                'ol_record_heal "$2" "$3" "$4" claude "$5" "$6"')
        bound = subprocess.run([self.env["JARVIS_TEST_BASH"], "-euo", "pipefail", "-c", bind, "fixture", str(scripts),
                                str(before["server_pid"]), terminal["pane"], str(before["server_started_at"]),
                                before["effective_home"], before["pending"]["native_session_id"]],
                               cwd=self.home, env=self.env, capture_output=True, text=True, timeout=30)
        self.assertEqual(bound.returncode, 0, bound.stdout + bound.stderr)
        unrelated = subprocess.run(["tmux", "-S", terminal["server"], "new-window", "-d", "-t", "=" + terminal["session"],
                                    "-P", "-F", "#{pane_id}", self.env["JARVIS_TEST_BASH"], "--noprofile", "--norc"],
                                   env=self.env, capture_output=True, text=True, timeout=10, check=True).stdout.strip()
        # Both revisions expose this public command; a migrated record field
        # cannot be a prerequisite for exercising the baseline watch writer.
        self.env["ORCH_OVERSEER_PREFERENCE"] = "claude:fable:high"
        line = self.orch_call("oversee-succeed", "--print-launch-line", "--handoff", "state/handoff.md",
                              "--", "--dangerously-skip-permissions").stdout.strip()
        printer = self.root / "print-line"
        printer.write_text("#!" + self.env["JARVIS_TEST_BASH"] + "\nprintf '%s\\n' " + shlex.quote(line) + "\n")
        printer.chmod(0o755)
        shell = ('SCRIPT_DIR=$1; source "$SCRIPT_DIR/lib/lane-context.sh"; source "$SCRIPT_DIR/lib/watch-overseer-record.sh"; '
                 'WORKFLOW_STATE="$SCRIPT_DIR/workflow-state"; WORKFLOW_STATE_ARGS=(); SUCCEED=$2; '
                 'HANDOFF=state/handoff.md; OVERSEER_HARNESS=claude; OVERSEER_FLAGS=(); '
                 'overseer_record_notice() { printf "notice=%s\\n" "$3" >&2; }; overseer_command_record')
        env = self.env | {"TMUX": terminal["server"] + "," + str(before["server_pid"]) + ",0"}
        for pane in (terminal["pane"], unrelated):
            result = subprocess.run([self.env["JARVIS_TEST_BASH"], "-euo", "pipefail", "-c", shell, "fixture", str(scripts), str(printer)],
                                    cwd=self.home, env=env | {"TMUX_PANE": pane}, capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            after = json.loads((self.home / "tmp/workflow-state-oversee.json").read_text())["overseer"]
            self.assertEqual(after.get("pane"), terminal["pane"], "watch-controller-owner")
            self.assert_shared_controller(json.loads(self.record.read_text()))
            self.assertEqual(after.get("session_id"), before["pending"]["native_session_id"], "watch-controller-native")

    def test_succession_identity(self):
        self.handoff()
        self.call("start")
        original = self.wait()
        record = json.loads(self.record.read_text())
        identity = dict(record["process"])
        record["process"]["started_at"] = "a different start time"
        self.record.write_text(json.dumps(record))
        self.call("succeed")
        saved = self.await_worker_result()
        answer, _ = self.call("status")
        self.assertEqual((answer["state"], answer["terminal"]), ("running", original["terminal"]))
        self.assertEqual(len(self.started()), 1)
        self.assertEqual(saved["pending"]["native_session_id"], record["pending"]["native_session_id"])
        saved["process"] = identity
        self.record.write_text(json.dumps(saved))

    def test_account_succession(self):
        for state, headroom, target in (("walled", 0, "claude"), ("walled", 0, "codex"), ("low", 4, "codex"),
                                        ("walled", 0, "copilot"), ("shared-reserve", 20, "claude"), ("app-missing", 0, "codex")):
            with self.subTest(state=state, target=target):
                self.call("start", mode="new")
                previous = self.wait()
                before = json.loads(self.record.read_text())
                native_count = len(self.started())
                predecessor_argv = self.started()[-1]["argv"]
                contents = self.handoff()
                account = self.root / ("next-" + state + "-" + target)
                account.mkdir()
                calls = self.root / ("picks-" + state + "-" + target)
                (self.home / ".lane-fixture.json").write_text(json.dumps({"harness": target, "account": str(account), "calls": str(calls), "headroom": headroom,
                                                                          "shared": state == "shared-reserve"}))
                (self.home / "kendex.settings.toml").write_text('[env]\nORCH_OVERSEER_PREFERENCE = "claude:standard:high,codex:standard:high,copilot:standard:high"\n')
                # Model classification is kendex's external boundary. Preserve
                # native defaults for these class entries, as its protocol does.
                kendex = self.root / "bin/kendex"
                kendex.write_text('#!/usr/bin/env python3\nimport json, sys\nprint(json.dumps({"protocol":"model-resolution-v1","request":{"tag":"class","class":"standard"},"resolution":{"diagnostics":[],"native_selector":"sonnet" if sys.argv[2] == "claude" else None}}))\n')
                kendex.chmod(0o755)
                if state == "app-missing":
                    missing = self.root / "bin" / target
                    missing.unlink()
                    # Keep native tooling, but remove every installed spelling
                    # of the selected harness from this request's PATH.
                    limited = self.root / "limited-bin"
                    limited.mkdir()
                    for folder in self.env["PATH"].split(os.pathsep):
                        if not Path(folder).is_dir():
                            continue
                        for tool in Path(folder).iterdir():
                            if tool.name != target and tool.is_file() and os.access(tool, os.X_OK) and not (limited / tool.name).exists():
                                (limited / tool.name).symlink_to(tool.resolve())
                    saved = self.record.read_bytes()
                    answer, code = self.call("succeed", env=self.env | {"PATH": str(limited)})
                    self.assertEqual((answer["state"], answer["reason"], code), ("blocked", "app-missing", 1))
                    self.assertEqual(self.record.read_bytes(), saved)
                    self.assertEqual(self.call("status")[0]["terminal"], previous["terminal"])
                    self.assertEqual(len(self.started()), native_count)
                    shutil.copyfile(session_test.HARNESS, missing)
                    missing.chmod(0o755)
                    self.call("stop")
                    self.wait("stopped", persisted_stop=True)
                    (self.home / ".lane-fixture.json").unlink()
                    continue
                self.call("succeed")
                current = self.wait()
                after = json.loads(self.record.read_text())
                kept = state == "shared-reserve"
                self.assertEqual((current["home"], current["harness"], current["account"]), (str(self.home), target, str(self.account if kept else account)))
                self.assertNotEqual(current["terminal"]["window"], previous["terminal"]["window"])
                self.assertEqual(Path(after["transfer"]["handoff"]).read_text(), contents)
                self.assertEqual((self.home / "state/handoff.md").read_text(), contents)
                queries = [json.loads(line) for line in calls.read_text().splitlines()]
                self.assertIn(str(self.account), queries[0])
                self.assertIn("--for-overseer", queries[0])
                for query in queries[1:]:
                    self.assertEqual(query[query.index("--exclude-lane") + 1], str(self.account))
                    if query[query.index("--harness") + 1] == "claude":
                        self.assertNotIn("--binding-floor", query)
                self.assertEqual(queries[-1][queries[-1].index("--harness") + 1], target)
                argv = self.started()[-1]["argv"]
                if not kept:
                    if target == "claude":
                        self.assertIn("--model", argv)
                        self.assertIn("--effort", argv)
                        self.assertEqual(argv[argv.index("--model") + 1], "sonnet")
                        self.assertEqual(argv[argv.index("--effort") + 1], "high")
                        self.assertEqual([word for word in argv if word.startswith("--settings")],
                                         [word for word in predecessor_argv if word.startswith("--settings")])
                    elif target == "codex":
                        self.assertIn("model_reasoning_effort=high", argv)
                        self.assertNotIn("-m", argv)
                        self.assertNotIn("--model", argv)
                        self.assertEqual(argv.count("--dangerously-bypass-hook-trust"), 1)
                        for setting in ("check_for_update_on_startup=false", "features.daemon_auto_start=false", "notice.hide_rate_limit_model_nudge=true",
                                        "model_auto_compact_token_limit=9223372036854775807", "model_auto_compact_token_limit_scope=body_after_prefix",
                                        "model_post_turn_compact_threshold_percent=0"):
                            self.assertEqual(argv.count(setting), 1)
                    elif target == "copilot":
                        self.assertIn("--reasoning-effort", argv)
                        self.assertEqual(argv[argv.index("--reasoning-effort") + 1], "high")
                        self.assertNotIn("--model", argv)
                        self.assertTrue(set(argv).isdisjoint({"--autopilot", "--max-autopilot-continues", "--context", "--no-auto-update"}))
                else:
                    self.assertEqual(len(queries), 1)
                self.assertEqual(after["transfer"]["phase"], "complete")
                self.assertNotEqual(after["pending"]["native_session_id"], before["pending"]["native_session_id"])
                self.call("stop")
                self.wait("stopped", persisted_stop=True)
                (self.home / ".lane-fixture.json").unlink()

    def test_missing_orch_keeps_predecessor(self):
        self.call("start")
        self.wait()
        before = self.record.read_bytes()
        predecessor = json.loads(self.record.read_text())
        self.handoff()
        orch = self.skills / "orch"
        moved = self.skills / "orch-absent"
        orch.rename(moved)
        try:
            result = subprocess.run([str(self.skills / "jarvis/scripts/jarvis-session"), "succeed", "--home", str(self.home)],
                                    env=self.env, capture_output=True, text=True, timeout=10)
            self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
            self.assertIn("dependency=orch", result.stderr)
            self.assertEqual(self.record.read_bytes(), before)
            pid = predecessor["process"]
            result = subprocess.run([self.env["JARVIS_TEST_BASH"], str(SKILLS / "orch/scripts/lib/session-backend.sh"),
                                     "worker-live", str(pid["pid"]), pid["started_at"]],
                                    capture_output=True, env=self.env, timeout=10)
            self.assertEqual(result.returncode, 0)
            self.assertEqual(len(self.started()), 1)
        finally:
            moved.rename(orch)

    def test_succession_foreign_session(self):
        self.handoff()
        self.call("start")
        self.wait()
        self.call("succeed")
        self.wait()
        self.call("stop")
        self.wait("stopped", persisted_stop=True)
        failed = json.loads(self.record.read_text())
        failed.update(state="failed", reason="handover-failed", detail="Retry succession.", intent="succeed", terminal=None)
        failed.pop("worker", None)
        self.record.write_text(json.dumps(failed))
        foreign = subprocess.run(["tmux", "-L", self.label, "new-session", "-d", "-s", "jarvis", "-P", "-F", "#{window_id}",
                                  self.env["JARVIS_TEST_BASH"], "--noprofile", "--norc"],
                                 capture_output=True, text=True, env=self.env, timeout=10, check=True).stdout.strip()
        count = len(self.started())
        self.call("succeed")
        self.wait("failed", "handover-failed")
        self.await_worker_result()
        windows = subprocess.run(["tmux", "-L", self.label, "list-windows", "-t", "jarvis", "-F", "#{window_id}"],
                                 capture_output=True, text=True, env=self.env, timeout=10, check=True)
        self.assertEqual(windows.stdout.splitlines(), [foreign])
        self.assertEqual(len(self.started()), count)

    def test_succession_recovery(self):
        # Interrupt the real writer before/after each transition write. Only
        # the disposable script copy gains barriers; operations stay production.
        skills = self.root / "instrumented/skills"
        for package in ("jarvis", "orch", "mailbox"):
            shutil.copytree(self.skills / package / "scripts", skills / package / "scripts")
        source = skills / "orch/scripts/lib/controller-session.py"
        original = source.read_text()
        marker = "            os.replace(name, self.path)"
        self.assertEqual(original.count(marker), 1)
        instrumented = original.replace(marker, "            self.checkpoint(record, 'before')\n" + marker + "\n            self.checkpoint(record, 'after')")
        method = '''    def checkpoint(self, record, edge):
        config = Path(self.home) / ".succession-pause.json"
        if not config.exists():
            return
        point = json.loads(config.read_text())
        if record.get("intent") != "succeed" or record.get("transfer", {}).get("phase") != point["phase"] or edge != point["edge"]:
            return
        try:
            stream = Path(point["event"]).open("x")
        except FileExistsError:
            return
        with stream:
            json.dump(json.loads(self.backend("process", os.getpid()).stdout), stream)
        while not Path(point["release"]).exists():
            time.sleep(0.05)

'''
        self.assertEqual(instrumented.count("    def write(self, record):"), 1)
        instrumented = instrumented.replace("    def write(self, record):", method + "    def write(self, record):")
        self.assertNotEqual(original, instrumented)
        source.write_text(instrumented)
        script = skills / "jarvis/scripts/jarvis-session"
        pause = self.home / ".succession-pause.json"
        event = self.root / "checkpoint.json"
        release = self.root / "release"
        phases = ("saved", "waiting", "retiring", "predecessor-ended", "confirmed", "brief-delivered", "complete")
        with patch.object(session_test, "SCRIPT", script):
            for harness in ("claude", "codex", "copilot", "pi"):
                for phase in phases:
                    for edge in ("before", "after"):
                        with self.subTest(harness=harness, phase=phase, edge=edge):
                            print("succession-row: harness=" + harness + " phase=" + phase + " edge=" + edge, flush=True)
                            self.handoff()
                            self.call("start", harness=harness, mode="new")
                            self.wait()
                            previous = json.loads(self.record.read_text())
                            native_count = len(self.started())
                            event.unlink(missing_ok=True)
                            pause.write_text(json.dumps({"phase": phase, "edge": edge, "event": str(event), "release": str(release)}))
                            with subprocess.Popen([str(script), "succeed", "--home", str(self.home)],
                                                  env=self.env, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as request:
                                deadline = time.monotonic() + 15
                                identity = None
                                while time.monotonic() < deadline:
                                    if event.exists():
                                        try:
                                            identity = json.loads(event.read_text())
                                            break
                                        except json.JSONDecodeError:
                                            pass
                                    if request.poll() is not None and request.returncode:
                                        self.fail("succession request refused: " + str(request.communicate()))
                                    time.sleep(0.05)
                                self.assertIsNotNone(identity, self.session_log())
                                persisted = json.loads(self.record.read_text())
                                during, _ = self.call("status")
                                expected = "running" if (phase, edge) in (("saved", "before"), ("complete", "after")) else "handing-over"
                                self.assertEqual(during["state"], expected)
                                owner = json.loads(Path(str(self.record)).read_text()).get("overseer") or {}
                                if edge == "after" and phase in ("predecessor-ended", "confirmed", "brief-delivered"):
                                    self.assertFalse(owner.get("pane"), "retired-controller-mail")
                                if (phase, edge) == ("complete", "after"):
                                    self.assertEqual(owner.get("pane"), persisted["terminal"]["pane"])
                                predecessor = previous.get("native_process") or previous["process"]
                                old_live = subprocess.run([self.env["JARVIS_TEST_BASH"], str(skills / "orch/scripts/lib/session-backend.sh"),
                                                           "worker-live", str(predecessor["pid"]), predecessor["started_at"]],
                                                          capture_output=True, env=self.env, timeout=10)
                                self.assertEqual(old_live.returncode, 0 if phase in ("saved", "waiting", "retiring") else 1)
                                self.assertEqual(len(self.started()) - native_count,
                                                 1 if phase in ("confirmed", "brief-delivered", "complete") else 0)
                                live = subprocess.run([self.env["JARVIS_TEST_BASH"], str(skills / "orch/scripts/lib/session-backend.sh"),
                                                       "worker-live", str(identity["pid"]), identity["started_at"]],
                                                      capture_output=True, env=self.env, timeout=10)
                                self.assertEqual(live.returncode, 0)
                                os.kill(identity["pid"], signal.SIGKILL)
                                request.communicate(timeout=10)
                            pause.unlink()
                            before_end = phase in ("saved", "waiting", "retiring")
                            completed = (phase, edge) == ("complete", "after")
                            if before_end or completed:
                                settled = self.wait("running")
                                owner = previous if before_end else persisted
                                self.assertEqual(settled["terminal"], owner["terminal"])
                            else:
                                settled = self.wait("failed", "handover-failed")
                                self.assertTrue(settled["detail"])
                                deadline = time.monotonic() + 15
                                while settled["terminal"] is not None and time.monotonic() < deadline:
                                    time.sleep(0.05)
                                    settled, _ = self.call("status")
                                self.assertIsNone(settled["terminal"], self.session_log())
                                # The app's Start/boot path cannot revive old history.
                                start, code = self.call("start", harness=harness)
                                self.assertEqual((start["state"], start["reason"], code), ("failed", "handover-failed", 1))
                            self.assertIn("TASK-ref", (self.home / "state/handoff.md").read_text())
                            retry, code = self.call("succeed")
                            self.assertEqual((retry["state"], code), ("handing-over", 0))
                            self.wait()
                            recovered = json.loads(self.record.read_text())
                            self.assert_shared_controller(recovered)
                            self.assertNotEqual(recovered["pending"]["native_session_id"], previous["pending"]["native_session_id"])
                            self.assertIn("TASK-ref", Path(recovered["transfer"]["handoff"]).read_text())
                            self.call("stop")
                            self.wait("stopped", persisted_stop=True)


if __name__ == "__main__":
    with native_launcher() as native:
        session_test.HARNESS = native
        unittest.main(defaultTest=["SuccessionContract.test_succession_contract", "SuccessionContract.test_succession_identity", "SuccessionContract.test_succession_foreign_session", "SuccessionContract.test_succession_recovery", "SuccessionContract.test_shared_first_launch", "SuccessionContract.test_shared_registration", "SuccessionContract.test_shared_orch_launch_and_recovery", "SuccessionContract.test_shared_recovery_harnesses", "SuccessionContract.test_legacy_controller_refuses_replacement", "SuccessionContract.test_orch_retirement_order", "SuccessionContract.test_shared_controller_mail", "SuccessionContract.test_watch_publication_keeps_controller", "SuccessionContract.test_account_succession", "SuccessionContract.test_missing_orch_keeps_predecessor"])
