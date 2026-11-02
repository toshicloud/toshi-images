#!/usr/bin/env bash
# Writes the two files image-manifest.sh assemble reads for a pool host image
# from linux-pool-host/versions.env: guest.env (the guest image the host
# carries) and toolsets.txt (what the host installs besides apt packages: the
# Toshi agent, passt and oras).
#   manifest-inputs.sh <versions.env> <dir>
set -euo pipefail

versions=${1:?usage: manifest-inputs.sh <versions.env> <dir>}
dir=${2:?usage: manifest-inputs.sh <versions.env> <dir>}
mkdir -p "$dir"
(
  # shellcheck disable=SC1090
  source "$versions"
  : "${GUEST_VERSION:?} ${GUEST_DIGEST:?} ${TOSHI_AGENT_VERSION:?} ${PASST_VERSION:?} ${ORAS_VERSION:?}"
  printf 'TOSHI_GUEST_VERSION=%s\nTOSHI_GUEST_DIGEST=%s\n' "$GUEST_VERSION" "$GUEST_DIGEST" >"$dir/guest.env"
  printf 'TOOLSET toshi-host %s\nTOOLSET passt %s\nTOOLSET oras %s\n' \
    "$TOSHI_AGENT_VERSION" "$PASST_VERSION" "$ORAS_VERSION" >"$dir/toolsets.txt"
)
