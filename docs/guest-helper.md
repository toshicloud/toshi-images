# The guest helper

The Linux and Windows VM images carry `toshi-guest`, the helper through
which the host agent runs a job in a VM. Toshi's CI
publishes it as one OCI artefact that holds `toshi-guest` (linux/amd64) and
`toshi-guest.exe` (windows/amd64), and [`guest.env`](../guest.env) pins the
artefact these images carry by version and digest. Each VM image's
`build.sh` runs [`fetch-guest.sh`](../fetch-guest.sh), which pulls that digest
with [oras](https://oras.land), reads its version with `jq`, and checks that
the artefact and its Linux binary report the pinned version. Both must be on
the `PATH`; [`mise.toml`](../mise.toml) pins oras:

```sh
mise install
mise exec -- ubuntu-24.04/build.sh
```

To bake another guest, such as a local build of `toshi-guest`, set
`TOSHI_GUEST_BIN` (Linux) or `TOSHI_GUEST_EXE` (Windows) to it. A guest built
without a version reports `dev`, and the Linux build warns. The container
image has no guest; [its README](../ubuntu-24.04-container/README.md) says why.

A guest helper that Toshi publishes is pinned here by the `guest-pin`
workflow, without a person in the chain: Toshi's `guest` workflow sends a
`repository_dispatch` of type `guest-published` with the helper's version and
digest, `guest-pin` writes both into `guest.env` on `main` and pushes the next
`v0.1.N` tag, and the `pin-pr` workflow opens the pull request in Toshi that
pins the images those tag runs published. A repeated dispatch with the same
version and digest commits nothing and creates no tag; a failed build loses
its tag again, so only a release that built has one. The tag-triggered
publication is unchanged.