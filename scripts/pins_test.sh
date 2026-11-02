#!/usr/bin/env bash
# The pins the Windows and service-agent images share with the Linux toolsets
# are declared once, in toolsets/versions.env. This fails when another
# versions.env copies one of them, or when a mise.toml that cannot read the
# file names a different Node or Go release.

set -euo pipefail

scripts=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH='' cd -- "$scripts/.." && pwd)

shared="NODE_VERSION NODE_SHA256 GO_VERSION JAVA17_VERSION JAVA21_VERSION CMAKE_VERSION GH_VERSION YQ_VERSION"

value() { # <root> <key>: the value toolsets/versions.env declares.
	sed -n "s/^$2=//p" "$1/toolsets/versions.env" | tail -n 1
}

mise_value() { # <mise.toml> <tool>: the version it pins, or nothing.
	sed -nE "s/^$2[[:space:]]*=[[:space:]]*\"([^\"]*)\"/\1/p" "$1" | head -n 1
}

check_mise() { # <root> <file> <tool> <key>
	local dir=$1 file=$2 want got
	file="$dir/$2"
	[[ -f $file ]] || return 0
	want=$(value "$dir" "$4")
	got=$(mise_value "$file" "$3")
	if [[ $got != "$want" ]]; then
		echo "FAIL ${file#"$dir"/} pins ${3} '${got:-nothing}'; toolsets/versions.env pins '${want}'"
		return 1
	fi
}

check_root() {
	local dir=$1 key file rc=0
	while IFS= read -r file; do
		[[ $file == "$dir/toolsets/versions.env" ]] && continue
		for key in $shared; do
			if grep -qE "^${key}=" "$file"; then
				echo "FAIL ${file#"$dir"/} declares ${key}; only toolsets/versions.env declares it"
				rc=1
			fi
		done
	done < <(find "$dir" -name versions.env -not -path '*/.git/*' | sort)
	# mise.toml files cannot source an env file; these stay literal.
	check_mise "$dir" service-agent/mise.toml node NODE_VERSION || rc=1
	check_mise "$dir" toolsets/ci/mise.toml node NODE_VERSION || rc=1
	check_mise "$dir" toolsets/ci/mise.toml go GO_VERSION || rc=1
	return "$rc"
}

failed=0
if check_root "$root"; then
	echo "ok pins: only toolsets/versions.env declares the shared pins"
else
	failed=1
fi

# A copy in another versions.env is what this check exists to catch.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/toolsets" "$tmp/windows-2025"
cp "$root/toolsets/versions.env" "$tmp/toolsets/versions.env"
printf 'NODE_VERSION=1.0.0\n' >"$tmp/windows-2025/versions.env"
if check_root "$tmp" >/dev/null 2>&1; then
	echo "FAIL self-test: a copied NODE_VERSION passed the check"
	failed=1
else
	echo "ok self-test: a copied NODE_VERSION fails the check"
fi

if ((failed)); then
	echo "pins_test: failed"
	exit 1
fi
echo "pins_test: ok"
