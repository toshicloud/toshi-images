# Contributing to toshi-images

Read this file, `README.md` and the README of every image directory your
change touches before your first change.

## Layout

1. **One directory per image.** Each holds its `build.sh`, its
   `versions.env` and a `README.md` that says what the build needs and how
   to run it. Shared install scripts live in `toolsets/`.
2. **Every input is pinned.** Every file a build downloads has its URL,
   version and SHA-256 in a `versions.env`, and a change moves all three
   together. A download whose SHA-256 differs from its pin fails the build.
3. **What comes from Toshi is a published artefact.** This repository
   builds without Toshi's source. The guest helper is the OCI artefact
   that `guest.env` pins by version and digest, and `fetch-guest.sh` pulls
   and checks it. A pin moves in a pull request of its own. The guest's
   protocol and the host agent belong to Toshi.
4. **Pinned tools.** `mise.toml` pins the scripts' tools and
   `mise.packer.toml` (with `MISE_ENV=packer`) adds Packer; each has its
   lock file. CI installs them with mise 2026.9.14, so refresh a lock file
   with that release (`mise lock`), or CI cannot read it.
5. **Licences.** Check the licence of every new dependency before adding
   it: nothing new under FSL, BSL, SSPL or other source-available terms.
   Prefer Apache-2.0, MIT or BSD. Files copied from another project keep
   their licence and say where they came from, as
   `windows-2025/vendor/runner-images/` does.

## Changes

- Commit messages follow [Conventional Commits](https://www.conventionalcommits.org).
  One logical change per commit.
- Every script passes `shellcheck`.
- A pull request runs these checks:
  - `images`: `lint` (shellcheck over every script, `packer validate` of
    the Windows template), `ubuntu-24-04` (builds the Ubuntu image and
    runs `ubuntu-24.04/boot-proof.sh` over user-mode networking and passt)
    and `build-fails-fast` (`build.sh` stops fast on three broken builds).
    The last two run when the change touches an image input
    (`ubuntu-24.04/`, `toolsets/`, `guest.env`, `fetch-guest.sh`,
    `mise.toml`, `mise.lock`, `.github/workflows/images.yml`); a release
    tag, the weekly run and a dispatch run them.
  - `container`, when the change touches the container recipe, the
    toolsets or the runner's pins: builds the container image and runs its
    smoke test.
  - `kvm`: weekly, after the weekly `images` build, and on dispatch: boots
    the stock Ubuntu cloud image under KVM. The image build's boot proof
    covers every change that can affect an image.
- Every job that boots a VM runs under KVM on a hosted runner and never
  falls back to TCG.
- Workflows use only the run's own `GITHUB_TOKEN`. This repository has no
  secrets.
- A release is a `v*` tag pushed by a maintainer. CI publishes images only
  from such a tag.
- Everything in this repository is public: no hostnames, IP addresses,
  account names, credentials or paths from a particular machine in code,
  docs, commit messages or pull requests.
