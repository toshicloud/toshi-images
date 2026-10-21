# gcp

`build-image.sh` turns the [ubuntu-24.04](../ubuntu-24.04/) image into a
Compute Engine image for a GCP cloud host. No second image is built: the
same disk runs in a Toshi VM, on EC2 and on GCE. On GCE, systemd starts
`toshi-guest-gce.service` instead of the serial-port and EC2 units
(`ConditionVirtualization=google`), which reads the runner from the
instance metadata.

## Steps

1. Convert the qcow2 file to a raw disk named `disk.raw`, rounded up to
   whole GiB as GCE requires (`qemu-img convert`, `qemu-img resize`).
2. Pack it as a sparse, gzipped tar in the old GNU format
   (`tar --format=oldgnu -Sczf`), the only layout `images create` takes.
3. Upload it to a Cloud Storage bucket (`gcloud storage cp`).
4. Create the image from the upload (`gcloud compute images create
   --source-uri`): x86_64, in the family `toshi-ubuntu-2404`, with the
   guest OS features `VIRTIO_SCSI_MULTIQUEUE,UEFI_COMPATIBLE`, and the
   labels `toshi-image` and, when `GUEST_VERSION` is set,
   `toshi-guest-version`.
5. Delete the upload (`KEEP_UPLOAD=1` keeps it).
6. With `SHARE_WITH=<service account,...>`, grant each service account
   `roles/compute.imageUser` on the image, so tenants' launcher service
   accounts in other projects can boot it.

```sh
ubuntu-24.04/build.sh
PROJECT=my-image-project BUCKET=my-image-bucket \
  GUEST_VERSION="$(git describe --tags --always --dirty)" \
  SHARE_WITH=toshi-runners@acme-ci-123.iam.gserviceaccount.com \
  gcp/build-image.sh
```

`DRY_RUN=1` converts and packs the disk and prints the gcloud calls
without making them. The script needs the gcloud CLI, `qemu-img` and GNU
tar. It prints the image name; pass `family/toshi-ubuntu-2404` (or
`projects/<project>/global/images/family/toshi-ubuntu-2404` from another
project) to `toshi tenant hosts add --image`, so new builds are picked up.

Other settings: `IMAGE_NAME` (default `toshi-ubuntu-2404-<UTC time>`),
`IMAGE_FAMILY`, `STORAGE_LOCATION` (empty lets GCE choose the
multi-region nearest the bucket), `GUEST_OS_FEATURES`, `GCS_PREFIX`,
`IMAGE`, `WORK_DIR`.

Images are global: one image serves every zone.

## IAM

The identity that builds the image needs, in the image project:

- `roles/storage.objectAdmin` on the bucket (upload and delete);
- `roles/compute.storageAdmin` (create images and set their IAM policy).

GCE reads the upload with the identity of the caller, so no service agent
needs access to the bucket.

## What the image relies on at boot

- **Network.** cloud-init's datasources are `NoCloud` and `None`, so it
  falls back to DHCP on the first interface (virtio-net) and never reads
  the metadata itself; `toshi-guest` does that.
- **Disk.** The boot disk is a virtio-scsi persistent disk; cloud-init
  grows the partition and the file system to the disk size (64 GiB) on
  first boot.
- **Firmware.** Ubuntu's cloud image, which the Toshi image is built
  from, boots with BIOS or UEFI; marking it `UEFI_COMPATIBLE` lets GCE use
  UEFI. Step 5 of the proof runbook in docs/byoc-gcp.md checks that a real
  instance boots.
- **Guest agent.** Google's guest environment is not installed: Toshi needs
  neither OS Login nor SSH keys from the metadata, and its guest helper
  writes the one guest attribute it needs itself.
