# windows-2025

Builds `windows-2025.qcow2`, the Windows runner image for the QEMU provider:
Windows Server 2025 Standard with Desktop Experience, installed unattended from
the evaluation ISO, with the GitHub Actions runner unpacked in
`C:\actions-runner` and `toshi-guest.exe` started at the logon of `runner` over
the `toshi.guest` virtio-serial port. The evaluation is activated during the
build, and a second blank disk given to the VM becomes a Dev Drive `D:` that
holds the runner's work directory. The build also installs the tools that
Rust projects' Windows jobs expect (see [Tools](#tools)).

| File | Purpose |
|------|---------|
| `build.sh` | downloads and verifies the inputs, runs the unattended install under QEMU, writes the image |
| `autounattend.xml` | Windows Setup answer file: partitions, drivers, Administrator and `runner` accounts, auto-logon |
| `firstlogon.ps1` | first-logon script: runner, helper and Dev Drive tasks, guest settings, activation, then shutdown |
| `devdrive.ps1` | startup script: formats a blank second disk as the Dev Drive `D:` and creates the runner's work folder on it |
| `tools.ps1` | first-logon step that installs the tools from the installers on the build's config CD |
| `versions.env` | pinned Windows media, virtio-win, runner and tool versions and URLs |
| `SHA256SUMS` | checksums we computed for the downloads, with the date and the file behind each link |

The evaluation media is for building and testing this image internally. It is
not a licence to run Windows runners for anyone else.

## Build locally

Run the build on a Linux x86_64 host with KVM, not in hosted CI: the install
takes much longer than the Linux build. You need `qemu-system-x86_64`, OVMF
(the 4M code and variable images), `genisoimage`, `curl` and `sha256sum`.
The build puts the guest helper pinned in [`guest.env`](../guest.env) into the
image, pulled with the tools in [`mise.toml`](../mise.toml) and `jq`, unless
`TOSHI_GUEST_EXE` points at another `toshi-guest.exe`. Read and write access
to `/dev/kvm` is expected, and the build VM needs outbound internet access to
activate Windows; set `TOSHI_QEMU_ACCEL=tcg` only for a very slow
fallback. The build needs about 50 GB of free disk: 10 GB of
downloads in `CACHE_DIR`, and under `OUT_DIR` a work directory of about
26 GB and the image of about 15 GB. The work directory stays after the
build, with its serial log, until the next build replaces it: remove it
once the image is installed.

The downloads come from the URLs in `versions.env`: the Windows Server
2025 evaluation ISO from Microsoft, the virtio-win ISO from the Fedora
project, the runner and most tools from their GitHub releases, and the
rest from their projects' download sites. A file already in `CACHE_DIR`
under its expected name whose checksum matches `SHA256SUMS` is not
downloaded again, so a host that keeps these files in another directory
sets `CACHE_DIR` to it.

On Debian or Ubuntu:

```sh
sudo apt-get install qemu-system-x86 qemu-utils ovmf genisoimage curl
```

From the extracted release archive (or the repository root):

```sh
WINDOWS_ADMIN_PASSWORD=... WINDOWS_RUNNER_PASSWORD=... windows-2025/build.sh
```

Both passwords are required and the build refuses to start without them. They
must meet Windows complexity rules: at least 8 characters, with three of
upper case, lower case, digits and symbols. They are rendered into a copy of
the answer file that lives only in the work directory and is deleted when the
build ends; neither password is written to Git or to the build log.

The build runs one QEMU VM at a time. It downloads and verifies the ISOs, boots
the installer, waits for the done marker from the first logon and for QEMU to
exit, then writes the disk as a compressed qcow2. It records how long the
unattended install took and the size of the compressed image.

With the downloads in place, a build on a 64-thread host took about 22
minutes: 15 for the unattended install and 6 to write the compressed
image. It prints each of its steps;
`step 8: wait for guest build marker` is the long one. With the default
`WORK_DIR`, this lists the guest's own steps:

```sh
grep -a TOSHI-IMAGE-BUILD ~/.cache/toshi-images/out/work-windows-2025/serial.log
```

They come one line each: the first appears once Windows Setup has
finished, a `tools-seconds` line follows each tool that has an
installer, and the last is `DONE`.

The archive's helper carries the release's version; one built from the tree
gets the version `git describe --tags --always --dirty` reports. The helper
sends it in its ready message. The first logon
activates the evaluation over the build VM's user-mode network and waits for
the activation; if Windows is not activated within five minutes the build
fails. The serial log records the activation's expiry date.

