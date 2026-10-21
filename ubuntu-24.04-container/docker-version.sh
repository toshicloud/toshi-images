# shellcheck shell=bash
# Appended to docker.sh's lines before its daemon section to make
# docker-nodaemon.sh (Dockerfile): an image build has no daemon, so this
# checks the installed package's version where docker.sh checks the server's.
docker buildx version >/dev/null
docker compose version >/dev/null

version=$(dpkg-query -W -f '${Version}' docker-ce | sed -E 's/^[0-9]+://; s/-.*//')
if [[ $version != "$DOCKER_VERSION" ]]; then
	echo "docker-nodaemon.sh: expected package ${DOCKER_VERSION}, got ${version}" >&2
	exit 1
fi

toolset_done docker "$version"
