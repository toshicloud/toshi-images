# ubuntu-24.04-container

Builds the Linux runner image as an OCI image, for the container tier:
jobs in Sysbox containers on a tenant's own host without KVM. The agent's
container provider runs it.

It is made from the same inputs as
[`ubuntu-24.04`](../ubuntu-24.04/README.md): that image's package lists
in the same order, the [`toolsets/`](../toolsets/) scripts at the pins
in `toolsets/versions.env`, and the runner at the version and SHA256 in
`ubuntu-24.04/versions.env`. It has no kernel, boot loader or
cloud-init. It differs from the VM image in five ways:

- the cloud image's user-space packages, from the manifest published
  beside the pinned cloud image, minus those in `cloud-exclude.txt`
  (kernel, boot, firmware, hardware and init packages), because the
  container base lacks them;
- Chromium's shared libraries, from Playwright's list for the release
  `versions.env` pins (the one Toshi's `web/package.json` pins);
- apt's package lists stay in the image;
- `runner` keeps passwordless `sudo`;
- it has no guest helper: the container provider bind-mounts the host's
  `toshi-guest` (`guest_binary`), which ships with the agent, so an image
  outlives agent upgrades and the helper has one path.

Its pinned inputs are the base image's digest (in the `Dockerfile`), the
runner and toolsets with their SHA256s, and the Playwright release. The
cloud image's manifest is read unpinned, but it only names packages; those
packages, and the Chromium libraries Playwright lists, come from Ubuntu's
archive, signed by Ubuntu's archive key but not pinned to exact versions.

| File | Purpose |
|------|---------|
| `build.sh` | checks the base image's digest, sets the image's version label and runs `docker build` with the repository root as the context |
| `Dockerfile` | the recipe; the base image is pinned by digest |
| `cloud-exclude.txt` | patterns of cloud image packages the container leaves out |
| `docker-version.sh` | checks the Docker package's version, where the VM build checks the running daemon's |
| `toshi-container-init` | the entrypoint: starts dockerd with its data root on `/cache`, then runs the container's command |
| `smoke-test.sh` | checks a built image with a plain `docker run` (below) |
| `publish.sh` | pushes the built image to a registry, pulls it back by its digest and compares it |

Build it on any Linux host with Docker; it needs no KVM:

```sh
ubuntu-24.04-container/build.sh [tag]
```

The tag defaults to `toshi-runner:ubuntu-24.04`. `build.sh` labels the
image with its version (`org.opencontainers.image.version`):
`IMAGE_VERSION` when set, else in a checkout of this repository the
commit's `git describe --tags --always --dirty`, and in a checkout it
also labels it with the commit (`org.opencontainers.image.revision`).
It reads the Playwright release from `versions.env` unless
`PLAYWRIGHT_VERSION` is set. Outside a checkout, set `IMAGE_VERSION`. Run
the image under
`sysbox-runc` with a volume on `/cache`, where Docker keeps its data.
The entrypoint
gives dockerd that data root as the `--data-root` flag, not in
`/etc/docker/daemon.json`, so that Sysbox's own volume for Docker goes
to `/var/lib/docker`.
An image built on this one must not set `data-root` in `daemon.json`:
dockerd does not start when the file and the flag both set it.

## Smoke test

```sh
ubuntu-24.04-container/smoke-test.sh [image]
```

It runs the image as `runner` with a plain `docker run`, without Sysbox,
so the entrypoint and its dockerd do not start, and fails unless:

- the image has a version label other than `dev`;
- the runner reports `RUNNER_VERSION` (its archive's SHA256 is checked
  when the image is built, which keeps only what the archive held);
- each toolset in `TOOLSETS` reports the version `toolsets/versions.env`
  pins, read the way the toolset's script reads it;
- `sudo -n` works for `runner`;
- every command of the `Dockerfile`'s tool check, `gpg` and `envsubst`
  are there, and every package the `Dockerfile` installs by name is
  installed, so `cloud-exclude.txt` left nothing out that the recipe
  needs.

## The workflow

[`container.yml`](../.github/workflows/container.yml) runs on a pull
request or a push to main that changes the recipe, the toolsets or the
runner's pins; on a dispatch; and on every release tag (`v*`). Its
`build` job builds the image with `build.sh`, checks that the revision
label is the run's commit, runs the smoke test, saves the image as a
zstd-compressed tarball (`docker save`, which `docker load` reads as it
is) and uploads it as an artifact kept for 7 days. The tarball's SHA-256
and sizes go to the job summary.

A broken pin stops the build at the pin: `build.sh` refuses a
`Dockerfile` whose base has no digest before anything is fetched, and a
download whose SHA256 differs from its pin fails at once, with no retry.
A dispatch with `break_pin` set to `base-digest` or `toolset-sha256`
breaks one on purpose to show it.

The `publish` job runs only on a release tag, and only when the
repository variable `CONTAINER_IMAGE` is set to an image reference with
its registry host and without a tag or digest. It takes the tarball from
`build` through the cache, logs in to that registry host with the run's
own token (`packages: write`; no token is stored) and runs
[`publish.sh`](publish.sh). The script checks the tarball's SHA-256,
loads it, pushes it with the release's version and with `ubuntu-24.04`
as tags, pulls it back at the pushed digest and compares it with the
loaded image, and writes `<reference>@sha256:<digest>` to the job
summary: the reference a container-tier host pulls.
Otherwise `build` writes why publishing was skipped: `publish skipped:
not a release tag` on any run but a release tag, and `publish skipped:
CONTAINER_IMAGE not set` while the variable is unset.

A dispatch with `rehearse_publish` runs `publish.sh` on any ref against
a registry that the `publish-rehearsal` job starts on its own loopback
address, and uploads the digest file as an artifact; the script refuses
any other registry in a rehearsal. The rehearsal proves the tarball
check, the load, the tags, the push and the pull back by digest; only a
release tag proves the login and the push to the real registry.
