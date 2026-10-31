# CI

The `images` workflow runs on GitHub-hosted `ubuntu-24.04` runners for
every pull request and every push to `main`. `lint` runs on every run; the
jobs that build and boot an image run only when the change touches a file
they read: `ubuntu-24.04/`, `toolsets/`, `guest.env`, `railpack.env`,
`fetch-guest.sh`, `mise.toml`, `mise.lock` or `.github/workflows/images.yml`.
A release tag, the weekly run and a dispatch run them all:

- `lint` runs shellcheck over every script, validates the Windows
  template with Packer, and fails when `mise.lock`, `mise.packer.lock` or
  `toolsets/ci/mise.lock` is out of date. The Windows image itself is not
  built in CI.
- `ubuntu-24-04` builds the Ubuntu image with the pinned guest helper,
  then boots it twice with `ubuntu-24.04/boot-proof.sh`, once over
  QEMU's user-mode networking and once over passt, the two network modes
  the host agent uses. Each boot passes only if `toshi-guest.service` is
  active, the helper reports the pinned version, an outbound HTTPS request is
  answered, and the image's Railpack pin names a version whose CLI reports it
  and whose frontend archive holds the digest beside it. The job summary
  carries one line per boot, and
  except on a pull request the built `ubuntu-24.04.qcow2` is kept as a
  workflow artifact for a day; the run's logs are kept for seven.
- `build-fails-fast` breaks the guest's provisioning three ways (QEMU
  exits early, a cloud-init stage fails, a toolset download fails) and
  checks that `build.sh` stops within a minute of the failure in each
  case, instead of waiting for its build timeout. The toolset case skips
  the provisioning steps that download, so its time does not depend on
  the Ubuntu archive; its timeout is 220 seconds.

On a release tag, `publish` pushes the image from `ubuntu-24-04` (see
[Published images](published-images.md)).

The `guest-pin` workflow pins a guest helper that Toshi published: it runs
on that repository's `guest-published` dispatch, writes the version and
digest into `guest.env` and pushes the next release tag (see
[The guest helper](guest-helper.md)). The `pin-pr` workflow runs when
`images` or `container` finishes for a release tag: once both have published,
it opens the pull request in Toshi that moves Toshi's image pins to the new
digests, and when a tag's build fails it deletes a tag a guest pin created.
Both workflows need the GitHub App named by `TOSHI_CHAIN_APP_ID` and
`TOSHI_CHAIN_APP_PRIVATE_KEY`; without it each says "no credential, skipped"
and succeeds. `pin-pr` also runs on a dispatch, to rehearse a pin by hand.

The `container` workflow builds the container image and checks it with a
plain `docker run`; on a release tag it publishes the image once the
repository variable `CONTAINER_IMAGE` is set. See
[its README](../ubuntu-24.04-container/README.md#the-workflow).

The `kvm` workflow boots the stock Ubuntu cloud image under KVM once a
week, after the `images` build, and by hand: the image build's own boot
proof covers every change that can affect an image.

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