# Published images

On a release tag (`v*`), whether a maintainer pushed it or the `guest-pin`
workflow created it for a new guest helper, the `images` workflow pushes the
Ubuntu image that passed its boot proof in that run to
`ghcr.io/toshicloud/toshi-images/ubuntu-24.04`, tagged with the release, as
an OCI artefact that holds `ubuntu-24.04.qcow2`. The job summary gives the
reference at its digest and the qcow2's SHA-256. Pull it by digest with
oras, which checks the content against the digest:

```sh
oras pull -o <dir> ghcr.io/toshicloud/toshi-images/ubuntu-24.04@sha256:<digest>
./install.sh <dir>/ubuntu-24.04.qcow2 --image-dir <image_dir>
```

The Windows image is not published.

Published image digests carry an SPDX SBOM attestation. The SBOM is recorded
in Rekor v2 using signing services resolved from Sigstore's TUF metadata,
so it does not depend on a fixed log shard. Verification requires cosign
3.0.5 or later; use a current release to verify the attestation and its signed
timestamp against the publishing workflow's release-tag identity. Ordinary
image signatures and SLSA provenance retain their existing signing configuration.