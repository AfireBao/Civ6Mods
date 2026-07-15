"""Background watcher: auto-submit Haikesi AI decisions when pending requests appear.

Usage:
  uv run python scripts/haikesi_llm_watch.py

Config: see scripts/haikesi_llm_decide.py (uses .env in repo root)
"""

from __future__ import annotations

import asyncio
import sys
import time

sys.path.insert(0, "src")

from civ_mcp.connection import GameConnection
from civ_mcp.game_state import GameState
from civ_mcp.haikesi_llm import (
    create_chat_client,
    decide_and_submit_once,
    load_haikesi_llm_config,
    poll_pending_request,
)


async def main() -> None:
    config = load_haikesi_llm_config()
    client = create_chat_client(config)
    interval = float(__import__("os").environ.get("HAIKESI_WATCH_INTERVAL_SEC", "3"))

    conn = GameConnection()
    gs = GameState(conn)

    print("=== Haikesi LLM Watch ===")
    print(f"Provider: {config.provider_label}")
    print(f"Model: {config.model}")
    print(f"Poll every {interval}s — Ctrl+C to stop\n")

    await conn.connect()
    if conn.haikesi_gameplay_index is None:
        print("FAIL — Haikesi GamePlay state not found")
        sys.exit(1)

    last_handled_id: str | None = None
    try:
        while True:
            try:
                payload = await poll_pending_request(conn)
                status = payload.get("status")
                request_id = payload.get("request_id")

                if status == "pending" and request_id and request_id != last_handled_id:
                    print(f"\n[{time.strftime('%H:%M:%S')}] New pending: {request_id}")
                    handled = await decide_and_submit_once(
                        conn, gs, client, config.model, verbose=True
                    )
                    if handled:
                        last_handled_id = request_id
                        print(f"[{time.strftime('%H:%M:%S')}] Submitted OK\n")
                elif status == "none" and last_handled_id is not None:
                    last_handled_id = None
            except ConnectionError as exc:
                print(f"[{time.strftime('%H:%M:%S')}] FireTuner disconnected: {exc}")
                print("  Retrying in 10s ...")
                await asyncio.sleep(10)
                try:
                    await conn.connect()
                except ConnectionError:
                    continue
            except Exception as exc:
                print(f"[{time.strftime('%H:%M:%S')}] Error: {exc}")

            await asyncio.sleep(interval)
    except KeyboardInterrupt:
        print("\nStopped.")
    finally:
        await conn.disconnect()


if __name__ == "__main__":
    asyncio.run(main())
