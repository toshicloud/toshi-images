#!/usr/bin/env bash
# boot-proof-manifest.sh passes a guest that matches its manifest and fails
# each property that differs: a user's groups, a missing user, the unit set,
# the guest helper's units, a firewall rule, sshd not masked, a wrong guest
# digest, and a runner with sudo.
set -euo pipefail

scripts=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
check="$scripts/../ubuntu-24.04/boot-proof-manifest.sh"
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
failed=0
expect() {
  local name=$1 want=$2 got=$3
  if [[ $want == "$got" ]]; then echo "ok $name"; else echo "FAIL $name: want '$want', got '$got'"; failed=$((failed + 1)); fi
}

cat >"$tmp/guest.env" <<'EOF'
TOSHI_GUEST_VERSION=v1
TOSHI_GUEST_DIGEST=sha256:guest
EOF
export GUEST_ENV="$tmp/guest.env"

cat >"$tmp/manifest.json" <<'EOF'
{"firewall":"none","guest":{"version":"v1","digest":"sha256:guest"},
 "users":[{"name":"root","uid":0,"groups":["root"],"sudo":"none"},
          {"name":"runner","uid":1001,"groups":["docker","kvm","runner"],"sudo":"none"}],
 "services":[{"name":"ssh.service","kind":"systemd","enabled":false},
             {"name":"toshi-guest-azure.service","kind":"systemd","enabled":true},
             {"name":"toshi-guest-gce.service","kind":"systemd","enabled":true},
             {"name":"toshi-guest-userdata.service","kind":"systemd","enabled":true},
             {"name":"toshi-guest.service","kind":"systemd","enabled":true}]}
EOF

write_serial() {
  cat >"$tmp/serial.log" <<EOF
boot noise
TOSHI-PROOF: service active
TOSHI-PROOF: user root 0 root
TOSHI-PROOF: user runner 1001 docker kvm runner
TOSHI-PROOF: units toshi-guest-azure.service toshi-guest-gce.service toshi-guest-userdata.service toshi-guest.service
TOSHI-PROOF: firewall none
TOSHI-PROOF: sshd masked
TOSHI-PROOF: DONE
EOF
}
run() { { bash "$check" check "$tmp/manifest.json" "$tmp/serial.log" >/dev/null; } 2>&1 || true; }
status() { bash "$check" check "$tmp/manifest.json" "$tmp/serial.log" >/dev/null 2>&1 && echo pass || echo fail; }
mutate() { sed -i "$1" "$tmp/serial.log"; }

write_serial
expect 'a guest that matches its manifest passes' pass "$(status)"
expect 'the user names come from the manifest' $'root\nrunner' "$(bash "$check" names "$tmp/manifest.json")"

write_serial; mutate 's/docker kvm runner/kvm runner/'
expect 'a missing group fails' fail "$(status)"
expect 'the failure names the groups' yes "$(grep -q "runner is in groups 'kvm runner'" <<<"$(run)" && echo yes || echo no)"

write_serial; mutate '/user runner/d'
expect 'a user the guest did not report fails' fail "$(status)"

write_serial; mutate 's/user runner 1001/user runner 1002/'
expect 'a wrong uid fails' fail "$(status)"

write_serial; mutate 's/ toshi-guest-gce.service//'
expect 'a unit set that differs fails' fail "$(status)"

write_serial; mutate 's/units .*/units toshi-guest-azure.service toshi-guest-gce.service toshi-guest-userdata.service toshi-guest.service ssh.service/'
expect 'an enabled sshd fails the unit set' fail "$(status)"

write_serial; mutate 's/firewall none/firewall 12 lines/'
expect 'a firewall rule in the guest fails' fail "$(status)"

write_serial; mutate 's/sshd masked/sshd enabled/'
expect 'an sshd that is not masked fails' fail "$(status)"

write_serial; mutate '/sshd masked/d'
expect 'an unreported sshd fails' fail "$(status)"

write_serial
sed -i 's/sha256:guest/sha256:other/' "$tmp/manifest.json"
expect 'a guest digest that is not the pinned one fails' fail "$(status)"
sed -i 's/sha256:other/sha256:guest/' "$tmp/manifest.json"

jq '.firewall = "/etc/nftables.conf"' "$tmp/manifest.json" >"$tmp/m2.json"
expect 'a stock rules file that nothing loads passes' pass "$(bash "$check" check "$tmp/m2.json" "$tmp/serial.log" >/dev/null 2>&1 && echo pass || echo fail)"
jq '.firewall = "/etc/nftables.conf" | .services += [{"name":"nftables.service","kind":"systemd","enabled":true}]' "$tmp/manifest.json" >"$tmp/m2b.json"
sed 's/toshi-guest.service$/toshi-guest.service nftables.service/' "$tmp/serial.log" >"$tmp/serial2.log"
expect 'a rules file with its service enabled fails' fail "$(bash "$check" check "$tmp/m2b.json" "$tmp/serial2.log" >/dev/null 2>&1 && echo pass || echo fail)"

jq '(.users[] | select(.name == "runner") | .sudo) = "password-less"' "$tmp/manifest.json" >"$tmp/m3.json"
expect 'a runner with password-less sudo fails' fail "$(bash "$check" check "$tmp/m3.json" "$tmp/serial.log" >/dev/null 2>&1 && echo pass || echo fail)"

jq '.users[0].name = "bad name; rm"' "$tmp/manifest.json" >"$tmp/m4.json"
expect 'a user name that is not an account name is refused' fail "$(bash "$check" names "$tmp/m4.json" >/dev/null 2>&1 && echo pass || echo fail)"

((failed == 0)) || { echo "$failed failed" >&2; exit 1; }
echo "ok boot-proof-manifest.sh"
