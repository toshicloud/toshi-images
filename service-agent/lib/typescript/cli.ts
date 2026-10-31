// A command line over the intent log, for the cross-language tests.
//
//     node cli.ts begin <path> <step> <intent> [run|workload]
//     node cli.ts finish <path> <step> <result as JSON>
//
// begin prints the step as JSON: {"key": ..., "done": ..., "result": ...}.

import { open, type Scope } from "./intents.ts";

const [command, path, step, arg, scope] = process.argv.slice(2);

if (command === "begin" && path && step && arg !== undefined) {
	const log = open(path);
	try {
		console.log(
			JSON.stringify(log.begin(step, arg, (scope ?? "run") as Scope)),
		);
	} finally {
		log.close();
	}
} else if (command === "finish" && path && step && arg !== undefined) {
	const log = open(path);
	try {
		log.finish(step, JSON.parse(arg));
	} finally {
		log.close();
	}
} else {
	console.error(
		"usage: node cli.ts begin <path> <step> <intent> [run|workload] | finish <path> <step> <json>",
	);
	process.exitCode = 2;
}
