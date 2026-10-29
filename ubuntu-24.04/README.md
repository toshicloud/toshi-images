# ubuntu-24.04

Builds `ubuntu-24.04.qcow2`, the Linux runner image for the QEMU provider:
the official Ubuntu 24.04 cloud image with the GitHub Actions runner in
`/opt/actions-runner`, pinned language toolsets on the path (Python, Node, Go,
Rust and .NET SDK) and Toshi's own CI tools (see [Tools](#tools)), and
`toshi-guest` running as a service on the
`toshi.guest` virtio-serial port. It carries a subset of GitHub's ubuntu-24.04 toolset
(see [Tools](#tools)), so most workflows written for GitHub's runner run
unchanged. The image also lets the runner user make and mount a tenant's
cache disk on `/cache` without root: a udev rule gives that user the disk
with serial `toshi-cache`, and an `/etc/fstab` entry with the `user` option
mounts it.
Docker's data root is `/cache/docker`, so images and BuildKit's cache stay
on that disk; dockerd starts from its socket at the first `docker` command,
and a polkit rule lets toshi-guest, as the runner user, stop it before the
unmount. The
runner user is in the `kvm` group, so in a pool with `nested_kvm` it opens
`/dev/kvm` without sudo. The
image also installs `passt`, the QEMU provider's default per-VM network:
a nested-KVM job that
boots VMs through the provider needs it on the `PATH`, or the agent refuses to
start.
A second `user` entry in `/etc/fstab` lets it mount a filler's host share,
the 9p tag `toshi-share`, on `/mnt/toshi-share`.

A workload reaches the services it is bound to by name. The drop-in
`/etc/systemd/resolved.conf.d/toshi-bindings.conf` sends the `toshi` and
`toshi.internal` zones to `toshi-guest`'s resolver on `127.84.0.1`. The
unit's `CAP_NET_BIND_SERVICE` lets the helper answer on port 53 and listen at
a bound channel's port. Guest port 7851 is reserved for the helper: the host
joins a bound connection there, so nothing else in the image may listen on
it. A helper that predates bindings ignores the drop-in, and every other
name resolves through the network's DNS as before.

| File | Purpose |
|------|---------|
| `build.sh` | downloads and verifies the inputs, boots the build VM, writes the image |
| `versions.env` | pinned Ubuntu release and runner version, with SHA256s |
| `user-data` | cloud-init configuration: provisioning and clean-up scripts |
| `meta-data` | cloud-init instance id and hostname for the build VM |
| `toshi-guest.service` | systemd unit for `toshi-guest` |

## Tools

Every pin is in [`../toolsets/versions.env`](../toolsets/versions.env), in
[`../railpack.env`](../railpack.env) for Railpack, or, for the CI tools, in
[`../toolsets/ci/mise.toml`](../toolsets/ci/mise.toml), a copy of the
repository's `mise.toml`.

| Tool | Version | Installed by |
|------|---------|--------------|
| Python | Ubuntu's noble-updates 3.12.x | `python.sh` |
| Node.js, npm, corepack | 24.22.1 | `node.sh` |
| Go | 1.27.3 | `go.sh` |
| Rust (rustup) | 1.99.0 (rustup 1.29.1) | `rust.sh` |
| .NET SDK | 10.0.401 | `dotnet.sh` |
| mise | 2026.10.18 | `mise.sh` |
| pnpm | 12.15.0 | `mise.sh` |
| task | 3.54.0 | `mise.sh` |
| golangci-lint | 2.14.0 | `mise.sh` |
| buf | 1.75.0 | `mise.sh` |
| goreleaser | 2.19.0 | `mise.sh` |
| protoc-gen-go | 1.36.11 | `mise.sh` |
| protoc-gen-connect-go | 1.21.0 | `mise.sh` |
| Railpack | v0.43.0 (every version the pin lists) | `railpack.sh` |

`railpack.sh` keeps each pinned Railpack release under
`/opt/toshi/railpack/<version>`: the CLI, the licence it ships with, and the
release's BuildKit frontend as an OCI archive (`frontend.tar`) with the digest
that archive holds (`frontend.digest`). `/opt/toshi/railpack/pinned` names the
version the image carries now; a version stays there when the pin moves, so an
image rebuilt from an older checkout still finds the frontend its pin names.
The boot proof checks that the pinned CLI reports its version and that
`frontend.digest` is the digest in the archive's `index.json`.

`mise.sh` installs the CI tools into mise's system directory,
`/usr/local/share/mise/installs`, where every mise looks. A job that runs
`mise install` in a checkout of Toshi therefore finds them all and
downloads nothing. The image's Go and Node are linked there. `task`,
`golangci-lint`, `buf`, `goreleaser` and the two protoc plugins are also
linked into `/usr/local/bin`. Plain `pnpm` stays corepack's, which follows a
project's `packageManager`.

### GitHub ubuntu-24.04 toolset

The image adds this subset of GitHub's ubuntu-24.04 toolset, one script
per tool; every pin is in
[`../toolsets/versions.env`](../toolsets/versions.env).

| Tool | Version | Source | Matches GitHub |
|------|---------|--------|----------------|
| Docker Engine | 28.0.4 (containerd.io 2.4.1-2, buildx 0.38.0, compose 2.38.2) | pinned by sha256 (Docker's `dists/noble` `Packages` index; buildx and compose release checksums) | yes |
| Eclipse Temurin JDK | 17.0.20.1+1 (default), 21.0.12.1+1, 25.0.4.1+1 | pinned by sha256 (Temurin's `.sha256.txt`) | GitHub has more versions (8 and 11) |
| CMake | 3.31.6 | pinned by sha256 (Kitware's `cmake-<v>-SHA-256.txt`) | yes |
| GitHub CLI | 2.102.0 | pinned by sha256 (the release checksum file) | yes |
| yq | 4.54.1 | pinned by sha256 (the release checksum file) | yes |
| git-lfs | 3.8.0 | pinned by sha256 (the release checksum file) | yes |
| clang | Ubuntu noble package (18) | Ubuntu noble package | GitHub has more versions (16 and 17) |
| zip, pkg-config, python3-dev | Ubuntu noble package | Ubuntu noble package | yes |
| pip | `break-system-packages = true` (`/etc/pip.conf`) | file written by the build | yes |

These Ubuntu installers are not vendored from `actions/runner-images`.
Upstream's installers resolve "latest" at build time and need their shared
helper module plus their Pester tests under pwsh, whereas the Windows image
vendors only configuration scripts, not installers. The scripts here instead
download the pinned releases above and verify each against its SHA-256.

## Build locally

You need a Linux x86_64 machine with `qemu-system-x86_64`, `qemu-img`,
`genisoimage`, `curl` and `sha256sum`, and read and write access to
`/dev/kvm` (or set `TOSHI_QEMU_ACCEL=tcg`, which is much slower). On Debian
or Ubuntu:

```sh
sudo apt-get install qemu-system-x86 qemu-utils genisoimage curl jq
```

Then, with the tools in [`mise.toml`](../mise.toml) installed:

```sh
mise exec -- ubuntu-24.04/build.sh
```

The image gets the guest helper pinned in [`guest.env`](../guest.env), or the
one `TOSHI_GUEST_BIN` names (see [The guest helper](../README.md#the-guest-helper)).
Either way the build prints the guest's version, the one the image's VMs
report, and warns when it is `dev` (built without a version).

The build boots one VM, which purges snapd, udisks2, fwupd and
modemmanager (their stop jobs held up shutdowns), installs base
packages, unpacks the runner, runs each script in [`../toolsets/`](../toolsets/) in the order given by
`toolsets/versions.env` (each toolset installs to the paths in
[`toolsets/README.md`](../toolsets/README.md)), enables services, cleans up
and powers off, then compresses its disk. It prints each line of the serial
log that begins with `TOOLSET ` or `downloaded: `, the image path, size and SHA256, the guest's version and
wall-clock build time at the end.

build.sh downloads three inputs on the machine it runs on, into `CACHE_DIR`:
the Ubuntu cloud image, the runner tarball and the Go tarball. It checks each
against its pinned SHA256 (the Go pin is in
[`../toolsets/versions.env`](../toolsets/versions.env), the other two in this
directory's `versions.env`), keeps a cached file whose SHA256 still matches,
and prints `cached:` or `downloaded:` for each. The Go tarball
is the official one, tried at dl.google.com and at go.dev in turn, twice
over; a completed download with another SHA256 fails the build. The runner
tarball and the Go tarball go to the build VM in the seed ISO. `go.sh`
checks the seed's `go.tar.gz` against the same SHA256 and installs it, so
the VM does not download Go: its line is `TOOLSET go <version> seed`, and
build.sh fails without that line. Run without a seed tarball, `go.sh`
downloads from go.dev as before and prints `download` instead. The other
toolsets are downloaded in the VM. In the `images` workflow the three
cached inputs are kept between runs, under a key made from both
`versions.env` files.

| Variable | Default | Meaning |
|----------|---------|---------|
| `TOSHI_GUEST_BIN` | the pinned guest, pulled into `$OUT_DIR/guest` | `toshi-guest` binary for linux/amd64 |
| `CACHE_DIR` | `${XDG_CACHE_HOME:-~/.cache}/toshi-images` | verified downloads |
| `OUT_DIR` | `$CACHE_DIR/out` | the image; build files and `serial.log` in `work/` |
| `TOSHI_QEMU_ACCEL` | `kvm` | `kvm` or `tcg` |
| `BUILD_TIMEOUT` | `1800` | seconds to wait for the build VM |
| `TRY_MAX_TIME` | `300` | seconds one try of a download in the build VM may take |
| `DISK_SIZE` | `24G` | virtual disk size of the image |
| `BUILD_CPUS` | `2` | CPUs of the build VM |
| `BUILD_MEMORY_MIB` | `4096` | memory of the build VM |
| `QEMU_SYSTEM`, `QEMU_IMG` | `qemu-system-x86_64`, `qemu-img` | binaries to use |

If the build fails, the end of the build VM's serial log is printed;
the whole log is `$OUT_DIR/work/serial.log`. When the guest's own provisioning fails, its `TOSHI-IMAGE-BUILD: FAILED` line names the script, the line and the command, with its exit status, and the build prints that line and the 80 serial lines before it, where the command's output is, instead of the end of the log, which by then holds only the shutdown. The line number counts from the script's `#!/bin/bash` line in `user-data`. A command that downloads is tried three times first, 10 and then 30 seconds apart, and each failed try is a `retry: try N/3 failed` line in the serial log that names the command; when a toolset script fails, those lines say which of its commands it was. Each try has a time limit, `TRY_MAX_TIME`: with the default, one download step in the VM fails at the latest 970 seconds after it began ([the toolsets' download limits](../toolsets/README.md#download-limits)). The first toolset script that fails ends the build: the VM prints `TOOLSET <name> <version> failed: ...` and runs no further script, and build.sh, which reads the serial log every 5 seconds, stops and prints that line. The limits of all steps add up to more than `BUILD_TIMEOUT`, so the build as a whole is bounded by `BUILD_TIMEOUT` as before. The build stops within seconds when QEMU exits or the serial log shows a cloud-init unit failing or a kernel panic, rather than waiting for `BUILD_TIMEOUT`.

## Try the image

Boot it once over each network mode the host agent uses, and check its
guest helper:

```sh
ubuntu-24.04/boot-proof.sh $HOME/.cache/toshi-images/out/ubuntu-24.04.qcow2 user
ubuntu-24.04/boot-proof.sh $HOME/.cache/toshi-images/out/ubuntu-24.04.qcow2 passt
```

## Update an input

When Toshi's `mise.toml` changes a CI tool, copy it to
`toolsets/ci/mise.toml` and refresh the lock file from that
directory with `mise lock --platform linux-x64`. The lock pins each
download's SHA256, and the build refuses a download that does not match.

Take the new serial's `ubuntu-24.04-server-cloudimg-amd64.img` line from
that release's `SHA256SUMS`, or the runner tarball's SHA256 from its release
page, and change the URL, version and checksum in `versions.env` together.
The `images` workflow proves the change on the pull request.
