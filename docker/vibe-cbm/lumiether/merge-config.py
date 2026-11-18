#!/usr/bin/env python3
"""Merge the LumiEther-managed Vibe settings into an existing ~/.vibe/config.toml.

Idempotent and non-destructive: it only adds two clearly marked blocks
(top-level keys, one set of tables; no MCP servers - Codebase Memory was retired). A key the
user already sets to the same value is left where it is; a different value is a conflict. Run with the Vibe venv interpreter so it can read
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
COMPACTION = "lumiether-compaction"  # ~/.vibe/prompts/lumiether-compaction.md must exist first
TOP_KEYS = {"default_agent": AGENT, "compaction_prompt_id": COMPACTION}
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
        effective = tomllib.loads(current)
    except tomllib.TOMLDecodeError as exc:
        print(f"ERROR: {path} is not valid TOML: {exc}", file=sys.stderr)
        return 1

    has_markers = TOP_BEGIN in current or TBL_BEGIN in current
    user_owns_bash = "bash" in before.get("tools", {})  # [tools.bash] sits outside the managed blocks
    allow = effective.get("tools", {}).get("bash", {}).get("allowlist", [])
    allow_ok = all(e in allow for e in EXTRA_ALLOW)

    conflicts = [f"{k} is already set to {before[k]!r}" for k, v in TOP_KEYS.items()
                 if k in before and before[k] != v]
    if user_owns_bash and not allow_ok:
        conflicts.append("[tools.bash] is already configured")
    if conflicts:
        print(f"CONFLICT in {path}: " + "; ".join(conflicts) + ". Not changing anything.", file=sys.stderr)
        return 3

    top_keys = {k: v for k, v in TOP_KEYS.items() if k not in before}
    need_tables = not user_owns_bash
    if not top_keys and not need_tables and not has_markers:
        print(f"unchanged {path} (already configured; settings are outside the managed blocks)")
        return 0

    sections = []
    if top_keys:
        sections.append("\n".join([TOP_BEGIN] + [f"{k} = {q(v)}" for k, v in top_keys.items()] + [TOP_END]))
    body = rest.strip("\n")
    if body:
        sections.append(body)
    if need_tables:
        tbl = [TBL_BEGIN]
        defaults = default_allowlist()
        if defaults is not None:
            allow_new = defaults + [p for p in EXTRA_ALLOW if p not in defaults]
            tbl += ["[tools.bash]", 'permission = "ask"', "allowlist = ["]
            tbl += [f"    {q(a)}," for a in allow_new] + ["]"]
        tbl.append(TBL_END)
        sections.append("\n".join(tbl))
    new = "\n\n".join(sections) + "\n"

    after = tomllib.loads(new)  # raises -> exit non-zero, nothing written
    expected = dict(after)
    for k in top_keys:
        expected.pop(k, None)
    if need_tables and "tools" in expected:
        t = dict(expected["tools"]); t.pop("bash", None)
        expected["tools"] = t
        if not t and "tools" not in before:
            expected.pop("tools")
    if expected != before:
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
