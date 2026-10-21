# Runner image toolsets

Bash scripts that install language toolchains during the Ubuntu runner image build.
Each script runs as root inside the guest from the read-only seed ISO; they must not
write next to themselves on the ISO.

| Script | Installs | Location |
|--------|----------|----------|
| `python.sh` | Python, venv, pip (Ubuntu's current noble-updates packages, checked as 3.12.x) | system |
| `node.sh` | Node.js LTS tarball | `/usr/local` |
| `go.sh` | Go toolchain tarball | `/usr/local/go` |
| `rust.sh` | rustup and a pinned stable toolchain for `runner` | `/home/runner/.cargo`, `/home/runner/.rustup` |
| `dotnet.sh` | .NET SDK tarball | `/usr/share/dotnet`, `dotnet` in `/usr/local/bin` |
| `mise.sh` | mise, and the CI tools in `ci/mise.toml` at the SHA256s in `ci/mise.lock` | `/usr/local/bin/mise`, `/usr/local/share/mise/installs` |
| `docker.sh` | Docker Engine, containerd and the buildx and compose CLI plugins | system; plugins in `/usr/libexec/docker/cli-plugins` |
| `java.sh` | Temurin JDK 17, 21 and 25 (17 default), on the alternatives system | `/usr/lib/jvm`, `update-alternatives` |
| `cmake.sh` | CMake tarball | `/usr/local` |
| `gh.sh` | GitHub CLI `.deb` | system |
| `yq.sh` | yq binary | `/usr/bin/yq` |
| `git-lfs.sh` | git-lfs tarball and system filters | `/usr/bin/git-lfs` |

Pins and download URLs live in `versions.env`. The `TOOLSETS` variable lists the
run order. Shared helpers are in `lib.sh`: `fetch_verified` downloads a file and
checks its checksum, and `retry` runs a command that downloads up to three times.
[Download limits](#download-limits) has the time limit of each try.

## Bumping a version

Change the version and its checksum in `versions.env` together from the upstream
release (Node `SHASUMS256.txt`, Go download page, rustup archive, Microsoft
release metadata for .NET, mise's `SHASUMS256.txt`). The toolsets added for
GitHub's ubuntu-24.04 set take their checksums from Docker's `dists/noble`
`Packages` index and the buildx, compose, gh, yq and git-lfs release checksum
files, Kitware's `cmake-<v>-SHA-256.txt` and Temurin's `.sha256.txt`. The CI tools follow
Toshi's `mise.toml`: copy it to `ci/mise.toml` and run `mise lock
--platform linux-x64` in `ci/`. Python has no exact pin: `PYTHON_SERIES` is the
major.minor checked against the interpreter, and apt installs whatever the noble-updates
packages currently are. The weekly `images` workflow rebuilds the image and fails if
a pin is wrong or stale.

## Build contract

When a script finishes successfully it prints one line to the serial console:

```text
TOOLSET <name> <version>
```

`<version>` is what the installed tool reports, not the pin string alone. The image
build greps the serial log for these lines (and later `TOOLSET env ok`) to verify
the toolsets.

A script that fails does not print that line. The image build runs each
script through `run_toolset` in `lib.sh`, which prints for a failed script:

```text
TOOLSET <name> <pinned version> failed: exit <status>: <the script's last line>
```

The first such line ends the image build
([`../ubuntu-24.04/README.md`](../ubuntu-24.04/README.md)).

`go.sh` adds where Go came from: `TOOLSET go <version> seed` when it installed the
`go.tar.gz` next to this directory in the seed, `download` when the seed had none
and it downloaded the tarball, `installed` when that version was already there.
Both tarballs are checked against `GO_SHA256`.

## Download limits

Every command here that downloads is tried three times, 10 and then 30 seconds
apart, and each try has a time limit: `TRY_MAX_TIME`, 300 seconds unless the
image build sets another (`limits.env` in the seed).

| Helper in `lib.sh` | Used for | What ends a try |
|--------------------|----------|-----------------|
| `fetch`, inside `fetch_verified` | every file a script downloads with curl | `TRY_MAX_TIME`; no connection within 30 seconds; fewer than 1024 bytes a second for 60 seconds |
| `apt_get`, `apt_install` | `apt-get update` and the download of an `apt-get install` | `TRY_MAX_TIME` (10 seconds more, exit 137, when the command ignores the signal) |
| `bounded` | `rustup-init`, which downloads the Rust toolchain, and `mise install`, which downloads the CI tools and the Go modules of the two `go:` tools | `TRY_MAX_TIME` (10 seconds more, exit 137, when the command ignores the signal) |

`fetch` prints `downloaded: <file> from <url>` when the file has arrived, and
`failed: <file> from <url> (curl exit <n>)` after the third failed try.
`apt_install` downloads with `apt-get install --download-only` under the limit
and then installs from apt's cache without one, so the limit does not end an
installation half way. `bounded` and `apt_get` end a try with `timeout`
(exit 124, or 137 when `-k` had to kill it). apt, rustup and mise have download timeouts of their own; these
are left as they are, and the limit here is `timeout`'s.

With the default limit, one download step fails at the latest after its
three tries and the two waits: 3 × 300 + 40 = 940 seconds for a file, and 970 seconds for a step under
`timeout`, which kills a command that ignores it 10 seconds later. A file
whose server accepts the connection and then sends nothing fails after about
3 × 60 + 40 = 220 seconds. A script has up to six download steps (`docker.sh`:
five files and one apt download), and each may use most of its limit and
still pass, so a whole script has no limit of its own below the build's.
