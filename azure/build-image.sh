#!/usr/bin/env bash
# Turns the ubuntu-24.04 image into an Azure Compute Gallery image version:
# qcow2 -> fixed VHD -> page blob -> image definition and version in the
# gallery. The README lists the permissions this needs. DRY_RUN=1 prints the
# az calls instead of making them.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

CACHE_DIR="${CACHE_DIR:-${XDG_CACHE_HOME:-${HOME}/.cache}/toshi-images}"
IMAGE="${IMAGE:-${CACHE_DIR}/out/ubuntu-24.04.qcow2}"
WORK_DIR="${WORK_DIR:-${CACHE_DIR}/out/azure}"
SUBSCRIPTION="${SUBSCRIPTION:-}"
# The resource group of the gallery.
RESOURCE_GROUP="${RESOURCE_GROUP:-}"
GALLERY="${GALLERY:-}"
STORAGE_ACCOUNT="${STORAGE_ACCOUNT:-}"
# The storage account that holds the uploads; the gallery's resource group
# unless it lives elsewhere.
STORAGE_RESOURCE_GROUP="${STORAGE_RESOURCE_GROUP:-${RESOURCE_GROUP}}"
CONTAINER="${CONTAINER:-toshi-images}"
# Where a storage account serves blobs; other Azure clouds use another
# suffix.
BLOB_ENDPOINT="${BLOB_ENDPOINT:-https://${STORAGE_ACCOUNT}.blob.core.windows.net}"
IMAGE_DEFINITION="${IMAGE_DEFINITION:-toshi-ubuntu-2404}"
PUBLISHER="${PUBLISHER:-Toshi}"
OFFER="${OFFER:-toshi-ubuntu}"
SKU="${SKU:-24.04}"
# The gallery wants three integers without leading zeros, each under 2^31:
# 2026.1031.140512 on 31 October at 14:05:12 UTC, and 2026.905.5 on
# 5 September at 00:00:05 UTC, where the month and the time lose their
# leading zeros and the day keeps its two digits. One date call keeps all
# three fields from the same second.
if [[ -z "${IMAGE_VERSION:-}" ]]; then
  now=$(date -u +%Y%m%d%H%M%S)
  IMAGE_VERSION="$((10#${now:0:4})).$((10#${now:4:2}))${now:6:2}.$((10#${now:8:6}))"
fi
# Comma-separated regions the version is copied to, the gallery's own
# among them; empty keeps it only in the gallery's region.
REGIONS="${REGIONS:-}"
# Comma-separated Microsoft Entra object ids that may read the image: the
# service principals of the tenants' launchers, when they are elsewhere.
SHARE_WITH="${SHARE_WITH:-}"
SHARE_ROLE="${SHARE_ROLE:-Compute Gallery Image Reader}"
# 1 publishes the gallery as a community gallery, which anyone may read.
COMMUNITY="${COMMUNITY:-0}"
# Recorded as a tag; the version the image's toshi-guest reports.
GUEST_VERSION="${GUEST_VERSION:-}"
KEEP_UPLOAD="${KEEP_UPLOAD:-0}"
DRY_RUN="${DRY_RUN:-0}"
QEMU_IMG="${QEMU_IMG:-qemu-img}"
AZ="${AZ:-az}"

usage() {
  cat <<USAGE
usage: SUBSCRIPTION=<subscription> RESOURCE_GROUP=<gallery resource group> GALLERY=<gallery> STORAGE_ACCOUNT=<account> $0

Optional: IMAGE (default ${IMAGE}), WORK_DIR, STORAGE_RESOURCE_GROUP,
CONTAINER (default ${CONTAINER}), BLOB_ENDPOINT, IMAGE_DEFINITION (default
${IMAGE_DEFINITION}), PUBLISHER, OFFER, SKU, IMAGE_VERSION (default the UTC
time), REGIONS=<region,...>, SHARE_WITH=<object id,...>, SHARE_ROLE (default
${SHARE_ROLE}), COMMUNITY=1, GUEST_VERSION, KEEP_UPLOAD=1, DRY_RUN=1.
Credentials come from az's usual configuration (az login).
USAGE
}

die() {
  echo "build-image: $*" >&2
  exit 1
}

