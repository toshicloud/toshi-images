#!/usr/bin/env bash
# Provisions a Linux cloud pool's host image on Packer's build instance, as
# root.
#
#   provision.sh plan [dir]          print what build would install; no network, no root
#   provision.sh build <cloud> [dir] install the agent, its packages and the guest image
#   provision.sh seal <cloud> [dir]  clear what must not be in the image
#
# <cloud> is aws or azure, the cloud of the template that runs this script.
# build is the same on both; seal is not.
#
# <dir> (default: this script's directory) holds versions.env, install.sh
# and the agent archive named in TOSHI_AGENT_ASSET; the template uploads
# them to one directory on the build instance.
#
# The image carries everything a pool host needs except the two files the
# pool's user data writes, /etc/toshi/enrollment-token and
# /etc/toshi/agent.toml; the user data then runs
# `systemctl enable --now toshi-agent.service`. The unit is installed and
# neither enabled nor started here.
set -euo pipefail

usage() {
  cat >&2 <<EOF
usage: $0 plan [dir]
       $0 build <aws|azure> [dir]
       $0 seal <aws|azure> [dir]
EOF
  exit 2
}

die() {
  echo "provision: $*" >&2
  exit 1
}

step() {
  echo "==> $*"
}

[[ $# -ge 1 ]] || usage
action=$1
shift
cloud=""
case "${action}" in
  plan) ;;
  build | seal)
    [[ $# -ge 1 ]] || usage
    cloud=$1
    shift
    case "${cloud}" in
      aws | azure) ;;
      *)
        echo "provision: unknown cloud: ${cloud}" >&2
        usage
        ;;
    esac
    ;;
  *) usage ;;
