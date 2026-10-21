#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/versions.env"

# `git-lfs version` prints "git-lfs/3.8.0 (GitHub; linux amd64; go 1.27.0)".
installed_version() {
	local v
	v=$(git-lfs version | awk '{ print $1 }')
	echo "${v#git-lfs/}"
}

if command -v git-lfs >/dev/null 2>&1 && [[ $(installed_version) == "$GIT_LFS_VERSION" ]]; then
	git lfs install --system --skip-repo
	toolset_done git-lfs "$(installed_version)"
	exit 0
fi

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
archive="${tmpdir}/git-lfs.tar.gz"
fetch_verified "$GIT_LFS_URL" sha256 "$GIT_LFS_SHA256" "$archive"

# The tarball holds git-lfs-<version>/git-lfs; strip the directory.
tar -xzf "$archive" -C "$tmpdir" --strip-components=1 "git-lfs-${GIT_LFS_VERSION}/git-lfs"
install -m 0755 "${tmpdir}/git-lfs" /usr/bin/git-lfs

git lfs install --system --skip-repo

version=$(installed_version)
if [[ $version != "$GIT_LFS_VERSION" ]]; then
	echo "git-lfs.sh: expected ${GIT_LFS_VERSION}, got ${version}" >&2
	exit 1
fi

toolset_done git-lfs "$version"
