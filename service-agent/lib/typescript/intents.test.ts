import assert from "node:assert/strict";
import { execFile, execFileSync } from "node:child_process";
import { mkdtempSync, rmSync, statSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { afterEach, beforeEach, describe, it } from "node:test";
import { fileURLToPath } from "node:url";
import { promisify } from "node:util";

import {
	type IntentLog,
	MissingVariable,
	open,
	StepAlreadyFinished,
	StepNotBegun,
	UnsupportedSchema,
} from "./intents.ts";

const here = dirname(fileURLToPath(import.meta.url));
const tsCli = join(here, "cli.ts");
const pyCli = join(here, "..", "python", "cli.py");
const run = promisify(execFile);

describe("the intent log", () => {
	let dir: string;
	let path: string;
	const logOf = (env: Record<string, string> = {}): IntentLog =>
		open(path, env);

	beforeEach(() => {
		dir = mkdtempSync(join(tmpdir(), "intents-"));
		path = join(dir, ".toshi", "intents.db");
	});
	afterEach(() => rmSync(dir, { recursive: true, force: true }));

	it("keeps a step's key after the run id changes when the step was cut short", () => {
		let log = logOf({ TOSHI_RUN_ID: "run-1" });
		assert.deepEqual(
			log.begin("open-pull-request", "open the pull request for issue 12"),
			{
				key: "run-1/open-pull-request",
				done: false,
				result: null,
			},
		);
		log.close();
		// The agent stopped before finish; the service woke as a new run.
		log = logOf({ TOSHI_RUN_ID: "run-2" });
		const again = log.begin(
			"open-pull-request",
			"open the pull request for issue 12",
		);
		log.close();
		assert.equal(again.key, "run-1/open-pull-request");
		assert.equal(again.done, false);
	});

	it("skips a finished step and gives its stored result", () => {
		let log = logOf({ TOSHI_RUN_ID: "run-1" });
		log.begin("open-pull-request", "open it");
		log.finish("open-pull-request", {
			number: 7,
			url: "https://example.com/pull/7",
		});
		log.close();
		log = logOf({ TOSHI_RUN_ID: "run-2" });
		const step = log.begin("open-pull-request", "open it");
		log.close();
		assert.deepEqual(step, {
			key: "run-1/open-pull-request",
			done: true,
			result: { number: 7, url: "https://example.com/pull/7" },
		});
	});

	it("keys a step of scope workload with the workload id", () => {
		const log = logOf({ TOSHI_RUN_ID: "run-1", TOSHI_WORKLOAD_ID: "wl-1" });
		assert.equal(
			log.begin("welcome-mail", "send the welcome mail", "workload").key,
			"wl-1/welcome-mail",
		);
		log.close();
	});

	it("refuses a new step without its variable", () => {
		let log = logOf();
		assert.throws(
			() => log.begin("open-pull-request", "open it"),
			MissingVariable,
		);
		log.close();
		log = logOf({ TOSHI_RUN_ID: "run-1" });
		assert.throws(
			() => log.begin("welcome-mail", "send it", "workload"),
			MissingVariable,
		);
		log.close();
	});

	it("refuses finish without begin", () => {
		const log = logOf({ TOSHI_RUN_ID: "run-1" });
		assert.throws(() => log.finish("never-begun", true), StepNotBegun);
		log.close();
	});

	it("takes a second finish only with the same result", () => {
		const log = logOf({ TOSHI_RUN_ID: "run-1" });
		log.begin("charge", "charge the card");
		log.finish("charge", { id: "ch_1" });
		log.finish("charge", { id: "ch_1" });
		assert.throws(
			() => log.finish("charge", { id: "ch_2" }),
			StepAlreadyFinished,
		);
		assert.deepEqual(log.begin("charge", "charge the card").result, {
			id: "ch_1",
		});
		log.close();
	});

	it("refuses a log of a newer schema", () => {
		logOf().close();
		const db = new DatabaseSync(path);
		db.exec("PRAGMA user_version = 2");
		db.close();
		assert.throws(() => logOf(), UnsupportedSchema);
	});

	it("makes the log and its directory private, at schema 1 in WAL mode", () => {
		logOf().close();
		assert.equal(statSync(dirname(path)).mode & 0o777, 0o700);
		const db = new DatabaseSync(path);
		assert.deepEqual(
			{ ...db.prepare("PRAGMA user_version").get() },
			{ user_version: 1 },
		);
		assert.deepEqual(
			{ ...db.prepare("PRAGMA journal_mode").get() },
			{ journal_mode: "wal" },
		);
		db.close();
	});

	it("records one key when processes begin one step at once", async () => {
		const answers = await Promise.all(
			Array.from({ length: 8 }, (_, n) =>
				run(
					process.execPath,
					[tsCli, "begin", path, "deploy", "deploy the app"],
					{
						env: { ...process.env, TOSHI_RUN_ID: `run-${n}` },
					},
				),
			),
		);
		const keys = new Set(
			answers.map(({ stdout }) => (JSON.parse(stdout) as { key: string }).key),
		);
		assert.equal(keys.size, 1, [...keys].join(", "));
		const db = new DatabaseSync(path);
		assert.deepEqual(
			{ ...db.prepare("SELECT count(*) AS n FROM steps").get() },
			{ n: 1 },
		);
		db.close();
	});
});

describe("across languages", () => {
	it("the Python library reads and finishes a TypeScript log", () => {
		const dir = mkdtempSync(join(tmpdir(), "intents-"));
		try {
			const path = join(dir, "intents.db");
			let log = open(path, { TOSHI_RUN_ID: "run-ts" });
			log.begin("open-pull-request", "open it");
			log.begin("label", "label it");
			log.finish("label", ["bug", "agent"]);
			log.close();

			const python = (...args: string[]): string =>
				execFileSync("python3", [pyCli, ...args], {
					env: { ...process.env, TOSHI_RUN_ID: "run-py" },
					encoding: "utf8",
				});
			assert.deepEqual(
				JSON.parse(python("begin", path, "open-pull-request", "open it")),
				{
					key: "run-ts/open-pull-request",
					done: false,
					result: null,
				},
			);
			assert.deepEqual(JSON.parse(python("begin", path, "label", "label it")), {
				key: "run-ts/label",
				done: true,
				result: ["bug", "agent"],
			});
			python("finish", path, "open-pull-request", '{"number":7}');

			log = open(path, { TOSHI_RUN_ID: "run-ts-2" });
			const step = log.begin("open-pull-request", "open it");
			log.close();
			assert.deepEqual(step, {
				key: "run-ts/open-pull-request",
				done: true,
				result: { number: 7 },
			});
		} finally {
			rmSync(dir, { recursive: true, force: true });
		}
	});
});
