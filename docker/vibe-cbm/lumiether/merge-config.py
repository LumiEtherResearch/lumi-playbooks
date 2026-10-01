#!/usr/bin/env python3
"""Merge the LumiEther-managed Vibe settings into an existing ~/.vibe/config.toml.

Idempotent and non-destructive: it only adds two clearly marked blocks
(one top-level key, one set of tables) and refuses to touch a file that already
sets the same things itself. Run with the Vibe venv interpreter so it can read
Vibe's own default Bash allowlist (a custom `allowlist` REPLACES the default).

  merge-config.py CONFIG [--check]

Exit codes: 0 ok / unchanged, 1 unreadable or invalid, 3 conflict with user settings.
"""
import json
import re
import shutil
import sys
import tomllib
from pathlib import Path

TOP_BEGIN, TOP_END = "# >>> LUMIETHER MANAGED (top) >>>", "# <<< LUMIETHER MANAGED (top) <<<"
TBL_BEGIN, TBL_END = "# >>> LUMIETHER MANAGED (tables) >>>", "# <<< LUMIETHER MANAGED (tables) <<<"
AGENT = "lumiether"
MCP_NAME = "codebase-memory-mcp"
MCP_COMMAND = "/usr/local/bin/codebase-memory-mcp"
# NOTE: matching is by command prefix, so "ast-grep run" also matches
# "ast-grep run ... --rewrite -U". The prompt forbids rewrites unless asked.
EXTRA_ALLOW = ["ast-grep run", "ast-grep --version"]


def q(v):
    return json.dumps(v)


def strip_managed(text):
    for b, e in ((TOP_BEGIN, TOP_END), (TBL_BEGIN, TBL_END)):
        text = re.sub(rf"\n?{re.escape(b)}.*?{re.escape(e)}\n?", "\n", text, flags=re.S)
    return text


def default_allowlist():
    try:
        from vibe.core.tools.builtins.bash import _get_default_allowlist
        return list(_get_default_allowlist())
    except Exception as exc:  # noqa: BLE001
        print(f"WARNING: cannot read Vibe's default bash allowlist ({exc}); "
              "leaving [tools.bash] alone - ast-grep will ask for approval.", file=sys.stderr)
        return None


def is_configured(cfg):
    """True when the config already holds every LumiEther setting (e.g. Vibe rewrote the
    file and dropped the marker comments)."""
    if cfg.get("default_agent") != AGENT:
        return False
    if not any(s.get("name") == MCP_NAME and s.get("command") == MCP_COMMAND
               for s in cfg.get("mcp_servers", [])):
        return False
    allow = cfg.get("tools", {}).get("bash", {}).get("allowlist", [])
    return all(e in allow for e in EXTRA_ALLOW)


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    check = "--check" in sys.argv
    if len(args) != 1:
        sys.exit(__doc__)
    path = Path(args[0])
    current = path.read_text(encoding="utf-8") if path.exists() else ""
    rest = strip_managed(current)

    try:
        before = tomllib.loads(rest)
    except tomllib.TOMLDecodeError as exc:
        print(f"ERROR: {path} is not valid TOML outside the managed blocks: {exc}", file=sys.stderr)
        return 1

    if TOP_BEGIN not in current and TBL_BEGIN not in current and is_configured(before):
        print(f"unchanged {path} (already configured; no managed markers)")
        return 0

    conflicts = []
    if "default_agent" in before and before["default_agent"] != AGENT:
        conflicts.append(f"default_agent is already set to {before['default_agent']!r}")
    if any(s.get("name") == MCP_NAME for s in before.get("mcp_servers", [])):
        conflicts.append(f"an MCP server named {MCP_NAME!r} already exists")
    if "bash" in before.get("tools", {}):
        conflicts.append("[tools.bash] is already configured")
    if conflicts:
        print(f"CONFLICT in {path}: " + "; ".join(conflicts) + ". Not changing anything.", file=sys.stderr)
        return 3

    top = f'{TOP_BEGIN}\ndefault_agent = "{AGENT}"\n{TOP_END}\n'
    tbl = [TBL_BEGIN, "[[mcp_servers]]", f"name = {q(MCP_NAME)}", 'transport = "stdio"',
           f"command = {q(MCP_COMMAND)}", "args = []", ""]
    defaults = default_allowlist()
    if defaults is not None:
        allow = defaults + [p for p in EXTRA_ALLOW if p not in defaults]
        tbl += ["[tools.bash]", 'permission = "ask"', "allowlist = ["]
        tbl += [f"    {q(a)}," for a in allow] + ["]"]
    tbl.append(TBL_END)

    body = rest.strip("\n")
    new = top + ("\n" + body + "\n" if body else "") + "\n" + "\n".join(tbl) + "\n"

    after = tomllib.loads(new)  # raises -> exit non-zero, nothing written
    expected = dict(after)
    expected.pop("default_agent", None)
    expected.pop("mcp_servers", None)
    if "tools" in expected:
        t = dict(expected["tools"]); t.pop("bash", None)
        expected["tools"] = t
        if not t and "tools" not in before:
            expected.pop("tools")
    prior = dict(before); prior.pop("default_agent", None)
    if expected != {k: v for k, v in prior.items() if k != "mcp_servers"}:
        print("ERROR: merge would alter existing settings; refusing.", file=sys.stderr)
        return 1

    if new == current:
        print(f"unchanged {path}")
        return 0
    if check:
        print(f"would change {path}")
        return 0
    if path.exists():
        bak = path.with_name(path.name + ".bak-lumiether")
        if not bak.exists():
            shutil.copy2(path, bak)
    tmp = path.with_name(path.name + ".lumiether.tmp")
    tmp.write_text(new, encoding="utf-8")
    shutil.copymode(path, tmp) if path.exists() else tmp.chmod(0o600)
    tmp.replace(path)
    print(f"changed {path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
