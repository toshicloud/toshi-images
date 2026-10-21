#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/versions.env"

CARGO_BIN=/home/runner/.cargo/bin
RUSTC="${CARGO_BIN}/rustc"
CARGO="${CARGO_BIN}/cargo"

installed_version() {
	runuser -u runner -- "$RUSTC" --version | awk '{print $2}'
}

rust_tools_ok() {
	runuser -u runner -- env PATH="${CARGO_BIN}:${PATH}" "$CARGO" fmt --version >/dev/null
	runuser -u runner -- env PATH="${CARGO_BIN}:${PATH}" "$CARGO" clippy --version >/dev/null
}

if [[ -x $RUSTC ]]; then
	version=$(installed_version)
	if [[ $version == "$RUST_VERSION" ]] && rust_tools_ok; then
		path_prepend "$CARGO_BIN"
		toolset_done rust "$version"
		exit 0
	fi
fi

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
# runner runs the installer, and mktemp creates the directory for root only.
chmod 0755 "$tmpdir"
installer="${tmpdir}/rustup-init"
fetch_verified "$RUSTUP_URL" sha256 "$RUSTUP_INIT_SHA256" "$installer"
chmod +x "$installer"

bounded runuser -u runner -- env HOME=/home/runner "$installer" -y --no-modify-path \
	--profile minimal --default-toolchain "$RUST_VERSION" \
	--component rustfmt --component clippy

path_prepend "$CARGO_BIN"

version=$(installed_version)
if [[ $version != "$RUST_VERSION" ]]; then
	echo "rust.sh: expected ${RUST_VERSION}, got ${version}" >&2
	exit 1
fi

if ! rust_tools_ok; then
	echo "rust.sh: rustfmt or clippy unavailable" >&2
	exit 1
fi

toolset_done rust "$version"
