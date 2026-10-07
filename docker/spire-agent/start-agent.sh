#!/bin/bash
# Managed by lumi-playbooks (configure_spire_agent.yml). Starts the SPIRE agent with a FRESH join token every time.
# Why: the agent identity lasts about an hour and is renewed in the background. When this host is off or asleep it
# expires, and a used join token cannot be used again, so the agent can only come back with a new token.
set -u
AGENT_DIR="${SPIRE_AGENT_DIR:-/opt/spire-agent}"
RUN_DIR="${SPIRE_RUN_DIR:-/run}"
SS="docker exec spire-server /opt/spire/bin/spire-server"

# the re-parent script (ExecStartPost) starts at the same moment and waits for a NEW token file
rm -f "$RUN_DIR/spire-agent-token"

# 1. wait for the SPIRE server container (up to about 5 minutes after boot)
ready=0
for i in $(seq 1 100); do
  if $SS healthcheck >/dev/null 2>&1; then ready=1; break; fi
  sleep 3
done
[ "$ready" = 1 ] || { echo "spire-server did not become healthy - giving up, systemd will retry" >&2; exit 1; }

# 2. a fresh join token (valid 10 minutes, one use)
TOKEN=$($SS token generate -ttl 600 | awk '/Token:/{print $2}')
[ -n "$TOKEN" ] || { echo "could not generate a join token - systemd will retry" >&2; exit 1; }
umask 077
printf '%s\n' "$TOKEN" > "$RUN_DIR/spire-agent-token"

# 3. clean agent data (the old identity is expired or about to be replaced); keep the two newest old copies
if [ -d "$AGENT_DIR/data" ]; then mv "$AGENT_DIR/data" "$AGENT_DIR/data.old-$(date +%s)"; fi
install -d -m 700 "$AGENT_DIR/data"
ls -dt "$AGENT_DIR"/data.old-* 2>/dev/null | tail -n +3 | xargs -r rm -rf

exec "$AGENT_DIR/bin/spire-agent" run -config "$AGENT_DIR/conf/agent.conf" -joinToken "$TOKEN"
