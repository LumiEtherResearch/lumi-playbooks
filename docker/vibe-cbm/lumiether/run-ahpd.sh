#!/usr/bin/env bash
# Run the Agent Host in the foreground as the container's main process.
# Reachable only through the host's published loopback port (see compose).
set -euo pipefail

PORT="${AHPD_PORT:-19187}"
TOKEN_FILE="${AHPD_TOKEN_FILE:-/root/.vibe/ahpd-token}"
export LUMI_PROBE_MODELS="${LUMI_PROBE_MODELS:-[{\"id\":\"mistral-small-4\",\"name\":\"Mistral Small 4\"}]}"

mkdir -p "$(dirname "$TOKEN_FILE")"
# ahpd writes a fresh random token if the file is missing; make sure only root can read it.
umask 077
exec ahpd run \
  --host 0.0.0.0 --port "$PORT" \
  --path /workspaces \
  --connection-token-file "$TOKEN_FILE" \
  --config-file /root/.config/ahpd/config.json \
  --no-update-check
