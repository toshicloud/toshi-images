#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "${SCRIPT_DIR}/versions.env"

CACHE_DIR="${CACHE_DIR:-${XDG_CACHE_HOME:-${HOME}/.cache}/toshi-images}"
OUT_DIR="${OUT_DIR:-${CACHE_DIR}/out}"
WORK_DIR="${WORK_DIR:-${OUT_DIR}/work-windows-2025}"
SERIAL_LOG="${WORK_DIR}/serial.log"
OUTPUT_IMAGE="${OUT_DIR}/windows-2025.qcow2"

WINDOWS_ISO_CACHE="windows-server-2025-eval-${WINDOWS_ISO_BUILD}.iso"
VIRTIO_ISO_CACHE="virtio-win-${VIRTIO_WIN_VERSION}.iso"
RUNNER_ZIP_CACHE="actions-runner-win-x64-${RUNNER_VERSION}.zip"

# The installers tools.ps1 runs; each has <KEY>_URL and <KEY>_CACHE in versions.env.
TOOL_INSTALLERS="POWERSHELL_7 GIT_FOR_WINDOWS RUSTUP_INIT VS_BUILDTOOLS SEVENZIP DOTNET_SDK_8 WIX
  PYTHON NODE GO DOTNET_SDK_9 JAVA17 JAVA21 CMAKE NINJA GH YQ JQ NUGET"
# tools.ps1 writes `TOOLSET <name> <version>` for each from the installed
# tool itself; the build fails unless every line ends with the pinned version.
TOOLSETS="pwsh git git-lfs python pip node go rust rust-extra dotnet-8 dotnet-9 java-17 java-21
  msbuild cmake ninja 7zip gh yq jq nuget wix"

TOSHI_QEMU_ACCEL="${TOSHI_QEMU_ACCEL:-kvm}"
BUILD_TIMEOUT="${BUILD_TIMEOUT:-7200}"
DISK_SIZE="${DISK_SIZE:-64G}"
BUILD_CPUS="${BUILD_CPUS:-4}"
BUILD_MEMORY_MIB="${BUILD_MEMORY_MIB:-8192}"
BOOT_KEY_SECONDS="${BOOT_KEY_SECONDS:-10}"
OVMF_CODE="${OVMF_CODE:-/usr/share/OVMF/OVMF_CODE_4M.fd}"
OVMF_VARS="${OVMF_VARS:-/usr/share/OVMF/OVMF_VARS_4M.fd}"
QEMU_SYSTEM="${QEMU_SYSTEM:-qemu-system-x86_64}"
QEMU_IMG="${QEMU_IMG:-qemu-img}"

qemu_pid=""
monitor_log_pid=""
qemu_start_seconds=0
install_wall_seconds=0

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
      QEMU_CPU="host,hv_relaxed,hv_vapic,hv_spinlocks=0x1fff,hv_vpindex,hv_synic,hv_stimer,hv_time"
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