# az_call runs an az call, or prints it under DRY_RUN.
az_call() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    printf '+ %s' "${AZ}" >&2
    printf ' %q' "$@" >&2
    printf ' --subscription %q --only-show-errors' "${SUBSCRIPTION}" >&2
    printf '\n' >&2
    return 0
  fi
  "${AZ}" "$@" --subscription "${SUBSCRIPTION}" --only-show-errors
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
[[ -n "${SUBSCRIPTION}" ]] || { usage >&2; die "SUBSCRIPTION is required"; }
[[ -n "${RESOURCE_GROUP}" ]] || { usage >&2; die "RESOURCE_GROUP is required"; }
[[ -n "${GALLERY}" ]] || { usage >&2; die "GALLERY is required"; }
[[ -n "${STORAGE_ACCOUNT}" ]] || { usage >&2; die "STORAGE_ACCOUNT is required"; }
# Three integers without leading zeros, each at most nine digits, so each
# fits the 32-bit field the gallery stores it in.
[[ "${IMAGE_VERSION}" =~ ^(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})\.(0|[1-9][0-9]{0,8})$ ]] \
  || die "IMAGE_VERSION ${IMAGE_VERSION} is not three integers without leading zeros"
[[ -f "${IMAGE}" ]] || die "no image at ${IMAGE}; build it with ubuntu-24.04/build.sh"
command -v "${QEMU_IMG}" >/dev/null || die "${QEMU_IMG} not found"
if [[ "${DRY_RUN}" != "1" ]]; then
  command -v "${AZ}" >/dev/null || die "${AZ} (Azure CLI) not found"
fi

definition="/subscriptions/${SUBSCRIPTION}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.Compute/galleries/${GALLERY}/images/${IMAGE_DEFINITION}"
echo "step 1: image definition ${IMAGE_DEFINITION} in gallery ${GALLERY}"
# Checked first, so a definition of another shape stops the script before
# the conversion and the upload. The show's answer decides what happens
# next, so it calls az directly rather than through az_call.
show_args=(sig image-definition show -g "${RESOURCE_GROUP}"
  --gallery-name "${GALLERY}"
  --gallery-image-definition "${IMAGE_DEFINITION}"
  --query "[osState, hyperVGeneration, architecture]" -o tsv)
create=1
if [[ "${DRY_RUN}" == "1" ]]; then
  az_call "${show_args[@]}"
elif state=$("${AZ}" "${show_args[@]}" --subscription "${SUBSCRIPTION}" --only-show-errors 2>/dev/null); then
  read -r os_state hyperv architecture <<<"${state}"
  [[ "${os_state}/${hyperv}/${architecture}" == "Specialized/V2/x64" ]] \
    || die "image definition ${IMAGE_DEFINITION} is ${os_state}/${hyperv}/${architecture}, not Specialized/V2/x64"
  create=0
fi
if [[ "${create}" == "1" ]]; then
  # Specialized: the VM boots the disk with no OS profile, so Azure runs no
  # provisioning agent on it and the guest configures itself. Standard: the
  # launcher asks for no security type.
  az_call sig image-definition create -g "${RESOURCE_GROUP}" \
    --gallery-name "${GALLERY}" \
    --gallery-image-definition "${IMAGE_DEFINITION}" \
    --publisher "${PUBLISHER}" \
    --offer "${OFFER}" \
    --sku "${SKU}" \
    --os-type Linux \
    --os-state Specialized \
    --hyper-v-generation V2 \
    --architecture x64 \
    --features SecurityType=Standard \
    --description "Toshi runner image (ubuntu-24.04)"
fi

mkdir -p "${WORK_DIR}"
blob="${IMAGE_DEFINITION}-${IMAGE_VERSION}.vhd"
raw="${WORK_DIR}/disk.raw"
vhd="${WORK_DIR}/${blob}"
cleanup() {
  rm -f "${raw}" "${vhd}"
}
trap cleanup EXIT

echo "step 2: convert ${IMAGE} to ${blob}"
# Azure takes only fixed VHDs whose virtual size is a whole number of MiB,
# and it reads them from a page blob.
"${QEMU_IMG}" convert -p -O raw "${IMAGE}" "${raw}"
size=$(stat -c %s "${raw}")
mib=$(((size + (1 << 20) - 1) >> 20))
if [[ "${size}" -ne $((mib * 1048576)) ]]; then
  "${QEMU_IMG}" resize -f raw "${raw}" "${mib}M" >/dev/null
fi
"${QEMU_IMG}" convert -f raw -O vpc -o subformat=fixed,force_size=on "${raw}" "${vhd}"
rm -f "${raw}"

