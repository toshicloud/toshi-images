#!/usr/bin/env bash
# Runs scripts/check-guest-protocol.sh against a fake registry and a fixture
# codec.go: overlapping ranges pass and print all four numbers, ranges that do
# not overlap fail naming them, an unreadable constant or a manifest without a
# range fails plainly, and an image with no manifest yet exits 3.

set -euo pipefail

scripts=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
script="$scripts/check-guest-protocol.sh"

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
has() { grep -q -- "$1" <<<"$output" && echo yes || echo no; }

# The registry: discover lists one referrer unless the test removes it, and
# pull writes the manifest the test prepared.
mkdir -p "$tmp/bin"
cat >"$tmp/bin/oras" <<'EOS'
#!/usr/bin/env bash
set -euo pipefail
case $1 in
  discover)
    if [[ -f $ORAS_MISSING ]]; then
      echo 'Error: 404 MANIFEST_UNKNOWN' >&2
      exit 1
    fi
    if [[ -f $ORAS_EMPTY ]]; then
      echo '{"referrers":[]}'
    else
      echo '{"referrers":[{"digest":"sha256:1111111111111111111111111111111111111111111111111111111111111111"}]}'
    fi
    ;;
  pull)
    out=
    while (($#)); do
      case $1 in
        -o) out=$2; shift 2 ;;
        *) shift ;;
      esac
    done
    mkdir -p "$out"
    cp "$ORAS_MANIFEST" "$out/manifest.json"
    ;;
esac
EOS
chmod +x "$tmp/bin/oras"
export PATH="$tmp/bin:$PATH" ORAS_MANIFEST="$tmp/manifest.json" ORAS_MISSING="$tmp/missing" ORAS_EMPTY="$tmp/empty"

core="$tmp/toshi.run"
mkdir -p "$core/internal/guestproto"
codec() { # <min line> <max line>
  printf 'package guestproto\n\n// MinProtocolVersion is the oldest version.\n%s\n\n// ProtocolVersion is the newest.\n%s\n' "$1" "$2" \
    >"$core/internal/guestproto/codec.go"
}
manifest() { # <jq object for guest>
  printf '{"image":"ubuntu-24.04","guest":%s}\n' "$1" >"$ORAS_MANIFEST"
}
ref=ghcr.io/toshicloud/toshi-images/ubuntu-24.04:v0.1.22
run() {
  set +e
  output=$("$script" "$core" "$ref" 2>&1)
  rc=$?
  set -e
}

codec 'const MinProtocolVersion = 1' 'const ProtocolVersion = 4'

manifest '{"protocol_min":1,"protocol_max":4}'
run
expect 'same range: exit 0' 0 "$rc"
expect 'same range: one line with the four numbers' yes "$([[ $(wc -l <<<"$output") -eq 1 ]] && grep -q 'speaks 1..4; the core speaks 1..4' <<<"$output" && echo yes || echo no)"
expect 'same range: names the image' yes "$(has 'ubuntu-24.04')"

manifest '{"protocol_min":3,"protocol_max":9}'
run
expect 'image newer, overlapping: exit 0' 0 "$rc"

manifest '{"protocol_min":0,"protocol_max":0}'
codec 'const MinProtocolVersion = 2' 'const ProtocolVersion = 4'
run
expect 'image max below the core minimum: exit 1' 1 "$rc"
expect 'image max below the core minimum: names the numbers' yes "$(has 'speaks 0..0; the core speaks 2..4')"
expect 'image max below the core minimum: says which side' yes "$(has 'below the core')"

manifest '{"protocol_min":5,"protocol_max":6}'
run
expect 'image min above the core version: exit 1' 1 "$rc"
expect 'image min above the core version: names the numbers' yes "$(has 'speaks 5..6; the core speaks 2..4')"
expect 'image min above the core version: says which side' yes "$(has 'above the core')"

codec 'const MinProtocolVersion = 1' 'const ProtocolVersion = four'
manifest '{"protocol_min":1,"protocol_max":4}'
run
expect 'core constant not an integer: exit 1' 1 "$rc"
expect 'core constant not an integer: names it' yes "$(has 'const ProtocolVersion')"

codec 'const MinProtocolVersion = 1' ''
run
expect 'core constant missing: exit 1' 1 "$rc"
expect 'core constant missing: names it' yes "$(has 'const ProtocolVersion')"

codec 'const MinProtocolVersion = 1' 'const ProtocolVersion = 4'
manifest '{"protocol_min":null,"protocol_max":null}'
run
expect 'image without a range: exit 1' 1 "$rc"
expect 'image without a range: says so' yes "$(has 'records no guest protocol range')"

: >"$ORAS_EMPTY"
run
expect 'no referrer yet: exit 3' 3 "$rc"
rm -f "$ORAS_EMPTY"
: >"$ORAS_MISSING"
run
expect 'image not in the registry: exit 3' 3 "$rc"
rm -f "$ORAS_MISSING"

rm -f "$core/internal/guestproto/codec.go"
run
expect 'no codec.go: exit 1' 1 "$rc"

if ((failed)); then
  echo "check-guest-protocol_test: ${failed} failed"
  exit 1
fi
echo "check-guest-protocol_test: ok"
