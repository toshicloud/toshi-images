#!/usr/bin/env bash
# Builds the Windows Server 2025 AMI of a cloud pool with
# windows-2025.pkr.hcl (docs/cloud-pools.md, "Build the image"), and gives
# Packer the means to check who answers on the build instance's WinRM port.
#
# Packer's WinRM connection has two settings: check the server's certificate
# against the trusted roots of the machine it runs on, or check nothing. A
# certificate the instance makes for itself is in nobody's roots, so this
# script makes the key and the certificate first, for this one build:
#
#   1. a key and a self-signed certificate for the public DNS names of EC2
#      instances in the region, in a directory that is removed at exit;
#   2. both go to the instance in its user data, which installs them as its
#      WinRM listener's certificate (windows-2025/winrm-userdata.txt);
#   3. Packer runs with that one certificate added to its trusted roots
#      (SSL_CERT_DIR) and connects to the instance by its public DNS name.
#
# Somebody between this machine and the instance cannot present that
# certificate, so the connection fails instead of handing them the
# Administrator password and the build. See the README for what this does
# not cover.
set -euo pipefail

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

AWS_REGION="${AWS_REGION:-}"
TOSHI_VERSION="${TOSHI_VERSION:-}"
PACKER="${PACKER:-packer}"
OPENSSL="${OPENSSL:-openssl}"

usage() {
  cat <<USAGE
usage: AWS_REGION=<region> $0 [build|validate] [packer arguments]

build (the default) makes the AMI; validate only runs packer validate with
a certificate made the same way, and needs no AWS account.
Optional: TOSHI_VERSION (default: git describe), PACKER, OPENSSL. Further
arguments go to Packer, for example -var subnet_id=subnet-...
AWS credentials come from the usual AWS environment (AWS_PROFILE etc.).
USAGE
}

die() {
  echo "build-windows-2025: $*" >&2
  exit 1
}

action=build
case "${1:-}" in
  -h | --help) usage; exit 0 ;;
  build | validate) action=$1; shift ;;
esac

[[ -n "${AWS_REGION}" ]] || { usage >&2; die "AWS_REGION is required"; }
# Go does not read SSL_CERT_DIR on macOS or Windows: Packer would not
# trust the certificate there and the build would stop at the connection.
case "$(uname -s)" in
  Linux | FreeBSD | OpenBSD | NetBSD) ;;
  *) die "run this on Linux: on $(uname -s) Packer may not read SSL_CERT_DIR, which gives it the certificate" ;;
esac
command -v "${OPENSSL}" >/dev/null || die "${OPENSSL} not found"
command -v "${PACKER}" >/dev/null || die "${PACKER} not found"

if [[ -z "${TOSHI_VERSION}" ]]; then
  TOSHI_VERSION=$(git -C "${SCRIPT_DIR}" describe --tags --always --dirty)
fi

# The public DNS name of an instance: ec2-<address>.<this>.
case "${AWS_REGION}" in
  us-east-1) dns_suffix="compute-1.amazonaws.com" ;;
  cn-*) dns_suffix="${AWS_REGION}.compute.amazonaws.com.cn" ;;
  *) dns_suffix="${AWS_REGION}.compute.amazonaws.com" ;;
esac

work=$(mktemp -d)
cleanup() {
  rm -rf "${work}"
}
trap cleanup EXIT
umask 077
mkdir "${work}/trust"

# Two days: longer than any build, short enough that a copy is soon useless.
"${OPENSSL}" req -x509 -newkey rsa:2048 -nodes -sha256 -days 2 \
  -keyout "${work}/key.pem" -out "${work}/trust/toshi-image-build.pem" \
  -subj "/CN=toshi-image-build" \
  -addext "subjectAltName=DNS:*.${dns_suffix}" \
  -addext "basicConstraints=critical,CA:FALSE" \
  -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
  -addext "extendedKeyUsage=serverAuth" 2>/dev/null ||
  die "could not make the certificate"
password=$("${OPENSSL}" rand -hex 24)
"${OPENSSL}" pkcs12 -export -keyex -name toshi-image-build \
  -inkey "${work}/key.pem" -in "${work}/trust/toshi-image-build.pem" \
  -out "${work}/cert.pfx" -passout "pass:${password}" ||
  die "could not make the PKCS #12 file"
pfx=$("${OPENSSL}" base64 -A -in "${work}/cert.pfx")

fingerprint=$("${OPENSSL}" x509 -in "${work}/trust/toshi-image-build.pem" -noout -fingerprint -sha256)
echo "WinRM certificate for *.${dns_suffix}: ${fingerprint#*=}"

# The certificate is added to the roots Packer already trusts for its calls
# to AWS: the default bundle file is still read, and so are these
# directories.
export SSL_CERT_DIR="${work}/trust:${SSL_CERT_DIR:-/etc/ssl/certs:/etc/pki/tls/certs}"
# Sensitive values reach Packer in its environment, not in its arguments.
export PKR_VAR_winrm_certificate_pfx="${pfx}"
export PKR_VAR_winrm_certificate_password="${password}"

template="${SCRIPT_DIR}/windows-2025.pkr.hcl"
"${PACKER}" init "${template}"
"${PACKER}" "${action}" -var "region=${AWS_REGION}" -var "toshi_version=${TOSHI_VERSION}" "$@" "${template}"
