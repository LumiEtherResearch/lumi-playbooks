#!/usr/bin/env python3
"""LUMIANS vision tool (MCP over stdio). One tool: describe_image(path, question?).
Reads an image that the user attached in LUMIANS and asks a vision-capable Mistral model about it through the local
adapter, then returns plain text. It can ONLY read files inside the user's own .claude-webui-attachments folder.
Standard library only."""
import base64, getpass, json, mimetypes, os, sys, urllib.request

API = os.environ.get("LUMIANS_VISION_API", "http://127.0.0.1:8090/v1/chat/completions")
MODEL = os.environ.get("LUMIANS_VISION_MODEL", "mistral-medium-2508")
USER = os.environ.get("LUMIANS_VISION_USER") or getpass.getuser()
ROOT = os.environ.get("LUMIANS_VISION_ROOT", "/srv/lumiether/workspaces")
MAX_BYTES = 10 * 1024 * 1024
OK_TYPES = {"image/png", "image/jpeg", "image/webp", "image/gif"}
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


try:
    from PIL import Image, ImageFilter
except Exception:  # noqa: BLE001
    Image = None


def _runs(vals, T, gap=3):
    best = (0, 0); cur = miss = start = 0
    for i, v in enumerate(vals):
        if v >= T:
            if cur == 0: start = i
            cur += 1; miss = 0
            if cur > best[0]: best = (cur, start)
        elif cur and miss < gap: miss += 1; cur += 1
        else: cur = miss = 0
    return best

def _merge(lines, tol):
    # lines: (pos, run, start); keep the strongest in each cluster
    out = []
    for ln in sorted(lines):
        if out and ln[0] - out[-1][-1][0] <= tol: out[-1].append(ln)
        else: out.append([ln])
    return [max(c, key=lambda t: t[1]) for c in out]

def measure(im, T=14):
    g = im.convert("L"); W0, H0 = g.size
    g = g.resize((768, max(1, int(H0 * 768 / W0))), Image.LANCZOS); W, H = g.size
    px = g.filter(ImageFilter.FIND_EDGES).load()
    V = []
    for x in range(3, W - 3):
        r, s = _runs([px[x, y] for y in range(H)], T)
        if r > 0.28 * H: V.append((x, r, s))
    Hh = []
    for y in range(3, H - 3):
        r, s = _runs([px[x, y] for x in range(W)], T)
        if r > 0.22 * W: Hh.append((y, r, s))
    V = _merge(V, 4); Hh = _merge(Hh, 4)
    rects = []
    for i, a in enumerate(Hh):
        for b in Hh[i + 1:]:
            if b[0] - a[0] < 0.12 * H: continue
            xs, xe = max(a[2], b[2]), min(a[2] + a[1], b[2] + b[1])
            if xe - xs < 0.8 * max(a[1], b[1]): continue
            # refine the sides with vertical lines
            lx = [v[0] for v in V if abs(v[0] - xs) <= 0.03 * W]; rx = [v[0] for v in V if abs(v[0] - xe) <= 0.03 * W]
            x0 = lx[0] if lx else xs; x1 = rx[-1] if rx else xe
            if lx or rx: rects.append((x0, a[0], x1, b[0]))
    # keep only the outermost rectangle of each group (inner dividers also pair up)
    def inside(r, q): return q is not r and q[0] - 5 <= r[0] and q[2] + 8 >= r[2] and q[1] - 5 <= r[1] and q[3] + 5 >= r[3]
    rects = [r for r in rects if not any(inside(r, q) for q in rects)]
    bars = [h for h in Hh if not any(abs(h[0] - r[1]) < 4 or abs(h[0] - r[3]) < 4 for r in rects) and h[1] > 0.5 * W]
    return W, H, rects, bars

def measured_layout(im):
    W, H, rects, bars = measure(im)
    pc = lambda v, t: int(round(100.0 * v / t))
    out = []
    for (x0, y0, x1, y1) in rects:
        gaps = {"left": x0, "top": y0, "right": W - x1, "bottom": H - y1}
        floats = [k for k, v in gaps.items() if v >= 0.01 * (W if k in ("left", "right") else H)]
        touches = [k for k in gaps if k not in floats]
        out.append("- A panel at x %d%%-%d%%, y %d%%-%d%% of the screen. Gap to the screen edge: left %d%%, top %d%%, right %d%%, bottom %d%%. %s%s" % (
            pc(x0, W), pc(x1, W), pc(y0, H), pc(y1, H), pc(gaps["left"], W), pc(gaps["top"], H), pc(gaps["right"], W), pc(gaps["bottom"], H),
            ("It floats (visible background on all sides)." if not touches else ("It touches: " + ", ".join(touches) + ".")), ""))
    for (y, r, s) in bars:
        x0, x1 = s, s + r
        out.append("- A wide bar whose lower edge is at y %d%% and which spans x %d%%-%d%%. Gap to the bottom of the screen: %d%%; to the left edge %d%%; to the right edge %d%%." % (
            pc(y, H), pc(x0, W), pc(x1, W), pc(H - y, H), pc(x0, W), pc(W - x1, W)))
    return out


