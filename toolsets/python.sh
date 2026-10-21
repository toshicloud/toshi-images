#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(dirname "$(readlink -f "$0")")
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib.sh"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/versions.env"

export DEBIAN_FRONTEND=noninteractive

installed_series() {
	python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])'
}

installed_version() {
	python3 -c 'import platform; print(platform.python_version())'
}

apt_version() {
	dpkg-query -W -f='${Version}' "$1" 2>/dev/null || true
}

package_installed() {
	[[ $(dpkg-query -W -f='${Status}' "$1" 2>/dev/null) == "install ok installed" ]]
}

# The base image already has python3 (cloud-init needs it), so venv and pip
# must be present as well as the right major.minor series.
report_packages() {
	echo "python packages: python3 $(apt_version python3), python3-pip $(apt_version python3-pip), python3-venv $(apt_version python3-venv)"
}

if [[ $(installed_series 2>/dev/null) == "$PYTHON_SERIES" ]] &&
	package_installed python3-venv &&
	package_installed python3-pip; then
	report_packages
	toolset_done python "$(installed_version)"
	exit 0
fi

if [[ ! -d /var/lib/apt/lists ]] || [[ -z $(ls -A /var/lib/apt/lists 2>/dev/null) ]]; then
	apt_get update --error-on=any
fi

apt_install --no-install-recommends python3 python3-venv python3-pip

series=$(installed_series)
version=$(installed_version)
if [[ $series != "$PYTHON_SERIES" ]]; then
	echo "python.sh: expected ${PYTHON_SERIES}.x, got ${version}" >&2
	exit 1
fi

report_packages
toolset_done python "$version"
