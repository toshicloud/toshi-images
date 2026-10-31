#!/bin/bash
# Builds the service agent image with Docker (README.md, "The image").
# Usage: service-agent/build.sh [tag]
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
tag=${1:-toshi-service-agent:latest}

# shellcheck disable=SC1091
. "$here/versions.env"
: "${BASE_IMAGE:?versions.env pins no BASE_IMAGE}"
: "${BASE_DIGEST:?versions.env pins no BASE_DIGEST}"
: "${NODE_VERSION:?versions.env pins no NODE_VERSION}"
: "${PYTHON_VERSION:?versions.env pins no PYTHON_VERSION}"

# The base image is pinned by digest: a Dockerfile whose BASE has none stops
# here, before anything is fetched.
if ! grep -qE '^ARG BASE=[^@ ]+@sha256:[0-9a-f]{64}$' "$here/Dockerfile"; then
	echo "build.sh: the Dockerfile's BASE is not pinned by a sha256 digest:" >&2
	grep '^ARG BASE=' "$here/Dockerfile" >&2 || echo "(no ARG BASE line)" >&2
	exit 1
fi
base=$(sed -n 's/^ARG BASE=//p' "$here/Dockerfile")
if [[ $base != "$BASE_IMAGE@$BASE_DIGEST" ]]; then
	echo "build.sh: the Dockerfile's base is '${base}', versions.env pins '${BASE_IMAGE}@${BASE_DIGEST}'" >&2
	exit 1
fi

# package.json and the lock install exactly what versions.env pins. npm ci
# verifies the lock's integrity, so a pin that moved without the lock fails
# at that package.
pin() {
	local name=$1 want=$2 got
	got=$(sed -nE "s|^[[:space:]]*\"${name}\"[[:space:]]*:[[:space:]]*\"([^\"]+)\",?[[:space:]]*\$|\1|p" "$here/package.json")
	[[ $want =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
		echo "build.sh: versions.env's version for ${name} is '${want}', not an exact version" >&2
		exit 1
	}
	if [[ $got != "$want" ]]; then
		echo "build.sh: package.json's ${name} is '${got:-missing}', versions.env pins ${want}" >&2
		exit 1
	fi
}
pin '@anthropic-ai/claude-code' "$CLAUDE_CODE_VERSION"
pin '@agentclientprotocol/claude-agent-acp' "$CLAUDE_AGENT_ACP_VERSION"
pin '@openai/codex' "$CODEX_VERSION"
pin '@agentclientprotocol/codex-acp' "$CODEX_ACP_VERSION"
pin 'opencode-ai' "$OPENCODE_VERSION"
if ! grep -q '"lockfileVersion": 3' "$here/package-lock.json"; then
	echo "build.sh: package-lock.json is not lockfileVersion 3; regenerate it with npm install --package-lock-only" >&2
	exit 1
fi

# Codex's licence files are committed, from the tag versions.env names.
licence() {
	local file=$1 var=$2 want got
	want=${!var}
	got=$(sha256sum "$here/licences/codex/${file}" | cut -d' ' -f1)
	if [[ $got != "$want" ]]; then
		echo "build.sh: licences/codex/${file} is ${got}, versions.env pins ${var}=${want}" >&2
		exit 1
	fi
}
licence LICENSE CODEX_LICENSE_SHA256
licence NOTICE CODEX_NOTICE_SHA256

# The image is labelled with its version: IMAGE_VERSION when set, else in a
# checkout of this repository the commit's, as `git describe` names it.
root=$here/..
version=${IMAGE_VERSION:-}
if [[ -z $version ]] && git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
	version=$(git -C "$root" describe --tags --always --dirty)
fi
: "${version:?set IMAGE_VERSION, the version the image is labelled with}"
echo "image version: ${version}"

labels=(--label "org.opencontainers.image.version=${version}")
if revision=$(git -C "$root" rev-parse HEAD 2>/dev/null); then
	labels+=(--label "org.opencontainers.image.revision=${revision}")
fi
docker build --progress=plain "${labels[@]}" \
	-f "$here/Dockerfile" -t "$tag" "$root"
