#!/bin/bash
# Checks a built container tier image with a plain `docker run`, without
# Sysbox, so the entrypoint's dockerd is not started: the image's version
# label, the runner's version, each toolset's version against
# toolsets/versions.env, sudo for runner, and the commands and packages the
# recipe needs.
# Usage: ubuntu-24.04-container/smoke-test.sh [image]
# The pins come from the env files the container reads at run time.
# shellcheck disable=SC1091,SC2153
set -euo pipefail
here=$(dirname "$(readlink -f "$0")")

if [[ ${1:-} != --inside ]]; then
	image=${1:-toshi-runner:ubuntu-24.04}
	label=$(docker image inspect -f '{{index .Config.Labels "org.opencontainers.image.version"}}' "$image")
	exec docker run --rm --user runner --entrypoint /bin/bash \
		-e IMAGE_VERSION="$label" \
		-v "$here/smoke-test.sh:/opt/smoke/smoke-test.sh:ro" \
		-v "$here/Dockerfile:/opt/smoke/Dockerfile:ro" \
		-v "$here/../toolsets/versions.env:/opt/smoke/toolsets.env:ro" \
		-v "$here/../railpack.env:/opt/smoke/railpack.env:ro" \
		-v "$here/../ubuntu-24.04/versions.env:/opt/smoke/ubuntu.env:ro" \
		"$image" /opt/smoke/smoke-test.sh --inside
fi

# In the container, as runner, with the environment a job gets.
set +eu
set -a
. /etc/environment
. /opt/smoke/toolsets.env
. /opt/smoke/railpack.env
. /opt/smoke/ubuntu.env
set +a
failed=0
checked=" "
# check <name> <want> <got>
check() {
	checked+="$1 "
	if [[ -n $3 && $3 == "$2" ]]; then
		echo "ok   $1 $3"
	else
		echo "FAIL $1: want ${2:-a value}, got ${3:-nothing}"
		failed=1
	fi
}

if [[ -z $IMAGE_VERSION || $IMAGE_VERSION == dev ]]; then
	echo "FAIL the image's version label is '${IMAGE_VERSION}'"
	failed=1
fi
# The runner's archive is checked against RUNNER_SHA256 when the image is
# built (fetch_verified); the image keeps only what it unpacked.
check runner "$RUNNER_VERSION" "$(/opt/actions-runner/bin/Runner.Listener --version 2>/dev/null)"

# Each toolset's version, read the way its script reads it.
v=$(python3 -c 'import platform; print(platform.python_version())')
check python "$PYTHON_SERIES" "${v%.*}"
v=$(node --version)
check node "$NODE_VERSION" "${v#v}"
v=$(go env GOVERSION)
check go "$GO_VERSION" "${v#go}"
check rust "$RUST_VERSION" "$(rustc --version | awk '{print $2}')"
check rustup "$RUSTUP_VERSION" "$(rustup --version 2>/dev/null | awk 'NR == 1 {print $2}')"
check dotnet "$DOTNET_SDK_VERSION" "$(dotnet --version)"
check mise "$MISE_VERSION" "$(mise --version 2>/dev/null | awk '{print $1}')"
v=$(dpkg-query -W -f '${Version}' docker-ce | sed -E 's/^[0-9]+://; s/-.*//')
check docker "$DOCKER_VERSION" "$v"
v=$(docker buildx version | awk '{print $2}')
check docker-buildx "$DOCKER_BUILDX_VERSION" "${v#v}"
check docker-compose "$DOCKER_COMPOSE_VERSION" "$(docker compose version --short)"
for major in 17 21 25; do
	home=JAVA_HOME_${major}_X64 pin=JAVA${major}_VERSION
	check "java-$major" "${!pin%%+*}" "$("${!home}/bin/java" -version 2>&1 | awk -F'"' 'NR == 1 {print $2}')"
done
checked+="java "
check cmake "$CMAKE_VERSION" "$(cmake --version | awk 'NR == 1 {print $3}')"
check gh "$GH_VERSION" "$(gh --version | awk 'NR == 1 {print $3}')"
v=$(yq --version | awk '{print $NF}')
check yq "$YQ_VERSION" "${v#v}"
v=$(git-lfs version | awk '{print $1}')
check git-lfs "$GIT_LFS_VERSION" "${v#git-lfs/}"
# Railpack: the pin, the CLI it names, and the frontend archive that pin
# describes.
railpack=/opt/toshi/railpack
railpack_version=$(cat "$railpack/pinned")
check railpack "$RAILPACK_VERSION" "$railpack_version"
check railpack-cli "${RAILPACK_VERSION#v}" "$("$railpack/$railpack_version/railpack" --version | awk '{print $NF}')"
railpack_digest=$(cat "$railpack/$railpack_version/frontend.digest")
check railpack-frontend "$railpack_digest" \
	"$(tar -xOf "$railpack/$railpack_version/frontend.tar" index.json \
		| jq -r --arg version "$railpack_version" '.manifests[] | select(.annotations["org.opencontainers.image.ref.name"] == $version) | .digest')"
railpack_digest_pin="RAILPACK_FRONTEND_DIGEST_${RAILPACK_VERSION//./_}"
check railpack-frontend-pin "${!railpack_digest_pin}" "$railpack_digest"
# A toolset added to TOOLSETS without a line above fails here.
for t in $TOOLSETS; do
	if [[ $checked != *" $t "* ]]; then
		echo "FAIL toolset $t has no check in smoke-test.sh"
		failed=1
	fi
done

check sudo 0 "$(sudo -n id -u)"

# What the recipe needs after cloud-exclude.txt: the commands of the
# Dockerfile's tool check, two the jobs use from the cloud image's packages,
# and every package the Dockerfile installs by name.
cmds=$(grep -oP 'for c in \K[^;]+(?=; do command -v)' /opt/smoke/Dockerfile)
for c in $cmds gpg envsubst; do
	command -v "$c" >/dev/null || {
		echo "FAIL command $c is missing"
		failed=1
	}
done
pkgs=$(grep -oP 'apt_install --no-install-recommends \K[^;"$]+(?=;)' /opt/smoke/Dockerfile)
for p in $pkgs; do
	[[ $(dpkg-query -W -f '${Status}' "$p" 2>/dev/null) == "install ok installed" ]] || {
		echo "FAIL package $p is not installed"
		failed=1
	}
done
echo "ok   $(wc -w <<<"$cmds") commands and gpg, envsubst; $(wc -w <<<"$pkgs") packages"

if ((failed)); then
	echo "smoke test failed"
	exit 1
fi
echo "smoke test passed"
