"""Run one Haikesi AI decision via DeepSeek API.

Usage:
  uv run python scripts/haikesi_deepseek_decide.py

Requires in .env:
  DEEPSEEK_API_KEY=sk-...
Optional:
  DEEPSEEK_MODEL=deepseek-chat   (or deepseek-reasoner)
"""

from __future__ import annotations

import asyncio
import sys

sys.path.insert(0, "src")

from civ_mcp.connection import GameConnection
from civ_mcp.game_state import GameState
from civ_mcp.haikesi_llm import create_chat_client, decide_and_submit_once, load_deepseek_config


async def main() -> None:
    config = load_deepseek_config()
    client = create_chat_client(config)
    conn = GameConnection()
    gs = GameState(conn)

    print("=== Haikesi DeepSeek Decision (once) ===")
    print(f"API: {config.base_url}")
    print(f"Model: {config.model}\n")

    await conn.connect()
    if conn.haikesi_gameplay_index is None:
        print("FAIL — Haikesi GamePlay state not found (game running + mod loaded?)")
        sys.exit(1)

    await decide_and_submit_once(conn, gs, client, config.model)
    await conn.disconnect()
    print("\n=== Done ===")


if __name__ == "__main__":
    asyncio.run(main())
