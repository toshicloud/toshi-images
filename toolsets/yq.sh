#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/versions.env"

# `yq --version` prints "yq (https://github.com/mikefarah/yq/) version v4.54.1".
installed_version() {
	local v
	v=$(yq --version | awk '{ print $NF }')
	echo "${v#v}"
}

if command -v yq >/dev/null 2>&1 && [[ $(installed_version) == "$YQ_VERSION" ]]; then
	toolset_done yq "$(installed_version)"
	exit 0
fi

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
binary="${tmpdir}/yq"
fetch_verified "$YQ_URL" sha256 "$YQ_SHA256" "$binary"
install -m 0755 "$binary" /usr/bin/yq

version=$(installed_version)
if [[ $version != "$YQ_VERSION" ]]; then
	echo "yq.sh: expected ${YQ_VERSION}, got ${version}" >&2
	exit 1
fi

toolset_done yq "$version"