info=$("${QEMU_IMG}" info -f vpc "${vhd}")
format=$(awk '/^file format:/ { print $3; exit }' <<<"${info}")
vsize=$(awk '/^virtual size:/ { sub(/.*\(/, ""); sub(/ bytes\).*/, ""); print; exit }' <<<"${info}")
[[ "${format}" == "vpc" ]] || die "${vhd} is ${format}, not vpc"
[[ -n "${vsize}" ]] || die "qemu-img info printed no virtual size for ${vhd}"
[[ "${vsize}" -eq $((mib * 1048576)) ]] || die "${vhd} has virtual size ${vsize} bytes, want $((mib * 1048576))"
# A fixed VHD is the disk followed by a 512-byte footer.
[[ "$(stat -c %s "${vhd}")" -eq $((vsize + 512)) ]] \
  || die "${vhd} is not a fixed VHD: its file is not the virtual size plus 512 bytes of footer"
echo "vhd: ${vhd}, virtual size ${vsize} bytes (${mib} MiB), fixed"

echo "step 3: upload ${vhd} to ${BLOB_ENDPOINT%/}/${CONTAINER}/${blob}"
az_call storage container create --auth-mode login \
  --account-name "${STORAGE_ACCOUNT}" --name "${CONTAINER}"
az_call storage blob upload --auth-mode login \
  --account-name "${STORAGE_ACCOUNT}" --container-name "${CONTAINER}" \
  --name "${blob}" --file "${vhd}" --type page --overwrite
rm -f "${vhd}"

echo "step 4: create image version ${IMAGE_VERSION}"
tags=("toshi-image=ubuntu-24.04")
[[ -n "${GUEST_VERSION}" ]] && tags+=("toshi-guest-version=${GUEST_VERSION}")
args=(sig image-version create -g "${RESOURCE_GROUP}"
  --gallery-name "${GALLERY}"
  --gallery-image-definition "${IMAGE_DEFINITION}"
  --gallery-image-version "${IMAGE_VERSION}"
  --os-vhd-uri "${BLOB_ENDPOINT%/}/${CONTAINER}/${blob}"
  --os-vhd-storage-account "/subscriptions/${SUBSCRIPTION}/resourceGroups/${STORAGE_RESOURCE_GROUP}/providers/Microsoft.Storage/storageAccounts/${STORAGE_ACCOUNT}"
  --tags "${tags[@]}")
if [[ -n "${REGIONS}" ]]; then
  IFS=, read -r -a regions <<<"${REGIONS}"
  args+=(--target-regions "${regions[@]}")
fi
az_call "${args[@]}"

if [[ "${KEEP_UPLOAD}" != "1" ]]; then
  echo "step 5: delete ${blob} from ${CONTAINER}"
  az_call storage blob delete --auth-mode login \
    --account-name "${STORAGE_ACCOUNT}" --container-name "${CONTAINER}" \
    --name "${blob}"
fi

if [[ -n "${SHARE_WITH}" ]]; then
  echo "step 6: share ${IMAGE_DEFINITION} with ${SHARE_WITH}"
  IFS=, read -r -a principals <<<"${SHARE_WITH}"
  for principal in "${principals[@]}"; do
    az_call role assignment create \
      --assignee-object-id "${principal}" \
      --assignee-principal-type ServicePrincipal \
      --role "${SHARE_ROLE}" \
      --scope "${definition}"
  done
fi

if [[ "${COMMUNITY}" == "1" ]]; then
  echo "step 7: publish gallery ${GALLERY} as a community gallery"
  az_call sig share enable-community -g "${RESOURCE_GROUP}" --gallery-name "${GALLERY}"
  # The public name is read back because the community path contains it.
  name_args=(sig show -g "${RESOURCE_GROUP}" --gallery-name "${GALLERY}"
    --query "sharingProfile.communityGalleryInfo.publicNames[0]" -o tsv)
  if [[ "${DRY_RUN}" == "1" ]]; then
    az_call "${name_args[@]}"
    public_name="<public name>"
  else
    public_name=$("${AZ}" "${name_args[@]}" --subscription "${SUBSCRIPTION}" --only-show-errors)
    [[ -n "${public_name}" ]] || die "gallery ${GALLERY} has no community public name"
  fi
  echo "community image: /CommunityGalleries/${public_name}/Images/${IMAGE_DEFINITION}/Versions/${IMAGE_VERSION}"
fi

echo "image version ${definition}/versions/${IMAGE_VERSION}"
echo "register it with: toshi workspace host create --cloud azure --image ${definition}/versions/${IMAGE_VERSION} ..."
echo "(see ${SCRIPT_DIR}/README.md)"
