# toshi-images

Runner images as code for Toshi:
build definitions and install scripts for the Linux and Windows VM images
and a Linux container image, reviewed and versioned like code. There is no macOS image yet. Built images are never committed.

| Directory | Image | Built with |
|-----------|-------|------------|
| [`ubuntu-24.04`](ubuntu-24.04/README.md) | `ubuntu-24.04.qcow2` for the QEMU provider | bash, cloud-init and QEMU |
| [`windows-2025`](windows-2025/README.md) | `windows-2025.qcow2` for the QEMU provider | bash, an answer file and QEMU |
| [`ubuntu-24.04-container`](ubuntu-24.04-container/README.md) | an OCI image for the container tier | Docker |

The [`toolsets/`](toolsets/) directory holds shared Bash install scripts and
`versions.env` pins for language toolchains (Python, Node, Go, Rust, .NET).
Each Ubuntu (and future Linux) image build copies that tree into the guest
and runs the scripts during provisioning.

Each image directory holds:

- `build.sh`, which builds the image on a suitable host;
- `versions.env`, which pins every input the build downloads, with its
  SHA256 (`ubuntu-24.04-container` reads `ubuntu-24.04`'s; its README
  lists what else it downloads);
- the files the build copies into the guest;
- a `README.md` that says what the build needs and how to run it.

The Ubuntu image's build is described in [its README](ubuntu-24.04/README.md).

The Windows Server 2025 image is built from the evaluation media, unattended,
on a Linux host with KVM rather than in hosted CI, because the install takes much
longer than the Linux build. The evaluation media is for internal build and
test only.
The build activates the evaluation, and a second blank disk becomes a Dev Drive for the work directory.
It also applies a few service, telemetry and .NET settings with scripts
copied unchanged from GitHub's runner-images (MIT); see
[`windows-2025/vendor/runner-images`](windows-2025/vendor/runner-images/README.md).

The QEMU provider boots an image the way its build expects only if the host
agent's configuration says how, in `[provider.qemu.images.<image>]`: the
guest OS, BIOS or UEFI firmware, and the size of a blank second disk. The
Linux image needs no entry: it boots with SeaBIOS from one disk. The Windows
image needs `os = "windows"`, `firmware = "uefi"` (OVMF, as in its build)
and a `work_disk_gib` that gives its Dev Drive the 50 GB it needs (64 in the
example); the provider gives
each VM its own UEFI variable store and work disk and includes both in its
snapshots. The Windows image's entry is in
[its README](windows-2025/README.md#agent-entry).

## The guest helper

The Linux and Windows VM images carry `toshi-guest`, the helper through
which the host agent runs a job in a VM. Toshi's CI
publishes it as one OCI artefact that holds `toshi-guest` (linux/amd64) and
`toshi-guest.exe` (windows/amd64), and [`guest.env`](guest.env) pins the
artefact these images carry by version and digest. Each VM image's
`build.sh` runs [`fetch-guest.sh`](fetch-guest.sh), which pulls that digest
with [oras](https://oras.land) and checks that the artefact and its Linux
binary report the pinned version. [`mise.toml`](mise.toml) pins oras:

```sh
mise install
mise exec -- ubuntu-24.04/build.sh
```

To bake another guest, such as a local build of `toshi-guest`, set
`TOSHI_GUEST_BIN` (Linux) or `TOSHI_GUEST_EXE` (Windows) to it. A guest built
without a version reports `dev`, and the Linux build warns. The container
image has no guest; [its README](ubuntu-24.04-container/README.md) says why.

## Install an image

`install.sh` installs a built image into the host agent's `image_dir`:

```sh
install.sh <image.qcow2> --image-dir <dir> [--name <name>] [--owner <user>:<group>] [--mode <mode>]
```

It checks that the file is a qcow2 image, copies it as `<name>.qcow2`
(by default the file's own name) with the directory's owner and mode 0640,
and writes `<sha256>  <name>.qcow2` into `<dir>/SHA256SUMS`. It refuses to
replace an installed image, because the agent's VMs and snapshots are built
on it, so a new build gets a new name.

## Published images

On a release tag (`v*`) the `images` workflow pushes the Ubuntu image that
passed its boot proof in that run to
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

## CI

The `images` workflow runs on GitHub-hosted `ubuntu-24.04` runners for
every pull request, every push to `main`, once a week and by hand:

- `lint` runs shellcheck over every script and validates the Windows
  template with Packer. The Windows image itself is not built in CI.
- `ubuntu-24-04` builds the Ubuntu image with the pinned guest helper,
  then boots it twice with `ubuntu-24.04/boot-proof.sh`, once over
  QEMU's user-mode networking and once over passt, the two network modes
  the host agent uses. Each boot passes only if `toshi-guest.service` is
  active, the helper reports the pinned version and an outbound HTTPS
  request is answered. The job summary carries one line per boot, and
  the built `ubuntu-24.04.qcow2` is kept as a workflow artifact for 7
  days.
- `build-fails-fast` breaks the guest's provisioning three ways (QEMU
  exits early, a cloud-init stage fails, a toolset download fails) and
  checks that `build.sh` stops within a minute of the failure in each
  case, instead of waiting for its build timeout. The toolset case skips
  the provisioning steps that download, so its time does not depend on
  the Ubuntu archive; its timeout is 220 seconds.

On a release tag, `publish` pushes the image from `ubuntu-24-04` (see
[Published images](#published-images)).

The `container` workflow builds the container image and checks it with a
plain `docker run`; on a release tag it publishes the image once the
repository variable `CONTAINER_IMAGE` is set. See
[its README](ubuntu-24.04-container/README.md#the-workflow).

The `kvm` workflow boots the stock Ubuntu cloud image under KVM, as a
quick check that the hosted runner gives jobs a usable `/dev/kvm`.

Every job that boots a VM makes `/dev/kvm` writable first and fails if it
cannot. QEMU runs with `accel=kvm` and never falls back to the much slower
TCG emulation, so a green check means the VMs ran under KVM.

To run the boot proof on a built image yourself, on a Linux host with KVM,
QEMU, genisoimage and passt:

```sh
ubuntu-24.04/boot-proof.sh <image.qcow2> user
ubuntu-24.04/boot-proof.sh <image.qcow2> passt
```

On Ubuntu 24.04, passt confined by its AppArmor profile gives the guest no
address, and the passt boot fails to resolve the proof URL. The
`ubuntu-24-04` job unloads the profile and allows unprivileged user
namespaces before that boot.
