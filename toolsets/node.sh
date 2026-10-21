#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/versions.env"

installed_version() {
	local v
	v=$(node --version)
	echo "${v#v}"
}

if command -v node >/dev/null 2>&1; then
	version=$(installed_version)
	if [[ $version == "$NODE_VERSION" ]]; then
		toolset_done node "$version"
		exit 0
	fi
fi

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
archive="${tmpdir}/node.tar.xz"
fetch_verified "$NODE_URL" sha256 "$NODE_SHA256" "$archive"

tar -xJf "$archive" -C /usr/local --strip-components=1 --no-same-owner

corepack enable

for bin in node npm npx corepack; do
	if [[ ! -x /usr/local/bin/$bin ]]; then
		echo "node.sh: /usr/local/bin/${bin} missing" >&2
		exit 1
	fi
done

version=$(installed_version)
if [[ $version != "$NODE_VERSION" ]]; then
	echo "node.sh: expected ${NODE_VERSION}, got ${version}" >&2
	exit 1
fi

toolset_done node "$version"
