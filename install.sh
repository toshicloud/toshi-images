#!/usr/bin/env bash
# Install a built runner image into the host agent's image directory.
set -euo pipefail

QEMU_IMG="${QEMU_IMG:-qemu-img}"

usage() {
  cat >&2 <<'EOF'
usage: install.sh <image.qcow2> --image-dir <dir> [--name <name>] [--owner <user>:<group>] [--mode <mode>] [--replace]

Copies a built image into the agent's image_dir as <name>.qcow2 and records
"<sha256>  <name>.qcow2" in <dir>/SHA256SUMS. The agent finds it as the
image <name>, the value for [images] in agent.toml.

  --image-dir  the agent's [provider.qemu] image_dir (it must exist)
  --name       image name, default the file's name without .qcow2
  --owner      owner of the installed file, default the owner of <dir>
  --mode       mode of the installed file, default 0640
  --replace    replace an image of the same name that is already installed

Without --replace an image that is already installed is left alone:
install a new build under a new --name. With it, the new file is renamed
over the old one: running VMs keep reading the old file, and a warm pool
on the image notices the change within a minute and takes a new snapshot.
Never copy over an installed image in place: VMs built on it
would read a mix of both files.
EOF
  exit 2
}

fail() {
  echo "install.sh: $*" >&2
  exit 1
}

src=""
image_dir=""
name=""
owner=""
mode="0640"
replace=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --image-dir) [[ $# -ge 2 ]] || usage; image_dir=$2; shift 2 ;;
    --name) [[ $# -ge 2 ]] || usage; name=$2; shift 2 ;;
    --owner) [[ $# -ge 2 ]] || usage; owner=$2; shift 2 ;;
    --mode) [[ $# -ge 2 ]] || usage; mode=$2; shift 2 ;;
    --replace) replace=1; shift ;;
    -h|--help) usage ;;
    -*) echo "install.sh: unknown option: $1" >&2; usage ;;
    *) [[ -z "${src}" ]] || usage; src=$1; shift ;;
  esac
done
[[ -n "${src}" && -n "${image_dir}" ]] || usage

[[ -f "${src}" ]] || fail "image not found: ${src}"
[[ -d "${image_dir}" ]] || fail "image dir not found: ${image_dir}"
if [[ -z "${name}" ]]; then
  name=$(basename "${src}")
fi
name=${name%.qcow2}
[[ "${name}" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || fail "image name must be letters, digits, '.', '_' or '-': ${name}"
[[ "${mode}" =~ ^[0-7]{3,4}$ ]] || fail "mode must be octal, such as 0640: ${mode}"
if [[ -z "${owner}" ]]; then
  owner=$(stat -c '%U:%G' "${image_dir}")
fi
[[ "${owner}" == *:* ]] || fail "owner must be <user>:<group>: ${owner}"

command -v "${QEMU_IMG}" >/dev/null 2>&1 || fail "required tool not found: ${QEMU_IMG}"
format=$("${QEMU_IMG}" info -U "${src}" | awk -F': ' '$1 == "file format" { print $2 }')
[[ "${format}" == "qcow2" ]] || fail "${src} is not a qcow2 image (format: ${format:-unknown})"

dest="${image_dir}/${name}.qcow2"
[[ "${replace}" == 1 || ! -e "${dest}" ]] || fail "${dest} already exists; install this build under a new --name, or pass --replace"

part="${image_dir}/.${name}.qcow2.part"
trap 'rm -f "${part}" "${image_dir}/.SHA256SUMS.part"' EXIT
install -m "${mode}" -o "${owner%%:*}" -g "${owner#*:}" "${src}" "${part}"
sha256=$(sha256sum "${part}" | awk '{ print $1 }')
if [[ "${replace}" == 1 ]]; then
  # rename(2) over the old file: whoever has it open keeps it.
  mv -f "${part}" "${dest}"
else
  mv -n "${part}" "${dest}"
  [[ ! -e "${part}" ]] || fail "${dest} appeared while copying; nothing replaced"
fi

sums="${image_dir}/SHA256SUMS"
{
  if [[ -f "${sums}" ]]; then
    awk -v file="${name}.qcow2" '$2 != file' "${sums}"
  fi
  printf '%s  %s\n' "${sha256}" "${name}.qcow2"
} >"${image_dir}/.SHA256SUMS.part"
install -m 0644 -o "${owner%%:*}" -g "${owner#*:}" "${image_dir}/.SHA256SUMS.part" "${sums}"

echo "installed: ${dest} (${owner}, ${mode})"
echo "sha256: ${sha256}"
echo "image name: ${name}"
