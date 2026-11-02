#!/usr/bin/env bash
# The opt-in playwright-chromium toolset's pins live in toolsets/playwright.env,
# apart from toolsets/versions.env, so a default image's manifest lists the same
# pins as before the toolset existed. The container image pins the same
# Playwright release; its version and the version line the guest script prints
# must agree with this file and ubuntu-24.04/build.sh.

set -euo pipefail

scripts=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
root=$(CDPATH='' cd -- "$scripts/.." && pwd)

value() { # <file> <key>
	sed -n "s/^$2=//p" "$1" | tail -n 1
}

check_root() { # <root>: 0 when the toolset's pins and wiring agree.
	local dir=$1 rc=0
	local env_file="$dir/toolsets/playwright.env"
	local toolsets_file="$dir/toolsets/versions.env"
	local container_file="$dir/ubuntu-24.04-container/versions.env"
	local toolset="$dir/toolsets/playwright-chromium.sh"
	local build="$dir/ubuntu-24.04/build.sh"
	local version revision browser key file pin line

	fail() {
		echo "FAIL $*"
		rc=1
	}

	version=$(value "$env_file" PLAYWRIGHT_VERSION)
	[[ $version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
		|| fail "toolsets/playwright.env has an invalid PLAYWRIGHT_VERSION: ${version:-nothing}"
	revision=$(value "$env_file" PLAYWRIGHT_CHROMIUM_REVISION)
	[[ $revision =~ ^[0-9]+$ ]] \
		|| fail "toolsets/playwright.env has an invalid PLAYWRIGHT_CHROMIUM_REVISION: ${revision:-nothing}"
	browser=$(value "$env_file" PLAYWRIGHT_BROWSER_VERSION)
	[[ $browser =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] \
		|| fail "toolsets/playwright.env has an invalid PLAYWRIGHT_BROWSER_VERSION: ${browser:-nothing}"
	for key in PLAYWRIGHT_CORE_SHA256 PLAYWRIGHT_CHROMIUM_SHA256 PLAYWRIGHT_HEADLESS_SHELL_SHA256; do
		[[ $(value "$env_file" "$key") =~ ^[0-9a-f]{64}$ ]] \
			|| fail "toolsets/playwright.env has an invalid ${key}"
	done

	set -a
	# shellcheck disable=SC1090,SC1091
	source "$env_file"
	set +a
	[[ ${PLAYWRIGHT_CHROMIUM_URL:-} == *"/${PLAYWRIGHT_BROWSER_VERSION}/"* ]] \
		|| fail "PLAYWRIGHT_CHROMIUM_URL does not name browser ${PLAYWRIGHT_BROWSER_VERSION}"
	[[ ${PLAYWRIGHT_HEADLESS_SHELL_URL:-} == *"/${PLAYWRIGHT_BROWSER_VERSION}/"* ]] \
		|| fail "PLAYWRIGHT_HEADLESS_SHELL_URL does not name browser ${PLAYWRIGHT_BROWSER_VERSION}"

	# The container image installs the same release's Chromium libraries.
	[[ $(value "$container_file" PLAYWRIGHT_VERSION) == "$PLAYWRIGHT_VERSION" ]] \
		|| fail "ubuntu-24.04-container/versions.env pins PLAYWRIGHT_VERSION $(value "$container_file" PLAYWRIGHT_VERSION), toolsets/playwright.env pins ${PLAYWRIGHT_VERSION}"
	while IFS= read -r file; do
		[[ $file == "$env_file" ]] && continue
		for key in PLAYWRIGHT_VERSION PLAYWRIGHT_CORE_URL PLAYWRIGHT_CORE_SHA256 \
			PLAYWRIGHT_CHROMIUM_REVISION PLAYWRIGHT_BROWSER_VERSION \
			PLAYWRIGHT_CHROMIUM_URL PLAYWRIGHT_CHROMIUM_SHA256 \
			PLAYWRIGHT_HEADLESS_SHELL_URL PLAYWRIGHT_HEADLESS_SHELL_SHA256; do
			[[ $file == "$container_file" && $key == PLAYWRIGHT_VERSION ]] && continue
			if grep -qE "^${key}=" "$file"; then
				fail "${file#"$dir"/} declares ${key}; toolsets/playwright.env declares the playwright pins"
			fi
		done
	done < <(find "$dir" -name versions.env -not -path '*/.git/*' | sort)

	# shellcheck disable=SC1090,SC1091
	source "$toolsets_file"
	if [[ " ${TOOLSETS:-} " == *' playwright-chromium '* ]]; then
		fail "playwright-chromium is in the default TOOLSETS"
	fi

	# toolset_pin, the script's own TOOLSET line and build.sh's pattern must
	# name the same version string.
	# shellcheck disable=SC1090,SC1091
	source "$dir/toolsets/lib.sh"
	pin=$(toolset_pin playwright-chromium)
	[[ $pin == "${PLAYWRIGHT_VERSION}+${PLAYWRIGHT_BROWSER_VERSION}" ]] \
		|| fail "toolset_pin prints '${pin}', not ${PLAYWRIGHT_VERSION}+${PLAYWRIGHT_BROWSER_VERSION}"
	line=$(grep -F 'toolset_done playwright-chromium' "$toolset" | head -n 1)
	[[ -n $line ]] || fail "toolsets/playwright-chromium.sh prints no toolset_done line"
	for key in PLAYWRIGHT_VERSION PLAYWRIGHT_BROWSER_VERSION; do
		[[ $line == *"${key}"* ]] || fail "the script's toolset_done line does not name ${key}"
	done
	line=$(grep -F 'playwright-chromium) echo' "$build" | head -n 1)
	if [[ -z $line ]]; then
		fail "ubuntu-24.04/build.sh has no playwright-chromium expected pattern"
	else
		# As build.sh's awk match sees it: the case's expression with the
		# pins expanded, matched against the line the script prints.
		expr=${line#*echo }
		expr=${expr% ;;*}
		pattern=$(eval "printf '%s' $expr")
		[[ $pin =~ ^$pattern$ ]] \
			|| fail "ubuntu-24.04/build.sh's pattern '${pattern}' does not match '${pin}'"
	fi

	return "$rc"
}

if check_root "$root"; then
	echo "ok playwright-chromium pins: the opt-in toolset's pins and wiring agree"
else
	exit 1
fi

# A copy of a playwright-only pin in another versions.env is what this check
# catches.
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/toolsets" "$tmp/ubuntu-24.04" "$tmp/ubuntu-24.04-container"
cp "$root/toolsets/playwright.env" "$root/toolsets/versions.env" \
	"$root/toolsets/lib.sh" "$root/toolsets/playwright-chromium.sh" "$tmp/toolsets/"
cp "$root/ubuntu-24.04/build.sh" "$tmp/ubuntu-24.04/"
cp "$root/ubuntu-24.04-container/versions.env" "$tmp/ubuntu-24.04-container/"
printf 'PLAYWRIGHT_BROWSER_VERSION=0.0.0.0\n' >"$tmp/ubuntu-24.04/versions.env"
if check_root "$tmp" >/dev/null 2>&1; then
	echo "FAIL self-test: a copied PLAYWRIGHT_BROWSER_VERSION passed the check"
	exit 1
fi
echo "ok self-test: a copied PLAYWRIGHT_BROWSER_VERSION fails the check"