| Variable | Default | Meaning |
|----------|---------|---------|
| `WINDOWS_ADMIN_PASSWORD` | required | password of the local Administrator |
| `WINDOWS_RUNNER_PASSWORD` | required | password of `runner`, the auto-logon runner user |
| `CACHE_DIR` | `${XDG_CACHE_HOME:-~/.cache}/toshi-images` | verified downloads |
| `OUT_DIR` | `$CACHE_DIR/out` | the image |
| `WORK_DIR` | `$OUT_DIR/work-windows-2025` | build files, the answer-file copy and the serial log |
| `DISK_SIZE` | `64G` | virtual disk size of the image |
| `BUILD_CPUS` | `4` | CPUs of the build VM |
| `BUILD_MEMORY_MIB` | `8192` | memory of the build VM |
| `BUILD_TIMEOUT` | `7200` | seconds to wait for the install and first logon |
| `BOOT_KEY_SECONDS` | `10` | seconds the build sends Enter at boot to pass the boot-from-CD prompt; longer can reach Setup's Cancel button |
| `TOSHI_QEMU_ACCEL` | `kvm` | `kvm` or `tcg` |
| `OVMF_CODE`, `OVMF_VARS` | see `build.sh` | OVMF 4M firmware code and the variable-store template; each build gets a fresh copy of the variables, Secure Boot off |
| `TOSHI_GUEST_EXE` | the pinned guest, pulled into `$OUT_DIR/guest` | a prebuilt `toshi-guest.exe` for windows/amd64 |

If the build fails, the end of the build VM's serial log is printed; the whole
log is `$WORK_DIR/serial.log`. When the guest itself reports the failure, the
build prints its `TOSHI-IMAGE-BUILD: FAILED` line, which carries the failed
step's error, and the 80 serial lines before it instead of the end of the log.

## Agent entry

The image's entry in the host agent's `agent.toml`:

```toml
[provider.qemu.images.windows-2025]
os = "windows"
firmware = "uefi"
work_disk_gib = 64
idle_memory_mib = 3072
```

`idle_memory_mib` is the balloon target of a warm VM. Without it a warm VM
holds most or all of its size on the host, because the Windows balloon driver does not
report the pages it frees. A lease pays for it: the job starts with the target
plus 1 GiB and the guest grows back in steps as it runs low, which takes some
of its CPU while it grows.

## Dev Drive

When a VM started from the image has a second, blank disk of at least 50 GB,
the `toshi-devdrive` startup task brings it online, formats it as a Dev Drive
(ReFS) labelled `work`, mounts it as `D:` and creates `D:\_work`, writable
by `runner`, and `D:\Dev`. The control plane mints Windows runners with the
work folder `D:\_work` (`[github.work_folder]`), so jobs work on the Dev
Drive directly. A disk that already carries the `work` volume is only mounted again. The
helper's logon task waits for this step, at most two minutes, before it starts
the helper. Without a second disk nothing changes and jobs work on `C:`. The
step writes `TOSHI-DEVDRIVE:` lines with the outcome, the format time and the
volume state to the first serial port.

Images built before this change also make `C:\actions-runner\_work` a
junction to `D:\_work`. Do not bring one back: `actions/checkout` v6 and
later attach the job token through `includeIf.gitdir` on the workspace path,
Git resolves the junction and sees the repository under `D:\_work`, so the
condition never matches and the fetch on a private repository goes out
without the token.

## Settings from runner-images

