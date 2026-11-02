#!/usr/bin/env bash
# linux-pool-host/manifest-inputs.sh turns the pins the pool host installs into
# the guest.env and toolset lines image-manifest.sh assemble reads, and that
# assemble puts them in the manifest's guest and toolsets fields.
set -euo pipefail
here=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL $*" >&2; exit 1; }

"$here/linux-pool-host/manifest-inputs.sh" "$here/linux-pool-host/versions.env" "$tmp"
echo '{"packages":[],"users":[],"services":[],"listening":[],"firewall":"none"}' >"$tmp/fragment.json"
"$here/scripts/image-manifest.sh" assemble --image linux-pool-host --fragment "$tmp/fragment.json" --out "$tmp/m.json" \
  --base 'Canonical:ubuntu-24_04-lts:server' --base-id x --guest-env "$tmp/guest.env" --toolsets "$tmp/toolsets.txt"

# shellcheck disable=SC1091
want=$(. "$here/linux-pool-host/versions.env" && echo "$GUEST_VERSION,$GUEST_DIGEST,$TOSHI_AGENT_VERSION,$PASST_VERSION,$ORAS_VERSION")
got=$(jq -r '[.guest.version, .guest.digest, (.toolsets[] | select(.name == "toshi-host") | .version), (.toolsets[] | select(.name == "passt") | .version), (.toolsets[] | select(.name == "oras") | .version)] | join(",")' "$tmp/m.json")
[[ $got == "$want" ]] || fail "pool host manifest fields: got $got, want $want"
echo "pool_host_manifest_inputs_test: ok"
