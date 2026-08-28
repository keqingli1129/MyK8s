import random
import socket

from fastapi import FastAPI
from pydantic import BaseModel

from layer4_deep_agent_harness import build_deep_agent

app = FastAPI()

_deep_agent = None


def get_deep_agent():
    global _deep_agent
    if _deep_agent is None:
        _deep_agent = build_deep_agent()
    return _deep_agent


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
    result = deep_agent.invoke({"messages": [{"role": "user", "content": request.task}]})
    tools_used = [tc["name"] for m in result["messages"] for tc in (getattr(m, "tool_calls", []) or [])]
    final_message = result["messages"][-1].content
    return {"answer": final_message, "tools_used": tools_used}

if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=8080)
