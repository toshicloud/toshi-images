#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/versions.env"

export DEBIAN_FRONTEND=noninteractive

# Docker's own packages look for CLI plugins here (the docker-ce-cli package
# does not create the directory itself).
CLI_PLUGINS=/usr/libexec/docker/cli-plugins

server_version() {
	docker version --format '{{.Server.Version}}' 2>/dev/null || true
}

plugins_ok() {
	[[ -x "${CLI_PLUGINS}/docker-buildx" ]] && [[ -x "${CLI_PLUGINS}/docker-compose" ]]
}

if command -v docker >/dev/null 2>&1 &&
	[[ $(server_version) == "$DOCKER_VERSION" ]] &&
	plugins_ok; then
	toolset_done docker "$(server_version)"
	exit 0
fi

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

fetch_verified "${DOCKER_DEB_URL}/${DOCKER_CONTAINERD_DEB}" sha256 "$DOCKER_CONTAINERD_SHA256" "${tmpdir}/${DOCKER_CONTAINERD_DEB}"
fetch_verified "${DOCKER_DEB_URL}/${DOCKER_CE_CLI_DEB}" sha256 "$DOCKER_CE_CLI_SHA256" "${tmpdir}/${DOCKER_CE_CLI_DEB}"
fetch_verified "${DOCKER_DEB_URL}/${DOCKER_CE_DEB}" sha256 "$DOCKER_CE_SHA256" "${tmpdir}/${DOCKER_CE_DEB}"

# The three packages are local; apt resolves their dependencies (iptables,
# libsystemd0) from the base image's configured repositories.
(
	cd "$tmpdir"
	apt_install --no-install-recommends ./containerd.io_*.deb ./docker-ce-cli_*.deb ./docker-ce_*.deb
)

fetch_verified "$DOCKER_BUILDX_URL" sha256 "$DOCKER_BUILDX_SHA256" "${tmpdir}/docker-buildx"
fetch_verified "$DOCKER_COMPOSE_URL" sha256 "$DOCKER_COMPOSE_SHA256" "${tmpdir}/docker-compose"

mkdir -p "$CLI_PLUGINS"
install -m 0755 "${tmpdir}/docker-buildx" "${CLI_PLUGINS}/docker-buildx"
install -m 0755 "${tmpdir}/docker-compose" "${CLI_PLUGINS}/docker-compose"

# user-data adds runner to this group; create it here so the group exists even
# if the package's postinst has not run.
groupadd -f docker

# Rootful daemon, started so the server version below is real.
systemctl enable docker.service containerd
systemctl start docker.service

for _ in $(seq 1 30); do
	if docker info >/dev/null 2>&1; then
		break
	fi
	sleep 1
done
docker info >/dev/null

docker buildx version >/dev/null
docker compose version >/dev/null

version=$(server_version)
if [[ $version != "$DOCKER_VERSION" ]]; then
	echo "docker.sh: expected server ${DOCKER_VERSION}, got ${version}" >&2
	exit 1
fi

toolset_done docker "$version"
