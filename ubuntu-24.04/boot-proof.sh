#!/usr/bin/env bash
# Boots a built ubuntu-24.04 image once under KVM, on an overlay that is
# thrown away, with a NoCloud seed that reports on the serial console
# whether the guest helper's service is active, which version it is, and
# whether an outbound HTTPS request is answered. The host agent's QEMU
# provider boots the image the same way: virtio disk and network, the
# toshi.guest serial port, user-mode networking or passt.
# Usage: ubuntu-24.04/boot-proof.sh <image.qcow2> <user|passt>
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../guest.env"

if [[ $# -ne 2 ]]; then
  echo "usage: boot-proof.sh <image.qcow2> <user|passt>" >&2
  exit 2
fi
IMAGE=$(readlink -f "$1")
NETWORK=$2
# The version the image's guest must report: the pinned one, unless the
# image was built with another TOSHI_GUEST_BIN.
EXPECT_GUEST_VERSION="${EXPECT_GUEST_VERSION:-${TOSHI_GUEST_VERSION}}"
BOOT_TIMEOUT="${BOOT_TIMEOUT:-300}"
# Seconds the guest has to power off after it reported the proof.
SHUTDOWN_TIMEOUT="${SHUTDOWN_TIMEOUT:-60}"
# Seconds QEMU has to exit after TERM before it is killed.
TERM_GRACE="${TERM_GRACE:-10}"
PROOF_URL="${PROOF_URL:-https://github.com/}"
QEMU_SYSTEM="${QEMU_SYSTEM:-qemu-system-x86_64}"
QEMU_IMG="${QEMU_IMG:-qemu-img}"
PASST="${PASST:-passt}"

case "${NETWORK}" in
  user | passt) ;;
  *)
    echo "network must be user or passt (got: ${NETWORK})" >&2
    exit 2
    ;;
esac
if [[ ! -f "${IMAGE}" ]]; then
  echo "no image at ${IMAGE}" >&2
  exit 1
fi
if [[ -z "${EXPECT_GUEST_VERSION}" ]]; then
  echo "no guest version to expect: guest.env pins none and EXPECT_GUEST_VERSION is unset" >&2
  exit 1
fi
if [[ ! -w /dev/kvm ]]; then
  echo "/dev/kvm is missing or not writable: the boot proof runs only under KVM" >&2
  exit 1
fi

WORK_DIR=$(mktemp -d "${TMPDIR:-/tmp}/boot-proof.XXXXXX")
SERIAL_LOG="${WORK_DIR}/serial.log"
qemu_pid=""
passt_pid=""
cleanup() {
  [[ -n "${qemu_pid}" ]] && kill "${qemu_pid}" 2>/dev/null || true
  [[ -n "${passt_pid}" ]] && kill "${passt_pid}" 2>/dev/null || true
  if [[ -n "${KEEP_SERIAL_LOG:-}" ]] && [[ -f "${SERIAL_LOG}" ]]; then
    cp "${SERIAL_LOG}" "${KEEP_SERIAL_LOG}"
  fi
  rm -rf "${WORK_DIR}"
}
trap cleanup EXIT

"${QEMU_IMG}" create -q -f qcow2 -b "${IMAGE}" -F qcow2 "${WORK_DIR}/overlay.qcow2"

mkdir "${WORK_DIR}/seed"
printf 'instance-id: boot-proof-%s\nlocal-hostname: boot-proof\n' "$(date +%s)" >"${WORK_DIR}/seed/meta-data"
cat >"${WORK_DIR}/seed/user-data" <<USERDATA
#cloud-config
runcmd:
  - |
    state=inactive
    for i in \$(seq 60); do
      state=\$(systemctl is-active toshi-guest.service)
      [ "\$state" = active ] && break
      sleep 1
    done
    echo "TOSHI-PROOF: service \$state" >/dev/ttyS0
    echo "TOSHI-PROOF: version \$(/usr/local/bin/toshi-guest version | awk '\$1 == "toshi-guest" {print \$2}')" >/dev/ttyS0
    echo "TOSHI-PROOF: https \$(curl -sS -o /dev/null -w '%{http_code}' --max-time 30 ${PROOF_URL} 2>&1)" >/dev/ttyS0
    echo "TOSHI-PROOF: DONE" >/dev/ttyS0
    systemctl poweroff
USERDATA
genisoimage -quiet -output "${WORK_DIR}/seed.iso" -volid cidata -joliet -rock \
  "${WORK_DIR}/seed/user-data" "${WORK_DIR}/seed/meta-data"

