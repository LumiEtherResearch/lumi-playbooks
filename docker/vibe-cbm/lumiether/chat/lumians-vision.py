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
DEFAULT_Q = ("Describe this image in exhaustive detail for a developer who must rebuild it exactly: overall layout and "
             "positions, every visible text string verbatim, colours (give hex estimates), fonts and sizes, icons, "
             "spacing, shapes, backgrounds, effects (blur, glass, shadows, gradients) and any interactive elements.")
TOOL = {"name": "describe_image",
        "description": "Look at an image the user attached (a file under .claude-webui-attachments) and return a detailed "
                       "text description. Use this whenever a user message mentions an attached image. Optional 'question' "
                       "asks something specific about it.",
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
    body = {"model": MODEL, "max_tokens": 1800, "messages": [{"role": "user", "content": [
        {"type": "text", "text": args.get("question") or DEFAULT_Q},
        {"type": "image_url", "image_url": "data:%s;base64,%s" % (mime, b64)}]}]}
    req = urllib.request.Request(API, json.dumps(body).encode(), {"Content-Type": "application/json"})
    r = json.load(urllib.request.urlopen(req, timeout=120))
    return r["choices"][0]["message"]["content"]


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
