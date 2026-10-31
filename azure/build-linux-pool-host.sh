#!/usr/bin/env bash
# Builds the Compute Gallery image version a Linux cloud pool's host boots
# on Azure, with linux-pool-host.pkr.hcl.
#
# The agent archive comes from the Toshi release linux-pool-host/versions.env
# pins. This script takes it from AGENT_TARBALL, or downloads it with the
# GitHub CLI, and checks its SHA-256 before Packer uploads it to the build
# instance, which checks it again.
#
# The gallery's image definition named AZURE_IMAGE_NAME must be Gen2,
# Generalized, x64 and Standard. The script creates it when it is absent
# and refuses an existing one that differs.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

AZURE_SUBSCRIPTION_ID="${AZURE_SUBSCRIPTION_ID:-}"
AZURE_GALLERY_RESOURCE_GROUP="${AZURE_GALLERY_RESOURCE_GROUP:-}"
AZURE_GALLERY="${AZURE_GALLERY:-}"
AZURE_LOCATION="${AZURE_LOCATION:-}"
AZURE_BUILD_RESOURCE_GROUP="${AZURE_BUILD_RESOURCE_GROUP:-}"
AZURE_IMAGE_NAME="${AZURE_IMAGE_NAME:-linux-pool-host}"
AZURE_CLIENT_ID="${AZURE_CLIENT_ID:-}"
AZURE_CLIENT_SECRET="${AZURE_CLIENT_SECRET:-}"
AZURE_TENANT_ID="${AZURE_TENANT_ID:-}"
IMAGE_VERSION="${IMAGE_VERSION:-}"
VM_SIZE="${VM_SIZE:-Standard_D4s_v5}"
OS_DISK_SIZE_GB="${OS_DISK_SIZE_GB:-30}"
TOSHI_VERSION="${TOSHI_VERSION:-}"
AGENT_TARBALL="${AGENT_TARBALL:-}"
AGENT_REPOSITORY="${AGENT_REPOSITORY:-toshicloud/toshi.run}"
PACKER="${PACKER:-packer}"
AZ="${AZ:-az}"
GH="${GH:-gh}"

usage() {
  cat <<USAGE
usage: AZURE_SUBSCRIPTION_ID=<id> AZURE_GALLERY_RESOURCE_GROUP=<rg> \\
       AZURE_GALLERY=<gallery> AZURE_LOCATION=<region> IMAGE_VERSION=<X.Y.Z> \\
       $0 [build|validate] [packer arguments]

build (the default) makes the gallery image version; validate only runs
packer init, packer validate and provision.sh plan, and needs no Azure
account and no agent archive.
Required for build: AZURE_SUBSCRIPTION_ID, AZURE_GALLERY_RESOURCE_GROUP,
AZURE_GALLERY, AZURE_LOCATION and IMAGE_VERSION (X.Y.Z).
Optional: AZURE_BUILD_RESOURCE_GROUP (an existing resource group to build
in; empty creates a temporary one in AZURE_LOCATION), AZURE_IMAGE_NAME
(default: linux-pool-host), VM_SIZE (default: Standard_D4s_v5),
OS_DISK_SIZE_GB (default: 30), AZURE_CLIENT_ID, AZURE_CLIENT_SECRET and
AZURE_TENANT_ID (a service principal; all three or none, and without them
Packer uses the Azure CLI's login), AGENT_TARBALL (the agent archive
versions.env pins; default: download it from the release with gh, from
AGENT_REPOSITORY), TOSHI_VERSION (default: git describe), PACKER, AZ, GH.
Further arguments go to Packer, for example -var vm_size=Standard_D8s_v5.
USAGE
}

die() {
  echo "build-linux-pool-host: $*" >&2
  exit 1
}

action=build
case "${1:-}" in
  -h | --help) usage; exit 0 ;;
  build | validate) action=$1; shift ;;
esac

command -v "${PACKER}" >/dev/null || die "${PACKER} not found"

