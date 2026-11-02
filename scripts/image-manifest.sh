#!/usr/bin/env bash
# Collect image contents and assemble or hash a Toshi image manifest.
set -euo pipefail

usage='usage: image-manifest.sh collect | assemble --image NAME --fragment FILE --out FILE [--base NAME@sha256:DIGEST] [--pins FILE ...] [--toolsets FILE] [--guest-env FILE] [--image-digest SHA] | digest FILE | pinset FILE'

canonical() {
  jq -S -c 'del(.built, .image_digest)' "$1"
}

sudo_level() {
  local name=$1 groups=$2 file level=none
  if [[ " $groups " == *' sudo '* ]]; then level=build-only; fi
  for file in /etc/sudoers.d/*; do
    [[ -f $file && -r $file ]] || continue
    # Match direct users and groups in the first field. A restricted rule or
    # password-requiring sudo group is build-only; unrestricted NOPASSWD is not.
    case $(awk -v user="$name" -v groups="$groups" '
      BEGIN { n = split(groups, a, " "); for (i = 1; i <= n; i++) g[a[i]] = 1 }
      /^[[:space:]]*#/ || NF < 2 { next }
      {
        n = split($1, subjects, ","); applies = 0
        for (i = 1; i <= n; i++) {
          s = subjects[i]
          if (s == user || s == "ALL" || (substr(s, 1, 1) == "%" && g[substr(s, 2)])) applies = 1
        }
        if (applies) {
          if ($0 ~ /NOPASSWD:[[:space:]]*ALL([[:space:]]|$)/) { print "password-less"; exit }
          found = 1
        }
      }
      END { if (found) print "build-only" }
    ' "$file") in
      *password-less*) echo password-less; return ;;
      *build-only*) level=build-only ;;
    esac
  done
  echo "$level"
}

collect() (
  local tmp firewall=none passwd shells line name uid groups sudo file
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  dpkg-query -W -f='${db:Status-Abbrev}\t${binary:Package}\t${Version}\n' |
    jq -Rn '[inputs | split("\t") | select(.[0] | startswith("ii")) | {name: .[1], version: .[2]}] | sort_by(.name, .version)' >"$tmp/packages.json"
  passwd=$(getent passwd)
  if [[ -r /etc/shells ]]; then
    shells=$(< /etc/shells)
  else
    shells=$'/bin/sh\n/bin/bash\n/usr/bin/sh\n/usr/bin/bash'
  fi
  (
    while IFS=: read -r name _ uid _ _ _ shell; do
      if [[ $name != root && $uid -lt 1000 ]] && ! grep -Fxq -- "$shell" <<<"$shells"; then continue; fi
      groups=$(id -nG "$name")
      sudo=$(sudo_level "$name" "$groups")
      jq -nc --arg name "$name" --argjson uid "$uid" --arg groups "$groups" --arg sudo "$sudo" \
        '{name:$name, uid:$uid, groups:($groups | split(" ") | sort | unique), sudo:$sudo}'
    done <<<"$passwd" | jq -s 'sort_by(.name)'
  ) >"$tmp/users.json"
  echo '[]' >"$tmp/services.json"
  if command -v systemctl >/dev/null && line=$(LC_ALL=C systemctl list-unit-files --state=enabled --type=service --no-legend --no-pager 2>/dev/null); then
    awk 'NF >= 2 && $2 == "enabled" { print $1 }' <<<"$line" |
      jq -Rn '[inputs | select(length > 0) | {name: ., kind: "systemd", enabled: true}] | sort_by(.name)' >"$tmp/services.json"
  fi
  echo '[]' >"$tmp/listening.json"
  if command -v ss >/dev/null && line=$(ss -ltnpH 2>/dev/null); then
    awk '
      NF >= 4 {
        port = $4; sub(/^.*:/, "", port)
        if (port !~ /^[0-9]+$/) next
        process = ""
        if (match($0, /users:\(\("[^"]+"/)) {
          process = substr($0, RSTART, RLENGTH); sub(/^users:\(\("/, "", process); sub(/"$/, "", process)
        }
        print port "\t" process
      }' <<<"$line" | jq -Rn '[inputs | split("\t") | {port: (.[0] | tonumber), process: .[1]}] | sort_by(.port, .process) | unique' >"$tmp/listening.json"
  fi
  if command -v nft >/dev/null; then
    for file in /etc/nftables.d/*.nft /etc/nftables.conf; do
      [[ $file == /etc/nftables.conf ]] ||
        { [[ -r /etc/nftables.conf ]] && grep -Fq "include \"$file\"" /etc/nftables.conf; } || continue
      if [[ -f $file && -r $file ]] && grep -Eq '^[[:space:]]*table[[:space:]]+(ip|ip6|inet|arp|bridge|netdev)[[:space:]]+' "$file"; then
        firewall=$file
        break
      fi
    done
  fi
  jq -n --slurpfile packages "$tmp/packages.json" --slurpfile users "$tmp/users.json" \
    --slurpfile services "$tmp/services.json" --slurpfile listening "$tmp/listening.json" --arg firewall "$firewall" \
    '{packages:$packages[0], users:$users[0], services:$services[0], listening:$listening[0], firewall:$firewall}'
)

resolved_pins() {
  local pin_file source_file line key jq_path
  jq_path=$(command -v jq)
  # Generate the sourcing program before running it: pin names cannot collide
  # with the reader's own variables, and each file's values are captured before
  # the next file can overwrite them.
  {
    printf 'set -euo pipefail\n'
    for pin_file in "$@"; do
      source_file=$pin_file
      [[ $source_file == */* ]] || source_file=./$source_file
      printf 'source %q >/dev/null\n' "$source_file"
      while IFS= read -r line || [[ -n $line ]]; do
        if [[ $line =~ ^([a-zA-Z_][a-zA-Z0-9_]*)= ]]; then
          key=${BASH_REMATCH[1]}
          # Expansions belong to the generated program and its jq filter.
          # shellcheck disable=SC2016
          printf '%q -nc --arg file %q --arg key %q --arg value "${%s}" %q\n' \
            "$jq_path" "$pin_file" "$key" "$key" '{file:$file, key:$key, value:$value}'
        fi
      done < "$pin_file"
    done
  } | bash
}

