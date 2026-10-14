#!/usr/bin/env python3
"""Remove an UNMARKED [[mcp_servers]] table named lumians-vision from a Vibe config.

Vibe can rewrite config.toml and drop our BEGIN/END comment markers; the playbook
would then add a second copy. The managed block between the markers is kept.
Usage: drop_unmarked_vision.py CONFIG   (prints 'changed: ...' or 'ok: ...')
"""
import sys
import tomllib

BEGIN, END = "# BEGIN LUMIANS VISION", "# END LUMIANS VISION"
NAMES = ('name = "lumians-vision"', "name = 'lumians-vision'")

path = sys.argv[1]
text = open(path, encoding="utf-8").read()

b, e = text.find(BEGIN), text.find(END)
if b != -1 and e > b:
    e_end = text.find("\n", e)
    e_end = len(text) if e_end == -1 else e_end + 1
    head, mid, tail = text[:b], text[b:e_end], text[e_end:]
else:
    head, mid, tail = text, "", ""


def drop(part):
    lines = part.splitlines(keepends=True)
    out, i, n = [], 0, 0
    while i < len(lines):
        if lines[i].strip() == "[[mcp_servers]]":
            j = i + 1
            while j < len(lines) and not lines[j].startswith("["):
                j += 1
            if any(l.strip() in NAMES for l in lines[i:j]):
                i, n = j, n + 1
                continue
        out.append(lines[i])
        i += 1
    return "".join(out), n


new_head, n1 = drop(head)
new_tail, n2 = drop(tail)
n = n1 + n2
if n:
    new = new_head + mid + new_tail
    tomllib.loads(new)  # raises on invalid TOML -> nothing is written
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(new)
    print(f"changed: removed {n} unmarked lumians-vision entry")
else:
    print("ok: no unmarked lumians-vision entry")
