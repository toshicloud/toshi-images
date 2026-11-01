#!/usr/bin/env bash
# Provisions a Linux cloud pool's host image on Packer's build instance, as
# root.
#
#   provision.sh plan [dir]          print what build would install; no network, no root
#   provision.sh build <cloud> [dir] install the agent, its packages and the guest image
#   provision.sh seal <cloud> [dir]  clear what must not be in the image
#
# <cloud> is aws or azure, the cloud of the template that runs this script.
# build is the same on both, with a read-only check of Azure's base image;
# seal differs.
#
# <dir> (default: this script's directory) holds versions.env, install.sh
# and the agent archive named in TOSHI_AGENT_ASSET; the template uploads
# them to one directory on the build instance.
#
# The image carries everything a pool host needs except the two files the
# pool's user data writes, /etc/toshi/enrollment-token and
# /etc/toshi/agent.toml; the user data then runs
# `systemctl enable --now toshi-host.service`. The unit is installed and
# neither enabled nor started here; the network helper's socket is enabled.
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
  for name in UBUNTU_SERIAL AZURE_UBUNTU_PUBLISHER AZURE_UBUNTU_OFFER AZURE_UBUNTU_SKU AZURE_UBUNTU_VERSION \
    TOSHI_AGENT_VERSION TOSHI_AGENT_ASSET GUEST_VERSION GUEST_REF ORAS_URL HOST_PACKAGES \
    PASST_VERSION PASST_URL; do
    [[ -n "${!name:-}" ]] || die "${name} is empty in versions.env"
  done
  for name in TOSHI_AGENT_SHA256 GUEST_SHA256 ORAS_SHA256 PASST_SHA256; do
    value=${!name:-}
    [[ "${value}" =~ ^[0-9a-f]{64}$ ]] || die "${name} is not a SHA-256: ${value}"
  done
  [[ "${GUEST_DIGEST}" =~ ^sha256:[0-9a-f]{64}$ ]] || die "GUEST_DIGEST is not a digest: ${GUEST_DIGEST}"
  [[ "${TOSHI_AGENT_ASSET}" == *_linux_amd64.tar.gz ]] || die "TOSHI_AGENT_ASSET is not a linux_amd64 archive: ${TOSHI_AGENT_ASSET}"
}

# The agent's image_dir: the directory the release's tmpfiles.d line
# creates, the default <data_dir>/images for the default data_dir ./data,
# which the unit resolves under /var/lib/toshi-host. It must exist when the
# agent starts.
image_dir=/var/lib/toshi-host/data/images

