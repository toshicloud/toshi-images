#!/usr/bin/env bash
# Pins a published guest helper in guest.env through a pull request, and tags
# the release that builds the images once that pin has merged.
#
# usage: pin-guest-release.sh <version> <digest> [--dry-run]
#        pin-guest-release.sh --tag [--dry-run]
#
# The first form is the dispatch payload: what Toshi's guest workflow
# published to ghcr.io/toshicloud/toshi-guest. The script runs in a checkout
# of this repository, commits the pin on the branch guest/pin made from
# origin/main, pushes that branch and opens the pull request that the merge
# queue lands, or updates the open one. Main takes no direct push.
#
# The second form runs in a checkout of main after the pin merged: when the
# last commit that changed guest.env is a guest pin that no release tag names
# yet, it pushes the next v<major>.<minor>.<patch> tag on it, which starts the
# image build and publication (images.yml and container.yml on the tag).
#
# --dry-run prints what it would do and writes nothing. A repeated pin of a
# version and digest guest.env already carries, or that the open pull request
# already pins, does nothing.
#
# env: GH_TOKEN and GITHUB_REPOSITORY (or REPOSITORY) for the pin.

set -euo pipefail

usage='usage: pin-guest-release.sh <version> <digest> [--dry-run] | --tag [--dry-run]'
mode=pin
if [[ ${1:-} == --tag ]]; then
  mode=tag
  shift
  set -- '' '' "$@"
fi
version=${1-}
digest=${2-}
if [[ $mode == pin && ( -z $version || -z $digest ) ]]; then
  echo "$usage" >&2
  exit 2
fi
dry_run=false
if [[ -n ${3:-} ]]; then
  if [[ $3 != --dry-run ]]; then
    echo "$usage" >&2
    exit 2
  fi
  dry_run=true
fi

repo=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)