require_passwords() {
  if [[ -z "${WINDOWS_ADMIN_PASSWORD:-}" ]] || [[ -z "${WINDOWS_RUNNER_PASSWORD:-}" ]]; then
    echo "WINDOWS_ADMIN_PASSWORD and WINDOWS_RUNNER_PASSWORD must both be set" >&2
    exit 2
  fi
  local label pw classes
  for label in Administrator runner; do
    if [[ "${label}" == Administrator ]]; then
      pw="${WINDOWS_ADMIN_PASSWORD}"
    else
      pw="${WINDOWS_RUNNER_PASSWORD}"
    fi
    if ((${#pw} < 8)); then
      echo "${label} password must be at least 8 characters (Windows Setup complexity)" >&2
      exit 2
    fi
    classes=0
    [[ "${pw}" =~ [A-Z] ]] && classes=$((classes + 1))
    [[ "${pw}" =~ [a-z] ]] && classes=$((classes + 1))
    [[ "${pw}" =~ [0-9] ]] && classes=$((classes + 1))
    [[ "${pw}" =~ [^A-Za-z0-9] ]] && classes=$((classes + 1))
    if ((classes < 3)); then
      echo "${label} password must include at least three of: upper, lower, digit, symbol" >&2
      exit 2
    fi
  done
}

# The version a toolset's line must end with, as an awk regular expression.
# Git LFS and pip come with Git for Windows and Python, and MSBuild with the
# Build Tools release, so only their presence and form are checked.
toolset_expected_pattern() {
  local name=$1
  case "${name}" in
    pwsh) echo "${POWERSHELL_7_VERSION//./[.]}" ;;
    git) echo "${GIT_FOR_WINDOWS_VERSION%.*}[.]windows[.]${GIT_FOR_WINDOWS_VERSION##*.}" ;;
    git-lfs) echo "[0-9]+[.][0-9]+[.][0-9]+" ;;
    python) echo "${PYTHON_VERSION//./[.]}" ;;
    pip) echo "[0-9]+[.][0-9.]+" ;;
    node) echo "${NODE_VERSION//./[.]}" ;;
    go) echo "${GO_VERSION//./[.]}" ;;
    rust) echo "${RUST_DEFAULT_TOOLCHAIN//./[.]}" ;;
    rust-extra) echo "${RUST_EXTRA_TOOLCHAINS//./[.]}" ;;
    dotnet-8) echo "${DOTNET_SDK_8_VERSION//./[.]}" ;;
    dotnet-9) echo "${DOTNET_SDK_9_VERSION//./[.]}" ;;
    java-17) echo "${JAVA17_VERSION//[.+]/[.+]}" ;;
    java-21) echo "${JAVA21_VERSION//[.+]/[.+]}" ;;
    msbuild) echo "17[.][0-9.]+" ;;
    cmake) echo "${CMAKE_VERSION//./[.]}" ;;
    ninja) echo "${NINJA_VERSION//./[.]}" ;;
    7zip) echo "${SEVENZIP_VERSION//./[.]}" ;;
    gh) echo "${GH_VERSION//./[.]}" ;;
    yq) echo "${YQ_VERSION//./[.]}" ;;
    jq) echo "${JQ_VERSION//./[.]}" ;;
    nuget) echo "${NUGET_VERSION//./[.]}[.0-9]*" ;;
    wix) echo "${WIX_VERSION//./[.]}" ;;
    *)
      echo "unknown toolset: ${name}" >&2
      exit 1
      ;;
  esac
}

verify_toolset_serial_log() {
  local serial_clean name want
  serial_clean=$(tr -d '\r' < "${SERIAL_LOG}")
  for name in ${TOOLSETS}; do
    want="TOOLSET ${name} $(toolset_expected_pattern "${name}")"
    # Console output can share a line with the script's, so a line counts
    # when it ends with the expected text.
    if ! printf '%s\n' "${serial_clean}" | awk -v want="${want}" '$0 ~ (want "$") { found = 1 } END { exit !found }'; then
      echo "missing serial line matching: ${want}" >&2
      tail_serial_on_failure
      exit 1
    fi
  done
}

sha256_for_cache_name() {
  local name=$1
  awk -v want="${name}" '$2 == want { print $1; exit }' "${SCRIPT_DIR}/SHA256SUMS"
}

fetch() {
  local url=$1
  local cache_name=$2
  local dest="${CACHE_DIR}/${cache_name}"
  local expected actual

  expected=$(sha256_for_cache_name "${cache_name}")
  if [[ -z "${expected}" ]]; then
    echo "no SHA256SUMS entry for cache file: ${cache_name}" >&2
    exit 1
  fi

  if [[ -f "${dest}" ]]; then
    actual=$(sha256sum "${dest}" | awk '{print $1}')
    if [[ "${actual}" == "${expected}" ]]; then
      return 0
    fi
    echo "cached file SHA256 mismatch for ${cache_name}: expected ${expected}, got ${actual} (remove the file to retry)" >&2
    exit 1
  fi

  curl -fL --retry 3 -o "${dest}.part" "${url}"
  actual=$(sha256sum "${dest}.part" | awk '{print $1}')
  if [[ "${actual}" != "${expected}" ]]; then
    rm -f "${dest}.part"
    echo "SHA256 mismatch for download ${cache_name}: expected ${expected}, got ${actual}" >&2
    exit 1
  fi
  mv "${dest}.part" "${dest}"
}

