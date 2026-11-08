"""OpenAI-compatible LLM stub for load tests: streams an answer the way a chat model would, without calling anyone.

Serves GET /v1/models and POST /v1/chat/completions (SSE when "stream": true, JSON otherwise). Defaults model a
real answer: first token after 1-2 s, 40 tokens/s, 600-900 tokens, i.e. 15-25 s per answer. The event rate
matters as much as the token rate: the app pays per SSE event (parse, objects, a socket write downstream), and a
real API sends ~1 token per event every 12-25 ms. STUB_TICK=0.025 with STUB_TPS=40 is close to that; the default
0.05 s sends 2 tokens per event and makes streams look about 1.5-2x cheaper than in production.

    uv run --with aiohttp python llm_stub.py      # 0.0.0.0:8090 (STUB_PORT)
    # point the app at it: OPENAI_BASE_URL=http://llm:8090/v1 (or your client's base_url setting)

Env: STUB_TTFT_MIN / STUB_TTFT_MAX (s), STUB_TPS, STUB_TOKENS_MIN / STUB_TOKENS_MAX, STUB_TICK (s between events),
STUB_FAIL_RATE (0..1: answer 500 to that share of requests, to test retries and error paths).
Run the stub on the target box only if production also pays for the model there; otherwise give it its own box or
subtract its CPU (it shows in `docker stats` as its own container).
"""

import asyncio
import json
import os
import random
import time
import uuid

from aiohttp import web

TTFT = (float(os.getenv("STUB_TTFT_MIN", "1.0")), float(os.getenv("STUB_TTFT_MAX", "2.0")))
TPS = float(os.getenv("STUB_TPS", "40"))
TOKENS = (int(os.getenv("STUB_TOKENS_MIN", "600")), int(os.getenv("STUB_TOKENS_MAX", "900")))
TICK = float(os.getenv("STUB_TICK", "0.025"))
FAIL = float(os.getenv("STUB_FAIL_RATE", "0"))

WORDS = (
    "The answer depends on what you already know and on what you are ready to change. Start small, measure, "
    "and keep what works. Most limits turn out to be habits, and most habits can be replaced one step at a time. "
).split()
MODELS = ["gpt-4o-mini", "gpt-4.1-mini", "gpt-4o"]


async def models(_: web.Request) -> web.Response:
    return web.json_response({"object": "list", "data": [{"id": m, "object": "model"} for m in MODELS]})


def _chunk(cid: str, model: str, content, finish) -> bytes:
    delta = {"content": content} if content is not None else {}
    body = {
        "id": cid,
        "object": "chat.completion.chunk",
        "created": int(time.time()),
        "model": model,
        "choices": [{"index": 0, "delta": delta, "finish_reason": finish}],
    }
    return f"data: {json.dumps(body)}\n\n".encode()


async def completions(request: web.Request) -> web.StreamResponse:
    req = await request.json()
    if FAIL and random.random() < FAIL:
        return web.json_response({"error": {"message": "stub failure", "type": "server_error"}}, status=500)
    model = req.get("model", MODELS[0])
    n_tokens = random.randint(*TOKENS)
    words = [random.choice(WORDS) for _ in range(n_tokens)]  # ~1 token per word, close enough
    cid = f"chatcmpl-{uuid.uuid4().hex[:24]}"
    await asyncio.sleep(random.uniform(*TTFT))

    if not req.get("stream"):
        await asyncio.sleep(n_tokens / TPS)
        return web.json_response({
            "id": cid, "object": "chat.completion", "created": int(time.time()), "model": model,
            "choices": [{"index": 0, "message": {"role": "assistant", "content": " ".join(words)}, "finish_reason": "stop"}],
            "usage": {"prompt_tokens": 500, "completion_tokens": n_tokens, "total_tokens": 500 + n_tokens},
        })

    resp = web.StreamResponse(headers={"Content-Type": "text/event-stream", "Cache-Control": "no-cache"})
    await resp.prepare(request)
    per_tick = max(1, round(TPS * TICK))
    for i in range(0, n_tokens, per_tick):
        await resp.write(_chunk(cid, model, " ".join(words[i : i + per_tick]) + " ", None))
        await asyncio.sleep(TICK)
    await resp.write(_chunk(cid, model, None, "stop"))
    await resp.write(b"data: [DONE]\n\n")
    await resp.write_eof()
    return resp


app = web.Application()
app.router.add_get("/v1/models", models)
app.router.add_post("/v1/chat/completions", completions)

if __name__ == "__main__":
    web.run_app(app, host="0.0.0.0", port=int(os.getenv("STUB_PORT", "8090")), access_log=None)
