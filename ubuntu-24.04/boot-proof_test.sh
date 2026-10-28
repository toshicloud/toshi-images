#!/usr/bin/env bash
set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
script=${1:-"${here}/boot-proof.sh"}
work=$(mktemp -d "${TMPDIR:-/tmp}/boot-proof-test.XXXXXX")
trap 'rm -rf -- "${work}"' EXIT
export SERIAL_LOG=${work}/serial.log

# Load the serial parsing helpers without booting an image.
eval "$(sed -n '/^done_marker() /p; /^proof() /p' "${script}")"
declare -F done_marker >/dev/null
declare -F proof >/dev/null

fail() { printf 'not ok - %s\n' "$*" >&2; exit 1; }
expect_proof() {
  local value
  value=$(proof "$1") || fail "missing $1 marker"
  [[ ${value} == "$2" ]] || fail "$1: expected '$2', got '${value}'"
}
expect_complete_proof() {
  done_marker || fail 'missing completion marker'
  expect_proof service active
  expect_proof version test-version
  expect_proof https 200
  expect_proof railpack v0.43.0
  expect_proof railpack_version 0.43.0
  expect_proof railpack_frontend sha256:355ef61fae6f2551103cd8b10c710cb07167dd353d561f15c69b8d7ac1c676cc
  expect_proof railpack_archive sha256:355ef61fae6f2551103cd8b10c710cb07167dd353d561f15c69b8d7ac1c676cc
}

printf '%s\r\n' \
  'TOSHI-PROOF: service active' \
  'TOSHI-PROOF: version test-version' \
  'boot-proof login: TOSHI-PROOF: https 200' \
  'TOSHI-PROOF: railpack v0.43.0' \
  'TOSHI-PROOF: railpack_version 0.43.0' \
  'TOSHI-PROOF: railpack_frontend sha256:355ef61fae6f2551103cd8b10c710cb07167dd353d561f15c69b8d7ac1c676cc' \
  'TOSHI-PROOF: railpack_archive sha256:355ef61fae6f2551103cd8b10c710cb07167dd353d561f15c69b8d7ac1c676cc' \
  'TOSHI-PROOF: DONE' >"${SERIAL_LOG}"
expect_complete_proof
printf 'ok - login prompt before HTTPS marker\n'

printf '%s\r\n' \
  'TOSHI-PROOF: service inactive' \
  'console: TOSHI-PROOF: service inactive TOSHI-PROOF: service active' \
  'TOSHI-PROOF: version old TOSHI-PROOF: version test-version' \
  'boot-proof login: TOSHI-PROOF: https 500 TOSHI-PROOF: https 200' \
  'TOSHI-PROOF: railpack v0.42.0' \
  'console: TOSHI-PROOF: railpack v0.42.0 TOSHI-PROOF: railpack v0.43.0' \
  'console: TOSHI-PROOF: railpack_version 0.42.0 TOSHI-PROOF: railpack_version 0.43.0' \
  'console: TOSHI-PROOF: railpack_frontend sha256:old TOSHI-PROOF: railpack_frontend sha256:355ef61fae6f2551103cd8b10c710cb07167dd353d561f15c69b8d7ac1c676cc' \
  'console: TOSHI-PROOF: railpack_archive sha256:old TOSHI-PROOF: railpack_archive sha256:355ef61fae6f2551103cd8b10c710cb07167dd353d561f15c69b8d7ac1c676cc' \
  'boot-proof login: TOSHI-PROOF: DONE' >"${SERIAL_LOG}"
expect_complete_proof
printf 'ok - prefixed completion and last marker values\n'
printf '2 serial parser cases passed\n'
