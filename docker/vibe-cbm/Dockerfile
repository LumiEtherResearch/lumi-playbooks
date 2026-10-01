FROM ubuntu:24.04

# git: required by Codebase Memory's watcher and detect_changes.
# xz-utils: to unpack the Node tarball below.
RUN apt-get update && apt-get install -y \
    curl \
    ca-certificates \
    python3 \
    python3-venv \
    python3-pip \
    git \
    xz-utils \
    && rm -rf /var/lib/apt/lists/*

# Install uv (needed for Vibe)
RUN curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh

# Install Vibe and ast-grep into a shared venv, with the Python interpreter in a
# world-readable location (same fix as the bare-metal install_vibe.yml).
# Versions are pinned so a rebuild cannot silently change behaviour; Vibe matches
# the bare-metal install (2.25.8).
ARG VIBE_VERSION=2.25.8
ARG ASTGREP_VERSION=0.45.3
ENV UV_PYTHON_INSTALL_DIR=/opt/uv-python
RUN mkdir -p /opt/uv-python && chmod 755 /opt/uv-python
RUN /usr/local/bin/uv venv /opt/mistral-vibe --python 3.12
RUN /usr/local/bin/uv pip install --python /opt/mistral-vibe/bin/python \
    "mistral-vibe==${VIBE_VERSION}" "ast-grep-cli==${ASTGREP_VERSION}"
RUN ln -sf /opt/mistral-vibe/bin/vibe /usr/local/bin/vibe \
 && ln -sf /opt/mistral-vibe/bin/ast-grep /usr/local/bin/ast-grep
# (no `sg` symlink: it would shadow /usr/bin/sg from the shadow package)

# Install codebase-memory-mcp via its official installer (checksum-verified)
# TODO: pin this to a release tag instead of `main`.
RUN curl -fsSL https://raw.githubusercontent.com/DeusData/codebase-memory-mcp/main/install.sh \
    | env HOME=/root bash -s -- --dir=/usr/local/bin

# Agent Host (AHP): Node, ahpd, the ACP backend plugin and the ahpc test client.
# Node is a checksum-verified tarball; everything is version-pinned.
ARG NODE_VERSION=22.22.2
ARG AHPD_VERSION=0.8.0
ARG AHPC_VERSION=0.6.0
RUN set -eux; \
    case "$(dpkg --print-architecture)" in amd64) NA=x64;; arm64) NA=arm64;; *) echo unsupported arch; exit 1;; esac; \
    F="node-v${NODE_VERSION}-linux-${NA}.tar.xz"; \
    curl -fsSLO "https://nodejs.org/dist/v${NODE_VERSION}/${F}"; \
    curl -fsSL "https://nodejs.org/dist/v${NODE_VERSION}/SHASUMS256.txt" | grep " ${F}$" | sha256sum -c -; \
    mkdir -p /opt/node && tar -xJf "${F}" -C /opt/node --strip-components=1 && rm -f "${F}"
ENV PATH=/opt/node/bin:${PATH}
RUN npm i -g "@ahpd/server@${AHPD_VERSION}" "@softov/ahpc@${AHPC_VERSION}" \
 && ahpd plugin install "@ahpd/agent-acp@${AHPD_VERSION}"
COPY lumiether/patch-ahpd-plugin.mjs /opt/lumiether/patch-ahpd-plugin.mjs
RUN node /opt/lumiether/patch-ahpd-plugin.mjs /root/.config/ahpd

# LumiEther-managed Vibe agent, prompt and config generator (synced into the
# /root/.vibe volume by the entrypoint on every start).
COPY lumiether/ /opt/lumiether/
RUN chmod 0755 /opt/lumiether/entrypoint.sh /opt/lumiether/gen-config.py \
    /opt/lumiether/run-ahpd.sh /opt/lumiether/patch-ahpd-plugin.mjs

RUN mkdir -p /workspaces /data/codebase-memory

WORKDIR /workspaces

ENTRYPOINT ["/opt/lumiether/entrypoint.sh"]
# Agent Host in the foreground. Override the command to get a plain idle container.
CMD ["/opt/lumiether/run-ahpd.sh"]

EXPOSE 19187