# author_identity sets identity to the repository's author, taken from the
# latest commit on the given revision that no bot wrote, as every pin on main
# carries it, whatever identity the checkout has. The pin commit and the
# release tag use it.
identity=()
identity_text=''
author_identity() {
  local line name email
  line=$(git -C "$repo" log -n 200 --format='%an%x09%ae' "$1" | grep -vm1 '\[bot\]' || true)
  name=${line%%$'\t'*}
  email=${line#*$'\t'}
  if [[ -z $line || -z $name || -z $email ]]; then
    echo "pin-guest-release: no commit by an author on ${1} to take the identity from" >&2
    return 1
  fi
  identity=(-c "user.name=${name}" -c "user.email=${email}")
  identity_text="${name} <${email}>"
}

# next_tag prints the next release: one patch above the highest
# v<major>.<minor>.<patch> tag. A tag with a suffix (a release candidate) is
# not a base for the count.
next_tag() {
  local last numbers major rest minor patch
  last=$(git -C "$repo" tag --list 'v*' | grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' | sort -V | tail -n 1 || true)
  if [[ -z $last ]]; then
    echo v0.1.0
    return
  fi
  numbers=${last#v}
  major=${numbers%%.*}
  rest=${numbers#*.}
  minor=${rest%%.*}
  patch=${rest#*.}
  echo "v${major}.${minor}.$((patch + 1))"
}

if [[ $mode == tag ]]; then
  if [[ -n $(git -C "$repo" status --porcelain) ]]; then
    echo "pin-guest-release: ${repo} has uncommitted changes" >&2
    exit 1
  fi
  pin=$(git -C "$repo" log -1 --format=%H -- guest.env)
  subject=$(git -C "$repo" log -1 --format=%s "$pin")
  if [[ $subject != 'chore(guest): pin '* ]]; then
    echo "pin-guest-release: the last change of guest.env is '${subject}', not a guest pin: nothing to do"
    exit 0
  fi
  if [[ -n $(git -C "$repo" tag --points-at "$pin" 'v*') ]]; then
    echo "pin-guest-release: ${pin} already has a release tag: nothing to do"
    exit 0
  fi
  next=$(next_tag)
  if git -C "$repo" rev-parse --verify --quiet "refs/tags/${next}" >/dev/null; then
    echo "pin-guest-release: tag ${next} already exists" >&2
    exit 1
  fi
  if [[ $dry_run == true ]]; then
    echo "pin-guest-release: would tag ${next} on ${pin} ('${subject}')"
    exit 0
  fi
  author_identity HEAD
  git -C "$repo" "${identity[@]}" tag -a "$next" -m "toshi-images ${next}: ${subject#chore(guest): pin }" "$pin"
  git -C "$repo" push -q origin "refs/tags/${next}"
  echo "pin-guest-release: tagged ${next} on ${pin} (started the image build)"
  exit 0
fi

if [[ ! $version =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
  echo "pin-guest-release: '${version}' is not a version to pin" >&2
  exit 2
fi
if [[ ! $digest =~ ^sha256:[0-9a-f]{64}$ ]]; then
  echo "pin-guest-release: '${digest}' is not a sha256 digest" >&2
  exit 2
fi

git -C "$repo" fetch -q origin main
pinned_env=$(git -C "$repo" show origin/main:guest.env)
pinned_version=$(sed -n 's/^TOSHI_GUEST_VERSION=//p' <<<"$pinned_env")
pinned_digest=$(sed -n 's/^TOSHI_GUEST_DIGEST=//p' <<<"$pinned_env")
if [[ $pinned_version == "$version" && $pinned_digest == "$digest" ]]; then
  echo "pin-guest-release: guest.env already pins ${version} ${digest}: nothing to do"
  exit 0
fi
if [[ $pinned_version == "$version" ]]; then
  echo "pin-guest-release: guest.env pins ${version} at ${pinned_digest}, not ${digest}" >&2
  exit 1
fi

title="chore(guest): pin ${version}"
branch=guest/pin
repository=${REPOSITORY:-${GITHUB_REPOSITORY:-}}
open=
if [[ $dry_run != true ]]; then
  if [[ -z ${GH_TOKEN:-} || -z $repository ]]; then
    echo "pin-guest-release: GH_TOKEN and GITHUB_REPOSITORY are needed to open the pull request" >&2
    exit 1
  fi
  open=$(gh pr list --repo "$repository" --head "$branch" --state open --json number,title --jq '.[0] // empty | "\(.number) \(.title)"' || true)
  # The open pull request's branch is left alone when it already pins this
  # version under the repository's author; a pin by another identity is
  # pushed again.
  author_identity origin/main
  git -C "$repo" fetch -q origin "$branch" 2>/dev/null || true
  tip=$(git -C "$repo" log -1 --format='%an <%ae>' "origin/${branch}" 2>/dev/null || true)
  if [[ $open == *" ${title}" && $tip == "$identity_text" ]]; then
    echo "pin-guest-release: pull request ${open%% *} already pins ${version}: nothing to do"
    exit 0
  fi
fi

if [[ $dry_run == true ]]; then
  echo "pin-guest-release: would pin ${version} ${digest}"
  echo "pin-guest-release: would push ${branch} from origin/main and open or update the pull request '${title}'"
  exit 0
fi

# The pin is committed in a worktree, so the script file in the checkout
# stays as it is while it runs.
work=$(mktemp -d)
body=$(mktemp)
trap 'git -C "$repo" worktree remove --force "$work" 2>/dev/null || true; rm -rf "$work" "$body"' EXIT
author_identity origin/main
git -C "$repo" worktree add -q -B "$branch" "$work" origin/main
sed -i "s|^TOSHI_GUEST_VERSION=.*|TOSHI_GUEST_VERSION=${version}|" "$work/guest.env"
sed -i "s|^TOSHI_GUEST_DIGEST=.*|TOSHI_GUEST_DIGEST=${digest}|" "$work/guest.env"
git -C "$work" add guest.env
git -C "$work" "${identity[@]}" commit -q -m "$title"
git -C "$work" push -q --force origin "HEAD:refs/heads/${branch}"
cat >"$body" <<EOF
Pins the guest helper that Toshi published.

- TOSHI_GUEST_VERSION: ${version}
- TOSHI_GUEST_DIGEST: ${digest}

When this merges, the next release tag is pushed on the pin commit and starts the image build.
EOF
if [[ -n $open ]]; then
  gh pr edit "${open%% *}" --repo "$repository" --title "$title" --body-file "$body"
  echo "pin-guest-release: updated pull request ${open%% *} to pin ${version}"
else
  gh pr create --repo "$repository" --base main --head "$branch" --title "$title" --body-file "$body"
  echo "pin-guest-release: opened the pull request pinning ${version}"
fi
