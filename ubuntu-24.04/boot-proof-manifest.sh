#!/usr/bin/env bash
# Holds a booted image to the properties its manifest declares: the users
# and their groups, the enabled service units, no firewall, sshd masked and
# the guest digest guest.env pins. The boot proof's guest prints one
# TOSHI-PROOF line per property on the serial console; this compares those
# lines with manifest.json and prints one result line per property.
#
# Usage: boot-proof-manifest.sh names <manifest.json>
#          the user names the guest must report, one per line
#        boot-proof-manifest.sh check <manifest.json> <serial.log>
#          exit 0 when every property holds, 1 otherwise
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
GUEST_ENV="${GUEST_ENV:-${SCRIPT_DIR}/../guest.env}"

# The units of the guest helper: record of the image's unit set.
GUEST_UNITS=(toshi-guest.service toshi-guest-userdata.service toshi-guest-gce.service toshi-guest-azure.service)

usage() {
  echo "usage: boot-proof-manifest.sh names <manifest.json> | check <manifest.json> <serial.log>" >&2
  exit 2
}

[[ $# -ge 2 ]] || usage
mode=$1
manifest=$2
[[ -f ${manifest} ]] || {
  echo "no manifest at ${manifest}" >&2
  exit 1
}

case "${mode}" in
  names)
    # A name goes into the guest's shell: only account-name characters pass.
    jq -r '.users[].name' "${manifest}" | while IFS= read -r name; do
      [[ ${name} =~ ^[a-z_][a-z0-9_-]*$ ]] || {
        echo "the manifest lists a user name the proof will not pass to the guest: '${name}'" >&2
        exit 1
      }
      printf '%s\n' "${name}"
    done
    exit 0
    ;;
  check) [[ $# -eq 3 ]] || usage ;;
  *) usage ;;
esac
serial=$3
[[ -f ${serial} ]] || {
  echo "no serial log at ${serial}" >&2
  exit 1
}

failures=0
fail() {
  echo "manifest proof: FAIL $*" >&2
  failures=$((failures + 1))
}
ok() { echo "manifest proof: ok $*"; }
# The last guest line for a property, without its prefix.
proof() { grep -a "TOSHI-PROOF: $1 " "${serial}" | tail -n 1 | tr -d '\r' | sed "s/.*TOSHI-PROOF: $1 //" || true; }

# Users: each manifest user exists in the guest with its uid and groups.
users_ok=1
count=0
while IFS=$'\t' read -r name uid groups; do
  count=$((count + 1))
  line=$(grep -a "TOSHI-PROOF: user ${name} " "${serial}" | tail -n 1 | tr -d '\r' | sed "s/.*TOSHI-PROOF: user ${name} //" || true)
  if [[ -z ${line} ]]; then
    fail "users: the guest reported nothing for ${name}"
    users_ok=0
    continue
  fi
  got_uid=${line%% *}
  got_groups=${line#* }
  if [[ ${got_uid} != "${uid}" ]]; then
    fail "users: ${name} has uid '${got_uid}', the manifest says ${uid}"
    users_ok=0
  fi
  if [[ ${got_groups} != "${groups}" ]]; then
    fail "users: ${name} is in groups '${got_groups}', the manifest says '${groups}'"
    users_ok=0
  fi
done < <(jq -r '.users[] | [.name, .uid, (.groups | sort | unique | join(" "))] | @tsv' "${manifest}")
((count > 0)) || fail "users: the manifest lists no user"
((users_ok)) && ((count > 0)) && ok "users: ${count} accounts, uids and groups as declared"

# The build removes the password-less sudo rule: the manifest must say so.
runner_sudo=$(jq -r '[.users[] | select(.name == "runner") | .sudo][0] // "absent"' "${manifest}")
if [[ ${runner_sudo} == none ]]; then
  ok "sudo: runner has none"
else
  fail "sudo: the manifest gives runner '${runner_sudo}', not none"
fi

# Units: the enabled service set is the manifest's, and holds the guest's.
want_units=$(jq -r '[.services[] | select(.enabled) | .name] | sort | unique | join(" ")' "${manifest}")
got_units=$(proof units)
if [[ -z ${got_units} ]]; then
  fail "units: the guest reported no unit set"
elif [[ ${got_units} != "${want_units}" ]]; then
  fail "units: the guest enables '${got_units}', the manifest says '${want_units}'"
else
  missing=""
  for unit in "${GUEST_UNITS[@]}"; do
    [[ " ${want_units} " == *" ${unit} "* ]] || missing+=" ${unit}"
  done
  if [[ -n ${missing} ]]; then
    fail "units: the guest helper's units are not enabled:${missing}"
  else
    ok "units: $(wc -w <<<"${want_units}") enabled units as declared, the guest helper's four among them"
  fi
fi

# Firewall: the image loads none. The manifest may name the distribution's
# stock rules file; that is no firewall while nothing enables the service
# that loads it and the booted guest holds no rule.
manifest_firewall=$(jq -r '.firewall // "absent"' "${manifest}")
live_firewall=$(proof firewall)
nft_enabled=$(jq -r '[.services[] | select(.enabled and .name == "nftables.service")] | length' "${manifest}")
if [[ ${manifest_firewall} == absent ]]; then
  fail "firewall: the manifest declares no firewall field"
elif [[ ${live_firewall} != none ]]; then
  fail "firewall: the guest holds rules (${live_firewall:-nothing reported})"
elif [[ ${manifest_firewall} != none && ${nft_enabled} != 0 ]]; then
  fail "firewall: the manifest names ${manifest_firewall} and enables nftables.service"
elif [[ ${manifest_firewall} != none ]]; then
  ok "firewall: none loaded (${manifest_firewall} is present, nftables.service is not enabled)"
else
  ok "firewall: none"
fi

# sshd: installed and masked, so it is in no enabled set and cannot start.
ssh_state=$(proof sshd)
if [[ ${ssh_state} == masked ]]; then
  ok "sshd: masked"
else
  fail "sshd: ssh.service is '${ssh_state:-unreported}', not masked"
fi

# The guest helper's digest in the manifest is the one guest.env pins.
pinned_digest=$(
  # shellcheck disable=SC1090
  source "${GUEST_ENV}" >/dev/null
  printf '%s' "${TOSHI_GUEST_DIGEST:-}"
)
manifest_digest=$(jq -r '.guest.digest // empty' "${manifest}")
if [[ -z ${pinned_digest} ]]; then
  fail "guest digest: guest.env pins none"
elif [[ ${manifest_digest} != "${pinned_digest}" ]]; then
  fail "guest digest: the manifest says '${manifest_digest:-none}', guest.env pins ${pinned_digest}"
else
  ok "guest digest: ${pinned_digest}"
fi

((failures == 0))