xml_escape() {
  local s=$1
  s=${s//&/&amp;}
  s=${s//</&lt;}
  s=${s//>/&gt;}
  s=${s//\"/&quot;}
  s=${s//\'/&apos;}
  printf '%s' "${s}"
}

render_autounattend() {
  local tmpl admin_esc runner_esc rendered
  tmpl=$(<"${SCRIPT_DIR}/autounattend.xml")
  admin_esc=$(xml_escape "${WINDOWS_ADMIN_PASSWORD}")
  runner_esc=$(xml_escape "${WINDOWS_RUNNER_PASSWORD}")
  rendered=${tmpl//@ADMIN_PASSWORD@/"${admin_esc}"}
  rendered=${rendered//@RUNNER_PASSWORD@/"${runner_esc}"}
  rendered=${rendered//@IMAGE_NAME@/"$(xml_escape "${WINDOWS_IMAGE_NAME}")"}
  printf '%s' "${rendered}" >"${WORK_DIR}/cfg/autounattend.xml"
}

stage_toshi_guest() {
  local dest="${WORK_DIR}/cfg/toshi-guest.exe"
  # The guest pinned in ../guest.env, unless TOSHI_GUEST_EXE names another
  # toshi-guest.exe, such as a local build.
  if [[ -z "${TOSHI_GUEST_EXE:-}" ]]; then
    "${SCRIPT_DIR}/../fetch-guest.sh" "${OUT_DIR}/guest"
    TOSHI_GUEST_EXE="${OUT_DIR}/guest/toshi-guest.exe"
  fi
  if [[ ! -f "${TOSHI_GUEST_EXE}" ]]; then
    echo "TOSHI_GUEST_EXE must point to an existing toshi-guest.exe" >&2
    exit 1
  fi
  echo "toshi-guest: ${TOSHI_GUEST_EXE}"
  install -m 0755 "${TOSHI_GUEST_EXE}" "${dest}"
}

tail_serial_on_failure() {
  echo "--- last 60 lines of serial log (${SERIAL_LOG}) ---" >&2
  tail -n 60 "${SERIAL_LOG}" >&2 || true
  echo "screen dump (if any): ${WORK_DIR}/screen-latest.ppm" >&2
}

# The guest's FAILED marker carries the failed step's error, and what the
# build wrote before it is on the serial lines above the marker. Printing up
# to the marker keeps it in the output whatever the guest writes while it
# shuts down.
FAILED_CONTEXT_LINES=80

serial_clean() {
  tr -d '\r' < "${SERIAL_LOG}" | sed -E $'s/\e\\[[0-9;]*m//g'
}

report_guest_failure() {
  local marker
  marker=$(serial_clean | grep -a -m1 -o 'TOSHI-IMAGE-BUILD: FAILED.*' || true)
  echo "guest reported ${marker:-TOSHI-IMAGE-BUILD: FAILED}" >&2
  echo "--- serial log up to the guest's FAILED marker, last ${FAILED_CONTEXT_LINES} lines (${SERIAL_LOG}) ---" >&2
  serial_clean \
    | awk '/TOSHI-IMAGE-BUILD: FAILED/ { print; exit } NF { print }' \
    | tail -n "${FAILED_CONTEXT_LINES}" >&2 || true
  echo "screen dump (if any): ${WORK_DIR}/screen-latest.ppm" >&2
}

cleanup_qemu() {
  if [[ -n "${qemu_pid}" ]] && kill -0 "${qemu_pid}" 2>/dev/null; then
    kill "${qemu_pid}" 2>/dev/null || true
  fi
}

cleanup_build() {
  cleanup_qemu
  if [[ -n "${monitor_log_pid}" ]] && kill -0 "${monitor_log_pid}" 2>/dev/null; then
    kill "${monitor_log_pid}" 2>/dev/null || true
  fi
  rm -f "${WORK_DIR}/cfg/autounattend.xml" "${WORK_DIR}/cfg.iso" "${WORK_DIR}/VARS.fd"
}

wait_for_build_marker() {
  local boot_seconds=$SECONDS
  local deadline=$((SECONDS + BUILD_TIMEOUT))
  local last_screendump=$SECONDS
  while true; do
    if [[ -f "${SERIAL_LOG}" ]]; then
      if grep -q 'TOSHI-IMAGE-BUILD: DONE' "${SERIAL_LOG}"; then
        return 0
      fi
      if grep -q 'TOSHI-IMAGE-BUILD: FAILED' "${SERIAL_LOG}"; then
        report_guest_failure
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

    if ((SECONDS - last_screendump >= 60)); then
      printf 'screendump %s\n' "${WORK_DIR}/screen-latest.ppm" >&3 2>/dev/null || true
      last_screendump=$SECONDS
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
  local deadline=$((SECONDS + 300))
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

# Enter passes the firmware's "press any key to boot from CD" prompt. Stop
# before Windows Setup shows its progress screen: an Enter there presses Cancel.
send_boot_keys() {
  local i
  for ((i = 0; i < BOOT_KEY_SECONDS; i++)); do
    printf 'sendkey ret\n' >&3 2>/dev/null || true
    sleep 1
  done
}

input_size_human() {
  du -h "${1}" | awk '{print $1}'
}

echo "step 0: register cleanup"
trap cleanup_build EXIT

build_start_seconds=$SECONDS
echo "build started: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
echo "serial log: ${SERIAL_LOG}"

echo "step 1: check tools and inputs"
require_passwords
require_cmd "${QEMU_SYSTEM}"
require_cmd "${QEMU_IMG}"
require_cmd genisoimage
require_cmd curl
require_cmd sha256sum
validate_accel
if [[ ! -f "${OVMF_CODE}" ]]; then
  echo "OVMF code firmware not found: ${OVMF_CODE}" >&2
  exit 1
fi
if [[ ! -f "${OVMF_VARS}" ]]; then
  echo "OVMF variable store template not found: ${OVMF_VARS}" >&2
  exit 1
fi
mkdir -p "${CACHE_DIR}" "${OUT_DIR}"

echo "step 2: fetch pinned inputs"
fetch "${WINDOWS_ISO_URL}" "${WINDOWS_ISO_CACHE}"
fetch "${VIRTIO_WIN_URL}" "${VIRTIO_ISO_CACHE}"
fetch "${RUNNER_URL}" "${RUNNER_ZIP_CACHE}"
for tool in ${TOOL_INSTALLERS}; do
  url_var="${tool}_URL"
  cache_var="${tool}_CACHE"
  fetch "${!url_var}" "${!cache_var}"
done

windows_iso="${CACHE_DIR}/${WINDOWS_ISO_CACHE}"
virtio_iso="${CACHE_DIR}/${VIRTIO_ISO_CACHE}"
runner_zip="${CACHE_DIR}/${RUNNER_ZIP_CACHE}"

echo "step 3: build toshi-guest.exe"
rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}/cfg"
stage_toshi_guest

echo "step 4: render answer file and build config ISO"
render_autounattend
cp "${SCRIPT_DIR}/firstlogon.ps1" "${WORK_DIR}/cfg/"
cp "${SCRIPT_DIR}/devdrive.ps1" "${WORK_DIR}/cfg/"
cp "${SCRIPT_DIR}/tools.ps1" "${WORK_DIR}/cfg/"
cp "${SCRIPT_DIR}/runner-images.ps1" "${WORK_DIR}/cfg/"
mkdir -p "${WORK_DIR}/cfg/vendor/runner-images"
cp "${SCRIPT_DIR}/vendor/runner-images/LICENSE" \
  "${SCRIPT_DIR}/vendor/runner-images/"*.ps1 \
  "${WORK_DIR}/cfg/vendor/runner-images/"
cp "${runner_zip}" "${WORK_DIR}/cfg/${RUNNER_ZIP_CACHE}"
# tools.ps1 reads installer names and versions from tools.env, so versions.env
# stays the only place to bump them.
: >"${WORK_DIR}/cfg/tools.env"
for tool in ${TOOL_INSTALLERS}; do
  cache_var="${tool}_CACHE"
  cp "${CACHE_DIR}/${!cache_var}" "${WORK_DIR}/cfg/"
  printf '%s=%s\r\n' "${tool}" "${!cache_var}" >>"${WORK_DIR}/cfg/tools.env"
done
printf 'RUST_TOOLCHAIN=%s\r\nRUST_EXTRA_TOOLCHAINS=%s\r\nWIX_VERSION=%s\r\n' \
  "${RUST_DEFAULT_TOOLCHAIN}" "${RUST_EXTRA_TOOLCHAINS}" "${WIX_VERSION}" \
  >>"${WORK_DIR}/cfg/tools.env"
(
  cd "${WORK_DIR}/cfg"
  genisoimage -output "${WORK_DIR}/cfg.iso" -joliet -rock -volid TOSHI_CFG .
)

echo "step 5: create disk and monitor pipes"
"${QEMU_IMG}" create -f qcow2 "${WORK_DIR}/disk.qcow2" "${DISK_SIZE}"
cp "${OVMF_VARS}" "${WORK_DIR}/VARS.fd"
rm -f "${WORK_DIR}/monitor.in" "${WORK_DIR}/monitor.out"
mkfifo "${WORK_DIR}/monitor.in" "${WORK_DIR}/monitor.out"
cat "${WORK_DIR}/monitor.out" >"${WORK_DIR}/monitor.log" &
monitor_log_pid=$!
# Hold the monitor input open read-write: writes then never block, even if QEMU exits early.
exec 3<>"${WORK_DIR}/monitor.in"

echo "step 6: boot VM for unattended install"
qemu_start_seconds=$SECONDS
# Activation needs outbound network; nothing else runs on the host during the build.
"${QEMU_SYSTEM}" \
  -name toshi-image-build-windows \
  -machine "q35,accel=${TOSHI_QEMU_ACCEL}" \
  -cpu "${QEMU_CPU}" \
  -smp "${BUILD_CPUS}" \
  -m "${BUILD_MEMORY_MIB}M" \
  -drive if=pflash,format=raw,readonly=on,unit=0,file="${OVMF_CODE}" \
  -drive if=pflash,format=raw,unit=1,file="${WORK_DIR}/VARS.fd" \
  -drive if=none,id=disk,file="${WORK_DIR}/disk.qcow2",format=qcow2,cache=unsafe,discard=unmap \
  -device virtio-blk-pci,drive=disk,bootindex=0 \
  -drive if=none,id=cd0,media=cdrom,readonly=on,file="${windows_iso}" \
  -device ide-cd,drive=cd0,bus=ide.0,bootindex=1 \
  -drive if=none,id=cd1,media=cdrom,readonly=on,file="${virtio_iso}" \
  -device ide-cd,drive=cd1,bus=ide.1 \
  -drive if=none,id=cd2,media=cdrom,readonly=on,file="${WORK_DIR}/cfg.iso" \
  -device ide-cd,drive=cd2,bus=ide.2 \
  -netdev user,id=net0 \
  -device virtio-net-pci,netdev=net0 \
  -chardev socket,id=guest,path="${WORK_DIR}/guest.sock",server=on,wait=off \
  -device virtio-serial-pci \
  -device virtserialport,chardev=guest,name=toshi.guest \
  -device qemu-xhci \
  -device usb-tablet \
  -rtc base=localtime \
  -vga std \
  -display none \
  -serial "file:${SERIAL_LOG}" \
  -monitor "pipe:${WORK_DIR}/monitor" \
  -pidfile "${WORK_DIR}/qemu.pid" &
qemu_pid=$!

echo "step 7: send boot key presses"
send_boot_keys

echo "step 8: wait for guest build marker"
wait_for_build_marker

echo "step 9: wait for guest power-off"
wait_for_qemu_exit
install_wall_seconds=$((SECONDS - qemu_start_seconds))
qemu_pid=""
verify_toolset_serial_log

echo "step 10: compress the image"
part_image="${OUTPUT_IMAGE}.part"
convert_start=$SECONDS
"${QEMU_IMG}" convert -O qcow2 -c "${WORK_DIR}/disk.qcow2" "${part_image}"
convert_seconds=$((SECONDS - convert_start))
mv "${part_image}" "${OUTPUT_IMAGE}"

echo "step 11: summary"
virtual_size=$("${QEMU_IMG}" info "${OUTPUT_IMAGE}" | awk '/virtual size/ {print $3, $4}')
disk_usage=$(du -h "${OUTPUT_IMAGE}" | awk '{print $1}')
image_sha256=$(sha256sum "${OUTPUT_IMAGE}" | awk '{print $1}')

echo "image: ${OUTPUT_IMAGE}"
echo "size on disk: ${disk_usage}, virtual size: ${virtual_size}"
echo "sha256: ${image_sha256}"
echo "install wall time: ${install_wall_seconds}s"
echo "convert time: ${convert_seconds}s"
echo "input ${WINDOWS_ISO_CACHE}: $(input_size_human "${windows_iso}")"
echo "input ${VIRTIO_ISO_CACHE}: $(input_size_human "${virtio_iso}")"
echo "input ${RUNNER_ZIP_CACHE}: $(input_size_human "${runner_zip}")"
echo "total build time: $((SECONDS - build_start_seconds))s"
echo "build finished: $(date -u '+%Y-%m-%dT%H:%M:%SZ')"
