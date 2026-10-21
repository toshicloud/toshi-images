#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/versions.env"

# mise installs the tools in ci/mise.toml, the pins of Toshi's own
# mise.toml, into its system directory. Every mise looks there, so a job's
# `mise install` finds them and downloads nothing. Go and Node are the image's
# own (go.sh, node.sh), linked in so that mise does not fetch them again.
SYSTEM_INSTALLS=/usr/local/share/mise/installs

installed_version() {
	/usr/local/bin/mise --version | awk '{print $1}'
}

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

if [[ ! -x /usr/local/bin/mise ]] || [[ $(installed_version) != "$MISE_VERSION" ]]; then
	fetch_verified "$MISE_URL" sha256 "$MISE_SHA256" "${tmpdir}/mise"
	install -m 0755 "${tmpdir}/mise" /usr/local/bin/mise
fi

mkdir -p "${SYSTEM_INSTALLS}/go" "${SYSTEM_INSTALLS}/node"
ln -sfn /usr/local/go "${SYSTEM_INSTALLS}/go/${GO_VERSION}"
ln -sfn /usr/local "${SYSTEM_INSTALLS}/node/${NODE_VERSION}"

# The seed ISO is read-only, and the lock file pins each download's SHA256.
# Everything mise and Go write besides the installs stays in tmpdir.
cp "$SCRIPT_DIR/ci/mise.toml" "$SCRIPT_DIR/ci/mise.lock" "$tmpdir/"
(
	cd "$tmpdir"
	export MISE_TRUSTED_CONFIG_PATHS="$tmpdir" MISE_YES=1 MISE_LOCKED=1
	export MISE_CONFIG_DIR="${tmpdir}/config" MISE_DATA_DIR="${tmpdir}/data" MISE_CACHE_DIR="${tmpdir}/cache" MISE_STATE_DIR="${tmpdir}/state"
	export GOPATH="${tmpdir}/gopath" GOCACHE="${tmpdir}/gocache"
	bounded mise install --system
	mise ls --current
	for bin in task golangci-lint buf goreleaser protoc-gen-go protoc-gen-connect-go; do
		ln -sfn "$(mise which "$bin")" "/usr/local/bin/${bin}"
	done
)

version=$(installed_version)
if [[ $version != "$MISE_VERSION" ]]; then
	echo "mise.sh: expected ${MISE_VERSION}, got ${version}" >&2
	exit 1
fi

toolset_done mise "$version"
