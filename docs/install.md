# Install an image

`install.sh` installs a built image into the host agent's `image_dir`:

```sh
install.sh <image.qcow2> --image-dir <dir> [--name <name>] [--owner <user>:<group>] [--mode <mode>] [--replace]
```

It checks that the file is a qcow2 image, copies it as `<name>.qcow2`
(by default the file's own name) with the directory's owner and mode 0640,
and writes `<sha256>  <name>.qcow2` into `<dir>/SHA256SUMS`. It refuses to
replace an installed image unless `--replace` is given, because the agent's
VMs and snapshots are built on it, so a new build normally gets a new name.
`--replace` renames the new file over the old one: running VMs keep reading
the old file, and a warm pool notices within a minute.

## The host agent's image entry

The QEMU provider boots an image the way its build expects only if the host
agent's configuration says how, in `[provider.qemu.images.<image>]`: the
guest OS, BIOS or UEFI firmware, and the size of a blank second disk. The
Linux image needs no entry: it boots with SeaBIOS from one disk. The Windows
image needs `os = "windows"`, `firmware = "uefi"` (OVMF, as in its build)
and a `work_disk_gib` that gives its Dev Drive the 50 GB it needs (64 in the
example); the provider gives
each VM its own UEFI variable store and work disk and includes both in its
snapshots. The Windows image's entry is in
[its README](../windows-2025/README.md#agent-entry).