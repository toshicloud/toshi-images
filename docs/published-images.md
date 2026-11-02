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

## The image manifest

Each image the workflows publish carries a manifest beside it: a JSON
document that records what the image contains and the pins it was built
from. It is attached to the published digest as an OCI referrer of type
`application/vnd.toshi.image-manifest.v1+json`, and the same document is
attested with cosign under the type
`https://toshicloud.io/image-manifest/v1`.

Read the attached document with oras. `discover` lists what is attached to
the published digest; `pull` fetches the manifest itself:

```sh
oras discover --artifact-type application/vnd.toshi.image-manifest.v1+json \
  ghcr.io/toshicloud/toshi-images/ubuntu-24.04:v0.1.22
oras pull -o <dir> \
  ghcr.io/toshicloud/toshi-images/ubuntu-24.04@sha256:<manifest-digest>
```

Or verify the attestation, which carries the manifest from the publishing
workflow at its release tag:

```sh
cosign verify-attestation --type https://toshicloud.io/image-manifest/v1 \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  --certificate-identity-regexp '^https://github.com/toshicloud/(toshi-images|cloud-images)/\.github/workflows/.*@refs/tags/v.*$' \
  ghcr.io/toshicloud/toshi-images/ubuntu-24.04:v0.1.22
```

The signing identity is the publishing workflow of the repository that built the image. That repository is `toshicloud/toshi-images` and will also be `toshicloud/cloud-images`; the expression above verifies an image signed under either name, including images signed before a rename.

The document holds:

| Field | What it records |
|---|---|
| `image` | the image kind: `ubuntu-24.04`, `ubuntu-24.04-container`, `service-agent`, `windows-2025` or `linux-pool-host` |
| `built` | when and from which commit the build ran |
| `base` | the base image's name and digest, when the build starts from a base pinned by digest |
| `guest` | the guest helper the image carries: its version, its digest and the protocol range it supports |
| `packages` | every package the image has, by name and version |
| `toolsets` | each toolset's version, as the image itself reports it |
| `users` | local accounts, their groups, and what they can escalate to: `none`, `build-only` or `password-less` |
| `services` | the services the image starts at boot |
| `listening` | the TCP ports the image listens on, and the process holding each |
| `firewall` | the firewall the image boots with |
| `pins` | every pin in the files the build read, by file, key and resolved value |
| `image_digest` | the digest of the image file itself, where the build knows it |

### What the comparison compares

The compared digest is the SHA-256 of a manifest's canonical form: keys
sorted, with `built` and `image_digest` removed. Package names and versions,
toolsets, users, services, listening ports, the firewall, the pins, the guest
and the base all stay in.

Ubuntu apt installs use the dated archive snapshot in `APT_SNAPSHOT`, read
through the cache at `https://apt.toshicloud.com/ubuntu/<APT_SNAPSHOT>`, which
serves the files of Ubuntu's snapshot service unchanged. The date alone pins
the package set, and their package versions participate in the compared digest. The snapshot is
used only during the build; the shipped image has its stock sources. The
container builds first install a CA bundle from the stock archive to reach
the HTTPS cache, then replace it and its bootstrap dependencies with the
snapshot's versions. An unchanged
pin set is expected to produce the same compared digest, and the comparison
reports any other drift. The image file's own digest is recorded but never
compared: qcow2 compression, ext4 timestamps and machine-id churn, and the
Windows build date can still change the image bytes.

Canonical keeps snapshots for about two years. Advance `APT_SNAPSHOT` in
`toolsets/versions.env` before it ages out; the next nightly comparison
reports `pins changed` once.

The scheduled Ubuntu build, and the container and service-agent builds on a
release tag or a manual run, compare the fresh image with the last published
manifest: the newest release tag for the qcow2 artefact, the floating tag
for the two container images. A changed pin set is reported as such and
passes. An unchanged pin set with the same manifest digest passes. An
unchanged pin set with a different manifest digest fails, with a diff of the
two canonical forms showing what changed outside the pins.

The workflows compare the three images they build and publish —
`ubuntu-24.04`, `ubuntu-24.04-container` and `service-agent` — and the publish
jobs attest their manifests. `linux-pool-host` and
`windows-2025` write their manifests from the same scripts and the same
fragment shape, but neither image is built in CI: their manifests are proven
on their next manual build. The pool host is an AMI or a gallery image
version, and the Windows qcow2 is not published.
