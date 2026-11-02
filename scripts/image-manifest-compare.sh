#!/usr/bin/env bash
# Compare an image manifest with the manifest attached to a published image.
set -euo pipefail

usage='usage: image-manifest-compare.sh NEW.json REF | NEW.json --newest-tag REPO'
new=${1:?$usage}
shift
ref=''
repo=''
newest=false
case $# in
  1)
    ref=$1
    if [[ $ref == *:latest-release ]]; then repo=${ref%:latest-release}; newest=true; fi ;;
  2)
    [[ $1 == --newest-tag ]] || { echo "$usage" >&2; exit 2; }
    repo=$2; newest=true ;;
  *) echo "$usage" >&2; exit 2 ;;
esac

scripts=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
manifest="$scripts/image-manifest.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

not_published() {
  echo "image-manifest-compare: no published manifest for $1"
  exit 0
}

registry_error() {
  # A missing image or repository is different from an authentication or
  # network failure, which must not be mistaken for a successful comparison.
  if grep -qiE '(^|[^0-9])404([^0-9]|$)|MANIFEST_UNKNOWN|NAME_UNKNOWN' "$tmp/error"; then
    not_published "$1"
  fi
  cat "$tmp/error" >&2
  exit 1
}

if [[ $newest == true ]]; then
  if ! oras repo tags "$repo" >"$tmp/tags" 2>"$tmp/error"; then registry_error "$repo"; fi
  tag=$(awk '/^v/ {print}' "$tmp/tags" | LC_ALL=C sort -V | tail -n 1)
  [[ -n $tag ]] || not_published "$repo"
  ref="${repo}:${tag}"
else
  repo=${ref%@*}
  if [[ $repo == "$ref" && ${ref##*/} == *:* ]]; then repo=${ref%:*}; fi
fi

if ! oras discover --artifact-type application/vnd.toshi.image-manifest.v1+json -o json "$ref" >"$tmp/discover.json" 2>"$tmp/error"; then
  registry_error "$ref"
fi
digest=$(jq -r 'if (.referrers | type) != "array" then error("missing referrers") else .referrers[-1].digest // "" end' "$tmp/discover.json")
[[ -n $digest ]] || not_published "$ref"
if [[ ! $digest =~ ^sha256:[0-9a-f]{64}$ ]]; then
  echo "image-manifest-compare: invalid referrer digest: $digest" >&2
  exit 1
fi
oras pull --no-tty -o "$tmp/pull" "${repo}@${digest}" >/dev/null
old="$tmp/pull/manifest.json"
[[ -f $old ]] || { echo 'image-manifest-compare: published manifest.json is missing' >&2; exit 1; }

new_pins=$("$manifest" pinset "$new")
old_pins=$("$manifest" pinset "$old")
if [[ $new_pins != "$old_pins" ]]; then
  echo 'image-manifest-compare: pins changed'
  exit 0
fi
new_digest=$("$manifest" digest "$new")
old_digest=$("$manifest" digest "$old")
if [[ $new_digest == "$old_digest" ]]; then
  echo 'image-manifest-compare: manifests match'
  exit 0
fi
echo 'image-manifest-compare: manifest changed with unchanged pins'
jq -S 'del(.built, .image_digest, .packages[].version)' "$old" >"$tmp/old.json"
jq -S 'del(.built, .image_digest, .packages[].version)' "$new" >"$tmp/new.json"
diff -u --label published --label new "$tmp/old.json" "$tmp/new.json" || true
exit 1
