# images

Runner images as code: build definitions and install scripts for the
Linux and Windows VM images and a Linux container image, reviewed and versioned like the rest of the
code. There is no macOS image yet. Built images are never committed.

| Directory | Image | Built with |
|-----------|-------|------------|
| [`ubuntu-24.04`](ubuntu-24.04/README.md) | `ubuntu-24.04.qcow2` for the QEMU provider | bash, cloud-init and QEMU |
| [`windows-2025`](windows-2025/README.md) | `windows-2025.qcow2` for the QEMU provider | bash, an answer file and QEMU |
| [`ubuntu-24.04-container`](ubuntu-24.04-container/README.md) | an OCI image for the container tier; `image-container` builds it, and on a release tag publishes it to the image reference the repository variable `CONTAINER_IMAGE` names, which stays unset until the operator of the repository sets it | Docker |

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

The `image-linux` workflow builds the Linux image and boots it with the QEMU
provider.

The `image-container` workflow builds the container image and checks it
with a plain `docker run`; on a release tag it publishes the image once
the repository variable `CONTAINER_IMAGE` is set, and adds the image's
reference at its digest to the release. A dispatch can rehearse the
publish against a registry on the job's loopback address. See
[its README](ubuntu-24.04-container/README.md#the-workflow).

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

## Evidence from image-linux

The workflow's real-VM proof needs KVM. Each job checks for a writable
`/dev/kvm` first, and never falls back to the much slower TCG emulation.

Without KVM each job fails in that first step. It runs no build or test
step, sets the job output `kvm=false`, and posts the error "no KVM on this
runner, image proof skipped" (`ubuntu-24-04`) or "no KVM on this runner,
fail-fast check skipped" (`build-fails-fast`), as an annotation and in the
job summary. With KVM, the last step of each job adds "image proof ran on
KVM" (or "fail-fast check ran on KVM") to the summary once every step has
passed. Until 2026-10-18 `build-fails-fast` skipped its steps without KVM
and ended green, with that message as a warning.

A green `ubuntu-24-04` check therefore means that the image proof ran on
KVM, and a green `build-fails-fast` check that the fail-fast check ran
on KVM.

To check the no-KVM path, start the workflow by hand with the
`simulate_no_kvm` input set to `true`: both jobs then fail with their
message, and nothing re-runs them.
