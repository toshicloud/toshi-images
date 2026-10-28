# shellcheck shell=bash

# retry runs a command that downloads, up to three times, and waits 10 s and
# then 30 s between the tries. Each failed try prints one line on stderr. It
# returns the last try's exit code. An ERR trap in the caller sees only this
# function's return statement in BASH_COMMAND, so the command is also left
# in RETRY_FAILED for the trap to print.
retry() {
	local try rc=0
	RETRY_FAILED=
	for try in 1 2 3; do
		"$@" && return 0 || rc=$?
		echo "retry: try ${try}/3 failed (exit ${rc}): $*" >&2
		if ((try < 3)); then
			sleep $((try * 20 - 10))
		fi
	done
	# shellcheck disable=SC2034
	RETRY_FAILED=$*
	return "$rc"
}

# Limits for a command that downloads. One try may take TRY_MAX_TIME seconds,
# or up to 10 more under `bounded` below, which kills a command that ignores
# the signal. A curl try also ends when the connection is not made within
# FETCH_CONNECT_TIME seconds, or has moved fewer than FETCH_SPEED_FLOOR bytes
# a second for FETCH_STALL_TIME seconds.
TRY_MAX_TIME=300
FETCH_CONNECT_TIME=30
FETCH_SPEED_FLOOR=1024
FETCH_STALL_TIME=60

# An image build sets another TRY_MAX_TIME in limits.env, next to this file in
# the seed (ubuntu-24.04/build.sh writes it).
if [[ -f "${BASH_SOURCE[0]%/*}/limits.env" ]]; then
	# shellcheck disable=SC1091
	source "${BASH_SOURCE[0]%/*}/limits.env"
fi

# bounded is retry around timeout, for a command that downloads by itself
# and whose own timeouts do not bound the whole run: each try is ended
# TRY_MAX_TIME seconds after it starts (up to 10 seconds later when the
# command ignores the signal); exit 124, or 137 when timeout had to kill it.
bounded() {
	retry timeout -k 10 "$TRY_MAX_TIME" "$@" || return $?
}

# fetch downloads a URL to a file with retry's three tries, each a curl with
# the limits above. It prints `downloaded: <file> from <url>`, or after the
# third try `failed: <file> from <url> (curl exit <n>)`.
fetch() {
	local url=$1 dest=$2 rc=0
	retry curl -fsSL --connect-timeout "$FETCH_CONNECT_TIME" \
		--speed-limit "$FETCH_SPEED_FLOOR" --speed-time "$FETCH_STALL_TIME" \
		--max-time "$TRY_MAX_TIME" -o "$dest" "$url" || rc=$?
	if ((rc != 0)); then
		rm -f "$dest"
		echo "failed: ${dest##*/} from ${url} (curl exit ${rc})" >&2
		return "$rc"
	fi
	echo "downloaded: ${dest##*/} from ${url}"
}

# apt_get is bounded apt-get, for a call that downloads (update, install
# --download-only). apt's own timeout and tries stay as they are.
apt_get() {
	bounded apt-get "$@" || return $?
}

# apt_install downloads the packages with apt_get and then installs them from
# apt's cache, so the time limit never ends an installation half way.
apt_install() {
	local rc=0
	apt_get install -y --download-only "$@" || return $?
	apt-get install -y "$@" || rc=$?
	if ((rc != 0)); then
		# shellcheck disable=SC2034
		RETRY_FAILED="apt-get install -y $*"
	fi
	return "$rc"
}

fetch_verified() {
	local url=$1 algo=$2 hash=$3 dest=$4
	fetch "$url" "$dest" || return $?
	local line
	if [[ $algo == sha256 ]]; then
		line="${hash}  ${dest}"
		if ! printf '%s\n' "$line" | sha256sum -c - >/dev/null; then
			rm -f "$dest"
			echo "fetch_verified: ${algo} mismatch for ${url}" >&2
			exit 1
		fi
	elif [[ $algo == sha512 ]]; then
		line="${hash}  ${dest}"
		if ! printf '%s\n' "$line" | sha512sum -c - >/dev/null; then
			rm -f "$dest"
			echo "fetch_verified: ${algo} mismatch for ${url}" >&2
			exit 1
		fi
	else
		echo "fetch_verified: unsupported algorithm ${algo}" >&2
		rm -f "$dest"
		exit 1
	fi
}

env_set() {
	local key=$1 value=$2
	local file=/etc/environment
	if [[ -f $file ]] && grep -q "^${key}=" "$file"; then
		sed -i "s|^${key}=.*|${key}=\"${value}\"|" "$file"
	else
		printf '%s="%s"\n' "$key" "$value" >>"$file"
	fi
}

path_prepend() {
	local dir=$1
	local file=/etc/environment
	local default_path='PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/usr/local/games:/snap/bin"'
	if [[ ! -f $file ]]; then
		printf '%s\n' "$default_path" >"$file"
	fi
	if ! grep -q '^PATH=' "$file"; then
		printf '%s\n' "$default_path" >>"$file"
	fi
	local current
	current=$(grep '^PATH=' "$file" | tail -1)
	local path_value
	path_value=${current#PATH=}
	path_value=${path_value#\"}
	path_value=${path_value%\"}
	local IFS=':'
	read -ra parts <<<"$path_value"
	local p
	for p in "${parts[@]}"; do
		if [[ $p == "$dir" ]]; then
			return 0
		fi
	done
	local new_path="${dir}:${path_value}"
	sed -i "s|^PATH=.*|PATH=\"${new_path}\"|" "$file"
}

toolset_done() {
	echo "TOOLSET $1 $2"
}

# toolset_pin prints the version versions.env pins for a toolset.
toolset_pin() {
	case $1 in
	python) echo "$PYTHON_SERIES" ;;
	node) echo "$NODE_VERSION" ;;
	go) echo "$GO_VERSION" ;;
	rust) echo "$RUST_VERSION" ;;
	dotnet) echo "$DOTNET_SDK_VERSION" ;;
	mise) echo "$MISE_VERSION" ;;
	docker) echo "$DOCKER_VERSION" ;;
	java) echo "$JAVA17_VERSION" ;;
	cmake) echo "$CMAKE_VERSION" ;;
	gh) echo "$GH_VERSION" ;;
	yq) echo "$YQ_VERSION" ;;
	git-lfs) echo "$GIT_LFS_VERSION" ;;
	# Railpack pins its versions and their checksums in ../railpack.env,
	# next to guest.env; the image build puts that file in the seed beside
	# this directory.
	railpack) (
		# shellcheck disable=SC1090,SC1091
		source "${BASH_SOURCE[0]%/*}/../railpack.env"
		echo "$RAILPACK_VERSION"
	) ;;
	*) echo unknown ;;
	esac
}

# run_toolset runs one toolset script and passes its output on. When the
# script fails it prints `TOOLSET <name> <pinned version> failed: exit <n>:
# <the script's last line>` and returns the script's exit status.
run_toolset() {
	local -
	set -o pipefail
	local name=$1 out rc=0 last
	out=$(mktemp)
	bash "${BASH_SOURCE[0]%/*}/${name}.sh" 2>&1 | tee "$out" || rc=$?
	if ((rc != 0)); then
		last=$(tr -d '\r' <"$out" | grep -av '^[[:space:]]*$' | tail -n 1 | cut -c1-300)
		echo "TOOLSET ${name} $(toolset_pin "$name") failed: exit ${rc}: ${last}"
	fi
	rm -f "$out"
	return "$rc"
}
