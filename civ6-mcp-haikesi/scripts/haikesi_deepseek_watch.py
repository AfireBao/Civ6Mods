"""Background watcher: auto-submit Haikesi AI decisions via DeepSeek.

Does NOT start with Civilization VI — you must run this script yourself
in a separate PowerShell window while the game is running.

Usage:
  uv run python scripts/haikesi_deepseek_watch.py

Requires:
  - Civ 6 running, EnableTuner=1, Haikesi mod + EXTERNAL_AI on
  - DEEPSEEK_API_KEY in .env
"""

from __future__ import annotations

import asyncio
import os
import sys
import time

sys.path.insert(0, "src")

from civ_mcp.connection import GameConnection, LuaError
from civ_mcp.game_state import GameState
from civ_mcp.haikesi_llm import (
    create_chat_client,
    decide_and_submit_once,
    load_deepseek_config,
    poll_pending_request,
)


async def main() -> None:
    print("Starting Haikesi DeepSeek watch...", flush=True)

    config = load_deepseek_config()
    client = create_chat_client(config)
    interval = float(os.environ.get("HAIKESI_WATCH_INTERVAL_SEC", "3"))
    heartbeat_every = max(1, int(os.environ.get("HAIKESI_WATCH_HEARTBEAT_EVERY", "10")))

    conn = GameConnection()
    gs = GameState(conn)

    print("=== Haikesi DeepSeek Watch ===", flush=True)
    print(f"API: {config.base_url}", flush=True)
    print(f"Model: {config.model}", flush=True)
    print(f"Poll every {interval}s — Ctrl+C to stop", flush=True)
    print("(Idle = no pending request; heartbeat prints every few polls.)\n", flush=True)

    while not conn.is_connected or conn.haikesi_gameplay_index is None:
        try:
            if not conn.is_connected:
                print("Connecting to FireTuner (127.0.0.1:4318) ...", flush=True)
                await conn.connect()
            if conn.haikesi_gameplay_index is None:
                print("FAIL — Haikesi GamePlay state not found", flush=True)
                print("  → Load a save with Haikesi mod enabled, then wait for retry.", flush=True)
                await conn.disconnect()
                await asyncio.sleep(10)
                continue
            print(
                f"Connected. Haikesi_GamePlay_Script index={conn.haikesi_gameplay_index}",
                flush=True,
            )
            print("Watching for pending AI requests...\n", flush=True)
        except ConnectionError as exc:
            print(f"FireTuner not ready: {exc}", flush=True)
            print("  Retrying in 10s (start/load Civ 6 with EnableTuner=1) ...\n", flush=True)
            await asyncio.sleep(10)

    last_handled_id: str | None = None
    poll_count = 0
    try:
        while True:
            try:
                payload = await poll_pending_request(conn)
                poll_count += 1
                status = payload.get("status")
                request_id = payload.get("request_id")

                if status == "pending" and request_id and request_id != last_handled_id:
                    print(f"\n[{time.strftime('%H:%M:%S')}] New pending: {request_id}", flush=True)
                    handled = await decide_and_submit_once(
                        conn, gs, client, config.model, verbose=True
                    )
                    if handled:
                        last_handled_id = request_id
                        print(f"[{time.strftime('%H:%M:%S')}] Submitted OK\n", flush=True)
                elif status == "none" and last_handled_id is not None:
                    last_handled_id = None
                elif status == "none" and poll_count % heartbeat_every == 0:
                    print(
                        f"[{time.strftime('%H:%M:%S')}] watching... no pending request "
                        f"(confirm a human hex in-game to trigger)",
                        flush=True,
                    )
                elif status == "not_ready" and poll_count % heartbeat_every == 0:
                    print(
                        f"[{time.strftime('%H:%M:%S')}] waiting for in-game map "
                        f"(Haikesi API not loaded — load a save, not main menu)",
                        flush=True,
                    )
            except LuaError as exc:
                print(
                    f"[{time.strftime('%H:%M:%S')}] Lua error (game not ready?): {exc}",
                    flush=True,
                )
            except ConnectionError as exc:
                print(f"[{time.strftime('%H:%M:%S')}] FireTuner disconnected: {exc}", flush=True)
                print("  Retrying in 10s ...", flush=True)
                await asyncio.sleep(10)
                conn.haikesi_gameplay_index = None
                try:
                    await conn.connect()
                except ConnectionError:
                    continue
            except Exception as exc:
                print(f"[{time.strftime('%H:%M:%S')}] Error: {exc}", flush=True)

            await asyncio.sleep(interval)
    except KeyboardInterrupt:
        print("\nStopped.", flush=True)
    finally:
        await conn.disconnect()


if __name__ == "__main__":
    asyncio.run(main())
