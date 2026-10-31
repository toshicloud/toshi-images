#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/versions.env"
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../toolsets/versions.env"
# Railpack's pins, which its toolset reads from the seed.
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/../railpack.env"

CACHE_DIR="${CACHE_DIR:-${XDG_CACHE_HOME:-${HOME}/.cache}/toshi-images}"
OUT_DIR="${OUT_DIR:-${CACHE_DIR}/out}"
WORK_DIR="${OUT_DIR}/work"
SERIAL_LOG="${WORK_DIR}/serial.log"
OUTPUT_IMAGE="${OUT_DIR}/ubuntu-24.04.qcow2"

TOSHI_QEMU_ACCEL="${TOSHI_QEMU_ACCEL:-kvm}"
BUILD_TIMEOUT="${BUILD_TIMEOUT:-1800}"
# Seconds one try of a download in the guest may take (toolsets/lib.sh).
TRY_MAX_TIME="${TRY_MAX_TIME:-300}"
DISK_SIZE="${DISK_SIZE:-24G}"
BUILD_CPUS="${BUILD_CPUS:-2}"
BUILD_MEMORY_MIB="${BUILD_MEMORY_MIB:-4096}"
QEMU_SYSTEM="${QEMU_SYSTEM:-qemu-system-x86_64}"
QEMU_IMG="${QEMU_IMG:-qemu-img}"

qemu_pid=""

require_cmd() {
  local name=$1
  if ! command -v "$name" >/dev/null 2>&1; then
    echo "required tool not found: ${name}" >&2
    exit 1
  fi
}

validate_accel() {
  case "${TOSHI_QEMU_ACCEL}" in
    kvm)
      QEMU_CPU=host
      ;;
    tcg)
      QEMU_CPU=max
      ;;
    *)
      echo "TOSHI_QEMU_ACCEL must be kvm or tcg (got: ${TOSHI_QEMU_ACCEL})" >&2
      exit 1
      ;;
  esac
}

require_guest_bin() {
  # The guest pinned in ../guest.env, unless TOSHI_GUEST_BIN names another
  # linux/amd64 toshi-guest, such as a local build.
  if [[ -z "${TOSHI_GUEST_BIN:-}" ]]; then
    "${SCRIPT_DIR}/../fetch-guest.sh" "${OUT_DIR}/guest"
    TOSHI_GUEST_BIN="${OUT_DIR}/guest/toshi-guest"
  fi
  if [[ ! -f "${TOSHI_GUEST_BIN}" ]]; then
    echo "TOSHI_GUEST_BIN must point to an existing linux/amd64 toshi-guest binary" >&2
    exit 1
  fi
  echo "toshi-guest: ${TOSHI_GUEST_BIN}"
  # The version the image's VMs report: the binary's own, so a given
  # TOSHI_GUEST_BIN shows what it is too.
  TOSHI_GUEST_VERSION="$("${TOSHI_GUEST_BIN}" version 2>/dev/null | awk '$1 == "toshi-guest" {print $2}')" || true
  TOSHI_GUEST_VERSION="${TOSHI_GUEST_VERSION:-unknown}"
  echo "toshi-guest version: ${TOSHI_GUEST_VERSION}"
  if [[ "${TOSHI_GUEST_VERSION}" == dev ]]; then
    echo "warning: this toshi-guest was built without a version" >&2
  fi
}

# How often fetch_from goes through its URLs.
FETCH_ROUNDS=2

