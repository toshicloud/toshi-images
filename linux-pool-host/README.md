# linux-pool-host

The provisioning and the pins of the Linux cloud pool host images: the AMI
that [`aws/linux-pool-host.pkr.hcl`](../aws/linux-pool-host.pkr.hcl)
builds and the Compute Gallery image that `azure/linux-pool-host.pkr.hcl`
builds. Each template uploads `provision.sh`, `versions.env`, `install.sh`
and the agent archive to the build instance and runs the same steps on it.

| File | What it is |
|---|---|
| `provision.sh` | what the template runs on the build instance as root: `build <cloud>`, then `seal <cloud>`; `plan` prints what `build` installs |
| `versions.env` | the pins: the Ubuntu image, the agent release and its archive's SHA-256, the guest image that release names, ORAS, the packages |
| [`../install.sh`](../install.sh) | installs the guest qcow2 into the agent's image directory |

## The provisioner

```sh
provision.sh plan [dir]
provision.sh build <aws|azure> [dir]
provision.sh seal <aws|azure> [dir]
```

`plan` needs no root, no network and no Azure or AWS account, which is why
CI runs it on every change. `build` and `seal` run as root on the build
instance; `<dir>` holds `versions.env`, `install.sh` and the agent archive
named in `TOSHI_AGENT_ASSET`, which the template uploads there.

`build` is the same on both clouds:

- it waits for cloud-init to finish before changing anything;
- it installs `HOST_PACKAGES` from the Ubuntu archive;
- it installs passt from the pinned Ubuntu 26.04 package `PASST_URL`,
  checks its SHA-256, holds it, and stops unless its `--help` lists
  `--dns-host` and `--map-host-loopback`: Ubuntu 24.04's passt has neither;
- it unpacks the agent archive, checks its SHA-256, refuses it when its
  `deploy/images.env` names another guest, and installs the agent, its
  unit (neither enabled nor started), its `sysusers.d` and `tmpfiles.d`
  lines, `/etc/toshi/mining-pools.txt`, the agent's firewall table and
  the network helper `toshi-host-netsets`, whose socket it enables;
- it pulls the guest image by digest with ORAS, checks its SHA-256 and
  installs it with `install.sh`;
- it checks that QEMU, `qemu-img`, passt, nft and OVMF are in place;
- on Azure it also reads the base image's `datasource_list`, its
  `waagent.conf` settings and its `resolv.conf` symlink, and refuses a base
  image that differs from Canonical's.

`seal` differs by cloud. On AWS it clears cloud-init's state and logs, the
machine id, the SSH host keys and the build's key. On Azure it clears
cloud-init's state and logs and the machine id and leaves the build's user
and keys to the template's last step, `waagent -deprovision+user`.

## The pins

`versions.env` holds every input with its SHA-256. The agent and the guest
image move together: `provision.sh` refuses a guest that the agent release
does not name. `UBUNTU_SERIAL` is the serial of Canonical's Ubuntu 24.04
AMI, pinned exactly and moved on its own, not with the guest's serial;
`AZURE_UBUNTU_VERSION` is Canonical's Azure image, a different string from
the AWS AMI name. `PASST_URL` is a passt package from the Ubuntu 26.04
archive, which installs on Ubuntu 24.04 unchanged; passt is licensed
GPL-2.0-or-later, with some files under BSD-3-Clause, and the image carries
Ubuntu's binary package as published.

## The contract

Toshi's Linux cloud pool documentation gives the image contract. One row
per line of it, for both clouds.

