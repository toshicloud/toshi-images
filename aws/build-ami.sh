#!/usr/bin/env bash
# Turns the ubuntu-24.04 image into an EC2 AMI for a cloud host:
# qcow2 -> raw -> S3 -> import-snapshot (VM Import) -> register-image.
# The README lists the IAM this needs. DRY_RUN=1 prints the AWS calls
# instead of making them.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

CACHE_DIR="${CACHE_DIR:-${XDG_CACHE_HOME:-${HOME}/.cache}/toshi-images}"
IMAGE="${IMAGE:-${CACHE_DIR}/out/ubuntu-24.04.qcow2}"
WORK_DIR="${WORK_DIR:-${CACHE_DIR}/out/aws}"
AWS_REGION="${AWS_REGION:-}"
BUCKET="${BUCKET:-}"
S3_PREFIX="${S3_PREFIX:-toshi-images}"
AMI_NAME="${AMI_NAME:-toshi-ubuntu-24.04-$(date -u +%Y%m%dT%H%M%SZ)}"
# The VM Import service role; AWS calls it vmimport unless told otherwise.
VMIMPORT_ROLE="${VMIMPORT_ROLE:-vmimport}"
# Comma-separated account ids that may launch the AMI (tenants' accounts).
SHARE_WITH="${SHARE_WITH:-}"
# Recorded as a tag; the version the image's toshi-guest reports.
GUEST_VERSION="${GUEST_VERSION:-}"
KEEP_UPLOAD="${KEEP_UPLOAD:-0}"
IMPORT_TIMEOUT="${IMPORT_TIMEOUT:-3600}"
DRY_RUN="${DRY_RUN:-0}"
QEMU_IMG="${QEMU_IMG:-qemu-img}"
AWS="${AWS:-aws}"

usage() {
  cat <<EOF
usage: AWS_REGION=<region> BUCKET=<bucket> $0

Optional: IMAGE (default ${IMAGE}), AMI_NAME, S3_PREFIX, VMIMPORT_ROLE,
SHARE_WITH=<account,...>, GUEST_VERSION, KEEP_UPLOAD=1, DRY_RUN=1.
AWS credentials come from the usual AWS CLI environment (AWS_PROFILE etc.).
EOF
}

die() {
  echo "build-ami: $*" >&2
  exit 1
}

# aws_call runs an AWS CLI call, or prints it under DRY_RUN.
aws_call() {
  if [[ "${DRY_RUN}" == "1" ]]; then
    printf '+ %s' "${AWS}" >&2
    printf ' %q' "$@" >&2
    printf '\n' >&2
    return 0
  fi
  "${AWS}" --region "${AWS_REGION}" "$@"
}

[[ "${1:-}" == "-h" || "${1:-}" == "--help" ]] && { usage; exit 0; }
[[ -n "${AWS_REGION}" ]] || { usage >&2; die "AWS_REGION is required"; }
[[ -n "${BUCKET}" ]] || { usage >&2; die "BUCKET is required"; }
[[ -f "${IMAGE}" ]] || die "no image at ${IMAGE}; build it with ubuntu-24.04/build.sh"
command -v "${QEMU_IMG}" >/dev/null || die "${QEMU_IMG} not found"
if [[ "${DRY_RUN}" != "1" ]]; then
  command -v "${AWS}" >/dev/null || die "${AWS} (AWS CLI v2) not found"
fi

mkdir -p "${WORK_DIR}"
raw="${WORK_DIR}/${AMI_NAME}.raw"
key="${S3_PREFIX%/}/${AMI_NAME}.raw"
cleanup() {
  rm -f "${raw}"
}
trap cleanup EXIT

echo "step 1: convert ${IMAGE} to raw"
"${QEMU_IMG}" convert -p -O raw "${IMAGE}" "${raw}"

echo "step 2: upload to s3://${BUCKET}/${key}"
aws_call s3 cp --only-show-errors "${raw}" "s3://${BUCKET}/${key}"
rm -f "${raw}"

echo "step 3: import the snapshot (role ${VMIMPORT_ROLE})"
task_id=$(aws_call ec2 import-snapshot \
  --role-name "${VMIMPORT_ROLE}" \
  --description "${AMI_NAME}" \
  --disk-container "Description=${AMI_NAME},Format=RAW,UserBucket={S3Bucket=${BUCKET},S3Key=${key}}" \
  --query ImportTaskId --output text)
snapshot_id="snap-dryrun"
if [[ "${DRY_RUN}" != "1" ]]; then
  echo "import task ${task_id}"
  deadline=$((SECONDS + IMPORT_TIMEOUT))
  while :; do
    read -r status snapshot_id message < <(aws_call ec2 describe-import-snapshot-tasks \
      --import-task-ids "${task_id}" \
      --query 'ImportSnapshotTasks[0].SnapshotTaskDetail.[Status,SnapshotId,StatusMessage]' \
      --output text)
    case "${status}" in
      completed) break ;;
      deleted | deleting) die "import ${task_id} failed: ${message}" ;;
    esac
    ((SECONDS < deadline)) || die "import ${task_id} still ${status} after ${IMPORT_TIMEOUT}s"
    echo "  ${status} ${message}"
    sleep 15
  done
fi
echo "snapshot ${snapshot_id}"

if [[ "${KEEP_UPLOAD}" != "1" ]]; then
  aws_call s3 rm --only-show-errors "s3://${BUCKET}/${key}"
fi

echo "step 4: register ${AMI_NAME}"
# /dev/sda1 and gp3 match what the ec2 launcher asks for; ENA and IMDSv2
# are required by the instance types and the guest.
ami_id=$(aws_call ec2 register-image \
  --name "${AMI_NAME}" \
  --description "Toshi runner image (ubuntu-24.04)" \
  --architecture x86_64 \
  --virtualization-type hvm \
  --ena-support \
  --imds-support v2.0 \
  --root-device-name /dev/sda1 \
  --block-device-mappings "DeviceName=/dev/sda1,Ebs={SnapshotId=${snapshot_id},VolumeType=gp3,DeleteOnTermination=true}" \
  --query ImageId --output text)
[[ "${DRY_RUN}" == "1" ]] && ami_id="ami-dryrun"

tags=("Key=Name,Value=${AMI_NAME}" "Key=toshi:image,Value=ubuntu-24.04")
[[ -n "${GUEST_VERSION}" ]] && tags+=("Key=toshi:guest-version,Value=${GUEST_VERSION}")
aws_call ec2 create-tags --resources "${ami_id}" "${snapshot_id}" --tags "${tags[@]}"

if [[ -n "${SHARE_WITH}" ]]; then
  echo "step 5: share with ${SHARE_WITH}"
  IFS=, read -r -a accounts <<<"${SHARE_WITH}"
  perms=""
  for a in "${accounts[@]}"; do
    perms+="{UserId=${a}},"
  done
  perms="${perms%,}"
  aws_call ec2 modify-image-attribute --image-id "${ami_id}" \
    --launch-permission "Add=[${perms}]"
  aws_call ec2 modify-snapshot-attribute --snapshot-id "${snapshot_id}" \
    --attribute createVolumePermission --operation-type add --user-ids "${accounts[@]}"
fi

echo "AMI ${ami_id} in ${AWS_REGION}"
echo "register it with: toshi tenant hosts add --cloud aws --region ${AWS_REGION} --ami ${ami_id} ..."
echo "(see ${SCRIPT_DIR}/README.md)"
