# syntax=docker/dockerfile:1
# The Linux runner image as an OCI image, for the container tier:
# the ubuntu-24.04 image's packages, toolsets and runner, without its kernel,
# boot or cloud-init. Build context: the repository root (see README.md).
ARG BASE=ubuntu:24.04@sha256:534baea6a22c03a63003dbc8dbe78fe34bc0d7e595d9a9dc9834884ff530eb55
FROM ${BASE}

# The Playwright release whose Chromium libraries the image carries; build.sh
# reads it from versions.env.
ARG PLAYWRIGHT_VERSION
ENV DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

COPY toolsets /opt/build/toolsets
COPY railpack.env /opt/build/railpack.env
COPY ubuntu-24.04/versions.env /opt/build/ubuntu-versions.env
COPY ubuntu-24.04-container/cloud-exclude.txt /opt/build/cloud-exclude.txt

# The cloud image's user-space packages: the manifest published beside the
# pinned cloud image, minus its kernel, boot, firmware, hardware and init
# packages (cloud-exclude.txt). The container base has few of them, and jobs
# use some (gpg, envsubst). The manifest only names packages; apt checks each
# package's signature.
RUN set -eux; . /opt/build/toolsets/lib.sh; . /opt/build/ubuntu-versions.env; \
    apt_get update; \
    apt_install --no-install-recommends curl ca-certificates; \
    fetch "${UBUNTU_IMAGE_URL%.img}.manifest" /opt/build/cloud.manifest; \
    awk '{print $1}' /opt/build/cloud.manifest | sed 's/:amd64$//' | sort -u | \
        grep -v -E -f /opt/build/cloud-exclude.txt > /opt/build/cloud-packages.txt; \
    mapfile -t pkgs < /opt/build/cloud-packages.txt; \
    apt_install --no-install-recommends "${pkgs[@]}"

# The package lists and order of ubuntu-24.04/user-data. sudo and iproute2
# come with the cloud image but not with the container base.
RUN set -eux; . /opt/build/toolsets/lib.sh; \
    apt_install --no-install-recommends sudo iproute2 git curl jq build-essential unzip ca-certificates zip pkg-config clang python3-dev openssh-server polkitd; \
    apt_install --no-install-recommends libx11-xcb1; \
    apt_install --no-install-recommends qemu-system-x86 qemu-utils genisoimage; \
    groupadd -f docker; groupadd -f -r kvm; \
    useradd -m -u 1001 -s /bin/bash -G docker,kvm runner; \
    echo 'runner ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/runner; chmod 0440 /etc/sudoers.d/runner

# The runner archive also carries its bundled node for musl in
# externals/node20_alpine and node24_alpine, which only a musl runner loads;
# a Linux job never does. They come out in this RUN, so their bytes never
# reach a layer.
RUN set -eux; . /opt/build/toolsets/lib.sh; . /opt/build/ubuntu-versions.env; \
    fetch_verified "$RUNNER_URL" sha256 "$RUNNER_SHA256" /opt/build/runner.tar.gz; \
    mkdir -p /opt/actions-runner; tar -xzf /opt/build/runner.tar.gz -C /opt/actions-runner; rm /opt/build/runner.tar.gz; \
    rm -rf /opt/actions-runner/externals/node20_alpine /opt/actions-runner/externals/node24_alpine; \
    chown -R runner:runner /opt/actions-runner; \
    bounded /opt/actions-runner/bin/installdependencies.sh; \
    mkdir -p /home/runner/_work /cache; chown runner:runner /home/runner/_work /cache

# docker.sh starts the daemon to check the server version, and an image build
# has none: docker-nodaemon.sh is docker.sh up to that point, then a check of
# the installed package's version.
COPY ubuntu-24.04-container/docker-version.sh /opt/build/docker-version.sh
# The JDKs carry javac's sources in lib/src.zip, and CMake ships the
# interactive cmake-gui and ccmake; a job in this image uses none of them.
# They come out in the same RUN as the toolsets that install them.
RUN set -eux; cd /opt/build/toolsets; \
    grep -q '^# Rootful daemon' docker.sh; \
    sed '/^# Rootful daemon/,$d' docker.sh > docker-nodaemon.sh; \
    cat /opt/build/docker-version.sh >> docker-nodaemon.sh; \
    . ./lib.sh; set -a; . ./versions.env; set +a; \
    for t in $TOOLSETS; do [[ $t != docker ]] || t=docker-nodaemon; run_toolset "$t"; done; \
    rm -f /usr/lib/jvm/*/lib/src.zip /usr/local/bin/cmake-gui /usr/local/bin/ccmake; \
    printf '[global]\nbreak-system-packages = true\n' > /etc/pip.conf

# Chromium's shared libraries, from Playwright's own list for the release the
# jobs use. The VM image lacks them too.
RUN set -eux; set -a; . /etc/environment; set +a; \
    test -n "$PLAYWRIGHT_VERSION"; \
    cd /opt/build; npx --yes "playwright@${PLAYWRIGHT_VERSION}" install-deps chromium; \
    rm -rf /root/.npm

# The VM image's tool check, minus the docker daemon, which starts with the
# container (toshi-container-init).
RUN runuser -u runner -- env -i HOME=/home/runner bash --noprofile --norc -c 'set -a; . /etc/environment; set +a; for c in qemu-system-x86_64 qemu-img genisoimage python3 pip3 node npm npx corepack go rustc cargo dotnet docker mise pnpm task golangci-lint buf goreleaser protoc-gen-go protoc-gen-connect-go java javac jar cmake clang pkg-config git-lfs yq gh zip unzip curl jq make gcc; do command -v "$c" >/dev/null || { echo "missing $c"; exit 1; }; done; docker buildx version >/dev/null && docker compose version >/dev/null && echo "TOOLSET env ok"'

# The apt lists stay: a job that installs a package with sudo apt-get
# install needs them, and the VM image, which deletes them, fails there.
RUN rm -rf /opt/build

# No guest helper: the container provider bind-mounts the host's own, which
# ships with the agent.
COPY ubuntu-24.04-container/toshi-container-init /usr/local/bin/toshi-container-init
ENTRYPOINT ["/usr/local/bin/toshi-container-init"]