net_args=(-netdev "user,id=net0" -device "virtio-net-pci,netdev=net0")
if [[ "${NETWORK}" == passt ]]; then
  # As the provider does: no gateway mapping, and the host's upstream
  # resolvers, since passt gives the guest no DNS through a loopback stub.
  dns_args=()
  for conf in /etc/resolv.conf /run/systemd/resolve/resolv.conf; do
    while read -r addr; do
      dns_args+=(--dns "${addr}")
    done < <(awk '$1 == "nameserver" && $2 !~ /^(127\.|::1$|0\.0\.0\.0$)/ {print $2}' "${conf}" 2>/dev/null)
    [[ ${#dns_args[@]} -gt 0 ]] && break
  done
  if [[ ${#dns_args[@]} -eq 0 ]]; then
    echo "the host lists only loopback resolvers: passt would give the guest no DNS" >&2
    exit 1
  fi
  "${PASST}" --foreground --no-map-gw "${dns_args[@]}" \
    --socket "${WORK_DIR}/passt.sock" 2>"${WORK_DIR}/passt.log" &
  passt_pid=$!
  for _ in $(seq 50); do
    [[ -S "${WORK_DIR}/passt.sock" ]] && break
    sleep 0.1
  done
  if [[ ! -S "${WORK_DIR}/passt.sock" ]]; then
    echo "passt did not open its socket:" >&2
    cat "${WORK_DIR}/passt.log" >&2
    exit 1
  fi
  net_args=(-netdev "stream,id=net0,server=off,addr.type=unix,addr.path=${WORK_DIR}/passt.sock"
    -device "virtio-net-pci,netdev=net0")
fi

start=$(date +%s)
"${QEMU_SYSTEM}" -machine q35,accel=kvm -cpu host -smp 2 -m 2048 \
  -display none -monitor none -serial "file:${SERIAL_LOG}" \
  -drive "file=${WORK_DIR}/overlay.qcow2,if=virtio,format=qcow2" \
  -drive "file=${WORK_DIR}/seed.iso,if=virtio,format=raw,readonly=on" \
  -chardev "socket,id=guest,path=${WORK_DIR}/guest.sock,server=on,wait=off" \
  -device virtio-serial-pci \
  -device virtserialport,chardev=guest,name=toshi.guest \
  "${net_args[@]}" &
qemu_pid=$!

fail() {
  echo "boot proof (${NETWORK}): $*" >&2
  echo "--- last 60 lines of the serial log ---" >&2
  tail -n 60 "${SERIAL_LOG}" 2>/dev/null | tr -d '\r' >&2 || true
  if [[ -s "${WORK_DIR}/passt.log" ]]; then
    echo "--- passt log ---" >&2
    cat "${WORK_DIR}/passt.log" >&2
  fi
  exit 1
}

done_marker() { grep -aq '^TOSHI-PROOF: DONE' "${SERIAL_LOG}" 2>/dev/null; }
while ! done_marker; do
  if ! kill -0 "${qemu_pid}" 2>/dev/null; then
    # The guest powers off right after the marker: read the log once more.
    done_marker && break
    fail "QEMU exited before the proof finished"
  fi
  if grep -aqE 'Failed to start .*cloud-|Kernel panic' "${SERIAL_LOG}" 2>/dev/null; then
    fail "a cloud-init stage failed or the kernel panicked"
  fi
  if (($(date +%s) - start >= BOOT_TIMEOUT)); then
    fail "no proof within ${BOOT_TIMEOUT} s"
  fi
  sleep 1
done
seconds=$(($(date +%s) - start))
# Waits up to $1 seconds for QEMU to exit; fails if it is still running.
qemu_exits_within() {
  for _ in $(seq "$1"); do
    kill -0 "${qemu_pid}" 2>/dev/null || return 0
    sleep 1
  done
  ! kill -0 "${qemu_pid}" 2>/dev/null
}
# The guest powers off after the marker. If QEMU still runs SHUTDOWN_TIMEOUT
# seconds later it gets TERM, and KILL if TERM_GRACE seconds after that it
# has not finished its cleanup, so no shutdown can hold the proof.
if ! qemu_exits_within "${SHUTDOWN_TIMEOUT}"; then
  echo "boot proof (${NETWORK}): the guest did not power off within ${SHUTDOWN_TIMEOUT} s of the proof; stopping QEMU" >&2
  kill -TERM "${qemu_pid}" 2>/dev/null || true
  if ! qemu_exits_within "${TERM_GRACE}"; then
    echo "boot proof (${NETWORK}): QEMU did not exit within ${TERM_GRACE} s of TERM; killing it" >&2
    kill -KILL "${qemu_pid}" 2>/dev/null || true
  fi
fi
wait "${qemu_pid}" 2>/dev/null || true
qemu_pid=""

proof() { grep -a "^TOSHI-PROOF: $1 " "${SERIAL_LOG}" | tail -n 1 | tr -d '\r' | cut -d' ' -f3-; }
service=$(proof service)
version=$(proof version)
https=$(proof https)
[[ "${service}" == active ]] || fail "toshi-guest.service is '${service}', not active"
[[ "${version}" == "${EXPECT_GUEST_VERSION}" ]] || fail "the guest reports version '${version}', expected ${EXPECT_GUEST_VERSION}"
[[ "${https}" =~ ^[23][0-9][0-9]$ ]] || fail "HTTPS to ${PROOF_URL} gave '${https}'"

echo "boot proof (${NETWORK}): proof in ${seconds} s; toshi-guest ${version} active; HTTPS ${PROOF_URL} ${https}"
