"""A command line over the intent log, for the cross-language tests.

    python3 cli.py begin <path> <step> <intent> [run|workload]
    python3 cli.py finish <path> <step> <result as JSON>

begin prints the step as JSON: {"key": ..., "done": ..., "result": ...}.
"""

import json
import sys

import toshi_intents


def main(argv: list[str]) -> int:
    if len(argv) >= 4 and argv[0] == "begin":
        scope = argv[4] if len(argv) > 4 else "run"
        with toshi_intents.open(argv[1]) as log:
            step = log.begin(argv[2], argv[3], scope)  # type: ignore[arg-type]
        print(json.dumps({"key": step.key, "done": step.done, "result": step.result}))
        return 0
    if len(argv) == 4 and argv[0] == "finish":
        with toshi_intents.open(argv[1]) as log:
            log.finish(argv[2], json.loads(argv[3]))
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
