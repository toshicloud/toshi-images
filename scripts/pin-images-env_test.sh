#!/usr/bin/env bash
# Runs scripts/pin-images-env.sh against a fake registry and a fake gh: the
# pin a release already has changes nothing, a new release rewrites
# deploy/images.env and opens the pull request, and an unpublished manifest
# waits for the other workflow instead of failing.

set -euo pipefail

scripts=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
script="$scripts/pin-images-env.sh"

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

failed=0
expect() {
  local name=$1 want=$2 got=$3
  if [[ $want == "$got" ]]; then
    echo "ok ${name}"
  else
    echo "FAIL ${name}: want '${want}', got '${got}'"
    failed=$((failed + 1))
  fi
}

# The registry: oras prints the descriptor or the manifest written for a ref,
# and fails when the test has not published that ref.
mkdir -p "$tmp/bin" "$tmp/registry"
cat >"$tmp/bin/oras" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
descriptor=false
ref=
for argument in "$@"; do
  case $argument in
    --descriptor) descriptor=true ;;
    manifest | fetch) ;;
    *) ref=$argument ;;
  esac
done
key=${ref//\//_}
key=${key//:/_}
if [[ $descriptor == true ]]; then
  file="${ORAS_FIXTURES}/${key}.descriptor"
else
  file="${ORAS_FIXTURES}/${key}.manifest"
fi
if [[ ! -f $file ]]; then
  echo "oras: ${ref}: not found" >&2
  exit 1
fi
cat "$file"
EOF

# gh: records what it was asked, lists no pull request and "creates" one.
cat >"$tmp/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"${GH_LOG}"
case "$1 $2" in
  'pr list') echo '[]' ;;
  'pr create')
    while (($#)); do
      case $1 in
        --body-file) cp "$2" "${GH_BODY}"; shift 2 ;;
        *) shift ;;
      esac
    done
    echo 'https://example.invalid/pull/1'
    ;;
  *) ;;
esac
EOF

chmod +x "$tmp/bin/oras" "$tmp/bin/gh"
export ORAS_FIXTURES="$tmp/registry" GH_LOG="$tmp/gh.log" GH_BODY="$tmp/gh-body.md"
export PATH="$tmp/bin:$PATH"

# The pins of the release the fixture starts at, and of the next one.
release_tag=v0.1.9
release_commit=aa51045d53669bd2ed3b986be95f3cd9d0eda8b7
release_digest=sha256:9f29b278f0098e65c3202563d626ef933fb66d195ea16eb14dbb5e74dbbaa738
release_sha=1e362c7d8e9f6f3f2c39dbdf752a977161df243a20c0b2ce04f105ac5e03f350
release_container=sha256:965cd176f705aef246039c754ffd56884f71a1bf55ceb18a7d67248fe50cb264
next_tag=v0.1.10
next_commit=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
next_digest=sha256:3333333333333333333333333333333333333333333333333333333333333333
next_sha=4444444444444444444444444444444444444444444444444444444444444444
next_container=sha256:5555555555555555555555555555555555555555555555555555555555555555
container_ref=ghcr.io/toshicloud/toshi-images/ubuntu-24.04-container
export CONTAINER_REF="$container_ref"

publish() { # <tag> <digest> <sha> <container digest>
  local tag=$1 digest=$2 sha=$3 container=$4
  local key="ghcr.io_toshicloud_toshi-images_ubuntu-24.04_${tag}"
  local ckey="ghcr.io_toshicloud_toshi-images_ubuntu-24.04-container_${tag}"
  printf '{"mediaType":"application/vnd.oci.image.manifest.v1+json","digest":"%s","size":1}' "$digest" \
    >"$ORAS_FIXTURES/${key}.descriptor"
  printf '{"layers":[{"digest":"sha256:%s"}]}' "$sha" >"$ORAS_FIXTURES/${key}.manifest"
  printf '{"mediaType":"application/vnd.docker.distribution.manifest.v2+json","digest":"%s","size":1}' "$container" \
    >"$ORAS_FIXTURES/${ckey}.descriptor"
}
publish "$release_tag" "$release_digest" "$release_sha" "$release_container"
publish "$next_tag" "$next_digest" "$next_sha" "$next_container"

