#!/bin/bash
# Builds the container tier's runner image with Docker.
# Usage: ubuntu-24.04-container/build.sh [tag]
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")
tag=${1:-toshi-runner:ubuntu-24.04}
# The base image is pinned by digest: a Dockerfile whose BASE has none stops
# here, before anything is fetched.
if ! grep -qE '^ARG BASE=[^@ ]+@sha256:[0-9a-f]{64}$' "$here/Dockerfile"; then
	echo "build.sh: the Dockerfile's BASE is not pinned by a sha256 digest:" >&2
	grep '^ARG BASE=' "$here/Dockerfile" >&2 || echo "(no ARG BASE line)" >&2
	exit 1
fi
# The Chromium libraries follow the Playwright release versions.env pins,
# unless PLAYWRIGHT_VERSION is set.
if [[ -z ${PLAYWRIGHT_VERSION:-} ]]; then
	# shellcheck disable=SC1091
	PLAYWRIGHT_VERSION=$(source "$here/versions.env" && echo "$PLAYWRIGHT_VERSION")
fi
: "${PLAYWRIGHT_VERSION:?versions.env pins no PLAYWRIGHT_VERSION}"

# The image has no guest helper: the container provider bind-mounts the
# host's own, which ships with the agent, so an image outlives agent
# upgrades. Its version is IMAGE_VERSION when set, else in a
# checkout of this repository the commit's, as `git describe` names it.
root=$here/..
version=${IMAGE_VERSION:-}
if [[ -z $version ]] && git -C "$root" rev-parse --git-dir >/dev/null 2>&1; then
	version=$(git -C "$root" describe --tags --always --dirty)
fi
: "${version:?set IMAGE_VERSION, the version the image is labelled with}"
echo "image version: ${version}"

# The image carries its version, and in a checkout the commit, as OCI
# labels.
labels=(--label "org.opencontainers.image.version=${version}")
if revision=$(git -C "$root" rev-parse HEAD 2>/dev/null); then
	labels+=(--label "org.opencontainers.image.revision=${revision}")
fi
docker build --progress=plain --build-arg PLAYWRIGHT_VERSION="$PLAYWRIGHT_VERSION" \
	"${labels[@]}" \
	-f "$here/Dockerfile" -t "$tag" "$here/.."