plan() {
  cat <<EOF
base AMI:   ubuntu-noble-24.04-amd64-server-${UBUNTU_SERIAL} (owner ${UBUNTU_AMI_OWNER})
base Azure: ${AZURE_UBUNTU_PUBLISHER}/${AZURE_UBUNTU_OFFER}/${AZURE_UBUNTU_SKU} ${AZURE_UBUNTU_VERSION}
packages:   ${HOST_PACKAGES}
passt:      ${PASST_URL##*/} (${PASST_VERSION}), sha256 ${PASST_SHA256}
  held, so apt keeps it
agent:      ${TOSHI_AGENT_ASSET} (${TOSHI_AGENT_VERSION}), sha256 ${TOSHI_AGENT_SHA256}
  /usr/local/bin/toshi-host, /usr/local/bin/toshi-host-pools
  /etc/systemd/system/toshi-host.service (installed, not enabled)
  /etc/sysusers.d/toshi.conf, /etc/tmpfiles.d/toshi.conf (the agent's lines)
  /etc/toshi/mining-pools.txt
  /etc/nftables.d/toshi-host.nft, included from /etc/nftables.conf
  /etc/systemd/system/toshi-host-netsets.socket (enabled) and toshi-host-netsets.service
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

# Ubuntu 24.04's passt has neither --dns-host nor --map-host-loopback, which
# the agent passes to each VM's passt. The pinned Ubuntu 26.04 package
# replaces it, and the hold keeps apt from replacing it again.
install_passt() {
  local work=$1
  local deb=${work}/passt.deb
  curl -fsSL --retry 3 -o "${deb}" "${PASST_URL}"
  check_sha256 "${deb}" "${PASST_SHA256}"
  DEBIAN_FRONTEND=noninteractive apt-get -o DPkg::Lock::Timeout=600 -y \
    install --no-install-recommends "${deb}"
  apt-mark hold passt

  local got
  got=$(dpkg-query -W -f='${Version}' passt)
  [[ "${got}" == "${PASST_VERSION}" ]] || die "passt ${got} is installed, want ${PASST_VERSION}"

  # No `| head`: under pipefail its SIGPIPE could kill the script.
  local version
  version=$(passt --version)
  echo "${version%%$'\n'*}"

  # grep -c exits 1 on no match, which `|| true` keeps from aborting here.
  local help n
  help=$(passt --help)
  n=$(printf '%s\n' "${help}" | grep -c -E 'dns-host|map-host-loopback' || true)
  echo "passt --help: ${n} of --dns-host, --map-host-loopback"
  if [[ ${n} -ne 2 ]]; then
    local missing=""
    [[ "${help}" == *--dns-host* ]] || missing+=" --dns-host"
    [[ "${help}" == *--map-host-loopback* ]] || missing+=" --map-host-loopback"
    die "passt --help lists ${n} of --dns-host, --map-host-loopback (missing${missing:-: none})"
  fi
}

# The agent's lines of the release's sysusers.d and tmpfiles.d files: the
# release also carries the control plane's, which a pool host does not run.
agent_lines() {
  local kind=$1 file=$2
  echo "# The agent's lines of ${kind}/toshi.conf in Toshi ${TOSHI_AGENT_VERSION}."
  case "${kind}" in
    sysusers.d) awk '!/^#/ && $2 == "toshi-host"' "${file}" ;;
    tmpfiles.d) awk '!/^#/ && ($2 == "/etc/toshi" || $2 ~ /^\/(var\/lib|run)\/toshi-host(\/|$)/)' "${file}" ;;
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

  local unit=${rel}/deploy/systemd/toshi-host.service
  grep -q '^ExecStart=/usr/local/bin/toshi-host ' "${unit}" || die "the unit does not run /usr/local/bin/toshi-host"

  install -m 0755 "${rel}/toshi-host" /usr/local/bin/toshi-host
  install -m 0755 "${rel}/deploy/nftables/toshi-host-pools.sh" /usr/local/bin/toshi-host-pools
  install -m 0644 "${unit}" /etc/systemd/system/toshi-host.service
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

  id -nG toshi-host | tr ' ' '\n' | grep -qx kvm || die "toshi-host is not in the group kvm"
  [[ -d "${image_dir}" ]] || die "the release's tmpfiles.d did not create ${image_dir}"
  systemctl is-enabled toshi-host.service >/dev/null 2>&1 && die "toshi-host.service is enabled"
  /usr/local/bin/toshi-host version
}

# The agent's host firewall, loaded at boot by nftables.service; the unit
# fills its cgroup sets when the agent starts, and the network helper writes
# each VM's sets when the agent asks on the helper's socket.
install_firewall() {
  local rel=$1
  install -d -m 0755 /etc/nftables.d
  install -m 0644 "${rel}/deploy/nftables/toshi-host.nft" /etc/nftables.d/toshi-host.nft
  # The image's table is the release's, byte for byte: nothing else goes
  # into the agent's firewall files.
  cmp -s "${rel}/deploy/nftables/toshi-host.nft" /etc/nftables.d/toshi-host.nft ||
    die "/etc/nftables.d/toshi-host.nft differs from the release's"
  local line='include "/etc/nftables.d/toshi-host.nft"'
  grep -qxF "${line}" /etc/nftables.conf || echo "${line}" >>/etc/nftables.conf
  nft -c -f /etc/nftables.conf
  systemctl enable nftables.service

  # The network helper: socket-activated, so enabling the socket is enough
  # for the helper to start on the agent's first request.
  local helper=${rel}/deploy/systemd/toshi-host-netsets.service
  grep -q '^ExecStart=/usr/local/bin/toshi-host netsets ' "${helper}" ||
    die "the network helper unit does not run /usr/local/bin/toshi-host netsets"
  install -m 0644 "${rel}/deploy/systemd/toshi-host-netsets.socket" "${helper}" /etc/systemd/system/
  systemctl daemon-reload
  systemctl enable toshi-host-netsets.socket
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
    --owner toshi-host:toshi-host --mode 0640
  rm -rf "${pull}"
}

# The Azure base image must keep the Azure datasource and walinuxagent's
# provisioning settings: the build changes the image only by adding the
# agent, and a pool's VM boots it as Canonical ships it. Read-only.
check_azure_base() {
  local file found=0
  for file in /etc/cloud/cloud.cfg.d/*; do
    [[ -f "${file}" ]] || continue
    if grep -Eq '^[[:space:]]*datasource_list:.*Azure' "${file}"; then
      found=1
      break
    fi
  done
  [[ ${found} -eq 1 ]] || die "no datasource_list in /etc/cloud/cloud.cfg.d/ names Azure"

  grep -Eq '^Provisioning\.Agent=(auto|cloud-init)$' /etc/waagent.conf ||
    die "/etc/waagent.conf does not leave provisioning to cloud-init"
  grep -qx 'OS.EnableFirewall=y' /etc/waagent.conf ||
    die "/etc/waagent.conf does not set OS.EnableFirewall=y"

  # The agent reads the upstream resolver from systemd-resolved's file and
  # leaves resolv.conf alone; the image keeps Canonical's symlink to the
  # stub.
  local resolv=/etc/resolv.conf
  if [[ "$(readlink "${resolv}")" != "../run/systemd/resolve/stub-resolv.conf" &&
    "$(readlink -f "${resolv}")" != /run/systemd/resolve/stub-resolv.conf ]]; then
    die "${resolv} does not resolve to systemd-resolved's stub"
  fi
}

build() {
  local cloud=$1
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
  step "installing passt ${PASST_VERSION}"
  install_passt "${work}"
  mkdir "${work}/release"
  step "installing the agent ${TOSHI_AGENT_VERSION}"
  install_agent "${work}/release"
  step "installing the firewall and the network helper"
  install_firewall "${work}/release"
  step "installing the guest image ${GUEST_VERSION}"
  install_guest "${work}"

  if [[ "${cloud}" == azure ]]; then
    step "checking the Azure base image"
    check_azure_base
  fi

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

seal_azure() {
  [[ ${EUID} -eq 0 ]] || die "seal runs as root"
  step "sealing"
  apt-get clean
  # A fresh instance gets a new machine id and its own cloud-init run. The
  # template's last step, waagent -deprovision+user, removes the build's
  # user, its keys and the SSH host keys; this script does not touch them.
  cloud-init clean --logs --machine-id
  rm -rf "${dir}"
}

check_pins
case "${action}" in
  plan) plan ;;
  build) build "${cloud}" ;;
  seal)
    case "${cloud}" in
      aws) seal_aws ;;
      azure) seal_azure ;;
    esac
    ;;
  *) usage ;;
esac
