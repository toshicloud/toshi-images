import json
import os
import sqlite3
import stat
import subprocess
import sys
import tempfile
import unittest
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

import toshi_intents

HERE = Path(__file__).resolve().parent
TS_CLI = HERE.parent / "typescript" / "cli.ts"
PY_CLI = HERE / "cli.py"


class IntentLogTest(unittest.TestCase):
    def setUp(self) -> None:
        self.dir = tempfile.TemporaryDirectory()
        self.path = os.path.join(self.dir.name, ".toshi", "intents.db")

    def tearDown(self) -> None:
        self.dir.cleanup()

    def open(self, **env: str) -> toshi_intents.IntentLog:
        return toshi_intents.open(self.path, env)

    def test_a_step_cut_short_keeps_its_key_after_the_run_id_changes(self) -> None:
        with self.open(TOSHI_RUN_ID="run-1") as log:
            first = log.begin("open-pull-request", "open the pull request for issue 12")
        self.assertEqual(
            first, toshi_intents.Step(key="run-1/open-pull-request", done=False)
        )
        # The agent stopped before finish; the service woke as a new run.
        with self.open(TOSHI_RUN_ID="run-2") as log:
            again = log.begin("open-pull-request", "open the pull request for issue 12")
        self.assertEqual(again.key, "run-1/open-pull-request")
        self.assertFalse(again.done)

    def test_a_finished_step_is_skipped_with_its_stored_result(self) -> None:
        with self.open(TOSHI_RUN_ID="run-1") as log:
            log.begin("open-pull-request", "open it")
            log.finish(
                "open-pull-request", {"number": 7, "url": "https://example.com/pull/7"}
            )
        with self.open(TOSHI_RUN_ID="run-2") as log:
            step = log.begin("open-pull-request", "open it")
        self.assertTrue(step.done)
        self.assertEqual(step.key, "run-1/open-pull-request")
        self.assertEqual(
            step.result, {"number": 7, "url": "https://example.com/pull/7"}
        )

    def test_scope_workload_keys_the_step_with_the_workload_id(self) -> None:
        with self.open(TOSHI_RUN_ID="run-1", TOSHI_WORKLOAD_ID="wl-1") as log:
            step = log.begin("welcome-mail", "send the welcome mail", "workload")
        self.assertEqual(step.key, "wl-1/welcome-mail")

    def test_a_new_step_without_its_variable_is_refused(self) -> None:
        with self.open() as log, self.assertRaises(toshi_intents.MissingVariable):
            log.begin("open-pull-request", "open it")
        with (
            self.open(TOSHI_RUN_ID="run-1") as log,
            self.assertRaises(toshi_intents.MissingVariable),
        ):
            log.begin("welcome-mail", "send it", "workload")

    def test_finish_without_begin_is_refused(self) -> None:
        with (
            self.open(TOSHI_RUN_ID="run-1") as log,
            self.assertRaises(toshi_intents.StepNotBegun),
        ):
            log.finish("never-begun", True)

    def test_a_second_finish_must_give_the_same_result(self) -> None:
        with self.open(TOSHI_RUN_ID="run-1") as log:
            log.begin("charge", "charge the card")
            log.finish("charge", {"id": "ch_1"})
            log.finish("charge", {"id": "ch_1"})
            with self.assertRaises(toshi_intents.StepAlreadyFinished):
                log.finish("charge", {"id": "ch_2"})
            self.assertEqual(
                log.begin("charge", "charge the card").result, {"id": "ch_1"}
            )

    def test_a_log_of_a_newer_schema_is_refused(self) -> None:
        self.open().close()
        db = sqlite3.connect(self.path)
        db.execute("PRAGMA user_version = 2")
        db.close()
        with self.assertRaises(toshi_intents.UnsupportedSchema):
            self.open()

    def test_the_log_and_its_directory_are_made_private(self) -> None:
        self.open().close()
        mode = stat.S_IMODE(os.stat(os.path.dirname(self.path)).st_mode)
        self.assertEqual(mode, 0o700)
        db = sqlite3.connect(self.path)
        self.assertEqual(db.execute("PRAGMA user_version").fetchone(), (1,))
        self.assertEqual(db.execute("PRAGMA journal_mode").fetchone(), ("wal",))
        db.close()

    def test_concurrent_begins_of_one_step_record_one_key(self) -> None:
        def begin(n: int) -> str:
            out = subprocess.run(
                [
                    sys.executable,
                    str(PY_CLI),
                    "begin",
                    self.path,
                    "deploy",
                    "deploy the app",
                ],
                env={**os.environ, "TOSHI_RUN_ID": f"run-{n}"},
                capture_output=True,
                text=True,
                check=True,
            )
            return json.loads(out.stdout)["key"]

        with ThreadPoolExecutor(max_workers=8) as pool:
            keys = list(pool.map(begin, range(8)))
        self.assertEqual(len(set(keys)), 1, keys)
        db = sqlite3.connect(self.path)
        self.assertEqual(db.execute("SELECT count(*) FROM steps").fetchone(), (1,))
        db.close()


class CrossLanguageTest(unittest.TestCase):
    """The TypeScript library reads and finishes a log the Python one wrote."""

    def node(self, *args: str, run_id: str) -> str:
        out = subprocess.run(
            ["node", str(TS_CLI), *args],
            env={**os.environ, "TOSHI_RUN_ID": run_id},
            capture_output=True,
            text=True,
            check=True,
        )
        return out.stdout

    def test_typescript_reads_and_finishes_a_python_log(self) -> None:
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "intents.db")
            with toshi_intents.open(path, {"TOSHI_RUN_ID": "run-py"}) as log:
                log.begin("open-pull-request", "open it")
                log.begin("label", "label it")
                log.finish("label", ["bug", "agent"])

            self.assertEqual(
                json.loads(
                    self.node(
                        "begin", path, "open-pull-request", "open it", run_id="run-ts"
                    )
                ),
                {"key": "run-py/open-pull-request", "done": False, "result": None},
            )
            self.assertEqual(
                json.loads(
                    self.node("begin", path, "label", "label it", run_id="run-ts")
                ),
                {"key": "run-py/label", "done": True, "result": ["bug", "agent"]},
            )
            self.node(
                "finish", path, "open-pull-request", '{"number":7}', run_id="run-ts"
            )

            with toshi_intents.open(path, {"TOSHI_RUN_ID": "run-py-2"}) as log:
                step = log.begin("open-pull-request", "open it")
            self.assertEqual(
                step,
                toshi_intents.Step(
                    key="run-py/open-pull-request", done=True, result={"number": 7}
                ),
            )


if __name__ == "__main__":
    unittest.main()
