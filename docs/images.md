# The images

Runner images as code for Toshi:
build definitions and install scripts for the Linux and Windows VM images
and a Linux container image, reviewed and versioned like code. There is no macOS image yet. Built images are never committed.

| Directory | Image | Built with |
|-----------|-------|------------|
| [`ubuntu-24.04`](../ubuntu-24.04/README.md) | `ubuntu-24.04.qcow2` for the QEMU provider | bash, cloud-init and QEMU |
| [`windows-2025`](../windows-2025/README.md) | `windows-2025.qcow2` for the QEMU provider | bash, an answer file and QEMU |
| [`ubuntu-24.04-container`](../ubuntu-24.04-container/README.md) | an OCI image for the container tier | Docker |
| [`service-agent`](../service-agent/README.md) | an OCI image with the agent CLIs and the intent-log library, for an Agent template's services | Docker and npm |
| [`aws`](../aws/README.md) | an AMI from `ubuntu-24.04.qcow2` (`build-ami.sh`), the Windows Server 2025 AMI of a cloud pool (`build-windows-2025.sh`), and the host AMI of a Linux cloud pool (`build-linux-pool-host.sh`) | bash and the AWS CLI; Packer, with OpenSSL for Windows |
| [`gcp`](../gcp/README.md) | a Compute Engine image from `ubuntu-24.04.qcow2` (`build-image.sh`) | bash and gcloud |
| [`azure`](../azure/README.md) | an Azure Compute Gallery image version from `ubuntu-24.04.qcow2` (`build-image.sh`), and the host image of a Linux cloud pool (`build-linux-pool-host.sh`) | bash and the Azure CLI; Packer for the pool host |

The [`toolsets/`](../toolsets/) directory holds shared Bash install scripts and
`versions.env` pins for the toolsets `TOOLSETS` lists there: Python, Node,
Go, Rust, .NET, mise, Docker, Railpack, Java, CMake, gh, yq and Git LFS.
Each Ubuntu (and future Linux) image build copies that tree into the guest
and runs the scripts during provisioning.

Each VM and container image directory holds:

- `build.sh`, which builds the image on a suitable host;
- `versions.env`, which pins every input the build downloads, with its
  SHA256 (`ubuntu-24.04-container` reads the runner from
  `ubuntu-24.04`'s, and its own pins the Playwright release; its README
  lists what else it downloads);
- the files the build copies into the guest;
- a `README.md` that says what the build needs and how to run it.

The Ubuntu image's build is described in [its README](../ubuntu-24.04/README.md).

The Windows Server 2025 image is built from the evaluation media, unattended,
on a Linux host with KVM rather than in hosted CI, because the install takes much
longer than the Linux build. The evaluation media is for internal build and
test only.
The build activates the evaluation, and a second blank disk becomes a Dev Drive for the work directory.
It also applies a few service, telemetry and .NET settings with scripts
copied unchanged from GitHub's runner-images (MIT); see
[`windows-2025/vendor/runner-images`](../windows-2025/vendor/runner-images/README.md).