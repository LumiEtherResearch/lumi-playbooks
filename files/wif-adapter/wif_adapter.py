import hmac, inspect, json, logging, os
from starlette.applications import Starlette
from starlette.requests import Request
from starlette.responses import JSONResponse, StreamingResponse
from starlette.routing import Route
from mistralai.workflows.client import get_mistral_client

log = logging.getLogger("wif_adapter")

def _filter(fn, body):
    allowed = inspect.signature(fn).parameters
    dropped = [k for k in body if k not in allowed]
    if dropped:
        log.warning("dropping unsupported fields: %s", dropped)
    return {k: v for k, v in body.items() if k in allowed}

def _dump(obj):
    return json.loads(obj.model_dump_json(by_alias=True, exclude_none=True))

async def chat(request: Request):
    body = await request.json()
    stream = body.pop("stream", False)
    body.pop("stream_options", None)
    client = get_mistral_client()
    try:
        if not stream:
            r = await client.chat.complete_async(**_filter(client.chat.complete_async, body))
            return JSONResponse(_dump(r))
        s = await client.chat.stream_async(**_filter(client.chat.stream_async, body))
    except Exception as e:
        log.exception("upstream error")
        return JSONResponse({"error": str(e)}, status_code=502)

    async def gen():
        async for ev in s:
            yield f"data: {ev.data.model_dump_json(by_alias=True, exclude_none=True)}\n\n"
        yield "data: [DONE]\n\n"
    return StreamingResponse(gen(), media_type="text/event-stream")

async def models(request: Request):
    client = get_mistral_client()
    return JSONResponse(_dump(await client.models.list_async()))

app = Starlette(routes=[
    Route("/v1/chat/completions", chat, methods=["POST"]),
    Route("/v1/models", models, methods=["GET"]),
])

# --- LumiEther: optional bearer-key check ---
class _KeyAuth:
    """Pure ASGI middleware (does not buffer streaming responses)."""

    def __init__(self, inner, key):
        self.inner = inner
        self.expected = b"Bearer " + key.encode()

    async def __call__(self, scope, receive, send):
        if scope["type"] == "http":
            got = dict(scope["headers"]).get(b"authorization", b"")
            if not hmac.compare_digest(got, self.expected):
                body = b'{"error":"unauthorized"}'
                await send({"type": "http.response.start", "status": 401,
                            "headers": [(b"content-type", b"application/json"),
                                        (b"content-length", str(len(body)).encode())]})
                await send({"type": "http.response.body", "body": body})
                return
        await self.inner(scope, receive, send)


_LUMI_KEY = os.environ.get("LUMI_ADAPTER_KEY")
if _LUMI_KEY:
    app = _KeyAuth(app, _LUMI_KEY)
