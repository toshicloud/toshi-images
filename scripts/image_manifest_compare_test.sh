#!/usr/bin/env bash
# Compare manifests through a fake registry, including error paths.
set -euo pipefail

scripts=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
script="$scripts/image-manifest-compare.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
failed=0
expect() {
  local name=$1 want=$2 got=$3
  if [[ $want == "$got" ]]; then echo "ok $name"; else echo "FAIL $name: want '$want', got '$got'"; failed=$((failed + 1)); fi
}
mkdir "$tmp/bin"
cat >"$tmp/bin/oras" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$ORAS_LOG"
case $1 in
  repo)
    if [[ ${ORAS_FAIL:-} == tags ]]; then echo 'registry unavailable' >&2; exit 1; fi
    printf '%s\n' latest v1.2.0 v1.10.0 v1.9.0 ;;
  discover)
    case ${ORAS_FAIL:-} in
      missing) echo '404 MANIFEST_UNKNOWN' >&2; exit 1 ;;
      auth) echo '401 unauthorized' >&2; exit 1 ;;
      invalid) echo '{"broken":true}'; exit 0 ;;
    esac
    if [[ ${ORAS_EMPTY:-} == yes ]]; then echo '{"referrers":[]}'; else
      printf '{"referrers":[{"digest":"sha256:%064d"}]}\n' 1
    fi ;;
  pull)
    if [[ ${ORAS_FAIL:-} == pull ]]; then echo 'pull failed' >&2; exit 1; fi
    while (($#)); do
      if [[ $1 == -o ]]; then mkdir -p "$2"; cp "$ORAS_MANIFEST" "$2/manifest.json"; break; fi
      shift
    done ;;
  *) exit 1 ;;
esac
EOF
chmod +x "$tmp/bin/oras"
export PATH="$tmp/bin:$PATH" ORAS_LOG="$tmp/oras.log" ORAS_MANIFEST="$tmp/published.json"
cat >"$tmp/published.json" <<'EOF'
{"image":"sample","built":{"date":"old"},"image_digest":"old","packages":[{"name":"alpha","version":"1"}],"pins":[{"file":"pin.env","key":"V","value":"1"}],"toolsets":[]}
EOF
jq '.built.date="new" | .image_digest="new" | .packages[0].version="2"' "$tmp/published.json" >"$tmp/new.json"
run() {
  rc=0
  output=$("$script" "$tmp/new.json" "$@" 2>&1) || rc=$?
}
export ORAS_EMPTY=yes
run registry.invalid/image:current
expect 'no referrers succeeds' 0 "$rc"
expect 'no referrers gives notice' yes "$(grep -q 'no published manifest' <<<"$output" && echo yes || echo no)"
unset ORAS_EMPTY
export ORAS_FAIL=missing
run registry.invalid/image:current
expect 'missing subject succeeds' 0 "$rc"
unset ORAS_FAIL
run registry.invalid/image:current
expect 'equal canonical manifests succeed' 0 "$rc"
expect 'equal manifests reported' yes "$(grep -q 'manifests match' <<<"$output" && echo yes || echo no)"
expect 'pull uses referrer digest' yes "$(grep -q 'pull .*registry.invalid/image@sha256:' "$ORAS_LOG" && echo yes || echo no)"
jq '.pins[0].value="2" | .packages[0].name="different"' "$tmp/new.json" >"$tmp/changed.json"
mv "$tmp/changed.json" "$tmp/new.json"
run registry.invalid/image:current
expect 'changed pins succeed' 0 "$rc"
expect 'changed pins reported' yes "$(grep -q 'pins changed' <<<"$output" && echo yes || echo no)"
jq '.pins[0].value="1"' "$tmp/new.json" >"$tmp/changed.json"
mv "$tmp/changed.json" "$tmp/new.json"
run registry.invalid/image:current
expect 'changed contents fail' 1 "$rc"
expect 'failure prints unified diff' yes "$(grep -q '^--- published' <<<"$output" && grep -q '^+++ new' <<<"$output" && grep -q '+.*different' <<<"$output" && echo yes || echo no)"
run --newest-tag registry.invalid/image
expect 'newest tag selected' yes "$(grep -q 'discover .*registry.invalid/image:v1.10.0' "$ORAS_LOG" && echo yes || echo no)"
run registry.invalid/image:latest-release
expect 'latest-release resolves newest tag' yes "$(grep -q 'discover .*registry.invalid/image:v1.10.0' "$ORAS_LOG" && echo yes || echo no)"
for failure in auth invalid pull tags; do
  export ORAS_FAIL=$failure
  if [[ $failure == tags ]]; then run --newest-tag registry.invalid/image; else run registry.invalid/image:current; fi
  expect "$failure is an error" yes "$([[ $rc != 0 ]] && echo yes || echo no)"
done
unset ORAS_FAIL
if ((failed)); then echo "image_manifest_compare_test: $failed failed"; exit 1; fi
echo 'image_manifest_compare_test: ok'
