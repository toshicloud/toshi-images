#!/usr/bin/env bash
# The identity each publishing workflow verifies its signature against must
# accept the workflow's own file at a release tag under both repository names,
# and nothing else: not another repository, not a branch, not another workflow.
set -euo pipefail
cd "$(dirname "$0")/.."
failed=0
fail() { echo "FAIL $*" >&2; failed=1; }

for workflow in container images service-agent; do
  file=.github/workflows/${workflow}.yml
  # The pin the sign-and-verify step of the workflow hands to cosign.
  pin=$(sed -n "s/^ *identity='\(.*\)'$/\1/p" "$file")
  [[ $(printf '%s\n' "$pin" | grep -c .) == 1 ]] || { fail "$file: want one identity pin, got: $pin"; continue; }
  for repository in toshicloud/toshi-images toshicloud/cloud-images; do
    uri="https://github.com/${repository}/.github/workflows/${workflow}.yml@refs/tags/v0.1.23"
    printf '%s\n' "$uri" | grep -Eq "$pin" || fail "$file: pin rejects $uri"
  done
  for uri in \
    "https://github.com/toshicloud/other/.github/workflows/${workflow}.yml@refs/tags/v0.1.23" \
    "https://github.com/toshicloud/toshi-images/.github/workflows/${workflow}.yml@refs/heads/main" \
    "https://github.com/toshicloud/cloud-images/.github/workflows/other.yml@refs/tags/v0.1.23" \
    "https://github.com/evil/toshicloud/toshi-images/.github/workflows/${workflow}.yml@refs/tags/v0.1.23" \
    "https://github.com/toshicloud/toshi-imagesX/.github/workflows/${workflow}.yml@refs/tags/v0.1.23"; do
    ! printf '%s\n' "$uri" | grep -Eq "$pin" || fail "$file: pin accepts $uri"
  done
  # The provenance buildType follows the repository that ran the build.
  ! grep -q 'buildType: "https://github.com/toshicloud' "$file" || fail "$file: buildType names a repository literally"
done
# The documented verify expression accepts both names too.
doc=$(sed -n "s/.*--certificate-identity-regexp '\(.*\)' .*/\1/p" docs/published-images.md | head -n 1)
for repository in toshicloud/toshi-images toshicloud/cloud-images; do
  printf '%s\n' "https://github.com/${repository}/.github/workflows/images.yml@refs/tags/v0.1.23" | grep -Eq "$doc" ||
    fail "docs/published-images.md: expression rejects ${repository}"
done

((failed == 0)) || exit 1
echo "signing_identity_test: ok"
