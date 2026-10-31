<p align="center">
  <img src="docs/assets/toshi-logo.svg" alt="Toshi" width="120">
</p>

<h1 align="center">toshi-images</h1>

<p align="center">Runner images as code for Toshi.</p>

<p align="center">
  <img alt="licence" src="https://img.shields.io/badge/licence-Apache--2.0-blue">
  <img alt="status" src="https://img.shields.io/badge/status-early-orange">
</p>

<p align="center">
  <a href="ubuntu-24.04/README.md">Get started</a> ·
  <a href="#documentation">Docs</a> ·
  <a href="https://github.com/toshicloud/toshi-images/issues">Issues</a>
</p>

The images Toshi runs CI jobs in, built from this repository: the
Ubuntu 24.04 and Windows Server 2025 VM images for the QEMU provider,
the Ubuntu container image for the container tier, and the cloud lanes
that turn them into AWS, GCP and Azure images, the host images of Linux
cloud pools among them. Build definitions and install scripts are
reviewed and versioned like code, and each build pins what it downloads.

> **Early stage.** CI builds and boot-proves the Ubuntu VM image on every
> change that can affect it, and each `v*` release tag publishes it; the
> Windows image is built on a KVM host and is not published, and there is
> no macOS image yet. Interfaces may change before 1.0.
> Compare the [release tags](https://github.com/toshicloud/toshi-images/tags) when upgrading.

## Quick start

On a Linux host with QEMU and the tools [its README](ubuntu-24.04/README.md) lists:

    mise install
    mise exec -- ubuntu-24.04/build.sh

That builds `ubuntu-24.04.qcow2` with the pinned guest helper;
[Install an image](docs/install.md) puts it where a host agent boots it.

## Documentation

- [The images](docs/images.md): what each directory builds, the shared toolsets, the Windows build
- VM and container images: [ubuntu-24.04](ubuntu-24.04/README.md) · [windows-2025](windows-2025/README.md) · [ubuntu-24.04-container](ubuntu-24.04-container/README.md) · [service-agent](service-agent/README.md)
- Cloud lanes: [AWS](aws/README.md) · [GCP](gcp/README.md) · [Azure](azure/README.md) · [Linux pool host](linux-pool-host/README.md)
- [The guest helper](docs/guest-helper.md): `toshi-guest`, its pin and how a new one is pinned
- [Install an image](docs/install.md): `install.sh` and the host agent's image entry
- [Published images](docs/published-images.md): pulling a release's image by digest, and its SBOM
- [CI](docs/ci.md): the workflows, the boot proof and running it yourself
- [Security](SECURITY.md) · [Licence](LICENSE)

## Status and support

Issues and questions go to [GitHub issues](https://github.com/toshicloud/toshi-images/issues).
Security reports follow [SECURITY.md](SECURITY.md).

Apache-2.0
