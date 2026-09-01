import asyncio
import json
import os
import random
import socket
import uuid

import redis.asyncio as redis
from fastapi import FastAPI, HTTPException, WebSocket, WebSocketDisconnect
from fastapi.responses import StreamingResponse
from pydantic import BaseModel

from layer4_deep_agent_harness import build_deep_agent

app = FastAPI()

_deep_agent = None
_background_tasks: set[asyncio.Task] = set()

_redis: redis.Redis | None = None
JOB_TTL_SECONDS = 3600


def get_deep_agent():
    global _deep_agent
    if _deep_agent is None:
        _deep_agent = build_deep_agent()
    return _deep_agent


def get_redis() -> redis.Redis:
    global _redis
    if _redis is None:
        redis_url = os.environ.get("REDIS_URL", "redis://localhost:6379/0")
        _redis = redis.from_url(redis_url, decode_responses=True)
    return _redis


async def _save_job(job_id: str, job: dict) -> None:
    await get_redis().set(f"job:{job_id}", json.dumps(job, default=str), ex=JOB_TTL_SECONDS)


async def _load_job(job_id: str) -> dict | None:
    raw = await get_redis().get(f"job:{job_id}")
    return json.loads(raw) if raw is not None else None


class AgentRequest(BaseModel):
    task: str

JOKES = [
    "Why don't scientists trust atoms? Because they make up everything!",
    "Why did the scarecrow win an award? Because he was outstanding in his field!",
    "Why don't skeletons fight each other? They don't have the guts.",
    "What do you call fake spaghetti? An impasta!",
    "Why did the bicycle fall over? Because it was two-tired!"
]

@app.get("/")
async def tell_a_joke():
    joke = random.choice(JOKES)
    hostname = socket.gethostname()
    return {"joke": joke, "served_by": hostname}

@app.post("/agent")
async def run_agent(request: AgentRequest):
    deep_agent = get_deep_agent()
    result = await deep_agent.ainvoke({"messages": [{"role": "user", "content": request.task}]})
    tools_used = [tc["name"] for m in result["messages"] for tc in (getattr(m, "tool_calls", []) or [])]
    final_message = result["messages"][-1].content
    return {"answer": final_message, "tools_used": tools_used}

def _serialize_messages(messages):
    return [
        {
            "type": getattr(m, "type", m.__class__.__name__),
            "content": getattr(m, "content", None),
            "tool_calls": getattr(m, "tool_calls", None) or None,
        }
        for m in messages
    ]

def _serialize_update(update: dict) -> dict:
    serialized = {}
    for node, state in update.items():
        if state is None:
            continue
        node_data = dict(state)
        if "messages" in node_data:
            node_data["messages"] = _serialize_messages(node_data["messages"])
        serialized[node] = node_data
    return serialized

@app.post("/agent/stream")
async def run_agent_stream(request: AgentRequest):
    deep_agent = get_deep_agent()

    async def event_generator():
        async for update in deep_agent.astream(
            {"messages": [{"role": "user", "content": request.task}]},
            stream_mode="updates",
        ):
            payload = _serialize_update(update)
            yield f"data: {json.dumps(payload, default=str)}\n\n"
        yield "event: done\ndata: {}\n\n"

    return StreamingResponse(event_generator(), media_type="text/event-stream")

@app.websocket("/ws/agent")
async def run_agent_ws(websocket: WebSocket):
    await websocket.accept()
    deep_agent = get_deep_agent()
    try:
        task = await websocket.receive_text()
        async for update in deep_agent.astream(
            {"messages": [{"role": "user", "content": task}]},
            stream_mode="updates",
        ):
            await websocket.send_json(_serialize_update(update))
        await websocket.send_json({"event": "done"})
    except WebSocketDisconnect:
        pass

async def _run_agent_job(job_id: str, task: str) -> None:
    job = {"status": "running", "updates": []}
    await _save_job(job_id, job)
    all_messages = []
    try:
        deep_agent = get_deep_agent()
        async for update in deep_agent.astream(
            {"messages": [{"role": "user", "content": task}]},
            stream_mode="updates",
        ):
            job["updates"].append(_serialize_update(update))
            await _save_job(job_id, job)
            for node_data in update.values():
                all_messages.extend(node_data.get("messages", []))
        tools_used = [tc["name"] for m in all_messages for tc in (getattr(m, "tool_calls", []) or [])]
        final_message = all_messages[-1].content if all_messages else None
        job.update(status="done", answer=final_message, tools_used=tools_used)
        await _save_job(job_id, job)
    except Exception as exc:
        job.update(status="error", error=str(exc))
        await _save_job(job_id, job)

@app.post("/agent/jobs")
async def create_agent_job(request: AgentRequest):
    job_id = uuid.uuid4().hex
    await _save_job(job_id, {"status": "pending"})
    task = asyncio.create_task(_run_agent_job(job_id, request.task))
    _background_tasks.add(task)
    task.add_done_callback(_background_tasks.discard)
    return {"job_id": job_id, "status": "pending"}

@app.get("/agent/jobs/{job_id}")
async def get_agent_job(job_id: str):
    job = await _load_job(job_id)
    if job is None:
        raise HTTPException(status_code=404, detail="job not found")
    return {"job_id": job_id, **job}

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8080)
