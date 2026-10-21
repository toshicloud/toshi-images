#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/versions.env"

JDK_ROOT=/usr/lib/jvm

jdk_dir() {
	echo "${JDK_ROOT}/temurin-$1-jdk-amd64"
}

# The version `java -version` prints on its first line, e.g. 17.0.20.1.
installed_version() {
	java -version 2>&1 | awk -F'"' 'NR == 1 { print $2 }'
}

install_jdk() {
	local major=$1 version=$2 url=$3 sha=$4
	local dir archive bin
	dir=$(jdk_dir "$major")
	archive="${tmpdir}/$(basename "$url")"
	fetch_verified "$url" sha256 "$sha" "$archive"
	rm -rf "$dir"
	mkdir -p "$dir"
	tar -xzf "$archive" -C "$dir" --strip-components=1 --no-same-owner
	for bin in java javac jar jshell; do
		update-alternatives --install "/usr/bin/${bin}" "${bin}" "${dir}/bin/${bin}" "${major}"
	done
}

# JAVA17_VERSION is the pin including its build number (17.0.20.1+1);
# `java -version`'s first line usually drops the build, but some builds print
# it too, so accept either form.
default_version=${JAVA17_VERSION%%+*}

is_default() {
	[[ $1 == "$default_version" || $1 == "$JAVA17_VERSION" ]]
}

if [[ -x "$(jdk_dir 17)/bin/java" ]] &&
	[[ -x "$(jdk_dir 21)/bin/java" ]] &&
	[[ -x "$(jdk_dir 25)/bin/java" ]] &&
	command -v java >/dev/null 2>&1 &&
	is_default "$(installed_version)"; then
	toolset_done java "$(installed_version)"
	exit 0
fi

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT

install_jdk 17 "$JAVA17_VERSION" "$JAVA17_URL" "$JAVA17_SHA256"
install_jdk 21 "$JAVA21_VERSION" "$JAVA21_URL" "$JAVA21_SHA256"
install_jdk 25 "$JAVA25_VERSION" "$JAVA25_URL" "$JAVA25_SHA256"

for bin in java javac jar jshell; do
	update-alternatives --set "${bin}" "$(jdk_dir 17)/bin/${bin}"
done

env_set JAVA_HOME_17_X64 "$(jdk_dir 17)"
env_set JAVA_HOME_21_X64 "$(jdk_dir 21)"
env_set JAVA_HOME_25_X64 "$(jdk_dir 25)"
env_set JAVA_HOME "$(jdk_dir 17)"

version=$(installed_version)
if ! is_default "$version"; then
	echo "java.sh: expected default ${default_version}, got ${version}" >&2
	exit 1
fi

toolset_done java "$version"
