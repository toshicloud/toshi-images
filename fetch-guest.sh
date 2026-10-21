#!/usr/bin/env bash
# Pulls the guest helper pinned in guest.env into a directory, which then
# holds toshi-guest and toshi-guest.exe.
# Usage: fetch-guest.sh <directory>
set -euo pipefail

here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck disable=SC1091
source "${here}/guest.env"

if [[ $# -ne 1 ]]; then
  echo "usage: fetch-guest.sh <directory>" >&2
  exit 2
fi
dest=$1

if [[ -z "${TOSHI_GUEST_VERSION:-}" ]]; then
  echo "guest.env pins no TOSHI_GUEST_VERSION" >&2
  exit 1
fi
if [[ ! "${TOSHI_GUEST_DIGEST:-}" =~ ^sha256:[0-9a-f]{64}$ ]]; then
  echo "guest.env's TOSHI_GUEST_DIGEST is not a sha256 digest: ${TOSHI_GUEST_DIGEST:-}" >&2
  exit 1
fi
for tool in oras jq; do
  if ! command -v "${tool}" >/dev/null 2>&1; then
    echo "required tool not found: ${tool}" >&2
    exit 1
  fi
done

ref="${TOSHI_GUEST_REF}@${TOSHI_GUEST_DIGEST}"
# Pulling by digest makes oras check the manifest and every file against it.
version=$(oras manifest fetch "${ref}" | jq -r '.annotations["org.opencontainers.image.version"] // empty')
if [[ "${version}" != "${TOSHI_GUEST_VERSION}" ]]; then
  echo "${ref} is version '${version}', guest.env pins ${TOSHI_GUEST_VERSION}" >&2
  exit 1
fi

rm -rf "${dest}"
mkdir -p "${dest}"
oras pull --no-tty -o "${dest}" "${ref}" >&2
for file in toshi-guest toshi-guest.exe; do
  if [[ ! -f "${dest}/${file}" ]]; then
    echo "${ref} has no ${file}" >&2
    exit 1
  fi
done
chmod 0755 "${dest}/toshi-guest" "${dest}/toshi-guest.exe"

reported=$("${dest}/toshi-guest" version | awk '$1 == "toshi-guest" {print $2}')
if [[ "${reported}" != "${TOSHI_GUEST_VERSION}" ]]; then
  echo "${dest}/toshi-guest reports version '${reported}', guest.env pins ${TOSHI_GUEST_VERSION}" >&2
  exit 1
fi
echo "toshi-guest ${TOSHI_GUEST_VERSION}: ${ref}" >&2
