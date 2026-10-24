#!/usr/bin/env bash
# Creates a TUF-derived Rekor v2 config and attests an OCI digest's full SPDX SBOM.
# Container mode catalogs the registry image; predicate mode uses a built image's SBOM.
set -euo pipefail

mode=${1:?usage: attest-sbom.sh config FILE | container\|predicate REF SBOM IDENTITY CONFIG BUNDLE}
if [[ $mode == config ]]; then
	exec cosign signing-config create --with-default-rekor-v2 --out "${2:?config file}"
fi
if [[ $mode != container && $mode != predicate ]]; then
	echo "unknown SBOM source: $mode" >&2
	exit 2
fi

ref=${2:?image digest}
sbom=${3:?SPDX file}
identity=${4:?certificate identity regexp}
config=${5:?signing config}
bundle=${6:?bundle file}
registry_flags=()
registry=${ref%%/*}
if [[ $registry =~ ^127\.0\.0\.1:[0-9]+$ ]]; then
	# The publish rehearsal's registry is private to the job and serves plain HTTP.
	registry_flags=(--allow-http-registry)
	export SYFT_REGISTRY_INSECURE_USE_HTTP=true
fi
if [[ $mode == container ]]; then
	syft "registry:${ref}" -o "spdx-json=${sbom}"
fi
bytes=$(wc -c < "$sbom")
packages=$(jq '.packages | length' "$sbom")
echo "SPDX SBOM: ${bytes} bytes, ${packages} packages"

cosign attest --yes "${registry_flags[@]}" --signing-config "$config" \
	--type spdxjson --predicate "$sbom" --bundle "$bundle" "$ref"
# Keep the full verified predicate out of the log; the bundle retains it.
cosign verify-attestation --timeout 90s "${registry_flags[@]}" --check-claims=true --type spdxjson \
	--certificate-oidc-issuer https://token.actions.githubusercontent.com \
	--certificate-identity-regexp "$identity" "$ref" > "${bundle}.verified.json"
jq -c '.verificationMaterial.tlogEntries[] | {logIndex, kindVersion}' "$bundle"
