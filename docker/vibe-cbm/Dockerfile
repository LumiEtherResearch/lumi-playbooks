FROM ubuntu:24.04

RUN apt-get update && apt-get install -y \
    curl \
    ca-certificates \
    python3 \
    python3-venv \
    python3-pip \
    && rm -rf /var/lib/apt/lists/*

# Install uv (needed for Vibe)
RUN curl -LsSf https://astral.sh/uv/install.sh | env UV_INSTALL_DIR=/usr/local/bin sh

# Install Vibe into a shared venv, with the Python interpreter in a
# world-readable location (same fix as the bare-metal install_vibe.yml)
ENV UV_PYTHON_INSTALL_DIR=/opt/uv-python
RUN mkdir -p /opt/uv-python && chmod 755 /opt/uv-python
RUN /usr/local/bin/uv venv /opt/mistral-vibe --python 3.12
RUN /usr/local/bin/uv pip install --python /opt/mistral-vibe/bin/python mistral-vibe
RUN ln -sf /opt/mistral-vibe/bin/vibe /usr/local/bin/vibe

# Install codebase-memory-mcp via its official installer (checksum-verified)
RUN curl -fsSL https://raw.githubusercontent.com/DeusData/codebase-memory-mcp/main/install.sh \
    | env HOME=/root bash --dir=/usr/local/bin

RUN mkdir -p /workspaces /data/codebase-memory

WORKDIR /workspaces

CMD ["sleep", "infinity"]
