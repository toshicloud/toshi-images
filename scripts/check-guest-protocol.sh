#!/usr/bin/env bash
# Checks that the guest protocol range of a published image overlaps the range
# the core speaks, before the image is pinned.
#
# usage: check-guest-protocol.sh <toshi-run-dir> <image-ref>
#
# The core's range is read from <toshi-run-dir>/internal/guestproto/codec.go:
# MinProtocolVersion is the oldest version it speaks and ProtocolVersion the
# newest. The image's range is guest.protocol_min and guest.protocol_max in the
# image manifest attached to <image-ref> (docs/published-images.md). The ranges
# must overlap: an image whose newest version is below the core's oldest, or
# whose oldest is above the core's newest, cannot agree a version with it.
#
# Exit codes: 0 the ranges overlap (one line names all four numbers), 1 they do
# not or an input is unusable, 2 a usage error, 3 the image has no manifest
# published yet.

set -euo pipefail

usage='usage: check-guest-protocol.sh <toshi-run-dir> <image-ref>'
core=${1:?$usage}
ref=${2:?$usage}
codec="$core/internal/guestproto/codec.go"

for tool in oras jq; do
  command -v "$tool" >/dev/null || {
    echo "check-guest-protocol: ${tool} is not on PATH" >&2
    exit 1
  }
done
if [[ ! -f $codec ]]; then
  echo "check-guest-protocol: ${codec} is not there" >&2
  exit 1
fi

# constant prints the integer a `const <name> = <n>` line of codec.go gives.
constant() {
  local name=$1 value
  value=$(sed -n "s/^const ${name} = \\([^ ]*\\)\$/\\1/p" "$codec")
  if [[ ! $value =~ ^[0-9]+$ ]]; then
    echo "check-guest-protocol: ${codec} has no line 'const ${name} = <integer>' (found '${value}')" >&2
    exit 1
  fi
  printf '%s\n' "$value"
}
core_min=$(constant MinProtocolVersion)
core_max=$(constant ProtocolVersion)

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

if ! oras discover --artifact-type application/vnd.toshi.image-manifest.v1+json -o json "$ref" >"$tmp/discover.json" 2>"$tmp/error"; then
  if grep -qiE '(^|[^0-9])404([^0-9]|$)|MANIFEST_UNKNOWN|NAME_UNKNOWN' "$tmp/error"; then
    echo "check-guest-protocol: ${ref} has no published manifest yet" >&2
    exit 3
  fi
  cat "$tmp/error" >&2
  exit 1
fi
digest=$(jq -r 'if (.referrers | type) != "array" then error("missing referrers") else .referrers[-1].digest // "" end' "$tmp/discover.json")
if [[ -z $digest ]]; then
  echo "check-guest-protocol: ${ref} has no published manifest yet" >&2
  exit 3
fi
if [[ ! $digest =~ ^sha256:[0-9a-f]{64}$ ]]; then
  echo "check-guest-protocol: invalid referrer digest: ${digest}" >&2
  exit 1
fi
repo=${ref%@*}
if [[ $repo == "$ref" && ${ref##*/} == *:* ]]; then repo=${ref%:*}; fi
oras pull --no-tty -o "$tmp/pull" "${repo}@${digest}" >/dev/null
manifest="$tmp/pull/manifest.json"
if [[ ! -f $manifest ]]; then
  echo "check-guest-protocol: the manifest attached to ${ref} has no manifest.json" >&2
  exit 1
fi

image=$(jq -r '.image // "unknown"' "$manifest")
image_min=$(jq -r '.guest.protocol_min // empty' "$manifest")
image_max=$(jq -r '.guest.protocol_max // empty' "$manifest")
if [[ ! $image_min =~ ^[0-9]+$ || ! $image_max =~ ^[0-9]+$ ]]; then
  echo "check-guest-protocol: the ${image} image ${ref} records no guest protocol range (protocol_min '${image_min}', protocol_max '${image_max}')" >&2
  exit 1
fi

summary="image ${image} (${ref}) speaks ${image_min}..${image_max}; the core speaks ${core_min}..${core_max}"
if ((image_max < core_min)); then
  echo "check-guest-protocol: ${summary}: the image's newest version ${image_max} is below the core's oldest ${core_min}" >&2
  exit 1
fi
if ((image_min > core_max)); then
  echo "check-guest-protocol: ${summary}: the image's oldest version ${image_min} is above the core's newest ${core_max}" >&2
  exit 1
fi
echo "check-guest-protocol: ${summary}: the ranges overlap"