assemble() (
  local image='' fragment='' out='' base='' toolsets='' guest_env='' image_digest=''
  local base_name='' base_digest='' commit date tmp
  local -a pins=()
  while (($#)); do
    case $1 in
      --image|--fragment|--out|--base|--toolsets|--guest-env|--image-digest)
        (($# >= 2)) || { echo "$usage" >&2; return 2; }
        case $1 in
          --image) image=$2 ;; --fragment) fragment=$2 ;; --out) out=$2 ;;
          --base) base=$2 ;; --toolsets) toolsets=$2 ;; --guest-env) guest_env=$2 ;;
          --image-digest) image_digest=$2 ;;
        esac
        shift 2 ;;
      --pins)
        shift
        (($#)) && [[ $1 != --* ]] || { echo "$usage" >&2; return 2; }
        while (($#)) && [[ $1 != --* ]]; do pins+=("$1"); shift; done ;;
      *) echo "$usage" >&2; return 2 ;;
    esac
  done
  [[ -n $image && -n $fragment && -n $out ]] || { echo "$usage" >&2; return 2; }
  if [[ -n $base ]]; then
    [[ $base == *@sha256:* ]] || { echo 'image-manifest: base must be NAME@sha256:DIGEST' >&2; return 2; }
    base_name=${base%@*}; base_digest=${base##*@}
  fi
  if [[ -n $guest_env ]]; then
    local guest_json
    guest_json=$(
      unset TOSHI_GUEST_VERSION TOSHI_GUEST_DIGEST
      [[ $guest_env == */* ]] || guest_env=./$guest_env
      # shellcheck disable=SC1090
      source "$guest_env" >/dev/null
      jq -nc --arg version "${TOSHI_GUEST_VERSION:-}" --arg digest "${TOSHI_GUEST_DIGEST:-}" \
        '{version:($version | select(length > 0) // null), digest:($digest | select(length > 0) // null), protocol_min:null, protocol_max:null}'
    )
  else
    guest_json='{"version":null,"digest":null,"protocol_min":null,"protocol_max":null}'
  fi
  tmp=$(mktemp -d)
  trap 'rm -rf "$tmp"' EXIT
  resolved_pins "${pins[@]}" | jq -s '.' >"$tmp/pins.json"
  echo '[]' >"$tmp/toolsets.json"
  if [[ -n $toolsets ]]; then
    awk '{gsub(/\r/, "")} $1 == "TOOLSET" && NF >= 3 {print $2 "\t" $3}' "$toolsets" |
      jq -Rn '[inputs | split("\t") | {name: .[0], version: .[1]}]' >"$tmp/toolsets.json"
  fi
  commit=$(git -C "$(dirname -- "$0")" rev-parse --verify HEAD)
  date=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  jq --arg image "$image" --arg date "$date" --arg commit "$commit" --arg base_name "$base_name" \
    --arg base_digest "$base_digest" --arg image_digest "$image_digest" --argjson guest "$guest_json" \
    --slurpfile pins "$tmp/pins.json" --slurpfile toolsets "$tmp/toolsets.json" \
    '{image:$image, built:{date:$date, commit:$commit},
      base:{name:($base_name | select(length > 0) // null), digest:($base_digest | select(length > 0) // null)},
      guest:$guest, packages:.packages, toolsets:$toolsets[0], users:.users, services:.services,
      listening:.listening, firewall:.firewall, pins:$pins[0],
      image_digest:($image_digest | select(length > 0) // null)}' "$fragment" > "$out"
)

command=${1:-}
(($#)) && shift
case $command in
  collect) (($# == 0)) || { echo "$usage" >&2; exit 2; }; collect ;;
  assemble) assemble "$@" ;;
  digest) (($# == 1)) || { echo "$usage" >&2; exit 2; }; canonical "$1" | sha256sum | cut -d ' ' -f1 ;;
  pinset) (($# == 1)) || { echo "$usage" >&2; exit 2; }; jq -S -c '.pins' "$1" | sha256sum | cut -d ' ' -f1 ;;
  *) echo "$usage" >&2; exit 2 ;;
esac
