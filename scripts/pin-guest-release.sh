#!/usr/bin/env bash
# Pins a published guest helper in guest.env and moves the release tag that
# builds the images with it.
#
# usage: pin-guest-release.sh <version> <digest> [--dry-run]
#
# <version> and <digest> are the dispatch payload: what Toshi's guest workflow
# published to ghcr.io/toshicloud/toshi-guest. The script runs in a checkout of
# this repository's main, commits the pin and pushes the next
# v<major>.<minor>.<patch> tag, which starts the image build and publication
# (images.yml and container.yml on the tag). --dry-run prints what it would do
# and writes nothing.
#
# It does nothing when guest.env already pins that version and digest: a
# repeated dispatch neither commits nor tags.

set -euo pipefail

usage='usage: pin-guest-release.sh <version> <digest> [--dry-run]'
version=${1:?$usage}
digest=${2:?$usage}
dry_run=false
if [[ -n ${3:-} ]]; then
  if [[ $3 != --dry-run ]]; then
    echo "$usage" >&2
    exit 2
  fi
  dry_run=true
fi

if [[ ! $version =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  echo "pin-guest-release: '${version}' is not a version to pin" >&2
  exit 2
fi
if [[ ! $digest =~ ^sha256:[0-9a-f]{64}$ ]]; then
  echo "pin-guest-release: '${digest}' is not a sha256 digest" >&2
  exit 2
fi

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
env_file="$repo/guest.env"
branch=$(git -C "$repo" rev-parse --abbrev-ref HEAD)
if [[ $branch != main ]]; then
  echo "pin-guest-release: ${repo} is on ${branch}, not main" >&2
  exit 1
fi
if [[ -n $(git -C "$repo" status --porcelain) ]]; then
  echo "pin-guest-release: ${repo} has uncommitted changes" >&2
  exit 1
fi

pinned_version=$(sed -n 's/^TOSHI_GUEST_VERSION=//p' "$env_file")
pinned_digest=$(sed -n 's/^TOSHI_GUEST_DIGEST=//p' "$env_file")
if [[ $pinned_version == "$version" && $pinned_digest == "$digest" ]]; then
  echo "pin-guest-release: guest.env already pins ${version} ${digest}: nothing to do"
  exit 0
fi
if [[ $pinned_version == "$version" ]]; then
  echo "pin-guest-release: guest.env pins ${version} at ${pinned_digest}, not ${digest}" >&2
  exit 1
fi

# The next release: one patch above the highest v<major>.<minor>.<patch> tag.
# A tag with a suffix (a release candidate) is not a base for the count.
last=$(git -C "$repo" tag --list 'v*' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -n 1 || true)
if [[ -z $last ]]; then
  next=v0.1.0
else
  numbers=${last#v}
  major=${numbers%%.*}
  rest=${numbers#*.}
  minor=${rest%%.*}
  patch=${rest#*.}
  next="v${major}.${minor}.$((patch + 1))"
fi
if git -C "$repo" rev-parse --verify --quiet "refs/tags/${next}" >/dev/null; then
  echo "pin-guest-release: tag ${next} already exists" >&2
  exit 1
fi

if [[ $dry_run == true ]]; then
  echo "pin-guest-release: would pin ${version} ${digest}"
  echo "pin-guest-release: would commit 'chore(guest): pin ${version}' on main and tag ${next}"
  exit 0
fi

sed -i "s|^TOSHI_GUEST_VERSION=.*|TOSHI_GUEST_VERSION=${version}|" "$env_file"
sed -i "s|^TOSHI_GUEST_DIGEST=.*|TOSHI_GUEST_DIGEST=${digest}|" "$env_file"
git -C "$repo" add guest.env
git -C "$repo" commit -q -m "chore(guest): pin ${version}"
git -C "$repo" push -q origin "HEAD:refs/heads/main"
git -C "$repo" tag -a "$next" -m "toshi-images ${next}: guest ${version}"
git -C "$repo" push -q origin "refs/tags/${next}"
echo "pin-guest-release: pinned ${version} ${digest} and tagged ${next} (started the image build)"
