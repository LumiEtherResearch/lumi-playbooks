#!/usr/bin/env bash
# Sync LumiEther-managed Vibe config into the persistent /root/.vibe volume,
# apply the CodebaseMem runtime settings, then run the container command.
set -uo pipefail

VIBE_HOME="${VIBE_HOME:-/root/.vibe}"
SRC=/opt/lumiether

mkdir -p "$VIBE_HOME/agents" "$VIBE_HOME/prompts"

# Managed files only. The existing codebase-memory* sub-agents/prompts and any
# developer-added files in the volume are left untouched.
install -m 0644 "$SRC/agents/lumiether.toml" "$VIBE_HOME/agents/lumiether.toml"
install -m 0644 "$SRC/prompts/lumiether-codebase-first.md" "$VIBE_HOME/prompts/lumiether-codebase-first.md"

if /opt/mistral-vibe/bin/python "$SRC/gen-config.py" > "$VIBE_HOME/config.toml.new"; then
  chmod 0600 "$VIBE_HOME/config.toml.new"
  mv -f "$VIBE_HOME/config.toml.new" "$VIBE_HOME/config.toml"
else
  echo "lumiether-entrypoint: config generation failed; keeping existing config.toml" >&2
  rm -f "$VIBE_HOME/config.toml.new"
fi

# CodebaseMem runtime settings (stored in CBM_CACHE_DIR, idempotent).
for kv in "auto_index true" "auto_index_limit 50000" "auto_watch true" "watcher_enabled true"; do
  # shellcheck disable=SC2086
  codebase-memory-mcp config set $kv >/dev/null 2>&1 \
    || echo "lumiether-entrypoint: could not set CodebaseMem '$kv'" >&2
done

# Agent Host config: one ACP backend, the Vibe agent. The container environment
# (PYTHON_KEYRING_BACKEND, LUMI_ADAPTER_KEY, ...) is inherited by vibe-acp.
AHPD_CFG=/root/.config/ahpd
mkdir -p "$AHPD_CFG"
cat > "$AHPD_CFG/config.json.new" <<'EOF_AHPD'
{
  "plugins": [
    {
      "name": "@ahpd/agent-acp",
      "options": {
        "provider": "vibe",
        "displayName": "Mistral Vibe (LumiEther)",
        "command": "/opt/mistral-vibe/bin/vibe-acp",
        "env": {}
      }
    }
  ]
}
EOF_AHPD
mv -f "$AHPD_CFG/config.json.new" "$AHPD_CFG/config.json"

exec "$@"
