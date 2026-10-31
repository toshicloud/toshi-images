#!/usr/bin/env bash
# Builds the AMI a Linux cloud pool's host boots with linux-pool-host.pkr.hcl.
#
# The agent archive comes from the Toshi release linux-pool-host/versions.env
# pins. This script takes it from AGENT_TARBALL, or downloads it with the
# GitHub CLI, and checks its SHA-256 before Packer uploads it to the build
# instance, which checks it again.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

AWS_REGION="${AWS_REGION:-}"
TOSHI_VERSION="${TOSHI_VERSION:-}"
AGENT_TARBALL="${AGENT_TARBALL:-}"
AGENT_REPOSITORY="${AGENT_REPOSITORY:-toshicloud/toshi.run}"
SHARE_WITH="${SHARE_WITH:-}"
PACKER="${PACKER:-packer}"
GH="${GH:-gh}"

usage() {
  cat <<USAGE
usage: AWS_REGION=<region> $0 [build|validate] [packer arguments]

build (the default) makes the AMI; validate only runs packer validate and
needs no AWS account and no agent archive.
Optional: AGENT_TARBALL (the agent archive versions.env pins; default:
download it from the release with gh, from AGENT_REPOSITORY), SHARE_WITH
(comma-separated account ids that may launch the AMI), TOSHI_VERSION
(default: git describe), PACKER, GH. Further arguments go to Packer, for
example -var subnet_id=subnet-...
AWS credentials come from the usual AWS environment (AWS_PROFILE etc.).
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

[[ -n "${AWS_REGION}" ]] || { usage >&2; die "AWS_REGION is required"; }
command -v "${PACKER}" >/dev/null || die "${PACKER} not found"
if [[ -n "${SHARE_WITH}" && ! "${SHARE_WITH}" =~ ^[0-9]{12}(,[0-9]{12})*$ ]]; then
  die "SHARE_WITH must be comma-separated 12-digit account ids"
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
"${PACKER}" init "${template}"
start=${SECONDS}
"${PACKER}" "${action}" -var "region=${AWS_REGION}" -var "toshi_version=${TOSHI_VERSION}" \
  -var "agent_tarball=${AGENT_TARBALL}" -var "share_with=${SHARE_WITH}" "$@" "${template}"

if [[ "${action}" == build ]]; then
  manifest="${SCRIPT_DIR}/linux-pool-host-ami.json"
  artifact=$(grep -o '"artifact_id": *"[^"]*"' "${manifest}" | tail -n 1 | sed 's/.*: *"\(.*\)"/\1/')
  echo "AMI ${artifact#*:} in ${artifact%%:*}, built in $((SECONDS - start)) s (${manifest})"
fi
