#!/usr/bin/env python3
"""LLM-driven browser agent (browser-use) for the sandbox.

Give a natural-language GOAL ("log in and download the latest invoice") and an
agent figures out the steps itself, driving an isolated Chromium inside this
container. It never touches the host screen or the user's real Chrome.

The LLM endpoint comes entirely from the environment (kept OUT of the repo):
  - OpenAI-compatible:  OPENAI_API_KEY  [+ OPENAI_BASE_URL]   (any compatible server)
  - Anthropic:          ANTHROPIC_API_KEY
  - Google:             GOOGLE_API_KEY
Pick the model with SANDBOX_AGENT_MODEL. Output is one JSON line on stdout.
"""
import asyncio
import json
import os
import sys


def _make_llm():
    """Build a browser-use chat model from whichever credential the env provides."""
    model = os.environ.get("SANDBOX_AGENT_MODEL")
    if os.environ.get("OPENAI_API_KEY") or os.environ.get("OPENAI_BASE_URL"):
        from browser_use import ChatOpenAI
        return ChatOpenAI(
            model=model or "gpt-4o",
            base_url=os.environ.get("OPENAI_BASE_URL"),
            api_key=os.environ.get("OPENAI_API_KEY"),
        )
    if os.environ.get("ANTHROPIC_API_KEY"):
        from browser_use import ChatAnthropic
        return ChatAnthropic(model=model or "claude-sonnet-4-6")
    if os.environ.get("GOOGLE_API_KEY"):
        from browser_use import ChatGoogle
        return ChatGoogle(model=model or "gemini-3-flash-preview")
    raise SystemExit(
        "agent: no LLM configured. Set OPENAI_API_KEY (+optional OPENAI_BASE_URL "
        "for any OpenAI-compatible endpoint), or ANTHROPIC_API_KEY, or GOOGLE_API_KEY."
    )


async def _run(goal: str) -> int:
    from browser_use import Agent, Browser

    browser = Browser(
        headless=os.environ.get("HEADLESS", "1") != "0",
        # Drive the SYSTEM chromium over CDP (browser-use 0.12.x ships no browser
        # of its own). Pointing executable_path here stops it fetching one at runtime.
        executable_path=os.environ.get("CHROMIUM_BIN", "/usr/bin/chromium"),
        # The container is the security boundary and runs --cap-drop ALL, so the
        # in-browser sandbox can't initialize -- same reason driver.py uses --no-sandbox.
        chromium_sandbox=False,
        user_data_dir=os.path.join(
            os.environ.get("PROFILE_DIR", "/profile"),
            os.environ.get("SANDBOX_PROFILE", "default"),
        ),
    )
    agent = Agent(task=goal, llm=_make_llm(), browser=browser)
    history = await agent.run(max_steps=int(os.environ.get("SANDBOX_AGENT_MAX_STEPS", "25")))
    try:
        result = history.final_result()
    except Exception:  # noqa: BLE001 - history shape varies across browser-use versions
        result = str(history)
    print(json.dumps({"ok": True, "goal": goal, "result": result}))
    return 0


def main() -> int:
    goal = " ".join(sys.argv[1:]).strip() or os.environ.get("SANDBOX_GOAL", "").strip()
    if not goal:
        print(json.dumps({"ok": False, "error": "no goal given"}))
        return 2
    return asyncio.run(_run(goal))


if __name__ == "__main__":
    sys.exit(main())
