#!/usr/bin/env bash
# Runs scripts/pin-guest-release.sh in a throwaway clone of this repository's
# layout: a guest.env, two release tags and a bare origin. It pins a helper,
# tags the next release, does nothing twice, and refuses a version that is
# already pinned elsewhere.

set -euo pipefail

scripts=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
script="$scripts/pin-guest-release.sh"

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

version=v0.1.0-rc.3-843-g40e6dac1f
digest=sha256:ef638e69e3ba81e1fe34855b81d877df60917b5a312a5cf52f933fc5e3c713f1
other_digest=sha256:1111111111111111111111111111111111111111111111111111111111111111

git init -q --bare "$tmp/origin.git"
git init -q -b main "$tmp/repo"
cd "$tmp/repo"
git config user.name test
git config user.email test@example.invalid
mkdir -p scripts
cp "$script" scripts/pin-guest-release.sh
cat >guest.env <<'EOF'
# The guest helper the VM images carry.
TOSHI_GUEST_REF=ghcr.io/toshicloud/toshi-guest
TOSHI_GUEST_VERSION=e8d651ef2
TOSHI_GUEST_DIGEST=sha256:2222222222222222222222222222222222222222222222222222222222222222
EOF
git add .
git commit -q -m 'chore: fixture'
git tag -a v0.1.8 -m v0.1.8
git tag -a v0.1.9 -m v0.1.9
git remote add origin "$tmp/origin.git"
git push -q origin main --tags

commits() { git rev-list --count HEAD; }
tags() { git tag --list 'v*' | wc -l; }
pinned() { sed -n 's/^TOSHI_GUEST_VERSION=//p' guest.env; }

run() {
  set +e
  output=$(scripts/pin-guest-release.sh "$@" 2>&1)
  rc=$?
  set -e
}

before_commits=$(commits)
before_tags=$(tags)

# A dry run says what it would pin, and writes nothing.
run "$version" "$digest" --dry-run
expect 'dry run: exit 0' 0 "$rc"
expect 'dry run: names the next tag' yes "$(grep -q 'v0.1.10' <<<"$output" && echo yes || echo no)"
expect 'dry run: no commit' "$before_commits" "$(commits)"
expect 'dry run: no tag' "$before_tags" "$(tags)"
expect 'dry run: guest.env unchanged' e8d651ef2 "$(pinned)"

# The pin: a commit on main and the next tag, both pushed.
run "$version" "$digest"
expect 'pin: exit 0' 0 "$rc"
expect 'pin: one commit' "$((before_commits + 1))" "$(commits)"
expect 'pin: guest.env carries the version' "$version" "$(pinned)"
expect 'pin: guest.env carries the digest' "$digest" "$(sed -n 's/^TOSHI_GUEST_DIGEST=//p' guest.env)"
expect 'pin: one new tag' "$((before_tags + 1))" "$(tags)"
expect 'pin: the next tag exists' yes "$(git rev-parse -q --verify refs/tags/v0.1.10 >/dev/null && echo yes || echo no)"
expect 'pin: the tag is on origin' yes "$(git --git-dir="$tmp/origin.git" rev-parse -q --verify refs/tags/v0.1.10 >/dev/null && echo yes || echo no)"
expect 'pin: main is on origin' yes "$(git --git-dir="$tmp/origin.git" rev-parse -q --verify refs/heads/main >/dev/null && echo yes || echo no)"
expect 'pin: the commit subject' 'chore(guest): pin v0.1.0-rc.3-843-g40e6dac1f' "$(git log -1 --format=%s)"

# The same dispatch again: no commit, no tag.
before_commits=$(commits)
before_tags=$(tags)
run "$version" "$digest"
expect 'repeat: exit 0' 0 "$rc"
expect 'repeat: says nothing to do' yes "$(grep -q 'nothing to do' <<<"$output" && echo yes || echo no)"
expect 'repeat: no commit' "$before_commits" "$(commits)"
expect 'repeat: no tag' "$before_tags" "$(tags)"

# A version pinned at another digest is a contradiction, not a pin.
run "$version" "$other_digest"
expect 'other digest: exit 1' 1 "$rc"

# A malformed digest is refused before anything is read or written.
run "$version" not-a-digest
expect 'bad digest: exit 2' 2 "$rc"

if ((failed)); then
  echo "pin-guest-release_test: ${failed} failed"
  exit 1
fi
echo "pin-guest-release_test: ok"
