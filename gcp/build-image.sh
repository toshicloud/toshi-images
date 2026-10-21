#!/usr/bin/env bash
# Turns the ubuntu-24.04 image into a GCE image for a cloud host:
# qcow2 -> disk.raw -> tar.gz -> Cloud Storage -> images create.
# The README lists the IAM this needs. DRY_RUN=1 prints the gcloud calls
# instead of making them.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

CACHE_DIR="${CACHE_DIR:-${XDG_CACHE_HOME:-${HOME}/.cache}/toshi-images}"
IMAGE="${IMAGE:-${CACHE_DIR}/out/ubuntu-24.04.qcow2}"
WORK_DIR="${WORK_DIR:-${CACHE_DIR}/out/gcp}"
PROJECT="${PROJECT:-}"
BUCKET="${BUCKET:-}"
GCS_PREFIX="${GCS_PREFIX:-toshi-images}"
IMAGE_NAME="${IMAGE_NAME:-toshi-ubuntu-2404-$(date -u +%Y%m%dt%H%M%Sz)}"
IMAGE_FAMILY="${IMAGE_FAMILY:-toshi-ubuntu-2404}"
# Where the image is stored; empty lets GCE pick the multi-region nearest
# the bucket.
STORAGE_LOCATION="${STORAGE_LOCATION:-}"
GUEST_OS_FEATURES="${GUEST_OS_FEATURES:-VIRTIO_SCSI_MULTIQUEUE,UEFI_COMPATIBLE}"
# Comma-separated service accounts that may use the image (the tenants'
# launcher service accounts, when the image lives in another project).
SHARE_WITH="${SHARE_WITH:-}"
# Recorded as a label; the version the image's toshi-guest reports.
GUEST_VERSION="${GUEST_VERSION:-}"
KEEP_UPLOAD="${KEEP_UPLOAD:-0}"
DRY_RUN="${DRY_RUN:-0}"
QEMU_IMG="${QEMU_IMG:-qemu-img}"
GCLOUD="${GCLOUD:-gcloud}"

usage() {
  cat <<USAGE
usage: PROJECT=<project> BUCKET=<bucket> $0

Optional: IMAGE (default ${IMAGE}), IMAGE_NAME, IMAGE_FAMILY (default
${IMAGE_FAMILY}), GCS_PREFIX, STORAGE_LOCATION, GUEST_OS_FEATURES,
SHARE_WITH=<service account,...>, GUEST_VERSION, KEEP_UPLOAD=1, DRY_RUN=1.
Credentials come from gcloud's usual configuration (gcloud auth, or
CLOUDSDK_AUTH_ACCESS_TOKEN_FILE).
USAGE
}

die() {
  echo "build-image: $*" >&2
  exit 1
}

# gcloud_call runs a gcloud call, or prints it under DRY_RUN.
gcloud_call() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    printf '+ %s' "${GCLOUD}" >&2
    printf ' %q' "$@" >&2
    printf '\n' >&2
    return 0
  fi
  "${GCLOUD}" --project "${PROJECT}" --quiet "$@"
}

# label is a GCE label value: lowercase letters, digits, - and _, at most
# 63 characters.
label() {
  local v
  v=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_-' '-')
  printf '%s' "${v:0:63}"
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
[[ -n "${PROJECT}" ]] || { usage >&2; die "PROJECT is required"; }
[[ -n "${BUCKET}" ]] || { usage >&2; die "BUCKET is required"; }
[[ "${IMAGE_NAME}" =~ ^[a-z]([-a-z0-9]{0,61}[a-z0-9])?$ ]] || die "IMAGE_NAME ${IMAGE_NAME} is not a valid image name"
[[ -f "${IMAGE}" ]] || die "no image at ${IMAGE}; build it with ubuntu-24.04/build.sh"
command -v "${QEMU_IMG}" >/dev/null || die "${QEMU_IMG} not found"
if [[ "${DRY_RUN}" != "1" ]]; then
  command -v "${GCLOUD}" >/dev/null || die "${GCLOUD} (Google Cloud CLI) not found"
fi

mkdir -p "${WORK_DIR}/${IMAGE_NAME}"
dir="${WORK_DIR}/${IMAGE_NAME}"
tarball="${WORK_DIR}/${IMAGE_NAME}.tar.gz"
object="gs://${BUCKET}/${GCS_PREFIX%/}/${IMAGE_NAME}.tar.gz"
cleanup() {
  rm -rf "${dir}" "${tarball}"
}
trap cleanup EXIT

echo "step 1: convert ${IMAGE} to disk.raw"
# GCE wants a raw disk named disk.raw, a whole number of GiB, in a sparse
# gzipped tar in the old GNU format.
"${QEMU_IMG}" convert -p -O raw "${IMAGE}" "${dir}/disk.raw"
size=$(stat -c %s "${dir}/disk.raw")
gib=$(((size + (1 << 30) - 1) >> 30))
"${QEMU_IMG}" resize -f raw "${dir}/disk.raw" "${gib}G" >/dev/null
tar --format=oldgnu -Sczf "${tarball}" -C "${dir}" disk.raw
rm -f "${dir}/disk.raw"

echo "step 2: upload to ${object}"
gcloud_call storage cp --no-user-output-enabled "${tarball}" "${object}"
rm -f "${tarball}"

echo "step 3: create image ${IMAGE_NAME} (family ${IMAGE_FAMILY})"
labels="toshi-image=ubuntu-24-04"
[[ -n "${GUEST_VERSION}" ]] && labels+=",toshi-guest-version=$(label "${GUEST_VERSION}")"
args=(compute images create "${IMAGE_NAME}"
  --source-uri "${object}"
  --family "${IMAGE_FAMILY}"
  --architecture X86_64
  --guest-os-features "${GUEST_OS_FEATURES}"
  --description "Toshi runner image (ubuntu-24.04)"
  --labels "${labels}")
[[ -n "${STORAGE_LOCATION}" ]] && args+=(--storage-location "${STORAGE_LOCATION}")
gcloud_call "${args[@]}"

if [[ "${KEEP_UPLOAD}" != "1" ]]; then
  gcloud_call storage rm --no-user-output-enabled "${object}"
fi

if [[ -n "${SHARE_WITH}" ]]; then
  echo "step 4: share with ${SHARE_WITH}"
  IFS=, read -r -a accounts <<<"${SHARE_WITH}"
  for a in "${accounts[@]}"; do
    gcloud_call compute images add-iam-policy-binding "${IMAGE_NAME}" \
      --member "serviceAccount:${a}" --role roles/compute.imageUser
  done
fi

echo "image projects/${PROJECT}/global/images/${IMAGE_NAME} (family ${IMAGE_FAMILY})"
echo "register it with: toshi tenant hosts add --cloud gcp --image projects/${PROJECT}/global/images/family/${IMAGE_FAMILY} ..."
echo "(see ${SCRIPT_DIR}/README.md)"