# The toshi.run checkout the pin lands in.
repo="$tmp/toshi.run"
git init -q -b main "$repo"
git -C "$repo" config user.name test
git -C "$repo" config user.email test@example.invalid
mkdir -p "$repo/deploy"
cat >"$repo/deploy/images.env" <<EOF
# The runner images this repository tests and deploys.
TOSHI_IMAGES_RELEASE=${release_tag}
TOSHI_IMAGES_COMMIT=${release_commit}
UBUNTU_24_04_REF=ghcr.io/toshicloud/toshi-images/ubuntu-24.04
UBUNTU_24_04_DIGEST=${release_digest}
UBUNTU_24_04_SHA256=${release_sha}
TOSHI_CONTAINER_IMAGE=${container_ref}@${release_container}
EOF
git -C "$repo" add -A
git -C "$repo" commit -q -m 'chore: fixture'
git init -q --bare "$tmp/toshi.run.git"
git -C "$repo" remote add origin "$tmp/toshi.run.git"
git -C "$repo" push -q origin main

commits() { git -C "$repo" rev-list --count HEAD; }
value() { sed -n "s/^$1=//p" "$repo/deploy/images.env"; }

run() {
  set +e
  output=$(GH_TOKEN=test RUNS="images 123, container 456" "$script" "$@" 2>&1)
  rc=$?
  set -e
}

# The release that is already pinned: nothing to do, and no pull request.
run "$release_tag" "$release_commit" "$repo"
expect 'already pinned: exit 0' 0 "$rc"
expect 'already pinned: says nothing to do' yes "$(grep -q 'nothing to do' <<<"$output" && echo yes || echo no)"
expect 'already pinned: no commit' 1 "$(commits)"
expect 'already pinned: no pull request' no "$([[ -f $GH_LOG ]] && echo yes || echo no)"

# The next release, as a dry run: the change is printed, nothing is written.
run "$next_tag" "$next_commit" "$repo" --dry-run
expect 'dry run: exit 0' 0 "$rc"
expect 'dry run: prints the new digest' yes "$(grep -q "$next_digest" <<<"$output" && echo yes || echo no)"
expect 'dry run: no commit' 1 "$(commits)"
expect 'dry run: images.env unchanged' "$release_tag" "$(value TOSHI_IMAGES_RELEASE)"

# The next release, for real: a commit on its branch and the pull request.
run "$next_tag" "$next_commit" "$repo"
expect 'pin: exit 0' 0 "$rc"
expect 'pin: images.env carries the release' "$next_tag" "$(value TOSHI_IMAGES_RELEASE)"
expect 'pin: images.env carries the commit' "$next_commit" "$(value TOSHI_IMAGES_COMMIT)"
expect 'pin: images.env carries the manifest digest' "$next_digest" "$(value UBUNTU_24_04_DIGEST)"
expect 'pin: images.env carries the qcow2 sha256' "$next_sha" "$(value UBUNTU_24_04_SHA256)"
expect 'pin: images.env carries the container digest' "${container_ref}@${next_container}" "$(value TOSHI_CONTAINER_IMAGE)"
expect 'pin: the branch is pushed' yes "$(git --git-dir="$tmp/toshi.run.git" rev-parse -q --verify refs/heads/images/pin-${next_tag} >/dev/null && echo yes || echo no)"
expect 'pin: the pull request title' yes "$(grep -q "pr create .*--title chore(images): pin toshi-images ${next_tag}" "$GH_LOG" && echo yes || echo no)"
expect 'pin: the body names both digests' yes "$(grep -q "$next_digest" "$GH_BODY" && grep -q "$next_container" "$GH_BODY" && echo yes || echo no)"
expect 'pin: the body names the runs' yes "$(grep -q 'images 123, container 456' "$GH_BODY" && echo yes || echo no)"

# A release whose container is not published yet: wait, do not fail.
rm -f "$ORAS_FIXTURES"/ghcr.io_toshicloud_toshi-images_ubuntu-24.04-container_"${release_tag}".descriptor
run "$release_tag" "$release_commit" "$repo"
expect 'not published: exit 3' 3 "$rc"

if ((failed)); then
  echo "pin-images-env_test: ${failed} failed"
  exit 1
fi
echo "pin-images-env_test: ok"
