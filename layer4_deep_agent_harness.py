# -*- coding: utf-8 -*-
"""Layer 4: the harness (`deepagents`, `create_deep_agent`).

What it gives you: planning, a filesystem and sub-agents.
What you control: your intent.

A Deep Agent takes `create_agent` and wraps it in an opinionated harness for
bigger, multi-step work. Three things come built in: a planning tool so the agent
can write itself a todo list, a filesystem so it can save its work, and
sub-agents it can delegate to. You supply the intent, and the harness supplies
the structure.

We give it the same single tool as before, and a task with several steps. Watch
the list of tool calls afterwards: it plans first, works through the lookups,
then writes its answer to a file, all unprompted.

Install: %pip install -qU langchain langchain-openai langgraph deepagents

Keys: set OPENAI_API_KEY in the environment (or as a Colab secret). Optionally
set ALPHAVANTAGE_API_KEY for live share prices; without it a built-in price
table is used.
"""

import os
from pathlib import Path

import requests
from deepagents import create_deep_agent
from langchain_core.tools import tool


def load_dotenv_file() -> None:
    """Load a local `.env` (or `env`) file into os.environ, if python-dotenv is here."""
    try:
        from dotenv import load_dotenv
    except ImportError:
        return
    for candidate in (".env", "env"):
        path = Path(__file__).with_name(candidate)
        if path.is_file():
            load_dotenv(path, override=True)
            return


def load_key(name: str, required: bool = True):
    """Read a key from the environment, falling back to a .env file or Colab secrets."""
    load_dotenv_file()
    value = os.environ.get(name)
    # if not value:
    #     try:
    #         from google.colab import userdata

    #         value = userdata.get(name)
    #     except Exception:
    #         value = None
    if value:
        os.environ[name] = value
    elif required:
        raise RuntimeError(f"{name} is not set. Export it, or add it as a Colab secret.")
    return value


# def show_markdown(text: str) -> None:
#     """Render markdown inline in a notebook, and as plain text otherwise."""
#     try:
#         from IPython.display import Markdown, display

#         display(Markdown(text))
#     except Exception:
#         print(text)


def fetch_live_price(symbol: str) -> float:
    response = requests.get("https://www.alphavantage.co/query", timeout=10, params={
        "function": "GLOBAL_QUOTE", "symbol": symbol, "apikey": os.environ["ALPHAVANTAGE_API_KEY"]})
    return float(response.json()["Global Quote"]["05. price"])


@tool
def get_share_price(symbol: str) -> float:
    """Return the current share price for a given ticker symbol."""
    if os.environ.get("ALPHAVANTAGE_API_KEY"):
        try:
            return fetch_live_price(symbol)
        except Exception:
            pass
    fake_prices = {"AAPL": 241.5, "GOOG": 168.2, "GOOGL": 168.2, "AMZN": 198.0}
    return fake_prices.get(symbol.upper(), 0.0)


def build_deep_agent():
    """Create the deep agent, loading required API keys first."""
    load_key("OPENAI_API_KEY")
    load_key("ALPHAVANTAGE_API_KEY", required=False)

    return create_deep_agent(
        model="openai:gpt-5.4-mini",
        tools=[get_share_price],
        system_prompt="You are an analyst. Plan your work with your todo tool, use your tools, and write your answer to a file when asked as a bulleted list.",
    )


def main() -> None:
    deep_agent = build_deep_agent()

    result = deep_agent.invoke({"messages": [{"role": "user", "content":
        "Look up the share prices of AAPL, GOOG and AMZN, then write a short markdown note ranking them to prices.md"}]})

    tools_used = [tc["name"] for m in result["messages"] for tc in (getattr(m, "tool_calls", []) or [])]
    print("Tools the agent called, in order:")
    print(tools_used)

    # The file lives in the agent's virtual filesystem, which travels in the
    # result state. Here is the note it wrote.
    # show_markdown(result["files"]["/prices.md"]["content"].replace("$", ""))


if __name__ == "__main__":
    main()
