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
# The guest binary's own range: integers when it prints one, null when it
# prints the version alone, null with a warning when it cannot run, and a
# failed assemble when its version is not the pinned one.
stub() {
  printf '#!/usr/bin/env bash\necho "%s"\n' "$2" >"$tmp/$1"
  chmod +x "$tmp/$1"
}
guest_manifest() {
  "$script" assemble --image sample --fragment "$tmp/fragment.json" --out "$tmp/guest-$1.json" \
    --guest-env "$tmp/guest.env" --guest-binary "$2" 2>"$tmp/guest-$1.err"
}
stub guest-new 'toshi-guest v1 protocol_min=1 protocol_max=6'
guest_manifest new "$tmp/guest-new"
expect 'guest range is read as integers' 'number,number,1,6' \
  "$(jq -r '.guest | [(.protocol_min|type),(.protocol_max|type),.protocol_min,.protocol_max] | map(tostring) | join(",")' "$tmp/guest-new.json")"
expect 'guest range keeps the pinned version and digest' 'v1,sha256:guest' \
  "$(jq -r '.guest | [.version,.digest] | join(",")' "$tmp/guest-new.json")"
stub guest-old 'toshi-guest v1'
guest_manifest old "$tmp/guest-old"
expect 'an older guest leaves the range null' 'null,null' \
  "$(jq -r '.guest | [.protocol_min,.protocol_max] | map(tostring) | join(",")' "$tmp/guest-old.json")"
guest_manifest missing "$tmp/no-such-guest"
expect 'a guest that cannot run leaves the range null' 'null,null' \
  "$(jq -r '.guest | [.protocol_min,.protocol_max] | map(tostring) | join(",")' "$tmp/guest-missing.json")"
expect 'a guest that cannot run gives one warning line' 1 "$(grep -c 'warning' "$tmp/guest-missing.err")"
stub guest-other 'toshi-guest v2 protocol_min=1 protocol_max=6'
if guest_manifest other "$tmp/guest-other"; then result=success; else result=failed; fi
expect 'a guest of another version fails assembly' failed "$result"
expect 'a guest of another version leaves no manifest' no "$([[ -e $tmp/guest-other.json ]] && echo yes || echo no)"
expect 'base without an id has no id field' null "$(jq -c '.base.id // null' "$tmp/manifest.json")"
"$script" assemble --image sample --fragment "$tmp/fragment.json" --out "$tmp/cloud.json" \
  --base 'Canonical:ubuntu-24_04-lts:server' --base-id 24.04.202609260 --guest-env "$tmp/guest.env"
expect 'cloud base keeps its name and id, no digest' 'Canonical:ubuntu-24_04-lts:server,24.04.202609260,null' \
  "$(jq -r '[.base.name,.base.id,.base.digest] | map(tostring) | join(",")' "$tmp/cloud.json")"
expect 'toolset versions' 'node:24.1,go:1.2' "$(jq -r '[.toolsets[] | .name + ":" + .version] | join(",")' "$tmp/manifest.json")"
digest=$("$script" digest "$tmp/manifest.json")
expect 'digest is stable' "$digest" "$("$script" digest "$tmp/manifest.json")"
expect 'digest is sha256' 64 "${#digest}"
jq '.built={date:"later",commit:"other"} | .image_digest="other"' "$tmp/manifest.json" >"$tmp/changed.json"
expect 'digest ignores build and image digest' "$digest" "$("$script" digest "$tmp/changed.json")"
for field in package package-version pin toolset; do
  case $field in
    package) filter='.packages[0].name="changed"' ;;
    package-version) filter='.packages[0].version="changed"' ;;
    pin) filter='.pins[0].value="changed"' ;;
    toolset) filter='.toolsets[0].version="changed"' ;;
  esac
  jq "$filter" "$tmp/manifest.json" >"$tmp/changed.json"
  expect "digest changes with $field" different "$([[ $digest != "$("$script" digest "$tmp/changed.json")" ]] && echo different || echo same)"
done
original_pins=$("$script" pinset "$tmp/manifest.json")
jq '.pins[0].value="changed"' "$tmp/manifest.json" >"$tmp/changed.json"
expect 'pinset changes with a pin' different "$([[ $original_pins != "$("$script" pinset "$tmp/changed.json")" ]] && echo different || echo same)"

# Exercise the smoke scripts' real manifest assembly without building images.
# Docker returns a fixed collector fragment; only guest.env changes between runs.
fixture="$tmp/smoke"
mkdir -p "$fixture/bin"
for input in scripts/image-manifest.sh service-agent/smoke-test.sh service-agent/versions.env \
  ubuntu-24.04-container/smoke-test.sh ubuntu-24.04-container/versions.env ubuntu-24.04-container/Dockerfile \
  ubuntu-24.04/versions.env toolsets/lib.sh toolsets/versions.env railpack.env; do
  mkdir -p "$fixture/$(dirname "$input")"
  cp "$scripts/../$input" "$fixture/$input"
done
printf 'gitdir: %s\n' "$(git -C "$scripts" rev-parse --absolute-git-dir)" >"$fixture/.git"
cat >"$fixture/bin/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case $1 in
  run) cat "$SMOKE_MANIFEST_FRAGMENT" ;;
  image) [[ ${2:-} == inspect ]]; echo sha256:fixture ;;
  volume) [[ ${2:-} == create || ${2:-} == rm ]] ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$fixture/bin/docker"
for image in service-agent ubuntu-24.04-container; do
  previous_pins=''
  for guest in 'v1 sha256:one' 'v2 sha256:one' 'v2 sha256:two'; do
    read -r version guest_digest <<<"$guest"
    printf 'TOSHI_GUEST_VERSION=%s\nTOSHI_GUEST_DIGEST=%s\n' "$version" "$guest_digest" >"$fixture/guest.env"
    manifest="$tmp/$image-$version-${guest_digest#sha256:}.json"
    SMOKE_MANIFEST_FRAGMENT="$tmp/fragment.json" PATH="$fixture/bin:$PATH" \
      "$fixture/$image/smoke-test.sh" fixture "$manifest" >/dev/null
    expect "$image guest metadata $guest" "$version,$guest_digest" \
      "$(jq -r '[.guest.version,.guest.digest] | join(",")' "$manifest")"
    current_pins=$("$script" pinset "$manifest")
    if [[ -n $previous_pins ]]; then
      expect "$image pinset changes with guest $guest" different \
        "$([[ $previous_pins != "$current_pins" ]] && echo different || echo same)"
    fi
    previous_pins=$current_pins
  done
done

# Keep systemctl, ss and nft out of PATH, while providing the required tools.
mkdir "$tmp/collect-bin"
for tool in bash jq awk grep mktemp rm; do ln -s "$(command -v "$tool")" "$tmp/collect-bin/$tool"; done
cat >"$tmp/collect-bin/dpkg-query" <<'EOF'
#!/usr/bin/env bash
printf 'ii \talpha\t1\nhi \theld\t3\nrc \tremoved\t2\n'
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
expect 'collect keeps held packages and excludes removed ones' 'alpha,held' "$(jq -r '[.packages[].name] | join(",")' "$tmp/collected.json")"
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