REGIONS = [("left third of the screen", 0, 0, .38, 1), ("right third of the screen", .62, 0, 1, 1),
           ("top centre of the screen", .2, 0, .8, .5), ("bottom strip of the screen", 0, .66, 1, 1)]
REGION_Q = ("This is a crop of a UI screenshot: the %s. Parts of elements may be cut by the crop edge: skip anything that is not "
            "fully visible. Describe ONLY what is visible, as short bullet lines, in four groups: "
            "TEXT: every label or heading, exact words, in reading order (note when a heading is on its own lines). "
            "ICONS: every icon as the plain shape drawn, followed by its label. "
            "BADGES: any small coloured dot or badge and the icon it sits on; if there is none write 'none'. "
            "COLOURS: the main colours you can see, in words only. "
            "Do not describe where panels start or end, do not guess, do not write code, do not give hex codes or sizes.")
WHOLE_Q = ("Describe ONLY what is visible in this UI image, as short bullet lines: background, every panel or bar, every text label "
           "(exact words), every icon as the plain shape drawn, any badge, main colours in words. Do not guess, do not write code, "
           "no hex codes or sizes.")


def ask(mime, b64, text, tokens=600):
    body = {"model": MODEL, "max_tokens": tokens, "messages": [{"role": "user", "content": [
        {"type": "text", "text": text},
        {"type": "image_url", "image_url": "data:%s;base64,%s" % (mime, b64)}]}]}
    req = urllib.request.Request(API, json.dumps(body).encode(), {"Content-Type": "application/json"})
    r = json.load(urllib.request.urlopen(req, timeout=150))
    return r["choices"][0]["message"]["content"].strip()


def jpeg_b64(img):
    import io
    img = img.copy(); img.thumbnail((1400, 1400)); buf = io.BytesIO(); img.save(buf, "JPEG", quality=88)
    return base64.b64encode(buf.getvalue()).decode()


def describe(args):
    real = resolve(args["path"])
    mime = mimetypes.guess_type(real)[0] or ""
    if mime not in OK_TYPES:
        raise ValueError("not a supported image type (png, jpg, webp, gif)")
    if os.path.getsize(real) > MAX_BYTES:
        raise ValueError("image is larger than 10 MB")
    parts = []
    if Image is not None:
        im = Image.open(real).convert("RGB"); W, H = im.size
        try:
            lay = measured_layout(im)
        except Exception:  # noqa: BLE001
            lay = []
        if lay:
            parts.append("Layout measured from the image pixels (these positions are measured, not guessed):\n" + "\n".join(lay))
        for name, x0, y0, x1, y1 in REGIONS:
            c = im.crop((int(x0 * W), int(y0 * H), int(x1 * W), int(y1 * H)))
            try:
                parts.append("Read from the %s (by a vision model):\n%s" % (name, ask("image/jpeg", jpeg_b64(c), REGION_Q % name)))
            except Exception as e:  # noqa: BLE001
                parts.append("Read from the %s: failed (%s)" % (name, str(e)[:60]))
    else:
        b64 = base64.b64encode(open(real, "rb").read()).decode()
        parts.append(ask(mime, b64, WHOLE_Q, 1500))
    text = "\n\n".join(parts)
    return ("FINAL ANSWER. Reply to the developer with the prompt below EXACTLY as written, from 'Goal' to the end. "
            "Add nothing, remove nothing, and do not reword it. Then add one line: 'The description is machine-generated "
            "and may miss details; check it against your image before pasting.'\n\n"
            "Goal\nBuild a single, self-contained HTML file that reproduces the attached UI screenshot as closely as "
            "possible. Use only what is described below. The measured layout is reliable; icon shapes and colours are "
            "approximate. Where something is not described, choose something simple and neutral rather than inventing detail.\n\n"
            "Image description (from the image tool)\n" + text + "\n")


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
