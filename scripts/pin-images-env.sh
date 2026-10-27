#!/usr/bin/env bash
# Pins the images a toshi-images release published in deploy/images.env and
# opens the pull request that lands it.
#
# usage: pin-images-env.sh <tag> <commit> <toshi-run-dir> [--dry-run]
#
# <tag> is a toshi-images release tag, v<major>.<minor>.<patch>, and <commit>
# the commit it names. The script reads the qcow2 and container manifests that
# tag published from their registry, rewrites
# <toshi-run-dir>/deploy/images.env, commits on a branch and opens the pull
# request. It exits 3 when either manifest is not in the registry yet, so the
# caller can try again after the other publication finishes. --dry-run prints
# the change and opens nothing.
#
# env: GH_TOKEN (opens the pull request; the dry run needs none),
# CONTAINER_REF (the container image reference without a tag),
# REPOSITORY (default toshicloud/toshi.run), RUNS (optional: the publishing
# runs for the body, such as "images 123, container 456").

set -euo pipefail

usage='usage: pin-images-env.sh <tag> <commit> <toshi-run-dir> [--dry-run]'
tag=${1:?$usage}
commit=${2:?$usage}
repo=${3:?$usage}
dry_run=false
if [[ -n ${4:-} ]]; then
  if [[ $4 != --dry-run ]]; then
    echo "$usage" >&2
    exit 2
  fi
  dry_run=true
fi

if [[ ! $tag =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "pin-images-env: '${tag}' is not a release tag" >&2
  exit 2
fi
if [[ ! $commit =~ ^[0-9a-f]{40}$ ]]; then
  echo "pin-images-env: '${commit}' is not a commit" >&2
  exit 2
fi
env_file="$repo/deploy/images.env"
if [[ ! -f $env_file ]]; then
  echo "pin-images-env: ${env_file} is not there" >&2
  exit 2
fi
for tool in oras jq; do
  command -v "$tool" >/dev/null || {
    echo "pin-images-env: ${tool} is not on PATH" >&2
    exit 1
  }
done

container_ref=${CONTAINER_REF:-ghcr.io/toshicloud/toshi-images/ubuntu-24.04-container}
repository=${REPOSITORY:-toshicloud/toshi.run}
images_ref="ghcr.io/toshicloud/toshi-images/ubuntu-24.04:${tag}"
container_tag="${container_ref}:${tag}"

# Not published yet is not a failure: the other workflow's publication starts
# the pin again when it finishes.
if ! qcow2_descriptor=$(oras manifest fetch --descriptor "$images_ref" 2>/dev/null); then
  echo "pin-images-env: ${images_ref} is not published yet" >&2
  exit 3
fi
if ! qcow2_manifest=$(oras manifest fetch "$images_ref" 2>/dev/null); then
  echo "pin-images-env: ${images_ref} has no manifest yet" >&2
  exit 3
fi
if ! container_descriptor=$(oras manifest fetch --descriptor "$container_tag" 2>/dev/null); then
  echo "pin-images-env: ${container_tag} is not published yet" >&2
  exit 3
fi

digest=$(jq -r '.digest' <<<"$qcow2_descriptor")
layer=$(jq -r '.layers[0].digest' <<<"$qcow2_manifest")
container_digest=$(jq -r '.digest' <<<"$container_descriptor")
for value in "$digest" "$layer" "$container_digest"; do
  if [[ ! $value =~ ^sha256:[0-9a-f]{64}$ ]]; then
    echo "pin-images-env: the registry gave '${value}', not a sha256 digest" >&2
    exit 1
  fi
done
# images.env pins the qcow2's own SHA-256, without the registry's sha256: prefix.
file_sha=${layer#sha256:}

pinned_release=$(sed -n 's/^TOSHI_IMAGES_RELEASE=//p' "$env_file")
pinned_digest=$(sed -n 's/^UBUNTU_24_04_DIGEST=//p' "$env_file")
pinned_sha=$(sed -n 's/^UBUNTU_24_04_SHA256=//p' "$env_file")
pinned_container=$(sed -n 's/^TOSHI_CONTAINER_IMAGE=//p' "$env_file")
if [[ $pinned_release == "$tag" && $pinned_digest == "$digest" && $pinned_sha == "$file_sha" &&
  $pinned_container == "${container_ref}@${container_digest}" ]]; then
  echo "pin-images-env: deploy/images.env already pins ${tag}: nothing to do"
  exit 0
fi

title="chore(images): pin toshi-images ${tag}"
if [[ $dry_run != true ]]; then
  if [[ -z ${GH_TOKEN:-} ]]; then
    echo "pin-images-env: GH_TOKEN is not set, so no pull request can be opened" >&2
    exit 1
  fi
  open=$(gh pr list --repo "$repository" --state open --limit 100 --json number,title |
    jq -r --arg title "$title" '.[] | select(.title == $title) | .number')
  if [[ -n $open ]]; then
    echo "pin-images-env: pull request ${open} already pins ${tag}: nothing to do"
    exit 0
  fi
fi

sed -i \
  -e "s|^TOSHI_IMAGES_RELEASE=.*|TOSHI_IMAGES_RELEASE=${tag}|" \
  -e "s|^TOSHI_IMAGES_COMMIT=.*|TOSHI_IMAGES_COMMIT=${commit}|" \
  -e "s|^UBUNTU_24_04_DIGEST=.*|UBUNTU_24_04_DIGEST=${digest}|" \
  -e "s|^UBUNTU_24_04_SHA256=.*|UBUNTU_24_04_SHA256=${file_sha}|" \
  -e "s|^TOSHI_CONTAINER_IMAGE=.*|TOSHI_CONTAINER_IMAGE=${container_ref}@${container_digest}|" \
  "$env_file"

if [[ $dry_run == true ]]; then
  git -C "$repo" diff -- deploy/images.env
  git -C "$repo" checkout -- deploy/images.env
  echo "pin-images-env: would commit '${title}' and open the pull request"
  exit 0
fi

branch="images/pin-${tag}"
body=$(mktemp)
trap 'rm -f "$body"' EXIT
cat >"$body" <<EOF
Pins the images that toshi-images ${tag} published.

- toshi-images tag: ${tag} at ${commit}
- UBUNTU_24_04_DIGEST: ${digest}
- UBUNTU_24_04_SHA256: ${file_sha}
- TOSHI_CONTAINER_IMAGE: ${container_ref}@${container_digest}
- publishing runs: ${RUNS:-the images and container workflows for the tag}
EOF

git -C "$repo" switch -C "$branch" >/dev/null
git -C "$repo" add deploy/images.env
git -C "$repo" commit -q -m "$title"
git -C "$repo" push -q --force origin "HEAD:refs/heads/${branch}"
gh pr create --repo "$repository" --base main --head "$branch" --title "$title" --body-file "$body"
echo "pin-images-env: opened the pull request pinning ${tag}"
