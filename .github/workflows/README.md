# Workflows

## Artifacts and retention

Each row describes one upload step. Sizes are classes, not fixed limits.
Actions artifacts are temporary build outputs; published images are stored
in the container registry instead.

| Artifact name | Producer workflow / job | Consumer | Size class | Retention | Why |
|---|---|---|---|---|---|
| `toshi-runner-ubuntu-24.04-oci` | `container.yml` / `build` | None; `publish` and `publish-rehearsal` restore the run's image from the Actions cache, not this artifact. | Multi-GB image archive | 1 day | Short-lived download of the smoke-tested container image. |
| `toshi-runner-ubuntu-24.04-digest` | `container.yml` / `publish-rehearsal` | None | Small digest file | 1 day | Records the registry round-trip result for the run. |
| `ubuntu-24.04-logs` | `images.yml` / `ubuntu-24-04` | None | Diagnostic text | 7 days | Keeps build, boot and failure details for diagnosis. |
| `ubuntu-24.04-qcow2` | `images.yml` / `ubuntu-24-04` | `images.yml` / `publish`, in the same release-tag run | Multi-GB disk image and SBOM | 1 day | Temporary handoff to publication; the released image lives in the registry. |
| `build-fails-fast-logs` | `images.yml` / `build-fails-fast` | None | Diagnostic text | 7 days | Keeps evidence from the deliberately failing build cases. |
| `kvm-probe-serial` | `kvm.yml` / `probe` | None | Diagnostic text | 7 days | Keeps the KVM boot probe's serial output. |

There are no later-run Actions-artifact downloads in these workflows. The
release-tag disk-image download names no other run, so it reads the artifact
produced by its own run. Container publication and its rehearsal use a
run-specific cache key independently of artifact retention.
