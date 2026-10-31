// An intent log for an agent's side effects, kept in SQLite on the service's
// state volume.
//
// Before a side effect, the agent calls begin with the step's name: the log
// records the step, its key and what it is about to do, and commits. The
// agent makes the call with that key, then calls finish with the result,
// which the log commits. A restarted agent calls begin again for each step:
// a step with a result comes back done, with its result, and is not run
// again; a step that began and did not finish comes back with the key it
// began with, so the retry carries the same key although the run id has
// changed.
//
// The Python library in ../python keeps the same log, in the same file and
// schema (../README.md). It runs on Node's node:sqlite with no package.

import { mkdirSync } from "node:fs";
import { dirname } from "node:path";
import { DatabaseSync } from "node:sqlite";
import { isDeepStrictEqual } from "node:util";

export const DEFAULT_PATH = "/volume/.toshi/intents.db";
export const SCHEMA_VERSION = 1;
export const BUSY_TIMEOUT_MS = 5000;

export type Scope = "run" | "workload";
export const SCOPE_VARIABLES: Record<Scope, string> = {
	run: "TOSHI_RUN_ID",
	workload: "TOSHI_WORKLOAD_ID",
};

const SCHEMA = `
CREATE TABLE steps (
  step TEXT PRIMARY KEY,
  key TEXT NOT NULL,
  intent TEXT NOT NULL,
  result TEXT,
  began_at TEXT NOT NULL,
  finished_at TEXT
)`;

/** An error of the intent log. */
export class IntentLogError extends Error {
	override name = "IntentLogError";
}
/** finish named a step that begin never recorded. */
export class StepNotBegun extends IntentLogError {
	override name = "StepNotBegun";
}
/** finish gave a step that has a result another result. */
export class StepAlreadyFinished extends IntentLogError {
	override name = "StepAlreadyFinished";
}
/** The log was written by a newer version of the library. */
export class UnsupportedSchema extends IntentLogError {
	override name = "UnsupportedSchema";
}
/** The variable a new step's key is made from is not set. */
export class MissingVariable extends IntentLogError {
	override name = "MissingVariable";
}

/** A step as begin answers it: its key, and its result when it is done. */
export interface Step {
	key: string;
	done: boolean;
	result: unknown;
}

type Env = Readonly<Record<string, string | undefined>>;

/** An open intent log. Use open() to make one. */
export class IntentLog {
	readonly #db: DatabaseSync;
	readonly #env: Env;

	constructor(path: string, env: Env) {
		mkdirSync(dirname(path), { recursive: true, mode: 0o700 });
		this.#env = env;
		this.#db = new DatabaseSync(path);
		try {
			this.#db.exec(`PRAGMA busy_timeout = ${BUSY_TIMEOUT_MS}`);
			this.#db.exec("PRAGMA journal_mode = WAL");
			this.#write(() => this.#migrate());
		} catch (err) {
			this.#db.close();
			throw err;
		}
	}

	// BEGIN IMMEDIATE takes the write lock first, so two processes of one
	// agent cannot both find a step missing and both record it.
	#write<T>(body: () => T): T {
		this.#db.exec("BEGIN IMMEDIATE");
		let out: T;
		try {
			out = body();
		} catch (err) {
			this.#db.exec("ROLLBACK");
			throw err;
		}
		this.#db.exec("COMMIT");
		return out;
	}

	#migrate(): void {
		const { user_version: version } = this.#db
			.prepare("PRAGMA user_version")
			.get() as {
			user_version: number;
		};
		if (version === 0) {
			this.#db.exec(SCHEMA);
			this.#db.exec(`PRAGMA user_version = ${SCHEMA_VERSION}`);
		} else if (version > SCHEMA_VERSION) {
			throw new UnsupportedSchema(
				`the intent log has schema version ${version}; this library reads ${SCHEMA_VERSION}`,
			);
		}
	}

	/**
	 * Records a step before its side effect and returns its key.
	 *
	 * A step already in the log comes back as it is: done with its result, or
	 * not done with the key it began with. Otherwise the key is
	 * <TOSHI_RUN_ID>/<step>, or <TOSHI_WORKLOAD_ID>/<step> for scope "workload".
	 */
	begin(step: string, intent: string, scope: Scope = "run"): Step {
		if (step === "") {
			throw new TypeError("a step needs a name");
		}
		if (!(scope in SCOPE_VARIABLES)) {
			throw new TypeError(
				`scope is run or workload, not ${JSON.stringify(scope)}`,
			);
		}
		return this.#write(() => {
			const row = this.#db
				.prepare("SELECT key, result FROM steps WHERE step = ?")
				.get(step) as { key: string; result: string | null } | undefined;
			if (row !== undefined) {
				return row.result === null
					? { key: row.key, done: false, result: null }
					: { key: row.key, done: true, result: JSON.parse(row.result) };
			}
			const variable = SCOPE_VARIABLES[scope];
			const prefix = this.#env[variable] ?? "";
			if (prefix === "") {
				throw new MissingVariable(`${variable} is not set`);
			}
			const key = `${prefix}/${step}`;
			this.#db
				.prepare(
					"INSERT INTO steps (step, key, intent, began_at) VALUES (?, ?, ?, ?)",
				)
				.run(step, key, intent, new Date().toISOString());
			return { key, done: false, result: null };
		});
	}

	/**
	 * Records a step's result. The result is stored as JSON.
	 *
	 * Finishing a finished step again with the same result changes nothing.
	 */
	finish(step: string, result: unknown): void {
		const text = JSON.stringify(result ?? null);
		this.#write(() => {
			const row = this.#db
				.prepare("SELECT result FROM steps WHERE step = ?")
				.get(step) as { result: string | null } | undefined;
			if (row === undefined) {
				throw new StepNotBegun(`step ${JSON.stringify(step)} was not begun`);
			}
			if (row.result !== null) {
				if (!isDeepStrictEqual(JSON.parse(row.result), JSON.parse(text))) {
					throw new StepAlreadyFinished(
						`step ${JSON.stringify(step)} already has another result`,
					);
				}
				return;
			}
			this.#db
				.prepare("UPDATE steps SET result = ?, finished_at = ? WHERE step = ?")
				.run(text, new Date().toISOString(), step);
		});
	}

	close(): void {
		this.#db.close();
	}
}

/**
 * Opens the intent log at path, making it and its directory (mode 0700)
 * when absent. env is where begin reads TOSHI_RUN_ID and TOSHI_WORKLOAD_ID;
 * the process's environment by default.
 */
export function open(
	path: string = DEFAULT_PATH,
	env: Env = process.env,
): IntentLog {
	return new IntentLog(path, env);
}
