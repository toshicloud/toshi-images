# aws

Three image paths for EC2: `build-ami.sh`, which turns the Ubuntu image into
an AMI for a cloud host, `windows-2025.pkr.hcl`, which builds the
Windows AMI of a cloud pool ([below](#windows-2025pkrhcl)), and
`linux-pool-host.pkr.hcl`, which builds the AMI a Linux cloud pool's host
boots ([below](#linux-pool-hostpkrhcl)).

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

Other settings: `IMAGE` (default `$CACHE_DIR/out/ubuntu-24.04.qcow2`, with
`CACHE_DIR` defaulting to `${XDG_CACHE_HOME:-~/.cache}/toshi-images`),
`WORK_DIR` (default `$CACHE_DIR/out/aws`), `S3_PREFIX` (default
`toshi-images`), `AMI_NAME` (default `toshi-ubuntu-24.04-<UTC time>`),
`VMIMPORT_ROLE` (default `vmimport`), `IMPORT_TIMEOUT` (seconds to wait for
the snapshot import, default `3600`), and `QEMU_IMG` and `AWS`, the
programs it runs.

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

`build-windows-2025.sh [build|validate] [packer arguments]` (`-h` prints
its usage) needs `AWS_REGION`; `TOSHI_VERSION` (default: `git describe` of
this repository), `PACKER` and `OPENSSL` are optional. It passes the region
and the version to the template, and further arguments to Packer, for
example `-var subnet_id=subnet-...`. The template's other variables:
`instance_type` (default `c7i.2xlarge`), `root_volume_gib` (default `64`),
`subnet_id` (default empty: the default VPC), `source_ami_name` (default
`Windows_Server-2025-English-Full-Base-*`, the newest match) and
`guest_version` (the `toshi:guest-version` tag, default `none`).

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

## linux-pool-host.pkr.hcl

A Packer template that builds the AMI a Linux cloud pool's host boots:
Ubuntu 24.04 with the Toshi agent, QEMU, passt, OVMF, nftables and the
guest image `ubuntu-24.04`. The pool's user data writes
`/etc/toshi/enrollment-token` and `/etc/toshi/agent.toml` and runs
`systemctl enable --now toshi-agent.service`; the image holds everything
else.

```sh
AWS_REGION=eu-west-1 aws/build-linux-pool-host.sh
```

| File | What it is |
|---|---|
| `build-linux-pool-host.sh` | what an operator runs: gets the agent archive and checks its SHA-256, then runs `packer init` and `packer build`, and prints the AMI id, the region and the build time |
| `linux-pool-host.pkr.hcl` | the template: Canonical's Ubuntu 24.04 AMI of the pinned serial, a temporary instance reached over SSH, the provisioning, the AMI's tags and sharing, the manifest `linux-pool-host-ami.json` |
| [`../linux-pool-host/versions.env`](../linux-pool-host/versions.env) | the pins, shared with the Azure image: the Ubuntu serial, the agent release and its archive's SHA-256, the guest image that release names, ORAS, the packages |
| [`../linux-pool-host/provision.sh`](../linux-pool-host/provision.sh) | what Packer runs on the instance as root: `build aws`, then `seal aws`; `plan` prints what `build` installs |
| `linux-pool-host/iam-policy.json` | the permissions of the user or role that runs the build |

The provisioner and the pins are shared with every cloud; this template runs
`provision.sh build aws` and `provision.sh seal aws`, and
[linux-pool-host/](../linux-pool-host/README.md) describes what they do.

`build-linux-pool-host.sh [build|validate] [packer arguments]` (`-h` prints
its usage) needs `AWS_REGION`. Optional:

- `AGENT_TARBALL`: the agent archive `versions.env` names
  (`toshi_<version>_linux_amd64.tar.gz` of a Toshi release). Without it the
  script downloads it with the GitHub CLI from `AGENT_REPOSITORY`.
- `SHARE_WITH`: comma-separated account ids that may launch the AMI; the
  AMI and its snapshot are shared with them, as `build-ami.sh` does.
- `TOSHI_VERSION` (default: `git describe` of this repository), `PACKER`,
  `GH`.

### What the image holds

- The agent at `/usr/local/bin/toshi-agent` and its unit at
  `/etc/systemd/system/toshi-agent.service`, both from the release
  archive. The unit is installed and neither enabled nor started; there is
  no `/etc/toshi/agent.toml` until the user data writes it.
- The user and group `toshi-agent`, in the group `kvm`, and the directories
  `/etc/toshi` and `/var/lib/toshi-agent`, from the agent's lines of the
  release's `sysusers.d` and `tmpfiles.d` files, and the agent's image
  directory `/var/lib/toshi-agent/images` (the default under the
  `data_dir` the pool's user data sets).
- The host firewall `/etc/nftables.d/toshi-agent.nft`, included from
  `/etc/nftables.conf` and loaded by `nftables.service`, with
  `toshi-agent-pools` and `/etc/toshi/mining-pools.txt`, which fill its
  sets when the agent starts.
- `qemu-system-x86`, `qemu-utils`, `passt`, `ovmf` and `nftables` from the
  Ubuntu archive. The guest boots with SeaBIOS; OVMF is there for
  `toshi-agent doctor`.
- The guest image `ubuntu-24.04` as
  `/var/lib/toshi-agent/images/ubuntu-24.04.qcow2` with its line in
  `SHA256SUMS`, installed with [`install.sh`](../install.sh). The guest is
  the one the agent release names in its `deploy/images.env`; `provision.sh`
  stops when `versions.env` pins another, so the agent and the guest move
  together. The Actions runner is inside the guest, at
  `/opt/actions-runner`.

The host itself needs cgroup v2, which the build checks, and nested
virtualisation for `/dev/kvm`, which the build instance does not need: a
pool launches the AMI with `NestedVirtualization=enabled` on an instance
type that supports it (M7i, C7i and later Intel families). The seal clears
cloud-init's state and logs, the machine id, the SSH host keys and the
build's key.

The tags on the AMI and its snapshot: `Name`, `toshi:image`
(`linux-pool-host`), `toshi:version`, `toshi:agent-version`,
`toshi:guest-version`, `toshi:ubuntu-serial` and `toshi:built`.

### The agent release

`versions.env` pins Toshi v0.1.0-rc.3 and the guest image it names,
toshi-images v0.1.6. That release has no network helper
(`toshi-agent-netsets`), so its agent does not enforce the per-VM egress
sets; the firewall table and the cgroup sets the unit fills at start are
enforced. Move the pin to the first Toshi release after v0.1.0-rc.3 before
a production pool uses this AMI.

### IAM

The user or role that runs the build needs
[`linux-pool-host/iam-policy.json`](linux-pool-host/iam-policy.json): Packer
starts and stops the temporary instance, makes its key pair and security
group, creates the image and its snapshot, tags them and, with
`SHARE_WITH`, shares them. No bucket and no service role are involved.

### Checking it without an account

CI (`lint` in `.github/workflows/images.yml`) runs `packer validate` on the
template and `provision.sh plan`, which need no credentials and start
nothing:

```sh
AWS_REGION=eu-west-1 aws/build-linux-pool-host.sh validate
linux-pool-host/provision.sh plan
```

`validate` needs no agent archive: without `AGENT_TARBALL` it passes an
empty file in its place.
