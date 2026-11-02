#!/usr/bin/env bash
# Points apt at a dated snapshot of the Ubuntu archive for the length of an
# image build, and puts the stock sources back before the image ships.
#
#   apt-snapshot.sh id FILE       print APT_SNAPSHOT from a versions.env
#   apt-snapshot.sh epoch FILE    print its date as SOURCE_DATE_EPOCH seconds
#   apt-snapshot.sh use FILE      switch apt to that snapshot (root)
#   apt-snapshot.sh restore       put the sources back and drop the package lists (root)
#
# One snapshot id serves the release, updates, backports and security pockets,
# so one deb822 stanza replaces the image's own sources while it builds.
set -euo pipefail

sources=/etc/apt/sources.list.d/ubuntu.sources
saved=/var/lib/toshi/apt-snapshot/ubuntu.sources
keyring=/usr/share/keyrings/ubuntu-archive-keyring.gpg
id_pattern='^[0-9]{8}T[0-9]{6}Z$'

snapshot_id() {
	local id
	id=$(sed -n 's/^APT_SNAPSHOT=//p' "$1")
	[[ $id =~ $id_pattern ]] || { echo "apt-snapshot: $1 has no valid APT_SNAPSHOT (want YYYYMMDDTHHMMSSZ)" >&2; return 1; }
	echo "$id"
}

case ${1:-} in
	id)
		snapshot_id "${2:?usage: apt-snapshot.sh id FILE}" ;;
	epoch)
		id=$(snapshot_id "${2:?usage: apt-snapshot.sh epoch FILE}")
		date -u -d "${id:0:4}-${id:4:2}-${id:6:2} ${id:9:2}:${id:11:2}:${id:13:2}" +%s ;;
	use)
		id=$(snapshot_id "${2:?usage: apt-snapshot.sh use FILE}")
		# shellcheck disable=SC1091
		codename=$(. /etc/os-release && echo "$VERSION_CODENAME")
		[[ -f $sources ]] || { echo "apt-snapshot: stock sources not found: $sources" >&2; exit 1; }
		[[ -f $saved ]] || { mkdir -p "$(dirname -- "$saved")"; cp -p "$sources" "$saved"; }
		cat >"$sources" <<EOF
Types: deb
URIs: https://snapshot.ubuntu.com/ubuntu/${id}
Suites: ${codename} ${codename}-updates ${codename}-backports ${codename}-security
Components: main restricted universe multiverse
Signed-By: ${keyring}
EOF
		# Do not let a failed update fall back to lists from the stock archive.
		rm -rf /var/lib/apt/lists/*
		echo "apt-snapshot: apt reads snapshot ${id}" ;;
	restore)
		[[ -f $saved ]] || { echo "apt-snapshot: saved stock sources not found: $saved" >&2; exit 1; }
		cp -p "$saved" "$sources"
		rm -rf "$(dirname -- "$saved")"
		rm -rf /var/lib/apt/lists/*
		echo "apt-snapshot: stock sources restored" ;;
	*)
		echo 'usage: apt-snapshot.sh id|epoch FILE | use FILE | restore' >&2
		exit 2 ;;
esac
