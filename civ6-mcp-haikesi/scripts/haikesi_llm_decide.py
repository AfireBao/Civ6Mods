"""Run one Haikesi external AI decision with configured LLM.

Usage: uv run python scripts/haikesi_llm_decide.py

Config (first match wins):
  - civ6-mcp-haikesi/.env  (recommended, gitignored)
  - environment variables
"""

from __future__ import annotations

import asyncio
import sys

sys.path.insert(0, "src")

from civ_mcp.connection import GameConnection
from civ_mcp.game_state import GameState
from civ_mcp.haikesi_llm import create_chat_client, decide_and_submit_once, load_haikesi_llm_config


async def main() -> None:
    config = load_haikesi_llm_config()
    client = create_chat_client(config)
    conn = GameConnection()
    gs = GameState(conn)

    print("=== Haikesi LLM Decision (once) ===")
    print(f"Provider: {config.provider_label}")
    print(f"Model: {config.model}\n")

    await conn.connect()
    if conn.haikesi_gameplay_index is None:
        print("FAIL — Haikesi GamePlay state not found")
        sys.exit(1)

    await decide_and_submit_once(conn, gs, client, config.model)
    await conn.disconnect()
    print("\n=== Done ===")


if __name__ == "__main__":
    asyncio.run(main())
