#!/usr/bin/env python3
"""Generate the managed ~/.vibe/config.toml for the LumiEther dev container.

Runs with the Vibe venv interpreter so it can read Vibe's own default Bash
allowlist (a custom `allowlist` REPLACES the default, so the defaults must be
copied, not omitted). Output goes to stdout.
"""
import json
import os
import sys

MODEL_FRAGMENT = "/etc/lumiether/vibe-model.toml"  # optional, mounted by compose

# Prefixes auto-allowed in addition to Vibe's defaults.
# NOTE: matching is by command prefix, so "ast-grep run" also matches
# "ast-grep run ... --rewrite ... -U". The prompt forbids rewrites unless the
# developer asks; the allowlist cannot enforce it.
EXTRA_ALLOW = ["ast-grep run", "ast-grep --version"]


def q(value: str) -> str:
    return json.dumps(value)


def main() -> None:
    out = []
    out.append("# MANAGED by the vibe-cbm container entrypoint - regenerated on every start.")
    out.append("# Change /opt/lumiether/gen-config.py in the lumi-playbooks repo instead.")
    out.append('default_agent = "lumiether"')
    out.append("")
    out.append("[[mcp_servers]]")
    out.append('name = "codebase-memory-mcp"')
    out.append('transport = "stdio"')
    out.append('command = "/usr/local/bin/codebase-memory-mcp"')
    out.append("args = []")
    out.append("")

    defaults = None
    try:
        from vibe.core.tools.builtins.bash import _get_default_allowlist

        defaults = list(_get_default_allowlist())
    except Exception as exc:  # noqa: BLE001 - never fail container start over this
        print(f"WARNING: cannot read Vibe default bash allowlist ({exc}); "
              "not setting [tools.bash] allowlist - ast-grep will ask for approval.",
              file=sys.stderr)

    if defaults is not None:
        allow = defaults + [p for p in EXTRA_ALLOW if p not in defaults]
        out.append("[tools.bash]")
        out.append('permission = "ask"')
        out.append("allowlist = [")
        out.extend(f"    {q(item)}," for item in allow)
        out.append("]")
        out.append("")

    if os.path.isfile(MODEL_FRAGMENT):
        out.append("# --- model provider (from " + MODEL_FRAGMENT + ") ---")
        with open(MODEL_FRAGMENT, encoding="utf-8") as fh:
            out.append(fh.read().rstrip())
        out.append("")

    sys.stdout.write("\n".join(out) + "\n")


if __name__ == "__main__":
    main()
