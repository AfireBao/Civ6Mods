"""Background watcher: Haikesi AI decisions via DeepSeek.

Single-player: FireTuner Stage path (preferred when port 4318 works).
Multiplayer: Lua.log dump + host UI hotkey inject (FireTuner banned).

Usage:
  uv run python scripts/haikesi_deepseek_watch.py

Env:
  HAIKESI_WATCH_MODE=auto|tuner|log   (default auto)
  HAIKESI_LUA_LOG=path\\to\\Lua.log
  HAIKESI_WATCH_INTERVAL_SEC=3
"""

from __future__ import annotations

import asyncio
import os
import sys
import time

sys.path.insert(0, "src")

from civ_mcp.connection import GameConnection, LuaError
from civ_mcp.extai_log_channel import LuaLogExtAITailer, default_lua_log_path
from civ_mcp.game_state import GameState
from civ_mcp.haikesi_llm import (
    create_chat_client,
    decide_and_inject_log_channel,
    decide_and_submit_once,
    load_deepseek_config,
    poll_pending_request,
)


def _resolve_mode() -> str:
    mode = (os.environ.get("HAIKESI_WATCH_MODE") or "auto").strip().lower()
    if mode in ("auto", "tuner", "log"):
        return mode
    return "auto"


async def _try_connect_tuner(conn: GameConnection, *, retries: int = 2) -> bool:
    for _ in range(retries):
        try:
            if not conn.is_connected:
                await conn.connect()
            if conn.haikesi_gameplay_index is not None:
                return True
            await conn.disconnect()
        except ConnectionError:
            pass
        await asyncio.sleep(2)
    return False


async def main() -> None:
    print("Starting Haikesi DeepSeek watch...", flush=True)

    config = load_deepseek_config()
    client = create_chat_client(config)
    interval = float(os.environ.get("HAIKESI_WATCH_INTERVAL_SEC", "3"))
    heartbeat_every = max(1, int(os.environ.get("HAIKESI_WATCH_HEARTBEAT_EVERY", "10")))
    mode = _resolve_mode()

    conn = GameConnection()
    gs = GameState(conn)
    log_tailer = LuaLogExtAITailer()
    channel = "tuner"

    print("=== Haikesi DeepSeek Watch ===", flush=True)
    print(f"API: {config.base_url}", flush=True)
    print(f"Model: {config.model}", flush=True)
    thinking = (os.environ.get("HAIKESI_LLM_THINKING") or "").strip().lower() in {
        "1",
        "true",
        "yes",
        "on",
    }
    print(
        f"Thinking: {'ON' if thinking else 'OFF'} "
        f"(HAIKESI_LLM_THINKING; slower/deeper when ON)",
        flush=True,
    )
    print(f"Mode: {mode} | Poll every {interval}s — Ctrl+C to stop", flush=True)

    if mode in ("auto", "tuner"):
        print("Trying FireTuner (127.0.0.1:4318) ...", flush=True)
        if await _try_connect_tuner(conn):
            channel = "tuner"
            print(
                f"Channel=TUNER Haikesi_GamePlay index={conn.haikesi_gameplay_index}",
                flush=True,
            )
        elif mode == "tuner":
            print("FAIL — FireTuner required (HAIKESI_WATCH_MODE=tuner)", flush=True)
            sys.exit(1)
        else:
            channel = "log"
            print(
                "FireTuner unavailable — switching to LOG channel (MP / no Tuner)",
                flush=True,
            )
    else:
        channel = "log"

    if channel == "log":
        log_path = default_lua_log_path()
        print(f"Channel=LOG tail={log_path}", flush=True)
        if not log_path.is_file():
            print(
                "WARNING: Lua.log not found at that path — dumps will be missed.\n"
                "  Set HAIKESI_LUA_LOG to the real file, e.g.\n"
                "  %LOCALAPPDATA%\\Firaxis Games\\Sid Meier's Civilization VI\\Logs\\Lua.log",
                flush=True,
            )
        print(
            "Host UI: pending 时在下方输入框 Ctrl+V（wire 在剪贴板 / apply.txt / exchange.json）",
            flush=True,
        )
        log_tailer = LuaLogExtAITailer(log_path, recover_pending=True)
        if log_tailer._recovered:  # noqa: SLF001 — startup hint only
            print(
                f"Recovered unapplied dump: {log_tailer._recovered.get('request_id')}",
                flush=True,
            )

    print("Watching for pending AI requests...\n", flush=True)

    last_handled_id: str | None = None
    poll_count = 0
    try:
        while True:
            try:
                if channel == "tuner":
                    payload = await poll_pending_request(conn)
                    poll_count += 1
                    status = payload.get("status")
                    request_id = payload.get("request_id")

                    if status == "pending" and request_id and request_id != last_handled_id:
                        print(
                            f"\n[{time.strftime('%H:%M:%S')}] New pending: {request_id}",
                            flush=True,
                        )
                        handled = await decide_and_submit_once(
                            conn, gs, client, config.model, verbose=True
                        )
                        if handled:
                            last_handled_id = request_id
                            print(
                                f"[{time.strftime('%H:%M:%S')}] Submitted OK\n",
                                flush=True,
                            )
                    elif status == "none" and last_handled_id is not None:
                        last_handled_id = None
                    elif status == "none" and poll_count % heartbeat_every == 0:
                        print(
                            f"[{time.strftime('%H:%M:%S')}] watching... no pending "
                            f"(confirm a human hex in-game to trigger)",
                            flush=True,
                        )
                    elif status == "not_ready" and poll_count % heartbeat_every == 0:
                        print(
                            f"[{time.strftime('%H:%M:%S')}] waiting for in-game map",
                            flush=True,
                        )
                else:
                    poll_count += 1
                    payload = log_tailer.poll_new_request()
                    if payload is not None:
                        request_id = str(payload.get("request_id") or "")
                        if request_id and request_id != last_handled_id:
                            print(
                                f"\n[{time.strftime('%H:%M:%S')}] "
                                f"New pending (log): {request_id}",
                                flush=True,
                            )
                            handled = await decide_and_inject_log_channel(
                                client, config.model, payload, verbose=True
                            )
                            if handled:
                                last_handled_id = request_id
                                print(
                                    f"[{time.strftime('%H:%M:%S')}] Published OK "
                                    f"(Ctrl+V in game EditBox; Ctrl+C keeps clipboard/file)\n",
                                    flush=True,
                                )
                    elif poll_count % heartbeat_every == 0:
                        exists = log_tailer.path.is_file()
                        print(
                            f"[{time.strftime('%H:%M:%S')}] watching Lua.log... "
                            f"{'no new ExtAI dump' if exists else 'FILE MISSING'} "
                            f"({log_tailer.path})",
                            flush=True,
                        )
            except LuaError as exc:
                print(
                    f"[{time.strftime('%H:%M:%S')}] Lua error: {exc}",
                    flush=True,
                )
            except ConnectionError as exc:
                print(
                    f"[{time.strftime('%H:%M:%S')}] FireTuner disconnected: {exc}",
                    flush=True,
                )
                if mode == "auto":
                    print("  Falling back to LOG channel ...", flush=True)
                    channel = "log"
                    log_tailer = LuaLogExtAITailer(default_lua_log_path())
                    await asyncio.sleep(2)
                    continue
                print("  Retrying Tuner in 10s ...", flush=True)
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
