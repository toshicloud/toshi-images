#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/versions.env"

installed_version() {
	DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 dotnet --version
}

if command -v dotnet >/dev/null 2>&1; then
	version=$(installed_version)
	if [[ $version == "$DOTNET_SDK_VERSION" ]]; then
		toolset_done dotnet "$version"
		exit 0
	fi
fi

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
archive="${tmpdir}/dotnet-sdk.tar.gz"
fetch_verified "$DOTNET_URL" sha512 "$DOTNET_SDK_SHA512" "$archive"

rm -rf /usr/share/dotnet
mkdir -p /usr/share/dotnet
tar -xzf "$archive" -C /usr/share/dotnet
ln -sf /usr/share/dotnet/dotnet /usr/local/bin/dotnet

env_set DOTNET_ROOT /usr/share/dotnet
env_set DOTNET_CLI_TELEMETRY_OPTOUT 1
env_set DOTNET_NOLOGO 1

if ! dpkg -s libicu74 >/dev/null 2>&1; then
	export DEBIAN_FRONTEND=noninteractive
	apt_install --no-install-recommends libicu74
fi

version=$(installed_version)
if [[ $version != "$DOTNET_SDK_VERSION" ]]; then
	echo "dotnet.sh: expected ${DOTNET_SDK_VERSION}, got ${version}" >&2
	exit 1
fi

toolset_done dotnet "$version"
