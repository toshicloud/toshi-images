#!/bin/bash
# Installs the Railpack releases the image carries: the CLI of every version
# in RAILPACK_VERSIONS, and the BuildKit frontend of each as an OCI archive
# beside it. The pins are next to guest.env at the repository root; the image
# build copies that file into the seed next to this directory.
set -euo pipefail

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/versions.env"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/../railpack.env"

ROOT=/opt/toshi/railpack
PINNED="${ROOT}/pinned"
ASSET_ARCH=x86_64-unknown-linux-musl
RELEASES=https://github.com/railwayapp/railpack/releases/download
FRONTEND_REPOSITORY=ghcr.io/railwayapp/railpack-frontend

# Provisioning runs as root without HOME (cloud-init sets none), and oras
# looks for its configuration under the user's home directory.
export HOME="${HOME:-/root}"

# pin prints the value of one version's pin, such as
# RAILPACK_CLI_SHA256_v0_43_0, or nothing when railpack.env has no such line.
pin() {
	local prefix=$1 version=$2
	local name="${prefix}_${version//./_}"
	printf '%s' "${!name:-}"
}

# `pinned` names the version the image carries now, so it must be one of the
# versions the image installs.
case " ${RAILPACK_VERSIONS} " in
*" ${RAILPACK_VERSION} "*)
	;;
*)
	echo "railpack.sh: RAILPACK_VERSION ${RAILPACK_VERSION} is not in RAILPACK_VERSIONS (${RAILPACK_VERSIONS})" >&2
	exit 1
	;;
esac

command -v jq >/dev/null 2>&1 || {
	echo "railpack.sh: jq is needed to read the frontend archive" >&2
	exit 1
}

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

# installed says whether a version is there and still matches its pins: the
# CLI is the release the checksum names, the frontend archive is the image
# the digest names, and the CLI reports the version.
installed() {
	local dir=$1 version=$2 sha=$3 digest=$4
	[[ -x "${dir}/railpack" ]] || return 1
	[[ "$(cat "${dir}/railpack.sha256" 2>/dev/null)" == "${sha}" ]] || return 1
	[[ -f "${dir}/frontend.tar" ]] || return 1
	[[ "$(cat "${dir}/frontend.digest" 2>/dev/null)" == "${digest}" ]] || return 1
	[[ "$("${dir}/railpack" --version 2>/dev/null | awk '{print $NF}')" == "${version#v}" ]] || return 1
}

oras_ready=""
# ensure_oras fetches oras once, when a version has to be installed. It is
# not kept: the images carry Railpack, not the tool that made its archive.
ensure_oras() {
	local reported
	[[ -n "${oras_ready}" ]] && return 0
	fetch_verified "${RAILPACK_ORAS_URL}" sha256 "${RAILPACK_ORAS_SHA256}" "${tmpdir}/oras.tar.gz"
	tar -xzf "${tmpdir}/oras.tar.gz" -C "${tmpdir}" oras
	reported=$("${tmpdir}/oras" version | awk '$1 == "Version:" {print $2}')
	if [[ "${reported}" != "${RAILPACK_ORAS_VERSION}" ]]; then
		echo "railpack.sh: oras reports ${reported}, expected ${RAILPACK_ORAS_VERSION}" >&2
		exit 1
	fi
	oras_ready=1
}

# copy_frontend writes the frontend image's OCI layout, so that a retry
# starts from an empty directory. oras checks every blob against the digest
# the tag resolved to.
copy_frontend() {
	local digest=$1 version=$2 layout=$3
	rm -rf "${layout}"
	timeout -k 10 "${TRY_MAX_TIME}" "${tmpdir}/oras" copy "${FRONTEND_REPOSITORY}@${digest}" \
		--to-oci-layout "${layout}:${version}"
}

# install_version downloads one release, checks the asset against the
# release's checksums.txt and the pinned SHA-256, installs the CLI with its
# licence, and archives the frontend image beside it.
install_version() {
	local version=$1 sha=$2 digest=$3 dir=$4
	local asset="railpack-${version}-${ASSET_ARCH}.tar.gz"
	local work="${tmpdir}/${version}"
	local layout="${work}/frontend"
	local checksum archive_digest reported

	mkdir -p "${work}"
	fetch "${RELEASES}/${version}/checksums.txt" "${work}/checksums.txt"
	checksum=$(awk -v asset="${asset}" '$2 == asset {print $1}' "${work}/checksums.txt")
	if [[ "${checksum}" != "${sha}" ]]; then
		echo "railpack.sh: ${version} checksums.txt gives ${checksum:-no line} for ${asset}, not the pinned ${sha}" >&2
		exit 1
	fi
	fetch_verified "${RELEASES}/${version}/${asset}" sha256 "${sha}" "${work}/${asset}"
	ensure_oras
	tar -xzf "${work}/${asset}" -C "${work}"

	mkdir -p "${dir}"
	install -m 0755 "${work}/railpack" "${dir}/railpack"
	install -m 0644 "${work}/LICENSE" "${dir}/LICENSE"
	printf '%s\n' "${sha}" >"${dir}/railpack.sha256"
	reported=$("${dir}/railpack" --version | awk '{print $NF}')
	if [[ "${reported}" != "${version#v}" ]]; then
		echo "railpack.sh: ${version} installed, but its CLI reports ${reported}" >&2
		exit 1
	fi

	retry copy_frontend "${digest}" "${version}" "${layout}"
	# The layout's index names the tag's digest, which is the digest the pin
	# carries, and holds the linux/amd64 image the runner runs.
	archive_digest=$(jq -r --arg version "${version}" \
		'.manifests[] | select(.annotations["org.opencontainers.image.ref.name"] == $version) | .digest' \
		"${layout}/index.json")
	if [[ "${archive_digest}" != "${digest}" ]]; then
		echo "railpack.sh: the ${version} frontend archive names ${archive_digest:-no manifest}, not the pinned ${digest}" >&2
		exit 1
	fi
	if ! jq -e '.manifests[] | select(.platform.os == "linux" and .platform.architecture == "amd64")' \
		"${layout}/index.json" >/dev/null; then
		echo "railpack.sh: the ${version} frontend archive holds no linux/amd64 image" >&2
		exit 1
	fi
	tar -C "${layout}" -cf "${dir}/frontend.tar" index.json oci-layout blobs
	printf '%s\n' "${digest}" >"${dir}/frontend.digest"
	rm -rf "${layout}"
	echo "railpack ${version} installed"
}

mkdir -p "${ROOT}"
for version in ${RAILPACK_VERSIONS}; do
	sha=$(pin RAILPACK_CLI_SHA256 "${version}")
	digest=$(pin RAILPACK_FRONTEND_DIGEST "${version}")
	if [[ -z "${sha}" || -z "${digest}" ]]; then
		echo "railpack.sh: no pin for ${version}: railpack.env needs RAILPACK_CLI_SHA256_${version//./_} and RAILPACK_FRONTEND_DIGEST_${version//./_}" >&2
		exit 1
	fi
	if installed "${ROOT}/${version}" "${version}" "${sha}" "${digest}"; then
		echo "railpack ${version} already installed"
		continue
	fi
	install_version "${version}" "${sha}" "${digest}" "${ROOT}/${version}"
done

printf '%s\n' "${RAILPACK_VERSION}" >"${PINNED}"
reported=$("${ROOT}/${RAILPACK_VERSION}/railpack" --version | awk '{print $NF}')
toolset_done railpack "${reported}"