# fetch_from puts one pinned input into the cache. A cached file whose SHA256
# matches is kept and nothing is downloaded. Otherwise the URLs, which serve
# the same file, are tried in turn, `rounds` times over, until one download
# completes; a connection that stalls counts as a failed try. A completed
# download with another SHA256 is deleted and fails the build.
fetch_from() {
  local rounds=$1
  local expected_sha256=$2
  local dest=$3
  shift 3
  local name=${dest##*/}
  local actual round url

  if [[ -f "${dest}" ]]; then
    actual=$(sha256sum "${dest}" | awk '{print $1}')
    if [[ "${actual}" == "${expected_sha256}" ]]; then
      echo "cached: ${name}"
      return 0
    fi
  fi

  for ((round = 1; round <= rounds; round++)); do
    for url in "$@"; do
      if curl -fL --retry 3 --connect-timeout 30 --speed-limit 1024 --speed-time 60 -o "${dest}.part" "${url}"; then
        actual=$(sha256sum "${dest}.part" | awk '{print $1}')
        if [[ "${actual}" != "${expected_sha256}" ]]; then
          rm -f "${dest}.part"
          echo "SHA256 mismatch for ${name} from ${url}: expected ${expected_sha256}, got ${actual}" >&2
          exit 1
        fi
        mv "${dest}.part" "${dest}"
        echo "downloaded: ${name} from ${url}"
        return 0
      fi
      echo "download failed (round ${round} of ${rounds}): ${url}" >&2
    done
  done
  rm -f "${dest}.part"
  echo "could not download ${name}" >&2
  exit 1
}

fetch() {
  local url=$1
  local expected_sha256=$2
  local dest=$3

  fetch_from 1 "${expected_sha256}" "${dest}" "${url}"
}

tail_serial_on_failure() {
  echo "--- last 60 lines of serial log (${SERIAL_LOG}) ---" >&2
  tail -n 60 "${SERIAL_LOG}" >&2 || true
}

# The guest's FAILED marker names the script, line and command that failed,
# and that command's output is on the serial lines before the marker. After it
# the console holds only the shutdown, so the end of the log would not say
# why the build failed.
FAILED_CONTEXT_LINES=80

serial_clean() {
  tr -d '\r' < "${SERIAL_LOG}" | sed -E $'s/\e\\[[0-9;]*m//g'
}

# The line run_toolset (toolsets/lib.sh) prints for a toolset that failed.
# The guest can still be writing the log's last line, so the log is read once
# and its last line counts only when it ends in a newline: the empty line that
# echo appends after a finished log is the one sed drops, and otherwise sed
# drops the unfinished line.
failed_toolset_line() {
  { tr -d '\r' < "${SERIAL_LOG}"; echo; } \
    | sed -E -e '$d' -e $'s/\e\\[[0-9;]*m//g' \
    | grep -aE -m1 -o 'TOOLSET [a-z-]+ [^ ]+ failed: .*' || true
}

report_guest_failure() {
  local marker toolset
  toolset=$(failed_toolset_line)
  if [[ -n "${toolset}" ]]; then
    echo "guest reported ${toolset}" >&2
  fi
  marker=$(serial_clean | grep -a -m1 -o 'TOSHI-IMAGE-BUILD: FAILED.*' || true)
  echo "guest reported ${marker:-TOSHI-IMAGE-BUILD: FAILED}" >&2
  echo "--- serial log up to the guest's FAILED marker, last ${FAILED_CONTEXT_LINES} lines (${SERIAL_LOG}) ---" >&2
  serial_clean \
    | awk '/TOSHI-IMAGE-BUILD: FAILED/ { print; exit } NF { print }' \
    | tail -n "${FAILED_CONTEXT_LINES}" >&2 || true
}

# The version a toolset's line must end with, as an awk regular expression.
# Python is Ubuntu's current package, so only its major.minor is fixed.
toolset_expected_pattern() {
  local name=$1
  case "${name}" in
    python) echo "${PYTHON_SERIES//./[.]}[.][0-9]+" ;;
    node) echo "${NODE_VERSION//./[.]}" ;;
    # The build put the tarball in the seed, so the guest must have used it.
    go) echo "${GO_VERSION//./[.]} seed" ;;
    rust) echo "${RUST_VERSION//./[.]}" ;;
    dotnet) echo "${DOTNET_SDK_VERSION//./[.]}" ;;
    mise) echo "${MISE_VERSION//./[.]}" ;;
    docker) echo "${DOCKER_VERSION//./[.]}" ;;
    # `java -version` reports the major and its build, e.g. 17.0.20.1.
    java) echo "${JAVA17_VERSION%%.*}[.][0-9.]+.*" ;;
    cmake) echo "${CMAKE_VERSION//./[.]}" ;;
    gh) echo "${GH_VERSION//./[.]}" ;;
    yq) echo "${YQ_VERSION//./[.]}" ;;
    git-lfs) echo "${GIT_LFS_VERSION//./[.]}" ;;
    # `railpack --version` reports the version without the pin's leading v.
    railpack)
      local reported="${RAILPACK_VERSION#v}"
      echo "${reported//./[.]}"
      ;;
    *)
      echo "unknown toolset: ${name}" >&2
      exit 1
      ;;
  esac
}

# Console output can share a line with the script's, so a line counts when it
# ends with the expected text.
serial_has_line() {
  printf '%s\n' "$1" | awk -v want="$2" '$0 ~ (want "$") { found = 1 } END { exit !found }'
}

