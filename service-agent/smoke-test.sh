#!/bin/bash
# Checks a built service agent image with `docker run --network none`, as the
# image's user, with a fresh named volume on /volume and HOME=/volume/home
# (README.md, "The image"): the pinned versions, the CLIs' signed-out status,
# the intent-log library in Python and TypeScript, a write to /volume and the
# licence files.
# Usage: service-agent/smoke-test.sh [image]
# shellcheck disable=SC1091
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")

if [[ ${1:-} != --inside ]]; then
	image=${1:-toshi-service-agent:latest}
	label=$(docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.version"}}' "$image")
	volume="toshi-service-agent-smoke-$$"
	docker volume create "$volume" >/dev/null
	trap 'docker volume rm -f "$volume" >/dev/null 2>&1' EXIT
	rc=0
	docker run --rm --network none --entrypoint /bin/bash \
		-e IMAGE_VERSION="$label" \
		-e HOME=/volume/home \
		-v "$volume:/volume" \
		-v "$here/smoke-test.sh:/opt/smoke/smoke-test.sh:ro" \
		-v "$here/versions.env:/opt/smoke/versions.env:ro" \
		-v "$here/lib:/opt/smoke/lib:ro" \
		"$image" /opt/smoke/smoke-test.sh --inside || rc=$?
	exit "$rc"
fi

# In the container, as the image's user, with no network.
set +e
. /opt/smoke/versions.env
failed=0
check() {
	if [[ -n $3 && $3 == "$2" ]]; then
		echo "ok   $1 $3"
	else
		echo "FAIL $1: want ${2:-a value}, got ${3:-nothing}"
		failed=1
	fi
}
contains() {
	if [[ $3 == *"$2"* ]]; then
		echo "ok   $1 (found '$2')"
	else
		echo "FAIL $1: '$2' not in: ${3:-nothing}"
		failed=1
	fi
}
exists() {
	if [[ -f $2 ]]; then
		echo "ok   $1 $2"
	else
		echo "FAIL $1: ${2} is missing"
		failed=1
	fi
}

if [[ -z $IMAGE_VERSION || $IMAGE_VERSION == dev ]]; then
	echo "FAIL the image's version label is '${IMAGE_VERSION}'"
	failed=1
fi

# The image's user, and its own writable /volume: a fresh named volume keeps
# the ownership the image gave the directory.
check uid "$(id -u)" 1001
check gid "$(id -g)" 1001
check home /home/runner "$(getent passwd runner | cut -d: -f6)"
mkdir -p "$HOME"
printf 'probe\n' >"$HOME/probe"
check volume-write probe "$(cat "$HOME/probe" 2>/dev/null)"

# Runtimes, and the CLIs' own versions.
check node "$NODE_VERSION" "$(node --version | sed 's/^v//')"
check python "$PYTHON_VERSION" "$(python3 --version | awk '{print $2}')"
check claude "$CLAUDE_CODE_VERSION" "$(claude --version 2>/dev/null | awk '{print $1}')"
check codex "$CODEX_VERSION" "$(codex --version 2>/dev/null | awk '{print $2}')"
check opencode "$OPENCODE_VERSION" "$(opencode --version 2>/dev/null | tail -n1)"
for bin in claude-agent-acp codex-acp; do
	if command -v "$bin" >/dev/null; then
		echo "ok   command $bin"
	else
		echo "FAIL command $bin is missing"
		failed=1
	fi
done
pkg() {
	node -p "require('/opt/agents/node_modules/$1/package.json').version" 2>/dev/null
}
check claude-package "$CLAUDE_CODE_VERSION" "$(pkg @anthropic-ai/claude-code)"
check claude-agent-acp-package "$CLAUDE_AGENT_ACP_VERSION" "$(pkg @agentclientprotocol/claude-agent-acp)"
check codex-package "$CODEX_VERSION" "$(pkg @openai/codex)"
check codex-acp-package "$CODEX_ACP_VERSION" "$(pkg @agentclientprotocol/codex-acp)"
check opencode-package "$OPENCODE_VERSION" "$(pkg opencode-ai)"

# Each CLI reports signed out, with no network: the text is the assertion,
# not the exit code.
claude_status=$(claude auth status 2>&1)
contains claude-signed-out '"loggedIn": false' "$claude_status"
codex_status=$(codex login status 2>&1)
contains codex-signed-out 'Not logged in' "$codex_status"
opencode_status=$(opencode auth list 2>&1)
contains opencode-signed-out '0 credentials' "$opencode_status"

# The intent-log library: Python from site-packages, TypeScript by absolute
# path, and both launchers.
if python3 -c 'import toshi_intents' 2>/dev/null; then
	echo "ok   python3 -c 'import toshi_intents'"
else
	echo "FAIL python3 cannot import toshi_intents"
	failed=1
fi
ts_probe=$(node --input-type=module -e "
	import { open } from '/opt/toshi/service-agent/typescript/intents.ts';
	const log = open('$HOME/typescript-probe.db', { TOSHI_RUN_ID: 'run-1' });
	const step = log.begin('probe', 'probe it');
	log.finish('probe', { ok: true });
	log.close();
	console.log(step.key);
" 2>&1)
check typescript-import run-1/probe "$ts_probe"
py_cli=$(TOSHI_RUN_ID=run-1 toshi-intents begin "$HOME/launcher.db" probe 'probe it' 2>&1)
contains toshi-intents '"key": "run-1/probe"' "$py_cli"
ts_cli=$(TOSHI_RUN_ID=run-1 toshi-intents-ts begin "$HOME/launcher-ts.db" probe 'probe it' 2>&1)
contains toshi-intents-ts '"key":"run-1/probe"' "$ts_cli"

# Both library suites, with the image's runtimes. The mount is read-only, so
# they run from a copy under HOME.
cp -a /opt/smoke/lib "$HOME/lib"
if (cd "$HOME/lib/python" && python3 -W error::ResourceWarning -m unittest -v) >"$HOME/python-suite.log" 2>&1; then
	echo "ok   python suite ($(grep -cE '^test_' "$HOME/python-suite.log") tests)"
else
	echo "FAIL python suite:"
	cat "$HOME/python-suite.log"
	failed=1
fi
if (cd "$HOME/lib/typescript" && node --test) >"$HOME/typescript-suite.log" 2>&1; then
	echo "ok   typescript suite ($(awk '/pass [0-9]+$/ {v = $NF} END {print v}' "$HOME/typescript-suite.log") tests)"
else
	echo "FAIL typescript suite:"
	cat "$HOME/typescript-suite.log"
	failed=1
fi

# The pins the image carries, and each licence at its documented path.
exists versions-file /usr/share/toshi/service-agent/versions.env
check versions-node "$NODE_VERSION" "$(sed -n 's/^NODE_VERSION=//p' /usr/share/toshi/service-agent/versions.env)"
lic=/usr/share/licenses/toshi-service-agent
exists claude-licence "$lic/claude-code/LICENSE.md"
exists codex-licence "$lic/codex/LICENSE"
exists codex-notice "$lic/codex/NOTICE"
exists opencode-licence "$lic/opencode/LICENSE"
exists claude-agent-acp-licence "$lic/claude-agent-acp/LICENSE"
exists codex-acp-licence "$lic/codex-acp/LICENSE"

if ((failed)); then
	echo "smoke test failed"
	exit 1
fi
echo "smoke test passed"
