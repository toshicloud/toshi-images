# service-agent

Builds the service agent image, the OCI image an Agent template's services
run in, and holds the library it carries: an intent log, in Python and
TypeScript, that lets an agent repeat a side effect safely after a restart.

## The image

The image is for the services of an Agent template: the agent runs its CLI
in it, signs in as the person the service belongs to, and keeps its sign-in
state and its intent log on the service's volume. It carries Node and Python
at the versions `mise.toml` pins for the libraries, the agent CLIs with their
ACP adapters, and the intent-log library, all installed here. It has no guest
helper, no Docker daemon and no `sudo`: it runs an agent, not a host.

| Component | Command | Version | Licence | Licence file in the image |
| --- | --- | --- | --- | --- |
| Node | `node` | 24.22.1 | MIT | in the runtime's own files |
| Python | `python3` | 3.13.18 | PSF-2.0 | in the runtime's own files |
| Claude Code | `claude` | 2.1.316 | Anthropic's terms (its `LICENSE.md`) | `/usr/share/licenses/toshi-service-agent/claude-code/LICENSE.md` |
| Claude Agent ACP | `claude-agent-acp` | 0.99.1 | Apache-2.0 | `/usr/share/licenses/toshi-service-agent/claude-agent-acp/LICENSE` |
| Codex | `codex` | 0.165.0 | Apache-2.0 | `/usr/share/licenses/toshi-service-agent/codex/LICENSE` and `NOTICE` |
| Codex ACP | `codex-acp` | 2.5.0 | Apache-2.0 | `/usr/share/licenses/toshi-service-agent/codex-acp/LICENSE` |
| OpenCode | `opencode`, `opencode acp` | 1.19.5 | MIT | `/usr/share/licenses/toshi-service-agent/opencode/LICENSE` |

Claude Code, Codex and OpenCode are preinstalled, unmodified. Each person
signs in with their own account, key or subscription; the image holds no
credentials and Toshi does not proxy, pay for or resell any of them.

Sign in as the image's user. The status commands answer without a network
and say when nobody is signed in:

```sh
claude auth login        # or: claude auth status
codex login --device-auth  # or: codex login status
opencode auth login      # or: opencode auth list
```

Sign-in state lives under `HOME`, on the service's volume: `~/.claude`,
`~/.codex` and `~/.local/share/opencode`. Toshi runs a service's sign-in
with `HOME=/volume/home`.

Each CLI has an ACP command, the one an ACP client starts: `claude-agent-acp`
and `codex-acp` are adapters, and OpenCode has `opencode acp` built in. The CLIs and adapters
were installed by `npm ci` from `package.json` and `package-lock.json`, which
name exact versions; the lock checks every package's integrity.

The intent log is in the image twice:

- Python: `toshi_intents` is in the image's site-packages, so
  `python3 -c "import toshi_intents"` works anywhere; the command line is
  `/opt/toshi/service-agent/python/cli.py` and the `toshi-intents` launcher
  runs it.
- TypeScript: `/opt/toshi/service-agent/typescript/intents.ts` and `cli.ts`,
  imported by absolute path (`node /opt/toshi/service-agent/typescript/cli.ts`
  or the `toshi-intents-ts` launcher); Node 24 strips the types.

The library's tests are not in the image. The image carries its pins at
`/usr/share/toshi/service-agent/versions.env`.

It runs as `runner` (uid 1001, gid 1001) with `/volume` owned by
`runner:runner`, so a fresh named volume the runtime mounts there keeps that
ownership; its HOME is `/home/runner`, and the runtime overrides the
entrypoint and the command.

Build it on any Linux host with Docker; the context is the repository root:

```sh
service-agent/build.sh [tag]
```