verify_toolset_serial_log() {
  local serial_clean name line
  serial_clean=$(tr -d '\r' < "${SERIAL_LOG}")
  for name in ${TOOLSETS}; do
    line="TOOLSET ${name} $(toolset_expected_pattern "${name}")"
    if ! serial_has_line "${serial_clean}" "${line}"; then
      echo "missing serial line matching: ${line}" >&2
      tail_serial_on_failure
      exit 1
    fi
  done
  if ! serial_has_line "${serial_clean}" 'TOOLSET env ok'; then
    echo "missing serial line: TOOLSET env ok" >&2
    tail_serial_on_failure
    exit 1
  fi
}

cleanup_qemu() {
  if [[ -n "${qemu_pid}" ]] && kill -0 "${qemu_pid}" 2>/dev/null; then
    kill "${qemu_pid}" 2>/dev/null || true
  fi
}

# systemd, cloud-init and the kernel print these on the serial console
# (systemd in colour, hence the escape codes stripped before matching). After
# one of them the guest never reaches the marker, so the build stops instead
# of waiting for BUILD_TIMEOUT. A runcmd that fails makes cloud-init log the
# warning below before its unit fails, and systemd's line for that unit does
# not always reach the console, so both are matched: the warning by its exact
# wording, so that no other cloud-init warning matches.
GUEST_FAILURE_PATTERN='Failed to start cloud-[a-z-]+[.]service|cc_scripts_user[.]py\[WARNING\]: Failed to run module scripts_user |Kernel panic - not syncing'

wait_for_build_marker() {
  local boot_seconds=$SECONDS
  local deadline=$((SECONDS + BUILD_TIMEOUT))
  local failure what
  while true; do
    if [[ -f "${SERIAL_LOG}" ]]; then
      if grep -q 'TOSHI-IMAGE-BUILD: DONE' "${SERIAL_LOG}"; then
        return 0
      fi
      if grep -q 'TOSHI-IMAGE-BUILD: FAILED' "${SERIAL_LOG}"; then
        report_guest_failure
        exit 1
      fi
      # A failed toolset is followed by the FAILED marker; the build does
      # not wait for a marker that may not come.
      failure=$(failed_toolset_line)
      if [[ -n "${failure}" ]]; then
        echo "a toolset failed in the guest (seen $((SECONDS - boot_seconds))s after boot): ${failure}" >&2
        tail_serial_on_failure
        exit 1
      fi
      failure=$(serial_clean | grep -aE -m1 "${GUEST_FAILURE_PATTERN}" || true)
      if [[ -n "${failure}" ]]; then
        what="cloud-init failed in the guest"
        [[ "${failure}" == *"Kernel panic"* ]] && what="the guest kernel panicked"
        echo "${what} (seen $((SECONDS - boot_seconds))s after boot): ${failure}" >&2
        tail_serial_on_failure
        exit 1
      fi
    fi

    if [[ -n "${qemu_pid}" ]] && ! kill -0 "${qemu_pid}" 2>/dev/null; then
      if [[ -f "${SERIAL_LOG}" ]] && grep -q 'TOSHI-IMAGE-BUILD: DONE' "${SERIAL_LOG}"; then
        return 0
      fi
      echo "QEMU exited before TOSHI-IMAGE-BUILD: DONE (seen $((SECONDS - boot_seconds))s after boot)" >&2
      tail_serial_on_failure
      exit 1
    fi

    if ((SECONDS >= deadline)); then
      echo "build timed out after ${BUILD_TIMEOUT}s" >&2
      tail_serial_on_failure
      exit 1
    fi

    sleep 5
  done
}

wait_for_qemu_exit() {
  local deadline=$((SECONDS + 120))
  while kill -0 "${qemu_pid}" 2>/dev/null; do
    if ((SECONDS >= deadline)); then
      kill "${qemu_pid}" 2>/dev/null || true
      wait "${qemu_pid}" 2>/dev/null || true
      return 0
    fi
    sleep 1
  done
  wait "${qemu_pid}" 2>/dev/null || true
}

echo "serial log: ${SERIAL_LOG}"

echo "step 1: check tools and inputs"
require_guest_bin
require_cmd "${QEMU_SYSTEM}"
require_cmd "${QEMU_IMG}"
require_cmd genisoimage
require_cmd curl
require_cmd sha256sum
validate_accel
if [[ ! "${TRY_MAX_TIME}" =~ ^[1-9][0-9]*$ ]]; then
  echo "TRY_MAX_TIME must be a number of seconds (got: ${TRY_MAX_TIME})" >&2
  exit 1
fi
mkdir -p "${CACHE_DIR}"
build_start_seconds=$SECONDS