if [[ "${action}" == build ]]; then
  for name in AZURE_SUBSCRIPTION_ID AZURE_GALLERY_RESOURCE_GROUP AZURE_GALLERY AZURE_LOCATION IMAGE_VERSION; do
    [[ -n "${!name}" ]] || { usage >&2; die "${name} is required"; }
  done
  [[ "${IMAGE_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "IMAGE_VERSION must be X.Y.Z"
  command -v "${AZ}" >/dev/null || die "${AZ} not found"
fi

if [[ -z "${TOSHI_VERSION}" ]]; then
  TOSHI_VERSION=$(git -C "${SCRIPT_DIR}" describe --tags --always --dirty)
fi

# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../linux-pool-host/versions.env"
bash "${SCRIPT_DIR}/../linux-pool-host/provision.sh" plan

work=$(mktemp -d)
trap 'rm -rf "${work}"' EXIT

if [[ -z "${AGENT_TARBALL}" ]]; then
  if [[ "${action}" == validate ]]; then
    # validate only needs a file to exist.
    AGENT_TARBALL=${work}/${TOSHI_AGENT_ASSET}
    : >"${AGENT_TARBALL}"
  else
    command -v "${GH}" >/dev/null || die "${GH} not found: set AGENT_TARBALL"
    "${GH}" release download "${TOSHI_AGENT_VERSION}" -R "${AGENT_REPOSITORY}" \
      -p "${TOSHI_AGENT_ASSET}" -D "${work}"
    AGENT_TARBALL=${work}/${TOSHI_AGENT_ASSET}
  fi
fi
[[ -f "${AGENT_TARBALL}" ]] || die "${AGENT_TARBALL} not found"
if [[ "${action}" == build ]]; then
  got=$(sha256sum "${AGENT_TARBALL}" | awk '{ print $1 }')
  [[ "${got}" == "${TOSHI_AGENT_SHA256}" ]] ||
    die "${AGENT_TARBALL}: sha256 ${got}, want ${TOSHI_AGENT_SHA256}"
fi

template="${SCRIPT_DIR}/linux-pool-host.pkr.hcl"
base_args=(
  -var "base_image_publisher=${AZURE_UBUNTU_PUBLISHER}"
  -var "base_image_offer=${AZURE_UBUNTU_OFFER}"
  -var "base_image_sku=${AZURE_UBUNTU_SKU}"
  -var "base_image_version=${AZURE_UBUNTU_VERSION}"
  -var "toshi_version=${TOSHI_VERSION}"
  -var "agent_tarball=${AGENT_TARBALL}"
)

"${PACKER}" init "${template}"

if [[ "${action}" == validate ]]; then
  "${PACKER}" fmt -check "${SCRIPT_DIR}"
  "${PACKER}" validate "${base_args[@]}" -var-file "${SCRIPT_DIR}/ci.pkrvars.hcl" "${template}"
  exit 0
fi

# A service principal goes through Packer's PKR_VAR_* environment rather
# than the command line, so the secret stays out of the process list.
if [[ -n "${AZURE_CLIENT_ID}" || -n "${AZURE_CLIENT_SECRET}" || -n "${AZURE_TENANT_ID}" ]]; then
  [[ -n "${AZURE_CLIENT_ID}" && -n "${AZURE_CLIENT_SECRET}" && -n "${AZURE_TENANT_ID}" ]] ||
    die "set all of AZURE_CLIENT_ID, AZURE_CLIENT_SECRET and AZURE_TENANT_ID, or none for the Azure CLI's login"
  export PKR_VAR_client_id="${AZURE_CLIENT_ID}"
  export PKR_VAR_client_secret="${AZURE_CLIENT_SECRET}"
  export PKR_VAR_tenant_id="${AZURE_TENANT_ID}"
  export PKR_VAR_use_azure_cli_auth=false
fi

definition=(
  --resource-group "${AZURE_GALLERY_RESOURCE_GROUP}"
  --gallery-name "${AZURE_GALLERY}"
  --gallery-image-definition "${AZURE_IMAGE_NAME}"
)
if "${AZ}" sig image-definition show "${definition[@]}" >/dev/null 2>&1; then
  read -r generation os_state architecture < <("${AZ}" sig image-definition show "${definition[@]}" \
    --query '[hyperVGeneration,osState,architecture]' -o tsv)
  security_type=$("${AZ}" sig image-definition show "${definition[@]}" \
    --query "features[?name=='SecurityType'].value | [0]" -o tsv 2>/dev/null || true)
  [[ "${generation}" == "V2" ]] || die "${AZURE_IMAGE_NAME}: Hyper-V generation ${generation}, want V2"
  [[ "${os_state}" == "Generalized" ]] || die "${AZURE_IMAGE_NAME}: OS state ${os_state}, want Generalized"
  [[ "${architecture}" == "x64" ]] || die "${AZURE_IMAGE_NAME}: architecture ${architecture}, want x64"
  [[ -z "${security_type}" || "${security_type}" == "Standard" ]] ||
    die "${AZURE_IMAGE_NAME}: security type ${security_type}, want Standard or none"
else
  "${AZ}" sig image-definition create "${definition[@]}" \
    --publisher toshi \
    --offer linux-pool-host \
    --sku ubuntu-24.04 \
    --os-type Linux \
    --os-state Generalized \
    --hyper-v-generation V2 \
    --architecture x64 \
    --features "SecurityType=Standard DiskControllerTypes=SCSI,NVMe"
fi

start=${SECONDS}
"${PACKER}" build "${base_args[@]}" \
  -var "subscription_id=${AZURE_SUBSCRIPTION_ID}" \
  -var "gallery_resource_group=${AZURE_GALLERY_RESOURCE_GROUP}" \
  -var "gallery_name=${AZURE_GALLERY}" \
  -var "image_name=${AZURE_IMAGE_NAME}" \
  -var "image_version=${IMAGE_VERSION}" \
  -var "location=${AZURE_LOCATION}" \
  -var "build_resource_group_name=${AZURE_BUILD_RESOURCE_GROUP}" \
  -var "vm_size=${VM_SIZE}" \
  -var "os_disk_size_gb=${OS_DISK_SIZE_GB}" \
  "$@" "${template}"

version_id=$("${AZ}" sig image-version show "${definition[@]}" \
  --gallery-image-version "${IMAGE_VERSION}" --query id -o tsv)
echo "image version ${version_id}, built in $((SECONDS - start)) s"
echo "  az sig image-version show ${definition[*]} --gallery-image-version ${IMAGE_VERSION}"
