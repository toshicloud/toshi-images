# aws

Two image paths for EC2: `build-ami.sh`, which turns the Ubuntu image into
an AMI for a cloud host, and `windows-2025.pkr.hcl`, which builds the
Windows AMI of a cloud pool ([below](#windows-2025pkrhcl)).

## build-ami.sh

`build-ami.sh` turns the [ubuntu-24.04](../ubuntu-24.04/) image into an EC2
AMI for a cloud host. No second image is built: the
same disk runs in a Toshi VM and on EC2. On EC2, systemd starts
`toshi-guest-userdata.service` instead of the serial-port unit
(`ConditionVirtualization=amazon`), which reads the runner from the
instance's user data.

## Steps

1. Convert the qcow2 file to a raw disk (`qemu-img convert`).
2. Upload it to an S3 bucket in the AMI's region.
3. Import it as an EBS snapshot (`aws ec2 import-snapshot`), which runs
   as the VM Import service role `vmimport`, and wait for the import.
4. Delete the upload (`KEEP_UPLOAD=1` keeps it).
5. Register the AMI: x86_64, HVM, ENA support, IMDSv2 only, root device
   `/dev/sda1` (gp3, deleted with the instance), as the ec2 launcher
   expects.
6. Tag the AMI and its snapshot (`toshi:image`, and `toshi:guest-version`
   when `GUEST_VERSION` is set).
7. With `SHARE_WITH=<account,...>`, share the AMI and its snapshot with
   the tenants' accounts, so each cloud host can launch it.

```sh
ubuntu-24.04/build.sh
AWS_PROFILE=toshi-images AWS_REGION=eu-central-1 BUCKET=my-image-bucket \
  GUEST_VERSION="$(git describe --tags --always --dirty)" \
  SHARE_WITH=123456789012 aws/build-ami.sh
```

`DRY_RUN=1` converts the disk and prints the AWS calls without making
them. The script needs the AWS CLI v2 and `qemu-img`. It prints the AMI ID
to pass to `toshi tenant hosts add --ami`. The AMI is built by hand today: no
workflow runs `build-ami.sh`.

An AMI is regional: build or copy one per region the cloud hosts use
(`aws ec2 copy-image`).

## IAM

The account that builds the AMI needs a bucket in the region and two
pieces of IAM.

**The `vmimport` service role**, which VM Import assumes to read the
upload. Its trust policy:

```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": { "Service": "vmie.amazonaws.com" },
    "Action": "sts:AssumeRole",
    "Condition": { "StringEquals": { "sts:Externalid": "vmimport" } }
  }]
}
```

Its permission policy (replace `my-image-bucket`):

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:GetBucketLocation", "s3:GetObject", "s3:ListBucket"],
      "Resource": ["arn:aws:s3:::my-image-bucket", "arn:aws:s3:::my-image-bucket/*"]
    },
    {
      "Effect": "Allow",
      "Action": [
        "ec2:ModifySnapshotAttribute", "ec2:CopySnapshot",
        "ec2:RegisterImage", "ec2:Describe*"
      ],
      "Resource": "*"
    }
  ]
}
```

**The user or role that runs the script:**

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["s3:PutObject", "s3:DeleteObject"],
      "Resource": "arn:aws:s3:::my-image-bucket/toshi-images/*"
    },
    {
      "Effect": "Allow",
      "Action": [
        "ec2:ImportSnapshot", "ec2:DescribeImportSnapshotTasks",
        "ec2:RegisterImage", "ec2:CreateTags",
        "ec2:ModifyImageAttribute", "ec2:ModifySnapshotAttribute"
      ],
      "Resource": "*"
    },
    {
      "Effect": "Allow",
      "Action": "iam:PassRole",
      "Resource": "arn:aws:iam::*:role/vmimport"
    }
  ]
}
```

These are build-time permissions in the operator's account. The control
plane never uses them, and the tenant's role (docs/byoc-aws.md) needs none
of them.

## What the image relies on at boot

- **Network.** The image's cloud-init datasources are `NoCloud` and
  `None`, so cloud-init falls back to DHCP on the first interface (ENA,
  `ens5`) and never reads the EC2 user data itself.
- **Disk.** The root disk is NVMe; cloud-init grows the partition and the
  file system to the volume size (64 GiB) on first boot.
- **Drivers.** Ubuntu's kernel carries the ENA and NVMe drivers.

## windows-2025.pkr.hcl

A Packer template that builds the Windows Server 2025 AMI a cloud pool
launches. Toshi's cloud pool documentation gives the operator's steps,
the tags and how a pool takes a new image.

```sh
AWS_REGION=eu-west-1 aws/build-windows-2025.sh
```