echo "step 2: fetch pinned inputs"
base_image="${CACHE_DIR}/ubuntu-24.04-server-cloudimg-amd64-${UBUNTU_SERIAL}.img"
runner_tarball="${CACHE_DIR}/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz"
go_tarball="${CACHE_DIR}/go${GO_VERSION}.linux-amd64.tar.gz"
# The Go tarball goes to the guest in the seed (toolsets/go.sh), so the guest
# does not download it. It is the smallest input and is fetched first: a
# build that cannot get it stops before the larger downloads.
fetch_from "${FETCH_ROUNDS}" "${GO_SHA256}" "${go_tarball}" "${GO_URL_ALT}" "${GO_URL}"
fetch "${UBUNTU_IMAGE_URL}" "${UBUNTU_IMAGE_SHA256}" "${base_image}"
fetch "${RUNNER_URL}" "${RUNNER_SHA256}" "${runner_tarball}"
base_image=$(readlink -f "${base_image}")

echo "step 3: create overlay disk"
rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"
(
  cd "${WORK_DIR}"
  "${QEMU_IMG}" create -f qcow2 -F qcow2 -b "${base_image}" overlay.qcow2 "${DISK_SIZE}"
)

echo "step 4: build cloud-init seed ISO"
seed_dir="${WORK_DIR}/seed"
mkdir -p "${seed_dir}"
cp "${SCRIPT_DIR}/user-data" "${SCRIPT_DIR}/meta-data" "${SCRIPT_DIR}/toshi-guest.service" "${SCRIPT_DIR}/toshi-guest-userdata.service" "${SCRIPT_DIR}/toshi-guest-gce.service" "${SCRIPT_DIR}/toshi-guest-azure.service" "${seed_dir}/"
install -m 0755 "${TOSHI_GUEST_BIN}" "${seed_dir}/toshi-guest"
cp "${runner_tarball}" "${seed_dir}/actions-runner-linux-x64.tar.gz"
cp "${go_tarball}" "${seed_dir}/go.tar.gz"
cp -r "${SCRIPT_DIR}/../toolsets" "${seed_dir}/toolsets"
# Railpack's pin file sits next to guest.env at the repository root, and its
# toolset reads it from beside the toolsets.
cp "${SCRIPT_DIR}/../railpack.env" "${seed_dir}/railpack.env"
echo "TRY_MAX_TIME=${TRY_MAX_TIME}" > "${seed_dir}/toolsets/limits.env"
(
  cd "${seed_dir}"
  genisoimage -output "${WORK_DIR}/seed.iso" -volid cidata -joliet -rock .
)

echo "step 5: boot VM for provisioning"
trap cleanup_qemu EXIT
pushd "${WORK_DIR}" >/dev/null
"${QEMU_SYSTEM}" \
  -name toshi-image-build \
  -machine "q35,accel=${TOSHI_QEMU_ACCEL}" \
  -cpu "${QEMU_CPU}" \
  -smp "${BUILD_CPUS}" \
  -m "${BUILD_MEMORY_MIB}M" \
  -drive file=overlay.qcow2,if=virtio,format=qcow2,discard=unmap \
  -drive file=seed.iso,if=virtio,format=raw,readonly=on \
  -netdev user,id=net0 \
  -device virtio-net-pci,netdev=net0 \
  -display none \
  -serial file:serial.log \
  -no-reboot &
qemu_pid=$!
popd >/dev/null

echo "step 6: wait for guest build marker"
wait_for_build_marker

echo "step 7: wait for guest power-off"
wait_for_qemu_exit
qemu_pid=""
trap - EXIT

echo "step 8: compress the image"
part_image="${OUTPUT_IMAGE}.part"
(
  cd "${WORK_DIR}"
  "${QEMU_IMG}" convert -O qcow2 -c overlay.qcow2 "${part_image}"
)
mv "${part_image}" "${OUTPUT_IMAGE}"

verify_toolset_serial_log

virtual_size=$("${QEMU_IMG}" info "${OUTPUT_IMAGE}" | awk '/virtual size/ {print $3, $4}')
disk_usage=$(du -h "${OUTPUT_IMAGE}" | awk '{print $1}')
image_sha256=$(sha256sum "${OUTPUT_IMAGE}" | awk '{print $1}')

# Each toolset's line, after the lines of the files it downloaded.
grep -aE '^(TOOLSET|downloaded:) ' "${SERIAL_LOG}" | tr -d '\r'
echo "image: ${OUTPUT_IMAGE}"
echo "size on disk: ${disk_usage}, virtual size: ${virtual_size}"
echo "sha256: ${image_sha256}"
echo "toshi-guest version: ${TOSHI_GUEST_VERSION}"
echo "build time: $((SECONDS - build_start_seconds))s"
