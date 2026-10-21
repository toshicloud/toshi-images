#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/versions.env"

export DEBIAN_FRONTEND=noninteractive

installed_version() {
	gh --version | awk 'NR == 1 { print $3 }'
}

if command -v gh >/dev/null 2>&1 && [[ $(installed_version) == "$GH_VERSION" ]]; then
	toolset_done gh "$(installed_version)"
	exit 0
fi

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
deb="${tmpdir}/gh_${GH_VERSION}_linux_amd64.deb"
fetch_verified "$GH_URL" sha256 "$GH_SHA256" "$deb"

(
	cd "$tmpdir"
	apt_install ./gh_*.deb
)

version=$(installed_version)
if [[ $version != "$GH_VERSION" ]]; then
	echo "gh.sh: expected ${GH_VERSION}, got ${version}" >&2
	exit 1
fi

toolset_done gh "$version"
