#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
# The toolset's own pins, beside this script and the toolsets that ship in
# the seed.
# shellcheck disable=SC1091
source "$SCRIPT_DIR/playwright.env"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/versions.env"

# Playwright's browser registry keeps each browser in
# PLAYWRIGHT_BROWSERS_PATH/<name>-<revision>, with the zip's own top-level
# directory inside and an INSTALLATION_COMPLETE marker beside it. This
# toolset is opt-in: it is not in TOOLSETS.
BROWSERS_PATH=/opt/playwright-browsers
CHROMIUM_DIR="${BROWSERS_PATH}/chromium-${PLAYWRIGHT_CHROMIUM_REVISION}"
HEADLESS_SHELL_DIR="${BROWSERS_PATH}/chromium_headless_shell-${PLAYWRIGHT_CHROMIUM_REVISION}"

# npm -g installs outside node's default search path, so point node at it.
NODE_PATH=
if command -v npm >/dev/null 2>&1; then
	NODE_PATH=$(npm root -g)
fi
export NODE_PATH

installed_version() {
	node -p 'require("playwright-core/package.json").version' 2>/dev/null
}

browsers_installed() {
	[[ -f "${CHROMIUM_DIR}/INSTALLATION_COMPLETE" && -f "${HEADLESS_SHELL_DIR}/INSTALLATION_COMPLETE" ]]
}

if command -v node >/dev/null 2>&1 && browsers_installed \
	&& [[ $(installed_version) == "$PLAYWRIGHT_VERSION" ]]; then
	env_set PLAYWRIGHT_BROWSERS_PATH "$BROWSERS_PATH"
	toolset_done playwright-chromium "${PLAYWRIGHT_VERSION}+${PLAYWRIGHT_BROWSER_VERSION}"
	exit 0
fi

tmpdir=$(mktemp -d)
trap 'rm -rf "$tmpdir"' EXIT
package="${tmpdir}/playwright-core-${PLAYWRIGHT_VERSION}.tgz"
fetch_verified "$PLAYWRIGHT_CORE_URL" sha256 "$PLAYWRIGHT_CORE_SHA256" "$package"

npm install -g --no-audit --no-fund "$package"
# npm may have created a new prefix; read it again.
NODE_PATH=$(npm root -g)
export NODE_PATH

version=$(installed_version)
if [[ $version != "$PLAYWRIGHT_VERSION" ]]; then
	echo "playwright-chromium.sh: expected playwright-core ${PLAYWRIGHT_VERSION}, got ${version:-nothing}" >&2
	exit 1
fi

install -d -m 0755 "$BROWSERS_PATH"
rm -rf "$CHROMIUM_DIR" "$HEADLESS_SHELL_DIR"
install -d -m 0755 "$CHROMIUM_DIR" "$HEADLESS_SHELL_DIR"

zip="${tmpdir}/chrome-linux64.zip"
fetch_verified "$PLAYWRIGHT_CHROMIUM_URL" sha256 "$PLAYWRIGHT_CHROMIUM_SHA256" "$zip"
unzip -q "$zip" -d "$CHROMIUM_DIR"
touch "${CHROMIUM_DIR}/INSTALLATION_COMPLETE"

zip="${tmpdir}/chrome-headless-shell-linux64.zip"
fetch_verified "$PLAYWRIGHT_HEADLESS_SHELL_URL" sha256 "$PLAYWRIGHT_HEADLESS_SHELL_SHA256" "$zip"
unzip -q "$zip" -d "$HEADLESS_SHELL_DIR"
touch "${HEADLESS_SHELL_DIR}/INSTALLATION_COMPLETE"

# The shared libraries Playwright 1.64 names for Chromium on Ubuntu 24.04.
# The list is static: the image build has no package manager to ask at run
# time, and apt installs them from the pinned snapshot.
apt_install --no-install-recommends \
	libasound2t64 libatk-bridge2.0-0t64 libatk1.0-0t64 libatspi2.0-0t64 \
	libcairo2 libcups2t64 libdbus-1-3 libdrm2 libgbm1 libglib2.0-0t64 \
	libnspr4 libnss3 libpango-1.0-0 libx11-6 libxcb1 libxcomposite1 \
	libxdamage1 libxext6 libxfixes3 libxkbcommon0 libxrandr2 \
	fonts-liberation libfontconfig1 libfreetype6

env_set PLAYWRIGHT_BROWSERS_PATH "$BROWSERS_PATH"

# Launch the installed browser on about:blank and report the version it
# prints. --no-sandbox because this runs as root; the launch also writes
# each browser directory's DEPENDENCIES_VALIDATED marker, as Playwright's
# own install does.
reported=$(
	PLAYWRIGHT_BROWSERS_PATH="$BROWSERS_PATH" node -e '
const { chromium } = require("playwright-core");
(async () => {
  const browser = await chromium.launch({ args: ["--no-sandbox"] });
  console.log(browser.version());
  await browser.close();
  // A job can ask for the full bundle with channel "chromium": launch it too,
  // so its directory ships the host-validation marker like the shell does.
  const full = await chromium.launch({ channel: "chromium", args: ["--no-sandbox"] });
  await full.close();
})().catch((error) => {
  console.error(error);
  process.exit(1);
});
'
)
if [[ $reported != "$PLAYWRIGHT_BROWSER_VERSION" ]]; then
	echo "playwright-chromium.sh: expected chromium ${PLAYWRIGHT_BROWSER_VERSION}, launched ${reported:-nothing}" >&2
	exit 1
fi

toolset_done playwright-chromium "${PLAYWRIGHT_VERSION}+${PLAYWRIGHT_BROWSER_VERSION}"
