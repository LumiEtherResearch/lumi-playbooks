#!/usr/bin/env python3
"""LUMIANS vision tool (MCP over stdio). One tool: describe_image(path, question?).
Reads an image that the user attached in LUMIANS and asks a vision-capable Mistral model about it through the local
adapter, then returns plain text. It can ONLY read files inside the user's own .claude-webui-attachments folder.
Standard library only."""
import base64, getpass, json, mimetypes, os, sys, urllib.request

API = os.environ.get("LUMIANS_VISION_API", "http://127.0.0.1:8090/v1/chat/completions")
MODEL = os.environ.get("LUMIANS_VISION_MODEL", "mistral-large-2512")
USER = os.environ.get("LUMIANS_VISION_USER") or getpass.getuser()
ROOT = os.environ.get("LUMIANS_VISION_ROOT", "/srv/lumiether/workspaces")
MAX_BYTES = 10 * 1024 * 1024
OK_TYPES = {"image/png", "image/jpeg", "image/webp", "image/gif"}
DEFAULT_Q = (
    "You are a meticulous UI analyst. Describe ONLY what is visible in the image. Never assume a common layout "
    "pattern (sidebar, split view, header, close button, avatar) unless it is really drawn. Use short bullet lines. "
    "Report in this order:\n"
    "1. Background: what fills the screen (photo, gradient, plain colour) and what it shows.\n"
    "2. Every panel or container, one bullet each: its position in words (left, centre, bottom ...), whether it "
    "touches a screen edge or floats with a gap on all sides, relative size in words (narrow, wide, small), corner "
    "shape (sharp, rounded, pill), fill (opaque, translucent, frosted glass) and any border or shadow.\n"
    "3. Inside each panel, in reading order: every element with its exact visible text, copied letter for letter, "
    "and a plain description of its icon (what shape is drawn). Mention a badge, dot or highlight only if you can "
    "see it.\n"
    "4. Text that sits directly on the background (titles, subtitles): exact words, position, relative size and weight.\n"
    "5. Colours: name main colours in words only. Do NOT give hex codes, pixel sizes or percentages.\n"
    "6. Not sure: list anything you could not read or identify. Never fill gaps with plausible guesses.\n"
    "Do not write code, HTML or CSS. Do not suggest how to build it. Do not add anything that is not on screen.")
TOOL = {"name": "describe_image",
        "description": "Look at an image the user attached (a file under .claude-webui-attachments) and return a detailed "
                       "text description. Use this whenever a user message mentions an attached image. Optional 'question' "
                       "adds a specific extra question; the full visual report is always produced.",
        "inputSchema": {"type": "object", "properties": {
            "path": {"type": "string", "description": "Path of the attached image file"},
            "question": {"type": "string", "description": "What to look for (optional)"}}, "required": ["path"]}}


def resolve(path):
    p = path
    if p.startswith("/workspaces/"):
        p = ROOT + "/" + p[len("/workspaces/"):]
    real = os.path.realpath(p)
    allowed = os.path.realpath(os.path.join(ROOT, USER, ".claude-webui-attachments"))
    if not (real == allowed or real.startswith(allowed + os.sep)):
        raise ValueError("only files in your own .claude-webui-attachments folder can be read")
    return real


def describe(args):
    real = resolve(args["path"])
    mime = mimetypes.guess_type(real)[0] or ""
    if mime not in OK_TYPES:
        raise ValueError("not a supported image type (png, jpg, webp, gif)")
    if os.path.getsize(real) > MAX_BYTES:
        raise ValueError("image is larger than 10 MB")
    b64 = base64.b64encode(open(real, "rb").read()).decode()
    extra = (args.get("question") or "").strip()
    q = DEFAULT_Q + (("\n\nAfter the numbered report, also answer this specific question, describing only what is visible: " + extra) if extra else "")
    body = {"model": MODEL, "max_tokens": 2800, "messages": [{"role": "user", "content": [
        {"type": "text", "text": q},
        {"type": "image_url", "image_url": "data:%s;base64,%s" % (mime, b64)}]}]}
    req = urllib.request.Request(API, json.dumps(body).encode(), {"Content-Type": "application/json"})
    r = json.load(urllib.request.urlopen(req, timeout=120))
    text = r["choices"][0]["message"]["content"]
    return ("FINAL ANSWER. Reply to the developer with the prompt below EXACTLY as written, from 'Goal' to the end. "
            "Add nothing, remove nothing, and do not reword it. Then add one line: 'The description is machine-generated "
            "and may miss details; check it against your image before pasting.'\n\n"
            "Goal\nBuild a single, self-contained HTML file that reproduces the attached UI screenshot as closely as "
            "possible. Use only what is described below. Where the description says it is unsure, choose something "
            "simple and neutral rather than inventing detail.\n\n"
            "Image description (from the image tool)\n" + text.strip() + "\n")


def send(obj):
    sys.stdout.write(json.dumps(obj) + "\n"); sys.stdout.flush()


def main():
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            m = json.loads(line)
        except ValueError:
            continue
        mid, method = m.get("id"), m.get("method")
        if method == "initialize":
            send({"jsonrpc": "2.0", "id": mid, "result": {
                "protocolVersion": (m.get("params") or {}).get("protocolVersion", "2024-11-05"),
                "capabilities": {"tools": {}}, "serverInfo": {"name": "lumians-vision", "version": "1.0"}}})
        elif method == "tools/list":
            send({"jsonrpc": "2.0", "id": mid, "result": {"tools": [TOOL]}})
        elif method == "tools/call":
            p = m.get("params") or {}
            try:
                if p.get("name") != "describe_image":
                    raise ValueError("unknown tool")
                text, err = describe(p.get("arguments") or {}), False
            except Exception as e:  # noqa: BLE001
                text, err = "describe_image failed: %s" % e, True
            send({"jsonrpc": "2.0", "id": mid, "result": {"content": [{"type": "text", "text": text}], "isError": err}})
        elif method == "ping":
            send({"jsonrpc": "2.0", "id": mid, "result": {}})
        elif mid is not None:
            send({"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": "method not found"}})


if __name__ == "__main__":
    main()
