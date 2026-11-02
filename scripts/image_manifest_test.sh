#!/usr/bin/env bash
# Exercise assembly, canonical hashing, collection without optional tools, and attestation.
set -euo pipefail

scripts=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
script="$scripts/image-manifest.sh"
attest="$scripts/../attest-sbom.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
failed=0
expect() {
  local name=$1 want=$2 got=$3
  if [[ $want == "$got" ]]; then echo "ok $name"; else echo "FAIL $name: want '$want', got '$got'"; failed=$((failed + 1)); fi
}

cat >"$tmp/fragment.json" <<'EOF'
{"packages":[{"name":"alpha","version":"1"},{"name":"beta","version":"2"}],"users":[],"services":[],"listening":[],"firewall":"none"}
EOF
cat >"$tmp/first.env" <<'EOF'
VERSION=1
URL="https://example.invalid/${VERSION}"
key=kept-key
pin_file=kept-file
EOF
cat >"$tmp/second.env" <<'EOF'
VERSION=2
OTHER="${URL}/${VERSION}"
EOF
cat >"$tmp/guest.env" <<'EOF'
TOSHI_GUEST_VERSION=v1
TOSHI_GUEST_DIGEST=sha256:guest
EOF
printf '%s\n' 'TOOLSET node 24.1' 'TOOLSET go 1.2 seed' >"$tmp/tools"
"$script" assemble --image sample --fragment "$tmp/fragment.json" --out "$tmp/manifest.json" \
  --base ubuntu@sha256:abcd --pins "$tmp/first.env" "$tmp/second.env" --toolsets "$tmp/tools" \
  --guest-env "$tmp/guest.env" --image-digest sha256:image

expect 'resolved pin values reflect each file in order' '1,https://example.invalid/1,kept-key,kept-file,2,https://example.invalid/1/2' \
  "$(jq -r '[.pins[].value] | join(",")' "$tmp/manifest.json")"
expect 'resolved pins keep file provenance' "$tmp/first.env,$tmp/first.env,$tmp/first.env,$tmp/first.env,$tmp/second.env,$tmp/second.env" \
  "$(jq -r '[.pins[].file] | join(",")' "$tmp/manifest.json")"
if "$script" assemble --image sample --fragment "$tmp/fragment.json" --out "$tmp/incomplete.json" \
  --pins "$tmp/first.env" "$tmp/missing.env" >"$tmp/assembly-error" 2>&1; then
  result=success
else
  result=failed
fi
expect 'missing later pin file fails assembly' failed "$result"
expect 'missing later pin file leaves no partial manifest' no "$([[ -e $tmp/incomplete.json ]] && echo yes || echo no)"
expect 'base and guest fields' 'ubuntu,sha256:abcd,v1,sha256:guest,null,null' \
  "$(jq -r '[.base.name,.base.digest,.guest.version,.guest.digest,.guest.protocol_min,.guest.protocol_max] | map(tostring) | join(",")' "$tmp/manifest.json")"
expect 'toolset versions' 'node:24.1,go:1.2' "$(jq -r '[.toolsets[] | .name + ":" + .version] | join(",")' "$tmp/manifest.json")"
digest=$("$script" digest "$tmp/manifest.json")
expect 'digest is stable' "$digest" "$("$script" digest "$tmp/manifest.json")"
expect 'digest is sha256' 64 "${#digest}"
jq '.built={date:"later",commit:"other"} | .image_digest="other" | .packages[].version="new"' "$tmp/manifest.json" >"$tmp/changed.json"
expect 'digest ignores build, image and apt versions' "$digest" "$("$script" digest "$tmp/changed.json")"
for field in package pin toolset; do
  case $field in
    package) filter='.packages[0].name="changed"' ;;
    pin) filter='.pins[0].value="changed"' ;;
    toolset) filter='.toolsets[0].version="changed"' ;;
  esac
  jq "$filter" "$tmp/manifest.json" >"$tmp/changed.json"
  expect "digest changes with $field" different "$([[ $digest != "$("$script" digest "$tmp/changed.json")" ]] && echo different || echo same)"
done
original_pins=$("$script" pinset "$tmp/manifest.json")
jq '.pins[0].value="changed"' "$tmp/manifest.json" >"$tmp/changed.json"
expect 'pinset changes with a pin' different "$([[ $original_pins != "$("$script" pinset "$tmp/changed.json")" ]] && echo different || echo same)"