esac
[[ $# -le 1 ]] || usage
dir=${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}

# shellcheck disable=SC1091
source "${dir}/versions.env"

check_pins() {
  local name value
  for name in UBUNTU_SERIAL TOSHI_AGENT_VERSION TOSHI_AGENT_ASSET GUEST_VERSION GUEST_REF ORAS_URL HOST_PACKAGES; do
    [[ -n "${!name:-}" ]] || die "${name} is empty in versions.env"
  done
  for name in TOSHI_AGENT_SHA256 GUEST_SHA256 ORAS_SHA256; do
    value=${!name:-}
    [[ "${value}" =~ ^[0-9a-f]{64}$ ]] || die "${name} is not a SHA-256: ${value}"
  done
  [[ "${GUEST_DIGEST}" =~ ^sha256:[0-9a-f]{64}$ ]] || die "GUEST_DIGEST is not a digest: ${GUEST_DIGEST}"
  [[ "${TOSHI_AGENT_ASSET}" == *_linux_amd64.tar.gz ]] || die "TOSHI_AGENT_ASSET is not a linux_amd64 archive: ${TOSHI_AGENT_ASSET}"
}

# The agent's image_dir: the pool's agent.toml sets data_dir =
# /var/lib/toshi-agent and no image_dir, so the default <data_dir>/images
# applies, and it must exist when the agent starts.
image_dir=/var/lib/toshi-agent/images

plan() {
  cat <<EOF
base AMI:   ubuntu-noble-24.04-amd64-server-${UBUNTU_SERIAL} (owner ${UBUNTU_AMI_OWNER})
packages:   ${HOST_PACKAGES}
agent:      ${TOSHI_AGENT_ASSET} (${TOSHI_AGENT_VERSION}), sha256 ${TOSHI_AGENT_SHA256}
  /usr/local/bin/toshi-agent, /usr/local/bin/toshi-agent-pools
  /etc/systemd/system/toshi-agent.service (installed, not enabled)
  /etc/sysusers.d/toshi.conf, /etc/tmpfiles.d/toshi.conf (the agent's lines)
  /etc/toshi/mining-pools.txt
  /etc/nftables.d/toshi-agent.nft, included from /etc/nftables.conf
guest:      ${GUEST_REF}@${GUEST_DIGEST} (${GUEST_VERSION})
  ${image_dir}/ubuntu-24.04.qcow2, sha256 ${GUEST_SHA256}
oras:       ${ORAS_VERSION}, sha256 ${ORAS_SHA256}
EOF
}

# Packer starts provisioning while cloud-init may still run apt.
wait_for_boot() {
  local status=0
  cloud-init status --wait >/dev/null || status=$?
  # 2: finished with recoverable errors, which a stock AMI can report.
  [[ ${status} -eq 0 || ${status} -eq 2 ]] || die "cloud-init failed (status ${status})"
}

apt_install() {
  export DEBIAN_FRONTEND=noninteractive
  local apt=(apt-get -o DPkg::Lock::Timeout=600 -y)
  "${apt[@]}" update
  # shellcheck disable=SC2086 # HOST_PACKAGES is a word list
  "${apt[@]}" install --no-install-recommends ${HOST_PACKAGES}
}

check_sha256() {
  local file=$1 want=$2 got
  got=$(sha256sum "${file}" | awk '{ print $1 }')
  [[ "${got}" == "${want}" ]] || die "${file}: sha256 ${got}, want ${want}"
}

# The agent's lines of the release's sysusers.d and tmpfiles.d files: the
# release also carries the control plane's, which a pool host does not run.
agent_lines() {
  local kind=$1 file=$2
  echo "# The agent's lines of ${kind}/toshi.conf in Toshi ${TOSHI_AGENT_VERSION}."
  case "${kind}" in
    sysusers.d) awk '!/^#/ && $2 == "toshi-agent"' "${file}" ;;
    tmpfiles.d) awk '!/^#/ && ($2 == "/etc/toshi" || $2 ~ /^\/(var\/lib|run)\/toshi-agent(\/|$)/)' "${file}" ;;
  esac
}

install_agent() {
  local archive=${dir}/${TOSHI_AGENT_ASSET} rel=$1
  [[ -f "${archive}" ]] || die "${archive} not found"
  check_sha256 "${archive}" "${TOSHI_AGENT_SHA256}"
  tar -xzf "${archive}" -C "${rel}"

  # The guest image must be the one this release names.
  local images_env=${rel}/deploy/images.env
  [[ -f "${images_env}" ]] || die "the agent archive has no deploy/images.env"
  local release_guest release_digest release_sha256
  release_guest=$(sed -n 's/^TOSHI_IMAGES_RELEASE=//p' "${images_env}")
  release_digest=$(sed -n 's/^UBUNTU_24_04_DIGEST=//p' "${images_env}")
  release_sha256=$(sed -n 's/^UBUNTU_24_04_SHA256=//p' "${images_env}")
  [[ "${release_guest}" == "${GUEST_VERSION}" && "${release_digest}" == "${GUEST_DIGEST}" && "${release_sha256}" == "${GUEST_SHA256}" ]] ||
    die "the guest pin differs from the one ${TOSHI_AGENT_VERSION} names: ${release_guest} ${release_digest} ${release_sha256}"

  local unit=${rel}/deploy/systemd/toshi-agent.service
  grep -q '^ExecStart=/usr/local/bin/toshi-agent ' "${unit}" || die "the unit does not run /usr/local/bin/toshi-agent"

  install -m 0755 "${rel}/toshi-agent" /usr/local/bin/toshi-agent
  install -m 0755 "${rel}/deploy/nftables/toshi-agent-pools.sh" /usr/local/bin/toshi-agent-pools
  install -m 0644 "${unit}" /etc/systemd/system/toshi-agent.service
  agent_lines sysusers.d "${rel}/deploy/sysusers.d/toshi.conf" >"${rel}/sysusers.conf"
  agent_lines tmpfiles.d "${rel}/deploy/tmpfiles.d/toshi.conf" >"${rel}/tmpfiles.conf"
  # Ubuntu's cloud images ship neither directory.
  install -d -m 0755 /etc/sysusers.d /etc/tmpfiles.d
  install -m 0644 "${rel}/sysusers.conf" /etc/sysusers.d/toshi.conf
  install -m 0644 "${rel}/tmpfiles.conf" /etc/tmpfiles.d/toshi.conf
  systemd-sysusers /etc/sysusers.d/toshi.conf
  systemd-tmpfiles --create /etc/tmpfiles.d/toshi.conf
  install -d -m 0755 /etc/toshi
  install -m 0644 "${rel}/deploy/nftables/mining-pools.txt" /etc/toshi/mining-pools.txt
  systemctl daemon-reload

  id -nG toshi-agent | tr ' ' '\n' | grep -qx kvm || die "toshi-agent is not in the group kvm"
  install -d -o toshi-agent -g toshi-agent -m 0750 "${image_dir}"
  systemctl is-enabled toshi-agent.service >/dev/null 2>&1 && die "toshi-agent.service is enabled"
  /usr/local/bin/toshi-agent version
}

# The agent's host firewall, loaded at boot by nftables.service; the unit
# fills its cgroup sets when the agent starts.
install_firewall() {
  local rel=$1
  install -d -m 0755 /etc/nftables.d
  install -m 0644 "${rel}/deploy/nftables/toshi-agent.nft" /etc/nftables.d/toshi-agent.nft
  # The image's table is the release's, byte for byte: nothing else goes
  # into the agent's firewall files.
  cmp -s "${rel}/deploy/nftables/toshi-agent.nft" /etc/nftables.d/toshi-agent.nft ||
    die "/etc/nftables.d/toshi-agent.nft differs from the release's"
  local line='include "/etc/nftables.d/toshi-agent.nft"'
  grep -qxF "${line}" /etc/nftables.conf || echo "${line}" >>/etc/nftables.conf
  nft -c -f /etc/nftables.conf
  systemctl enable nftables.service
}

install_guest() {
  local work=$1
  local oras_tgz=${work}/oras.tar.gz
  curl -fsSL --retry 3 -o "${oras_tgz}" "${ORAS_URL}"
  check_sha256 "${oras_tgz}" "${ORAS_SHA256}"
  tar -xzf "${oras_tgz}" -C "${work}" oras

  local pull=/var/tmp/toshi-guest
  rm -rf "${pull}"
  # The registry can drop a 2.6 GB stream part-way; the digest makes a
  # retry safe.
  local try
  for try in 1 2 3; do
    "${work}/oras" pull --no-tty -o "${pull}" "${GUEST_REF}@${GUEST_DIGEST}" && break
    [[ ${try} -lt 3 ]] || die "pulling ${GUEST_REF}@${GUEST_DIGEST} failed 3 times"
    rm -rf "${pull}"
    sleep $((try * 10))
  done
  check_sha256 "${pull}/ubuntu-24.04.qcow2" "${GUEST_SHA256}"
  bash "${dir}/install.sh" "${pull}/ubuntu-24.04.qcow2" --image-dir "${image_dir}" \
    --owner toshi-agent:toshi-agent --mode 0640
  rm -rf "${pull}"
}

build() {
  [[ ${EUID} -eq 0 ]] || die "build runs as root"
  # The agent delegates its cgroup to its VMs: cgroup v2 only.
  [[ -f /sys/fs/cgroup/cgroup.controllers ]] || die "this system does not run cgroup v2"

  step "waiting for cloud-init"
  wait_for_boot
  step "installing ${HOST_PACKAGES}"
  apt_install

  local work
  work=$(mktemp -d)
  # shellcheck disable=SC2064 # expand now: work is local
  trap "rm -rf '${work}'" EXIT
  mkdir "${work}/release"
  step "installing the agent ${TOSHI_AGENT_VERSION}"
  install_agent "${work}/release"
  step "installing the firewall"
  install_firewall "${work}/release"
  step "installing the guest image ${GUEST_VERSION}"
  install_guest "${work}"

  local cmd
  for cmd in qemu-system-x86_64 qemu-img passt nft; do
    command -v "${cmd}" >/dev/null || die "${cmd} not found"
  done
  [[ -f /usr/share/OVMF/OVMF_CODE_4M.fd ]] || die "OVMF firmware not found"
}

seal_aws() {
  [[ ${EUID} -eq 0 ]] || die "seal runs as root"
  step "sealing"
  apt-get clean
  # A fresh instance gets a new machine id, new SSH host keys and its own
  # cloud-init run; the build's key leaves with the build.
  cloud-init clean --logs --machine-id
  rm -f /etc/ssh/ssh_host_*
  rm -f /root/.ssh/authorized_keys /home/*/.ssh/authorized_keys
  rm -rf "${dir}"
}

check_pins
case "${action}" in
  plan) plan ;;
  build) build ;;
  seal)
    case "${cloud}" in
      aws) seal_aws ;;
      *) die "seal ${cloud} is not implemented yet" ;;
    esac
    ;;
  *) usage ;;
esac