| File | What it is |
|---|---|
| `build-windows-2025.sh` | what an operator runs: makes the certificate of the build's WinRM connection, then runs `packer init` and `packer build` so that Packer accepts that certificate and no other |
| `windows-2025.pkr.hcl` | the template: Amazon's newest licence-included Windows Server 2025 base image by name, a temporary instance, the provisioning steps, the AMI's tags, the manifest `windows-2025-ami.json` |
| `windows-2025/winrm-userdata.txt` | the temporary instance's user data, a template Packer fills in: WinRM over HTTPS with the build's certificate |
| `windows-2025/provision.ps1` | the wrapper Packer runs on the instance, one step at a time |

Nothing is copied from [`windows-2025`](../windows-2025/): the
template uploads that directory as it is, and `provision.ps1` gives its
scripts what `build.sh` and `firstlogon.ps1` give them in the local build.

- `versions.env` and `SHA256SUMS` stay the only place a version or a
  checksum is written. The local build downloads the installers on the
  build host and puts them on a CD; here the instance downloads them and
  checks each against `SHA256SUMS`, then writes the same `tools.env`.
- `runner-images.ps1` and `tools.ps1` run unchanged. `Write-SerialLog`
  writes to Packer's output and to `C:\toshi\image-build.log`; the
  `TOOLSET <name> <version>` lines also go to `C:\toshi\toolsets.txt`,
  which stays in the image.
- `firstlogon.ps1` is not run: it installs the KVM drivers, the guest agent
  and its tasks, and activates the evaluation edition. The wrapper repeats
  its settings that are not about the hypervisor (power plan, lock screen,
  Defender, Server Manager) and creates the `runner` account with the
  automatic logon `autounattend.xml` gives the local image.
- `devdrive.ps1` runs once, unchanged, against a temporary virtual disk, to
  prove the image can format a Dev Drive. The AMI holds no work volume and
  no start-up task for it: the pool's user data formats each instance's
  own volume.
- No Sysprep. The last step resets EC2Launch (so an instance of the AMI
  runs its user data), removes the WinRM listener, firewall rule and
  certificate the user data added, and shuts Windows down.

### The WinRM certificate

Packer drives the temporary instance over WinRM as Administrator, with the
password EC2 generates. Its WinRM connection can check the server's
certificate against the trusted roots of the machine Packer runs on, or
check nothing (`winrm_insecure`); it has no setting for a certificate
authority or a fingerprint. The template used to check nothing, because
the instance made its own certificate at boot. Somebody on the network
between the build machine and the instance could then answer in its
place, receive the Administrator password, and read or change what the
build puts into the image every instance of the pool starts from.

The check is on now (`winrm_insecure = false`), and `build-windows-2025.sh`
gives it something to check:

1. it makes a key and a self-signed certificate for this one build, valid
   for two days and for the public DNS names of EC2 instances in the
   region (`*.eu-west-1.compute.amazonaws.com`), in a directory it removes
   when it exits;
2. the template writes both into the instance's user data, which installs
   them as the WinRM listener's certificate;
3. the script adds that one certificate to the roots Packer trusts
   (`SSL_CERT_DIR`), and the template makes Packer connect by the
   instance's public DNS name (`ssh_interface = "public_dns"`, which also
   picks the address of a WinRM connection).

A server that does not hold the build's key is refused before Packer
sends the password. The script prints the certificate's SHA-256
fingerprint.

What this does not cover, and what it needs:

- The key and its password are in the instance's user data while the
  build runs. Whoever may read instance attributes in the AWS account, and
  any process on the instance, can read them. Nothing trusts the
  certificate once the script has exited, and the last build step removes
  it and its key from the instance.
- The script runs on Linux (or a BSD) and refuses to start elsewhere:
  Packer, a Go program, does not read `SSL_CERT_DIR` on macOS or Windows.
  It needs OpenSSL, and was tried with 3.5.
- The instance needs a public DNS name: the VPC must have DNS hostnames
  enabled, as a default VPC has. Without one Packer has no name to connect
  to and the build fails at the connection.
- `packer build` on its own, without the script, stops at the two
  certificate variables; with values that are not a certificate Packer
  trusts, it fails at the connection.

### Checking it without an account

CI (`lint` in `.github/workflows/images.yml`) runs `packer fmt -check` and
`packer validate` on the template, which need no credentials and start
nothing.
`AWS_REGION=eu-west-1 aws/build-windows-2025.sh validate` runs
`packer validate` with a certificate made the way a build makes it.

`provision.ps1 -Step plan` runs under PowerShell 7 on any system. It writes
`tools.env` and prints the downloads without fetching them, so its reading
of `versions.env` and `SHA256SUMS` can be compared with `build.sh`'s:

```sh
mkdir -p /tmp/plan && cp windows-2025/versions.env windows-2025/SHA256SUMS /tmp/plan/
pwsh -NoProfile -File aws/windows-2025/provision.ps1 -Step plan -ConfigRoot /tmp/plan
```

Everything else needs Windows on EC2 and has not run yet: Windows
importing the certificate and its listener presenting it, Packer
connecting by the public DNS name and accepting it, the installs under an Administrator session instead of the
`runner` logon of the local build, the Dev Drive proof, the EC2Launch
reset, the seal and the AMI itself.
