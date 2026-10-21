#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/versions.env"

installed_version() {
	cmake --version | awk 'NR == 1 { print $3 }'
}

if command -v cmake >/dev/null 2>&1 && [[ $(installed_version) == "$CMAKE_VERSION" ]]; then
	toolset_done cmake "$(installed_version)"
	exit 0
fi

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
archive="${tmpdir}/cmake.tar.gz"
fetch_verified "$CMAKE_URL" sha256 "$CMAKE_SHA256" "$archive"

tar -xzf "$archive" -C /usr/local --strip-components=1 --no-same-owner

version=$(installed_version)
if [[ $version != "$CMAKE_VERSION" ]]; then
	echo "cmake.sh: expected ${CMAKE_VERSION}, got ${version}" >&2
	exit 1
fi

toolset_done cmake "$version"
