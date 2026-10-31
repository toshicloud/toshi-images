# azure

`build-image.sh` turns the [ubuntu-24.04](../ubuntu-24.04/) image into an
Azure Compute Gallery image version for an Azure cloud host. No second
image is built: the same disk runs in a Toshi VM, on EC2, on GCE and on
Azure. On Azure, systemd starts `toshi-guest-azure.service` instead of the
serial-port unit (`ConditionVirtualization=microsoft`, and
`ConditionVirtualization=!microsoft` on `toshi-guest.service`), which reads
the runner from the instance metadata service.

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