| Contract line | Where the image meets it | Checked by |
|---|---|---|
| cloud-init and systemd | Canonical's Ubuntu 24.04 image, whose init is systemd; on Azure the image keeps the `Azure` datasource in `/etc/cloud/cloud.cfg.d/` | `build` runs `cloud-init status --wait` and stops on a failure; `build azure` reads the datasource list and refuses one that does not name Azure |
| Root file system on `/dev/sda1` (AWS) | AWS: the template pins the root volume to `/dev/sda1`, where Canonical's AMI boots it. Azure: Canonical's OS disk is `/dev/sda1` on a SCSI controller on the v5 sizes and `/dev/nvme0n1p1` on NVMe on the v6 sizes; Canonical's `/etc/fstab` mounts by label/UUID, so the device name does not matter | AWS: the template's `launch_block_device_mappings`, and the build boots the AMI. Azure: the image definition's `DiskControllerTypes=SCSI,NVMe`, and Packer boots the base image; `az sig image-version show` prints the version |
| `/usr/local/bin/toshi-host` and `toshi-host.service` installed not started, reading `/etc/toshi/agent.toml`, user and group `toshi-host` in `kvm`, state directory `/var/lib/toshi-host` | `install_agent`: the binary and the unit from the release archive; the agent's lines of the release's `sysusers.d` and `tmpfiles.d`; `/etc/toshi` | `install_agent` refuses a unit that does not run the binary, fails unless `toshi-host` is in `kvm` and the image directory exists, and fails if the unit is enabled; it runs `toshi-host version` |
| `qemu-system-x86_64`, `qemu-img`, passt and firmware, with `/dev/kvm` from nested virtualisation on the instance | `HOST_PACKAGES` (QEMU, `qemu-utils`, OVMF, nftables), passt from `PASST_URL`, and OVMF's `OVMF_CODE_4M.fd`. `/dev/kvm` is not in the image: the pool launches the image on an instance that nests virtualisation, and the agent's user is in `kvm` | `install_passt` checks passt's version and both options; `build` checks the four commands and the OVMF file. The build instance needs no `/dev/kvm`; the instance type and its nested-virtualisation setting are the pool's, not the image's |
| cgroup v2 with delegation, and nft | `build` refuses a host without cgroup v2, whose controllers the agent delegates to its VMs. `install_firewall` installs the release's `/etc/nftables.d/toshi-host.nft` byte for byte, includes it from `/etc/nftables.conf` and enables `nftables.service`; it installs the release's `toshi-host-netsets.socket` and `toshi-host-netsets.service` and enables the socket, so the helper writes each VM's sets when the agent asks | the cgroup check, `cmp` against the release's table, `nft -c -f /etc/nftables.conf` and `systemctl enable nftables.service` |
| the guest `ubuntu-24.04` in the agent's image directory, with the Actions runner at `/opt/actions-runner` inside the guest | `install_guest` pulls the pinned `GUEST_REF@GUEST_DIGEST` with ORAS, checks the qcow2's SHA-256 and installs it as `/var/lib/toshi-host/data/images/ubuntu-24.04.qcow2` with `install.sh`. The Actions runner is inside the guest image, from the guest's own build | the digest pull, the SHA-256 check, `install.sh`'s qcow2 check, and `install_agent`'s refusal when the agent release names another guest |
| User data writes `/etc/toshi/enrollment-token` (`toshi-host:toshi-host` 0600) and `/etc/toshi/agent.toml` (root 0644) and runs `systemctl enable --now toshi-host.service` | the pool's step, not the image's: the image leaves both files absent and the unit disabled, and the agent's `sysusers.d` and `tmpfiles.d` lines make `toshi-host` the owner of `/etc/toshi` | `install_agent` fails if the unit is enabled. The write and the enable are Toshi's user data, outside this repository |
| Azure: a Compute Gallery image version that is x64, Gen2, Generalized, with the Azure datasource, and a VM security type of Standard | `azure/linux-pool-host.pkr.hcl` and `azure/build-linux-pool-host.sh`: the definition is created as V2, Generalized, x64 and `SecurityType=Standard DiskControllerTypes=SCSI,NVMe`; the template sets no `security_type`, so the build VM and the pool's VMs are Standard; the gallery destination writes the version with `Standard_LRS` | `build azure` refuses an existing definition unless it is Gen2, Generalized and x64 with `SecurityType` Standard or absent; after the build it prints the version and `az sig image-version show` |