Near the end of the first logon, `runner-images.ps1` runs two build scripts
copied unchanged from GitHub's
[actions/runner-images](https://github.com/actions/runner-images) (MIT):
Defender off with `C:\` and `D:\` excluded, telemetry, Windows Update,
SysMain and maintenance tasks off. It then runs .NET NGen once during the
build, with upstream's commands, instead of after each boot. None of this
installs software. The files, the pinned
upstream commit and how to update them are in
[`vendor/runner-images/`](vendor/runner-images/README.md). A failure in either
script fails the build; the serial log has a `runner-images-seconds` line for
each and a `runner-images-ngen` line with the exit code of each NGen step. Toshi's own scheduled tasks live in the `\toshi\` task folder,
because `Configure-System.ps1` disables every task in the root folder.

## Tools

`tools.ps1` installs these during the first logon, after the drivers and
before the cleanup:

| Tool | Version | Where | GitHub's `windows-2025` |
|------|---------|-------|-------------------------|
| PowerShell 7 (`pwsh`) | 7.6.6 | `C:\Program Files\PowerShell\7`, on `PATH` | 7.6 |
| Git for Windows, with Git LFS, Bash and the Unix tools | 2.56.0.2 | `C:\Program Files\Git`; `cmd`, `bin`, `mingw64\bin` and `usr\bin` on `PATH` | newest |
| Python, with pip and the `py` launcher | 3.12.10 | `C:\Python312` and its `Scripts`, on `PATH` | 3.12 is the default; also 3.10, 3.11, 3.13, 3.14 |
| Node.js, with npm | 24.21.0 | `C:\Program Files\nodejs`, on `PATH` | 22 and 24 |
| Go | 1.27.1 | `C:\Program Files\Go`, `bin` on `PATH` | 1.24 (the default) to 1.26 |
| rustup, with Rust 1.99.0 (the default) and 1.98.1, each with `clippy` and `rustfmt` | rustup 1.29.1 | `C:\Rust` (`RUSTUP_HOME`, `CARGO_HOME`), `C:\Rust\cargo\bin` on `PATH` | stable |
| .NET SDK 8 and 9 | 8.0.425, 9.0.318 | `C:\Program Files\dotnet`, on `PATH` | also 10 |
| Eclipse Temurin JDK 17 (the default) and 21 | 17.0.20.1+1, 21.0.12.1+1 | `C:\Program Files\Eclipse Adoptium`; `JAVA_HOME` (17), `JAVA_HOME_17_X64`, `JAVA_HOME_21_X64`; 17's `bin` on `PATH` | also 8, 11, 25 |
| Visual Studio 2022 Build Tools: the C++ desktop workload (MSVC x64/x86, MSBuild) and the Windows 11 SDK (10.0.26100) | 17.14.41 | `C:\Program Files (x86)\Microsoft Visual Studio`; find `link.exe` and `MSBuild.exe` with `vswhere` | Visual Studio Enterprise, every workload |
| CMake | 3.31.6 | `C:\Program Files\CMake`, `bin` on `PATH` | 3.31.6 |
| Ninja | 1.13.2 | `C:\Tools\bin`, on `PATH` | newest |
| 7-Zip | 26.04 | `C:\Program Files\7-Zip`, on `PATH` | newest |
| GitHub CLI (`gh`) | 2.102.0 | `C:\Program Files\GitHub CLI`, on `PATH` | newest |
| yq, jq | 4.54.1, 1.8.2 | `C:\Tools\bin`, on `PATH` | newest |
| NuGet CLI (`nuget`) | 7.9.0 | `C:\Tools\bin`, on `PATH` | newest |
| WiX Toolset (`wix`) | 4.0.6 | `C:\Tools\wix`, on `PATH` | not on GitHub's image |

Where GitHub's image pins a version (Python 3.12, CMake 3.31.6, PowerShell
7.6), this one has it. Elsewhere it follows the Ubuntu image's toolsets
(Node 24, Go 1.27, Rust 1.99, Temurin 17 as the default), and keeps Rust
1.98.1 for the workflows that pin it. `setup-python`, `setup-node`,
`setup-go` and `setup-java` download other versions into the runner's tool
cache, as they do on any self-hosted runner.

`build.sh` downloads every installer, checks it against `SHA256SUMS` and puts
it on the config CD with a `tools.env` naming the files, so a version bump
changes only `versions.env` and `SHA256SUMS`. Two installs still download
inside the VM: the Build Tools bootstrapper fetches its payload for the
pinned release, and rustup fetches the toolchains and checks them against
the channel manifest. Git is set with `core.longpaths`, `safe.directory '*'`
and `credential.interactive false`, so a job's credential setup is never met
by a prompt. Users may modify `C:\Rust`, so jobs can add toolchains and fill
the cargo registry. No compiler wrapper is set. The two rustup calls are
tried three times, 10 and then 30 seconds apart, with a
`tools <name> try N/3 failed` line in the serial log for each failed try;
the other installers run once. A failed install or a missing
tool executable afterwards fails the build; the serial log has a
`tools-seconds` line for each install. Then `tools.ps1` runs each tool
through the machine `PATH` a job gets and logs `TOOLSET <name> <version>`
from its own output, and `build.sh` fails unless every line carries the
version pinned in `versions.env` (Git LFS, pip and MSBuild come with Git,
Python and the Build Tools, so only their presence is checked).

OpenSSH Server, which ships with Windows Server 2025, is installed and its
`sshd` service disabled. `toshi-guest` starts it when the runner of a job
with debug minutes exits, before the host knows whether a
session is granted, with the session's key as the administrators'
authorized key and an `sshd_config` of its own that allows public key login
only. You log in as `runner`, into `cmd.exe`. The server runs until the host
destroys the VM. The `OpenSSH-Server-In-TCP` firewall rule Windows ships
covers the Private profile only and the VM's network is Public, so
`toshi-guest` sets the rule to every profile when it starts the server. A
missing `sshd.exe` fails the build; the serial log has a `TOOLSET sshd`
line.

The image has no GPU driver. The only Direct3D 12 adapter is WARP
("Microsoft Basic Render Driver"), the software adapter that ships with
Windows, so wgpu returns it on a plain adapter request without
`force_fallback_adapter`. Rendering to a texture and reading it back works on
it.

## Drivers

The image carries the virtio-win drivers for storage, network, serial and the
balloon device. The build uses virtio-win 0.1.302. If its storage driver
misbehaves, switch the pin to 0.1.271, the documented fallback, in
`versions.env` and `SHA256SUMS` together; this README records which version
the image uses (currently 0.1.302). The drivers are licensed under BSD, GPLv2 and Apache (see
`virtio-win_license.txt` on the ISO). The image carries them; the repository
does not.

## Update an input

Change the URL, the version (for the Windows media, `WINDOWS_ISO_FILE` and
`WINDOWS_ISO_BUILD`) and the checksum in `versions.env` and `SHA256SUMS`
together. Microsoft publishes no checksum for the evaluation ISO, so a media
refresh behind the same link fails the check; compute the new SHA256 from the
downloaded file, record the date with `date -u`, and bump the entry
deliberately. The evaluation expires 180 days after the build installs and
activates it, and every VM started from the image shares that clock, so
rebuild from newer media rather than keep one image for long.
