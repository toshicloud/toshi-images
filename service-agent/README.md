# service-agent

The service agent image is planned and not built yet. This directory holds
the library it will carry: an intent log, in Python and TypeScript, that
lets an agent repeat a side effect safely after a restart.

## Why

An agent's run can stop at any point: its service sleeps, wakes as a new
run, or its VM restarts. A side effect it was making when it stopped, such
as opening a pull request or charging a card, may or may not have
happened. Only the API that receives the call can drop a repeat, and only
when the repeat carries the same key as the first call. Toshi gives the
guest two variables to make keys from:

- `TOSHI_RUN_ID`, the run's id, new at each start or wake of a service;
- `TOSHI_WORKLOAD_ID`, the workload's id, the same for its whole life.

A step's key is `<TOSHI_RUN_ID>/<step>`, such as
`run-…/open-pull-request`. The agent passes it as `request_key` on a Toshi
Workspace API call, and as the `Idempotency-Key` header to another API that
takes one. Toshi never makes or reads the key.

Since the run id changes when a service wakes, the key of a step that was
cut short would change too. The intent log keeps it: the log is a SQLite
file on the service's state volume, at `/volume/.toshi/intents.db`, which
outlives the run.

## Using it

1. Before a side effect, call `begin(step, intent)`. The log records the
   step, its key and what it is about to do, commits, and returns the key.
2. Make the call with that key.
3. Call `finish(step, result)`. The log stores the result, as JSON, and
   commits.

A restarted agent calls `begin` again for each step. It gets back:

- `done` true and the stored `result` for a step that finished: do not run
  it again, use the result;
- `done` false and the key the step began with for a step that began and
  did not finish: make the call again with that key, which the receiving
  API recognises as a repeat.

Python (`lib/python/toshi_intents.py`, standard library only):

```python
import toshi_intents

with toshi_intents.open() as log:
    step = log.begin("open-pull-request/issue-12", "open the pull request for issue 12")
    if step.done:
        pull = step.result
    else:
        pull = github.create_pull(..., idempotency_key=step.key)
        log.finish("open-pull-request/issue-12", pull)
```

TypeScript (`lib/typescript/intents.ts`, Node 24's `node:sqlite`, no
package):

```ts
import { open } from "./intents.ts";

const log = open();
const step = log.begin("open-pull-request/issue-12", "open the pull request for issue 12");
const pull = step.done ? step.result : await createPull({ idempotencyKey: step.key });
if (!step.done) log.finish("open-pull-request/issue-12", pull);
log.close();
```

### Naming a step

**A finished step is never run again**, by this agent or any later run of
the same service. A step's name must therefore name one side effect for
good. When an agent does the same kind of step again for new work, the
name carries that work's own id: `open-pull-request/issue-12`, then
`open-pull-request/issue-13`, never `open-pull-request` for both. A name
reused for new work gets the old step's result back and the new work is
silently skipped.

### Scope: run or workload

`begin(step, intent, "workload")` keys a new step with `TOSHI_WORKLOAD_ID`
in place of `TOSHI_RUN_ID`. Use it for a step that must happen at most
once in the service's whole life, such as a welcome mail, when losing the
log must not lead to a second one. A state volume's newest data can be
lost with a host, and with it an intent written just before; the next run
then has a new run id, so a run-scoped key would be new, while a
workload-scoped key is the same. The receiving API can then still drop the
repeat. For every other step, keep the default scope, `"run"`.

The scope matters only when a step is first recorded: a step already in
the log keeps the key it began with.

## Errors

The same names in both languages:

| Error | When |
| --- | --- |
| `MissingVariable` | `begin` records a new step and `TOSHI_RUN_ID` (or `TOSHI_WORKLOAD_ID` for scope `"workload"`) is not set |
| `StepNotBegun` | `finish` names a step `begin` never recorded |
| `StepAlreadyFinished` | `finish` gives a finished step a different result (the same result again changes nothing) |
| `UnsupportedSchema` | the log was written by a newer schema version than the library reads |

## The schema

One table, and the schema version in SQLite's `user_version` (now 1). A
library refuses a log with a newer version.

```sql
CREATE TABLE steps (
  step TEXT PRIMARY KEY,   -- the agent's name for the step
  key TEXT NOT NULL,       -- <TOSHI_RUN_ID or TOSHI_WORKLOAD_ID>/<step>, as first recorded
  intent TEXT NOT NULL,    -- what the step was about to do
  result TEXT,             -- the result as JSON; NULL until finish
  began_at TEXT NOT NULL,  -- UTC, ISO 8601 with milliseconds, e.g. 2026-10-31T09:12:03.456Z
  finished_at TEXT         -- the same form; NULL until finish
);
PRAGMA user_version = 1;
```

The log runs in WAL mode with a 5 second busy timeout. Every `begin` and
`finish` is one `BEGIN IMMEDIATE` transaction, which takes the write lock
before reading, so two processes of one agent that begin the same step at
once record it once and both get its one key. The directory `/volume/.toshi`
is made with mode 0700. Either library reads and finishes a log the other
wrote.

## Checks

The tools are pinned in `mise.toml`, with Node at the version the runner
images install. In this directory:

```sh
mise install
ruff check lib/python && ruff format --check lib/python
biome ci lib/typescript
(cd lib/python && python3 -m unittest -v)
(cd lib/typescript && node --test)
```

Each suite also runs the other language's `cli.py` or `cli.ts` on a log
it wrote, so both directions of the cross-language check run in each
suite. The `service-agent` workflow runs all of this when a change touches
this directory.
