# azure

`build-image.sh` turns the [ubuntu-24.04](../ubuntu-24.04/) image into an
Azure Compute Gallery image version for an Azure cloud host. No second
image is built: the same disk runs in a Toshi VM, on EC2, on GCE and on
Azure. On Azure, systemd starts `toshi-guest-azure.service` instead of the
serial-port unit (`ConditionVirtualization=microsoft`, and
`ConditionVirtualization=!microsoft` on `toshi-guest.service`), which reads
the runner from the instance metadata service.

The directory also holds a second, separate image: the host image of a
Linux cloud pool, built with Packer (see
[The Linux pool host image](#the-linux-pool-host-image)).

## Steps

1. Create the image definition `toshi-ubuntu-2404` in the gallery if it is
   missing (`az sig image-definition create`): Linux, x64, Hyper-V
   generation 2, OS state `Specialized`, security type `Standard`. An
   existing definition with other properties stops the script before it
   converts or uploads anything.
2. Convert the qcow2 file to a raw disk, round it up to a whole number of
   MiB, and convert that to a fixed-size VHD (`qemu-img convert -O vpc -o
   subformat=fixed,force_size=on`): Azure takes only fixed VHDs whose
   virtual size is a whole number of MiB. The script checks the result
   with `qemu-img info`.
3. Upload the VHD as a page blob to a container of a storage account
   (`az storage blob upload --type page`, signed in with `--auth-mode
   login`). All-zero pages are not sent, so the upload is about as large
   as the data on the disk.
4. Create the image version from the blob (`az sig image-version
   create --os-vhd-uri`), tagged `toshi-image` and, when `GUEST_VERSION` is
   set, `toshi-guest-version`, and replicated to `REGIONS`.
5. Delete the blob (`KEEP_UPLOAD=1` keeps it); the version holds its own
   copy.
6. With `SHARE_WITH=<object id,...>`, give each service principal the
   `Compute Gallery Image Reader` role on the image definition, so a
   launcher in another subscription of the tenant can boot it.
7. With `COMMUNITY=1`, share the gallery with everyone as a community
   gallery (`az sig share enable-community`), for workspaces in other
   tenants.

```sh
ubuntu-24.04/build.sh
SUBSCRIPTION=00000000-0000-0000-0000-000000000000 \
  RESOURCE_GROUP=toshi-images GALLERY=toshi_images STORAGE_ACCOUNT=toshiimages \
  IMAGE_VERSION=1.0.0 GUEST_VERSION="$(git describe --tags --always --dirty)" \
  azure/build-image.sh
```

`DRY_RUN=1` converts the disk and prints the az calls without making
them. The script needs the Azure CLI (signed in with `az login`) and
`qemu-img`. It prints the image version's resource ID, and with
`COMMUNITY=1` its community path
`/CommunityGalleries/<public name>/Images/toshi-ubuntu-2404/Versions/<version>`;
pass either to `toshi workspace host create --cloud azure --image`. A host
names one version, so a new build reaches a host when its `--image`
changes. The image is built by hand: no workflow runs `build-image.sh`.

Azure bills the uploaded blob while it is kept, and each version as
storage in every region it is replicated to, until the version is deleted
(`az sig image-version delete`).

Other settings: `IMAGE_VERSION` (three integers; by default
`<year>.<month and day>.<hours, minutes and seconds>` in UTC, such as
`2026.1031.140512`), `IMAGE_DEFINITION`, `PUBLISHER`, `OFFER` and `SKU`
(default `Toshi`, `toshi-ubuntu`, `24.04`; used only when the definition is
created), `REGIONS` (comma-separated, the gallery's location among them;
empty keeps the version in the gallery's location only), `STORAGE_RESOURCE_GROUP` (default `RESOURCE_GROUP`),
`CONTAINER` (default `toshi-images`), `BLOB_ENDPOINT` (default
`https://<account>.blob.core.windows.net`), `SHARE_ROLE`, `IMAGE`,
`WORK_DIR`, `CACHE_DIR` (default `${XDG_CACHE_HOME:-~/.cache}/toshi-images`),
and `QEMU_IMG` and `AZ`, the programs it runs. `-h` prints its usage.

The gallery and the storage account are created once, in one location:

```sh
az group create --name toshi-images --location westeurope
az storage account create --resource-group toshi-images --name toshiimages \
  --location westeurope --sku Standard_LRS --allow-blob-public-access false
az sig create --resource-group toshi-images --gallery-name toshi_images \
  --location westeurope
```

For a community gallery, create it with `--permissions Community
--publisher-uri <url> --publisher-email <address> --eula <url>
--public-name-prefix <prefix>` instead; Azure shows the publisher details
to everyone. When the gallery is in the workspace's own subscription, its
resource group carries the host's `toshi-external-id` tag, as Toshi's guide
to Azure cloud hosts (docs/byoc-azure.md) says.

## Roles

The identity that builds the image needs:

- `Storage Blob Data Contributor` on the storage account: creating the
  container and uploading and deleting the blob with `--auth-mode login`
  (a data role; owning the account is not enough);
- `Microsoft.Storage/storageAccounts/listKeys/action` on the storage
  account (in `Storage Account Contributor`): the gallery reads the VHD
  with it when it creates the version;
- `Compute Gallery Artifacts Publisher` on the gallery: creating the image
  definition and the version;
- with `SHARE_WITH`, `Microsoft.Authorization/roleAssignments/write` on the
  image definition (in `Role Based Access Control Administrator`);
- with `COMMUNITY=1`, `Microsoft.Compute/galleries/share/action`
  (`Compute Gallery Sharing Admin`, or the subscription's `Owner`;
  `Contributor` excludes it).

## What the image relies on at boot

- **Specialized.** The virtual machine has no OS profile, no
  administrator account and no SSH key, and Azure runs no provisioning
  step in it. No Azure guest agent is installed. cloud-init's datasources
  are `NoCloud` and `None`, so it never reads Azure's metadata and falls
  back to DHCP on the first interface (Hyper-V's synthetic network
  adapter); `toshi-guest` reads the user data itself.
- **Firmware.** Generation 2 boots with UEFI, which Ubuntu's cloud image
  supports. Security type `Standard` means no Secure Boot or virtual TPM;
  the definition sets it because new generation 2 definitions otherwise
  default to Trusted Launch, and Toshi's launcher asks for no security
  type.
- **Disk.** The OS disk is a Premium SSD made from the image; cloud-init
  grows the partition and the file system to the disk size on first boot.
- **Serial console.** `toshi-guest` writes `toshi-egress: <address>`, or
  `toshi-refused: <reason>` when it does not start the runner, to
  `/dev/ttyS0`, the first serial port, which Azure's boot diagnostics
  capture and Toshi reads.
- **Metadata.** `toshi-guest` blocks the instance metadata service
  (`169.254.169.254`) and the Azure host address (`168.63.129.16`) for
  every user but root and for every container on a Docker bridge, except
  DNS on port 53, before the runner starts. The image opens neither.

## The Linux pool host image

A Packer template that builds the Compute Gallery image version a Linux
cloud pool's host boots on Azure: Ubuntu 24.04 with the Toshi agent, QEMU,
passt, OVMF, nftables and the guest image `ubuntu-24.04`. The pool's user
data writes `/etc/toshi/enrollment-token` and `/etc/toshi/agent.toml` and
runs `systemctl enable --now toshi-host.service`; the image holds
everything else.

```sh
AZURE_SUBSCRIPTION_ID=<id> AZURE_GALLERY_RESOURCE_GROUP=<rg> \
  AZURE_GALLERY=<gallery> AZURE_LOCATION=westeurope IMAGE_VERSION=1.0.0 \
  azure/build-linux-pool-host.sh
```

The provisioner and the pins are shared with the AWS host AMI; see
[linux-pool-host/README.md](../linux-pool-host/README.md) for what they do
and for the contract table of both images.

| File | What it is |
|---|---|
| `build-linux-pool-host.sh` | what an operator runs: gets the agent archive and checks its SHA-256, ensures the gallery's image definition, runs `packer init` and `packer build`, and prints the version id and the build time |
| `linux-pool-host.pkr.hcl` | the template: Canonical's pinned Ubuntu 24.04 Azure image, a temporary build VM, the shared provisioning, the gallery destination, the manifest `linux-pool-host.json` |
| `ci.pkrvars.hcl` | placeholder values for `validate`, which needs no Azure account |

### linux-pool-host.pkr.hcl

The template builds one gallery image version. Where each property of it is
set:

| Property | Value | Set by |
|---|---|---|
| OS state | Generalized | the image definition (`--os-state Generalized`). The build ends with `waagent -force -deprovision+user`, and Packer generalizes and captures the image |
| Hyper-V generation | V2 | the image definition (`--hyper-v-generation V2`) |
| Architecture | x64 | the image definition (`--architecture x64`) |
| Security type | Standard | the template sets no `security_type`, which the plugin only accepts as TrustedLaunch or ConfidentialVM; the definition carries the `SecurityType=Standard` feature |
| Disk controllers | SCSI and NVMe | the definition's `DiskControllerTypes=SCSI,NVMe`: a v5 size exposes the OS disk as `/dev/sda1` on SCSI, a v6 size as `/dev/nvme0n1p1` on NVMe. Canonical's `/etc/fstab` mounts by label/UUID, so either boots |
| Replication | one replica, in `location` | `shared_image_gallery_destination` with `target_region { name = location }` and `Standard_LRS` |

The script creates the image definition when the gallery has none, and
refuses an existing one that is not Gen2, Generalized and x64 with
`SecurityType` Standard or absent:

```sh
az sig image-definition create -g <rg> --gallery-name <gallery> \
  --gallery-image-definition linux-pool-host \
  --publisher toshi --offer linux-pool-host --sku ubuntu-24.04 \
  --os-type Linux --os-state Generalized --hyper-v-generation V2 \
  --architecture x64 \
  --features "SecurityType=Standard DiskControllerTypes=SCSI,NVMe"
```

#### Prerequisites

- A Compute Gallery in `AZURE_GALLERY_RESOURCE_GROUP`, and an image
  definition named `linux-pool-host` (or `AZURE_IMAGE_NAME`). The script
  creates the definition when it is absent; it does not create the gallery.
- The identity that runs the build needs to create and delete a temporary
  resource group with a VM, a disk and a network in the subscription, or
  Contributor in `AZURE_BUILD_RESOURCE_GROUP` when that is set, and to
  write the image version and read and write the definition in the
  gallery's resource group. Packer deletes the temporary resource group
  when the build ends.
- Outbound network from the build VM, for the Ubuntu archive, the guest
  image registry and the agent archive.

#### What the script needs

`build` requires `AZURE_SUBSCRIPTION_ID`, `AZURE_GALLERY_RESOURCE_GROUP`,
`AZURE_GALLERY`, `AZURE_LOCATION` and `IMAGE_VERSION` (X.Y.Z).

Optional:

- `AZURE_BUILD_RESOURCE_GROUP`: an existing resource group to build in.
  Empty (the default) creates a temporary one in `AZURE_LOCATION`; the
  template passes the location only in that case, because the plugin
  refuses both.
- `AZURE_IMAGE_NAME` (default `linux-pool-host`), `VM_SIZE` (default
  `Standard_D4s_v5`; Dsv5 sizes support nested virtualisation, though the
  build runs no VM), `OS_DISK_SIZE_GB` (default 30, from 16 to 64).
- `AZURE_CLIENT_ID`, `AZURE_CLIENT_SECRET` and `AZURE_TENANT_ID`: a service
  principal. Set all three or none; with none, Packer uses the Azure CLI's
  login. The script passes them to Packer through `PKR_VAR_*`, so the
  secret stays out of the process list.
- `AGENT_TARBALL`: the agent archive `linux-pool-host/versions.env` pins.
  Without it the script downloads it with the GitHub CLI from
  `AGENT_REPOSITORY`.
- `TOSHI_VERSION` (default `git describe` of this repository), `PACKER`,
  `AZ`, `GH`.

Further arguments go to Packer, for example
`-var vm_size=Standard_D8s_v5`.

#### Checking the definition and the version

```sh
az sig image-definition show -g <rg> --gallery-name <gallery> \
  --gallery-image-definition linux-pool-host \
  --query '{gen:hyperVGeneration,os:osState,arch:architecture,features:features}'
az sig image-version show -g <rg> --gallery-name <gallery> \
  --gallery-image-definition linux-pool-host --gallery-image-version 1.0.0
```

The build prints the version's resource id and the `show` command when it
ends.

#### Checking it without an account

CI (`lint` in `.github/workflows/images.yml`) runs the template's
validation, which needs no Azure account and no agent archive:

```sh
azure/build-linux-pool-host.sh validate
```

It runs `packer init`, `packer fmt -check` and `packer validate` with
`ci.pkrvars.hcl`, then `provision.sh plan`. The build itself has not run
yet: it needs a subscription, the gallery and the rights above.

### 168.63.129.16

On the host, `walinuxagent` and cloud-init run as root and talk to Azure's
WireServer at `168.63.129.16`; systemd-resolved and DHCP use the same
address for DNS. A job's VM is not on that path: its traffic leaves as the
agent's user, and the agent's rule files allow only DNS to
`168.63.129.16`. The image adds no rule, route, sysctl or `waagent.conf`
change for the address. It keeps Canonical's `waagent.conf` and its
`/etc/resolv.conf` symlink to systemd-resolved's stub, and the build
checks both.
