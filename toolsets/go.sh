#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/versions.env"

installed_version() {
	local v
	v=$(/usr/local/go/bin/go env GOVERSION)
	echo "${v#go}"
}

if [[ -x /usr/local/go/bin/go ]]; then
	version=$(installed_version)
	if [[ $version == "$GO_VERSION" ]]; then
		path_prepend /usr/local/go/bin
		toolset_done go "$version installed"
		exit 0
	fi
fi

# An image build that fetched the tarball on its host puts it in the seed,
# next to this directory (ubuntu-24.04/build.sh). Then nothing is
# downloaded here.
seed_archive="${SCRIPT_DIR}/../go.tar.gz"
if [[ -f $seed_archive ]]; then
	if ! printf '%s  %s\n' "$GO_SHA256" "$seed_archive" | sha256sum -c - >/dev/null; then
		echo "go.sh: sha256 mismatch for ${seed_archive}" >&2
		exit 1
	fi
	archive=$seed_archive
	from=seed
else
	tmpdir=$(mktemp -d)
	trap 'rm -rf "$tmpdir"' EXIT
	archive="${tmpdir}/go.tar.gz"
	fetch_verified "$GO_URL" sha256 "$GO_SHA256" "$archive"
	from=download
fi

rm -rf /usr/local/go
tar -xzf "$archive" -C /usr/local
path_prepend /usr/local/go/bin

version=$(installed_version)
if [[ $version != "$GO_VERSION" ]]; then
	echo "go.sh: expected ${GO_VERSION}, got ${version}" >&2
	exit 1
fi

toolset_done go "$version $from"