The tag defaults to `toshi-service-agent:latest`. `build.sh` refuses a
`Dockerfile` whose base has no digest, a `package.json` whose versions differ
from `versions.env`, and a committed Codex licence that differs from its
SHA256. The build runs each CLI's `--version` and checks that both ACP
commands are on `PATH`, so a platform package npm skipped fails the build
rather than making an image without it (npm treats an optional dependency's
failure as a warning). It labels the image with its version
(`org.opencontainers.image.version`): `IMAGE_VERSION` when set, else in a
checkout of this repository the commit's `git describe --tags --always
--dirty`, and in a checkout it also labels it with the commit
(`org.opencontainers.image.revision`).

```sh
service-agent/smoke-test.sh [image]
```

It runs the image with `--network none`, as `runner`, with a fresh named
volume on `/volume` and `HOME=/volume/home`, and fails unless:

- the image has a version label other than `dev`, and runs as uid and gid
  1001, and `runner` can write to `/volume/home`;
- Node, Python, Claude Code, Codex and OpenCode report the versions
  `versions.env` pins, the two ACP commands are on `PATH`, and the packages
  in `/opt/agents/node_modules` report the same versions;
- `claude auth status`, `codex login status` and `opencode auth list` each
  report signed out;
- `python3 -c "import toshi_intents"` works, the TypeScript module imports by
  absolute path, and both launchers begin a step;
- both library suites pass with the image's runtimes, from a copy of
  `lib/` mounted read-only;
- `/usr/share/toshi/service-agent/versions.env` and each licence file above
  are there.

A broken pin stops the build at the pin: `build.sh` refuses a `Dockerfile`
whose base has no digest before anything is fetched, a download whose SHA256
differs from its pin fails in `fetch_verified` with
`fetch_verified: sha256 mismatch for <url>`, and a lock entry whose integrity
was changed fails `npm ci` with `EINTEGRITY`. A dispatch with `break_pin` set
to `base-digest`, `node-sha256` or `npm-integrity` breaks one on purpose to
show it.

## The workflow

[`service-agent.yml`](../.github/workflows/service-agent.yml) keeps the
`libraries` job for the intent-log libraries and adds three jobs. It runs on
a pull request or a push to main that changes `service-agent/**`,
`toolsets/lib.sh` or the workflow, on a dispatch, and on every release tag
(`v*`).

The `image` job builds the image with `build.sh`, checks that the revision
label is the run's commit, runs the smoke test, saves the image as a
zstd-compressed tarball (`docker save`, which `docker load` reads as it is)
and, except on a pull request, uploads it as an artifact kept for a day. The
tarball's SHA-256 and sizes go to the job summary.

The `image-publish` job runs only on a release tag, and only when the
repository variable `SERVICE_AGENT_IMAGE` is set to an image reference with
its registry host and without a tag or digest. It takes the tarball from
`image` through the cache, logs in to that registry host with the run's own
token (`packages: write`; no token is stored), and runs
[`publish.sh`](publish.sh). The script checks the tarball's SHA-256, loads
it, pushes it with the release's version and with `service-agent` as tags,
pulls it back at the pushed digest and compares it with the loaded image,
then signs it and attests and verifies its SBOM and provenance; it writes
`<reference>@sha256:<digest>` to the job summary: the reference a service
pulls. Otherwise `image` writes why publishing was skipped: `publish
skipped: not a release tag` on any run but a release tag, and `publish
skipped: SERVICE_AGENT_IMAGE not set` while the variable is unset.

A dispatch with `rehearse_publish` runs `publish.sh` on a branch against a
registry that the `image-publish-rehearsal` job starts on its own loopback
address, and uploads the digest file as an artifact (`service-agent-digest`);
the script refuses any other registry in a rehearsal. The rehearsal proves
the tarball check, the load, the tags, the push and the pull back by digest,
then catalogs the full image and attests and verifies its SBOM through the
same script as a release. Only a release tag proves the login and the push
to the real registry.

`publish.sh` reads `GITHUB_SHA`, which it requires for `push`: the image's
revision label must name that commit. `REHEARSE=1` is the rehearsal: the
registry must be the loopback address with a port, and the version may be
the commit instead of a release tag.

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