# Keep systemctl, ss and nft out of PATH, while providing the required tools.
mkdir "$tmp/collect-bin"
for tool in bash jq awk grep mktemp rm; do ln -s "$(command -v "$tool")" "$tmp/collect-bin/$tool"; done
cat >"$tmp/collect-bin/dpkg-query" <<'EOF'
#!/usr/bin/env bash
printf 'ii \talpha\t1\nrc \tremoved\t2\n'
EOF
cat >"$tmp/collect-bin/getent" <<'EOF'
#!/usr/bin/env bash
case $1 in
  passwd) printf 'root:x:0:0:root:/root:/bin/bash\nrunner:x:1001:1001::/home/runner:/bin/bash\ndaemon:x:1:1::/nonexistent:/usr/sbin/nologin\nsystemlogin:x:42:42::/home/system:/bin/bash\n' ;;
  *) exit 1 ;;
esac
EOF
cat >"$tmp/collect-bin/id" <<'EOF'
#!/usr/bin/env bash
case $2 in root) echo root ;; runner) echo 'runner docker' ;; systemlogin) echo systemlogin ;; esac
EOF
chmod +x "$tmp/collect-bin/"{dpkg-query,getent,id}
PATH="$tmp/collect-bin" "$script" collect >"$tmp/collected.json"
expect 'absent optional tools degrade' '[],[],none' \
  "$(jq -r '[.services,.listening,.firewall] | map(if type == "string" then . else tojson end) | join(",")' "$tmp/collected.json")"
expect 'collect users and packages' 'root,runner,systemlogin;alpha' \
  "$(jq -r '[.users[].name] | join(",")' "$tmp/collected.json");$(jq -r '.packages[0].name' "$tmp/collected.json")"
expect 'collect excludes removed packages' 1 "$(jq '.packages | length' "$tmp/collected.json")"
cat >"$tmp/collect-bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf 'example.service enabled enabled\nignored.service disabled disabled\n'
EOF
cat >"$tmp/collect-bin/ss" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'LISTEN 0 128 127.0.0.1:22 0.0.0.0:* users:(("sshd",pid=1,fd=3))' 'LISTEN 0 128 [::]:8080 [::]:* users:(("server",pid=2,fd=3))'
EOF
chmod +x "$tmp/collect-bin/systemctl" "$tmp/collect-bin/ss"
PATH="$tmp/collect-bin" "$script" collect >"$tmp/collected.json"
expect 'collects enabled services' 'example.service' "$(jq -r '[.services[].name] | join(",")' "$tmp/collected.json")"
expect 'collects listening ports and processes' '22:sshd,8080:server' \
  "$(jq -r '[.listening[] | (.port | tostring) + ":" + .process] | join(",")' "$tmp/collected.json")"

# Check the supplied manifest uses the same signing and verification flags.
mkdir "$tmp/bin"
cat >"$tmp/bin/cosign" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$COSIGN_LOG"
if [[ $1 == attest ]]; then
  while (($#)); do
    if [[ $1 == --bundle ]]; then printf '{"verificationMaterial":{"tlogEntries":[]}}\n' >"$2"; break; fi
    shift
  done
fi
EOF
chmod +x "$tmp/bin/cosign"
export COSIGN_LOG="$tmp/cosign.log"
PATH="$tmp/bin:$PATH" "$attest" manifest 127.0.0.1:5000/image@sha256:abc "$tmp/manifest.json" identity config "$tmp/bundle" >/dev/null
expect 'manifest attest type and flags' yes "$(grep -q 'attest --yes --allow-http-registry --signing-config config --type https://toshicloud.io/image-manifest/v1 --predicate ' "$COSIGN_LOG" && echo yes || echo no)"
expect 'manifest verify type and flags' yes "$(grep -q 'verify-attestation --timeout 90s --allow-http-registry --check-claims=true --type https://toshicloud.io/image-manifest/v1 ' "$COSIGN_LOG" && echo yes || echo no)"
PATH="$tmp/bin:$PATH" "$attest" predicate registry.invalid/image@sha256:abc "$tmp/fragment.json" identity config "$tmp/bundle" >/dev/null
expect 'SPDX predicate still uses its type' yes "$(grep -q 'attest --yes --signing-config config --type spdxjson --predicate ' "$COSIGN_LOG" && echo yes || echo no)"
expect 'SPDX verification still uses its type' yes "$(grep -q 'verify-attestation --timeout 90s --check-claims=true --type spdxjson ' "$COSIGN_LOG" && echo yes || echo no)"

if ((failed)); then echo "image_manifest_test: $failed failed"; exit 1; fi
echo 'image_manifest_test: ok'
