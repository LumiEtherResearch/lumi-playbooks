# Base pinned by digest (Ubuntu 24.04.5). The apt packages below are not pinned.
FROM ubuntu:24.04@sha256:008173c23f95b170204355c12626cb5a965d779a7e1283b09e9cffbb1bf33ca3

# git: required by Codebase Memory's watcher and detect_changes.
RUN apt-get update && apt-get install -y \
    curl \
    ca-certificates \
    python3 \
    python3-venv \
    python3-pip \
    git \
    && rm -rf /var/lib/apt/lists/*

# Install uv (needed for Vibe). The versioned installer is downloaded, checked against a
# known sha256 and only then run. To bump: change both ARGs (sha256sum of the new install.sh).
ARG UV_VERSION=0.12.21
ARG UV_INSTALLER_SHA256=0722d6c438395e39e1c27a86a79054d3b2820dd9399c7f8b0f6f84cd27ce36c3
RUN curl -fsSL -o /tmp/uv-install.sh "https://astral.sh/uv/${UV_VERSION}/install.sh" \
 && echo "${UV_INSTALLER_SHA256}  /tmp/uv-install.sh" | sha256sum -c - \
 && env UV_INSTALL_DIR=/usr/local/bin sh /tmp/uv-install.sh \
 && rm /tmp/uv-install.sh \
 && uv --version | grep -qF "uv ${UV_VERSION}"

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

# Install codebase-memory-mcp via its official installer. Both the installer script (tag
# v${CBM_VERSION}, checked against a known sha256) and the binary it downloads (the same
# release's assets, verified by the installer against that release's checksums.txt) are pinned.
# To bump: change both ARGs (sha256sum of the new tag's install.sh).
ARG CBM_VERSION=0.11.0
ARG CBM_INSTALLER_SHA256=13049c7cc51bc508d68b8ecb8a9fd9574ecb7c6f2c9dd5a19bf7d4c187321145
RUN curl -fsSL -o /tmp/cbm-install.sh \
      "https://raw.githubusercontent.com/DeusData/codebase-memory-mcp/v${CBM_VERSION}/install.sh" \
 && echo "${CBM_INSTALLER_SHA256}  /tmp/cbm-install.sh" | sha256sum -c - \
 && env HOME=/root \
      CBM_DOWNLOAD_URL="https://github.com/DeusData/codebase-memory-mcp/releases/download/v${CBM_VERSION}" \
      bash /tmp/cbm-install.sh --dir=/usr/local/bin \
 && rm /tmp/cbm-install.sh \
 && codebase-memory-mcp --version | grep -qF "${CBM_VERSION}"

# LumiEther-managed Vibe agent, prompt and config generator (synced into the
# /root/.vibe volume by the entrypoint on every start).
COPY lumiether/ /opt/lumiether/
RUN chmod 0755 /opt/lumiether/entrypoint.sh /opt/lumiether/gen-config.py

RUN mkdir -p /workspaces /data/codebase-memory

WORKDIR /workspaces

ENTRYPOINT ["/opt/lumiether/entrypoint.sh"]
CMD ["sleep", "infinity"]
