#!/usr/bin/env bash
# Runs scripts/pin-guest-release.sh in a throwaway clone of this repository's
# layout: a guest.env, two release tags and a bare origin, with a stub gh. It
# pins a helper in a pull request without touching main, updates the open
# pull request, does nothing twice, refuses a version that is already pinned
# elsewhere, and tags the next release only on a merged guest pin.

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
expect 'dry run: says it would open the pull request' yes "$(grep -q 'pull request' <<<"$output" && echo yes || echo no)"
expect 'dry run: no commit' "$before_commits" "$(commits)"
expect 'dry run: no tag' "$before_tags" "$(tags)"
expect 'dry run: guest.env unchanged' e8d651ef2 "$(pinned)"

# A stub gh, so the pin needs no network: it records its calls, and answers
# the list of open pull requests from $tmp/open.
mkdir -p "$tmp/bin"
cat >"$tmp/bin/gh" <<'EOF'
#!/usr/bin/env bash
echo "$*" >>"$GH_LOG"
if [[ $1 == pr && $2 == list ]]; then
  cat "$GH_OPEN" 2>/dev/null || true
fi
EOF
chmod +x "$tmp/bin/gh"
export PATH="$tmp/bin:$PATH" GH_LOG="$tmp/gh.log" GH_OPEN="$tmp/open" GH_TOKEN=x GITHUB_REPOSITORY=owner/repo
: >"$GH_LOG"
branch_on_origin() { git --git-dir="$tmp/origin.git" rev-parse -q --verify refs/heads/guest/pin >/dev/null && echo yes || echo no; }
origin_env() { git --git-dir="$tmp/origin.git" show "guest/pin:guest.env" | sed -n 's/^TOSHI_GUEST_VERSION=//p'; }

# The pin: a branch on origin and a pull request, no push to main, no tag.
main_before=$(git --git-dir="$tmp/origin.git" rev-parse refs/heads/main)
run "$version" "$digest"
expect 'pin: exit 0' 0 "$rc"
expect 'pin: guest/pin is on origin' yes "$(branch_on_origin)"
expect 'pin: the branch carries the version' "$version" "$(origin_env)"
expect 'pin: the branch carries the digest' "$digest" "$(git --git-dir="$tmp/origin.git" show guest/pin:guest.env | sed -n 's/^TOSHI_GUEST_DIGEST=//p')"
expect 'pin: the commit subject' "chore(guest): pin ${version}" "$(git --git-dir="$tmp/origin.git" log -1 --format=%s guest/pin)"
expect 'pin: main on origin untouched' "$main_before" "$(git --git-dir="$tmp/origin.git" rev-parse refs/heads/main)"
expect 'pin: no tag' "$before_tags" "$(tags)"
expect 'pin: a pull request is created against main' yes "$(grep -q 'pr create .*--base main --head guest/pin' "$GH_LOG" && echo yes || echo no)"
expect 'pin: the checkout is unchanged' e8d651ef2 "$(pinned)"
expect 'pin: the checkout has no leftover worktree' 1 "$(git worktree list | wc -l)"

# The same dispatch with the pull request open: nothing is pushed or edited.
: >"$GH_LOG"
echo "7 chore(guest): pin ${version}" >"$GH_OPEN"
run "$version" "$digest"
expect 'repeat: exit 0' 0 "$rc"
expect 'repeat: says nothing to do' yes "$(grep -q 'nothing to do' <<<"$output" && echo yes || echo no)"
expect 'repeat: no create or edit' 0 "$(grep -c 'pr create\|pr edit' "$GH_LOG" || true)"

# A newer version updates the open pull request.
: >"$GH_LOG"
newer=v0.1.0-rc.8
run "$newer" "$other_digest"
expect 'update: exit 0' 0 "$rc"
expect 'update: the open pull request is edited' yes "$(grep -q 'pr edit 7 ' "$GH_LOG" && echo yes || echo no)"
expect 'update: the branch carries the newer version' "$newer" "$(origin_env)"
: >"$GH_OPEN"

# A version pinned at another digest on main is a contradiction.
run e8d651ef2 "$other_digest"
expect 'other digest: exit 1' 1 "$rc"

# A malformed digest is refused before anything is read or written.
run "$version" not-a-digest
expect 'bad digest: exit 2' 2 "$rc"

# The tag after the merge: land the pin on main the way the queue does.
git fetch -q origin guest/pin
git merge -q --ff-only FETCH_HEAD
git push -q origin main

before_tags=$(tags)
run --tag --dry-run
expect 'tag dry run: names the next tag' yes "$(grep -q 'would tag v0.1.10' <<<"$output" && echo yes || echo no)"
expect 'tag dry run: no tag' "$before_tags" "$(tags)"

run --tag
expect 'tag: exit 0' 0 "$rc"
expect 'tag: one new tag' "$((before_tags + 1))" "$(tags)"
expect 'tag: names the pin commit' "$(git rev-parse HEAD)" "$(git rev-parse 'v0.1.10^{commit}')"
expect 'tag: the tag is on origin' yes "$(git --git-dir="$tmp/origin.git" rev-parse -q --verify refs/tags/v0.1.10 >/dev/null && echo yes || echo no)"

# Again, and after an unrelated commit: the pin already has its tag.
git commit -q --allow-empty -m 'chore: unrelated'
before_tags=$(tags)
run --tag
expect 'tag repeat: exit 0' 0 "$rc"
expect 'tag repeat: no tag' "$before_tags" "$(tags)"

# A guest.env change that is not a guest pin gets no tag.
sed -i 's|^TOSHI_GUEST_VERSION=.*|TOSHI_GUEST_VERSION=by-hand|' guest.env
git commit -q -am 'chore: edit by hand'
run --tag
expect 'tag by hand: exit 0' 0 "$rc"
expect 'tag by hand: no tag' "$before_tags" "$(tags)"

if ((failed)); then
  echo "pin-guest-release_test: ${failed} failed"
  exit 1
fi
echo "pin-guest-release_test: ok"
