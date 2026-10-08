#!/bin/bash
# Managed by lumi-playbooks (configure_plum_readonly.yml).
# Each developer works in VS Code on this host and clones repositories into his home. Plum (LUMIANS) shows only
# /srv/lumiether/workspaces/<user>. This script makes every top-level git repository in a developer's home appear there,
# READ-ONLY (a bind mount), so Plum and Vibe-in-Plum can read it and nothing else of the home is exposed.
# usage: lumiether-expose-repos <user> [<user> ...]     (run every minute by lumiether-expose-repos.timer)
set -u
WS=${LUMIETHER_WS:-/srv/lumiether/workspaces}
for u in "$@"; do
  home=$(getent passwd "$u" | cut -d: -f6)
  [ -n "$home" ] && [ -d "$home" ] && [ -d "$WS/$u" ] || continue
  for d in "$home"/*/; do
    d=${d%/}; n=${d##*/}
    [ -d "$d/.git" ] || continue
    case "$n" in .*|*[!A-Za-z0-9._-]*) continue ;; esac
    t="$WS/$u/$n"
    mountpoint -q "$t" && continue                                   # already exposed (also keeps older manual mounts)
    if [ -d "$t" ] && [ -n "$(ls -A "$t" 2>/dev/null)" ]; then continue; fi   # a real folder with content: never cover it
    mkdir -p "$t" && mount --bind "$d" "$t" && mount -o remount,bind,ro "$t" \
      && logger -t lumiether-expose-repos "exposed $d read-only at $t" \
      || logger -t lumiether-expose-repos "FAILED to expose $d at $t"
  done
done
exit 0
