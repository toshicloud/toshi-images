"""An intent log for an agent's side effects, kept in SQLite on the service's state volume.

Before a side effect, the agent calls begin with the step's name: the log
records the step, its key and what it is about to do, and commits. The agent
makes the call with that key, then calls finish with the result, which the
log commits. A restarted agent calls begin again for each step: a step with
a result comes back done, with its result, and is not run again; a step that
began and did not finish comes back with the key it began with, so the retry
carries the same key although the run id has changed.

The TypeScript library in ../typescript keeps the same log, in the same
file and schema (../README.md).
"""

from __future__ import annotations

import json
import os
import sqlite3
from collections.abc import Mapping
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any, Literal, Self

DEFAULT_PATH = "/volume/.toshi/intents.db"
SCHEMA_VERSION = 1
BUSY_TIMEOUT_MS = 5000

Scope = Literal["run", "workload"]
SCOPE_VARIABLES: dict[str, str] = {
    "run": "TOSHI_RUN_ID",
    "workload": "TOSHI_WORKLOAD_ID",
}

_SCHEMA = """
CREATE TABLE steps (
  step TEXT PRIMARY KEY,
  key TEXT NOT NULL,
  intent TEXT NOT NULL,
  result TEXT,
  began_at TEXT NOT NULL,
  finished_at TEXT
)
"""


class IntentLogError(Exception):
    """An error of the intent log."""


class StepNotBegun(IntentLogError):
    """finish named a step that begin never recorded."""


class StepAlreadyFinished(IntentLogError):
    """finish gave a step that has a result another result."""


class UnsupportedSchema(IntentLogError):
    """The log was written by a newer version of the library."""


class MissingVariable(IntentLogError):
    """The variable a new step's key is made from is not set."""


@dataclass(frozen=True)
class Step:
    """A step as begin answers it: its key, and its result when it is done."""

    key: str
    done: bool
    result: Any = None


def _now() -> str:
    return datetime.now(UTC).isoformat(timespec="milliseconds").replace("+00:00", "Z")


class IntentLog:
    """An open intent log. Use open() to make one."""

    def __init__(self, path: str, env: Mapping[str, str]) -> None:
        directory = os.path.dirname(path)
        if directory:
            os.makedirs(directory, mode=0o700, exist_ok=True)
        self._env = env
        # Autocommit: each write below opens its own transaction.
        self._db = sqlite3.connect(path, isolation_level=None)
        try:
            self._db.execute(f"PRAGMA busy_timeout = {BUSY_TIMEOUT_MS}")
            self._db.execute("PRAGMA journal_mode = WAL")
            self._write(self._migrate)
        except BaseException:
            self._db.close()
            raise

    def _write(self, body: Any) -> Any:
        # BEGIN IMMEDIATE takes the write lock first, so two processes of one
        # agent cannot both find a step missing and both record it.
        self._db.execute("BEGIN IMMEDIATE")
        try:
            out = body()
        except BaseException:
            self._db.execute("ROLLBACK")
            raise
        self._db.execute("COMMIT")
        return out

    def _migrate(self) -> None:
        (version,) = self._db.execute("PRAGMA user_version").fetchone()
        if version == 0:
            self._db.execute(_SCHEMA)
            self._db.execute(f"PRAGMA user_version = {SCHEMA_VERSION}")
        elif version > SCHEMA_VERSION:
            raise UnsupportedSchema(
                f"the intent log has schema version {version}; this library reads {SCHEMA_VERSION}"
            )

    def begin(self, step: str, intent: str, scope: Scope = "run") -> Step:
        """Records a step before its side effect and returns its key.

        A step already in the log comes back as it is: done with its result,
        or not done with the key it began with. Otherwise the key is
        <TOSHI_RUN_ID>/<step>, or <TOSHI_WORKLOAD_ID>/<step> for scope
        "workload".
        """
        if not step:
            raise ValueError("a step needs a name")
        if scope not in SCOPE_VARIABLES:
            raise ValueError(f"scope is run or workload, not {scope!r}")

        def body() -> Step:
            row = self._db.execute(
                "SELECT key, result FROM steps WHERE step = ?", (step,)
            ).fetchone()
            if row is not None:
                key, result = row
                if result is None:
                    return Step(key=key, done=False)
                return Step(key=key, done=True, result=json.loads(result))
            variable = SCOPE_VARIABLES[scope]
            prefix = self._env.get(variable, "")
            if not prefix:
                raise MissingVariable(f"{variable} is not set")
            key = f"{prefix}/{step}"
            self._db.execute(
                "INSERT INTO steps (step, key, intent, began_at) VALUES (?, ?, ?, ?)",
                (step, key, intent, _now()),
            )
            return Step(key=key, done=False)

        return self._write(body)

    def finish(self, step: str, result: Any) -> None:
        """Records a step's result. The result is stored as JSON.

        Finishing a finished step again with the same result changes nothing.
        """
        text = json.dumps(result, separators=(",", ":"))

        def body() -> None:
            row = self._db.execute(
                "SELECT result FROM steps WHERE step = ?", (step,)
            ).fetchone()
            if row is None:
                raise StepNotBegun(f"step {step!r} was not begun")
            (stored,) = row
            if stored is not None:
                if json.loads(stored) != result:
                    raise StepAlreadyFinished(
                        f"step {step!r} already has another result"
                    )
                return
            self._db.execute(
                "UPDATE steps SET result = ?, finished_at = ? WHERE step = ?",
                (text, _now(), step),
            )

        self._write(body)

    def close(self) -> None:
        self._db.close()

    def __enter__(self) -> Self:
        return self

    def __exit__(self, *_: object) -> None:
        self.close()


def open(path: str = DEFAULT_PATH, env: Mapping[str, str] | None = None) -> IntentLog:
    """Opens the intent log at path, making it and its directory (mode 0700) when absent.

    env is where begin reads TOSHI_RUN_ID and TOSHI_WORKLOAD_ID; the process's
    environment when None.
    """
    return IntentLog(path, os.environ if env is None else env)
