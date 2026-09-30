FROM ubuntu:24.04

# git: required by Codebase Memory's watcher and detect_changes.
RUN apt-get update && apt-get install -y \
    curl \
    ca-certificates \
    python3 \
    python3-venv \
    python3-pip \
    git \
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

# LumiEther-managed Vibe agent, prompt and config generator (synced into the
# /root/.vibe volume by the entrypoint on every start).
COPY lumiether/ /opt/lumiether/
RUN chmod 0755 /opt/lumiether/entrypoint.sh /opt/lumiether/gen-config.py

RUN mkdir -p /workspaces /data/codebase-memory

WORKDIR /workspaces

ENTRYPOINT ["/opt/lumiether/entrypoint.sh"]
CMD ["sleep", "infinity"]
