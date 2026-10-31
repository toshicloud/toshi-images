# syntax=docker/dockerfile:1
# The service agent image: Node, Python, the agent CLIs with their ACP
# adapters, and the intent-log library (service-agent/README.md, "The image").
# Build context: the repository root (see build.sh). The base image is pinned
# by digest; build.sh refuses a Dockerfile whose ARG BASE has none.
ARG BASE=ubuntu:24.04@sha256:534baea6a22c03a63003dbc8dbe78fe34bc0d7e595d9a9dc9834884ff530eb55
FROM ${BASE}

ENV DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# The shared fetch helper and the pins. toolsets/lib.sh is the repository's
# own downloader: fetch_verified fails at once on a SHA256 mismatch.
COPY toolsets/lib.sh /opt/build/lib.sh
COPY service-agent/versions.env /opt/build/versions.env

# Node and Python, from the pins. apt installs the CA bundle and curl they are
# fetched with, git and ripgrep for the CLIs and their status commands; curl
# comes out again in the same layer once the downloads are done.
RUN set -eux; . /opt/build/lib.sh; . /opt/build/versions.env; \
    apt_get update; \
    apt_install --no-install-recommends ca-certificates curl git ripgrep xz-utils; \
    fetch_verified "$NODE_URL" sha256 "$NODE_SHA256" /opt/build/node.tar.xz; \
    tar -xJf /opt/build/node.tar.xz -C /usr/local --strip-components=1; \
    rm /opt/build/node.tar.xz; \
    fetch_verified "$PYTHON_URL" sha256 "$PYTHON_SHA256" /opt/build/python.tar.gz; \
    mkdir -p /opt/python; \
    tar -xzf /opt/build/python.tar.gz -C /opt/python --strip-components=1; \
    rm /opt/build/python.tar.gz; \
    ln -sf /opt/python/bin/python3 /usr/local/bin/python3; \
    ln -sf /opt/python/bin/python3.13 /usr/local/bin/python3.13; \
    node --version; python3 --version; \
    apt-get purge -y --auto-remove curl xz-utils; \
    apt-get clean; rm -rf /var/lib/apt/lists/*

# The agent CLIs and ACP adapters, installed unmodified by `npm ci` from the
# committed lock; every package's integrity is checked against it. Their bins
# go on PATH. The licences come from the installed packages' own files; Codex
# ships none in its tarball, so licences/codex holds the release's. The intent
# log's Python module goes into site-packages and its command lines and
# TypeScript module into /opt/toshi/service-agent.
COPY service-agent/package.json service-agent/package-lock.json /opt/agents/
COPY service-agent/lib /opt/build/lib
COPY service-agent/licences /opt/build/licences
RUN set -eux; \
    export npm_config_cache=/opt/build/npm-cache; \
    cd /opt/agents; \
    npm ci --omit=dev --ignore-scripts=false --no-audit --no-fund; \
    for bin in /opt/agents/node_modules/.bin/*; do ln -sf "$bin" /usr/local/bin/"${bin##*/}"; done; \
    claude --version; codex --version; opencode --version; \
    command -v claude-agent-acp >/dev/null; command -v codex-acp >/dev/null; \
    lic=/usr/share/licenses/toshi-service-agent; \
    install -D -m 0644 /opt/agents/node_modules/@anthropic-ai/claude-code/LICENSE.md "$lic/claude-code/LICENSE.md"; \
    install -D -m 0644 /opt/agents/node_modules/opencode-ai/LICENSE "$lic/opencode/LICENSE"; \
    install -D -m 0644 /opt/agents/node_modules/@agentclientprotocol/claude-agent-acp/LICENSE "$lic/claude-agent-acp/LICENSE"; \
    install -D -m 0644 /opt/agents/node_modules/@agentclientprotocol/codex-acp/LICENSE "$lic/codex-acp/LICENSE"; \
    install -D -m 0644 /opt/build/licences/codex/LICENSE "$lic/codex/LICENSE"; \
    install -D -m 0644 /opt/build/licences/codex/NOTICE "$lic/codex/NOTICE"; \
    install -D -m 0644 /opt/build/versions.env /usr/share/toshi/service-agent/versions.env; \
    install -D -m 0644 /opt/build/lib/python/cli.py /opt/toshi/service-agent/python/cli.py; \
    install -D -m 0644 /opt/build/lib/typescript/intents.ts /opt/toshi/service-agent/typescript/intents.ts; \
    install -D -m 0644 /opt/build/lib/typescript/cli.ts /opt/toshi/service-agent/typescript/cli.ts; \
    purelib=$(python3 -c 'import sysconfig; print(sysconfig.get_paths()["purelib"])'); \
    install -D -m 0644 /opt/build/lib/python/toshi_intents.py "$purelib/toshi_intents.py"; \
    printf '#!/bin/sh\nexec python3 /opt/toshi/service-agent/python/cli.py "$@"\n' > /usr/local/bin/toshi-intents; \
    printf '#!/bin/sh\nexec node /opt/toshi/service-agent/typescript/cli.ts "$@"\n' > /usr/local/bin/toshi-intents-ts; \
    chmod 0755 /usr/local/bin/toshi-intents /usr/local/bin/toshi-intents-ts; \
    rm -rf /opt/build /root/.npm

# The image runs as one unprivileged user with no sudo, docker or kvm: it
# runs jobs, not hosts. /volume is where the platform mounts the service's
# state; it is runner's, so a fresh named volume inherits that ownership. The
# runtime overrides the entrypoint and the command, so the image has no
# entrypoint of its own.
RUN set -eux; \
    groupadd -g 1001 runner; \
    useradd -m -u 1001 -g runner -s /bin/bash -d /home/runner runner; \
    mkdir -p /volume; \
    chown runner:runner /volume /home/runner

LABEL org.opencontainers.image.source="https://github.com/toshicloud/toshi-images" \
      org.opencontainers.image.description="Toshi service agent: Node, Python, Claude Code, Codex, OpenCode, their ACP adapters and the intent-log library"

ENV HOME=/home/runner
USER runner
WORKDIR /home/runner
CMD ["bash"]
