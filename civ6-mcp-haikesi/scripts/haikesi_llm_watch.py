"""Background watcher: Haikesi AI decisions (OpenAI-compatible / Anthropic).

Same dual-channel behavior as haikesi_deepseek_watch.py:
  tuner (SP) | log+hotkey inject (MP)

Usage:
  uv run python scripts/haikesi_llm_watch.py

Env: HAIKESI_WATCH_MODE=auto|tuner|log
     HAIKESI_LLM_PIPELINE=single|dual
     HAIKESI_LLM_DRAFT / HAIKESI_LLM_REVIEW = provider ids
       (deepseek|grok|glm|openai|anthropic|draft|review|custom)
"""

from __future__ import annotations

import asyncio
import os
import sys
import time

sys.path.insert(0, "src")

from civ_mcp.connection import GameConnection
from civ_mcp.extai_log_channel import LuaLogExtAITailer, default_lua_log_path
from civ_mcp.game_state import GameState
from civ_mcp.haikesi_llm import (
    decide_and_inject_log_channel,
    decide_and_submit_once,
    llm_effective_review_rounds,
    llm_thinking_enabled,
    poll_pending_request,
    resolve_decision_pipeline,
)


def _resolve_mode() -> str:
    mode = (os.environ.get("HAIKESI_WATCH_MODE") or "auto").strip().lower()
    return mode if mode in ("auto", "tuner", "log") else "auto"


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
    pipeline = resolve_decision_pipeline(prefer="haikesi")
    draft_client = pipeline.draft_client
    review_client = pipeline.review_client if pipeline.mode == "dual" else None
    review_model = pipeline.review_model if pipeline.mode == "dual" else None
    interval = float(os.environ.get("HAIKESI_WATCH_INTERVAL_SEC", "3"))
    mode = _resolve_mode()
    rounds = llm_effective_review_rounds(dual=pipeline.mode == "dual")

    conn = GameConnection()
    gs = GameState(conn)
    channel = "tuner"

    print("=== Haikesi LLM Watch ===")
    print(f"Pipeline: {pipeline.mode}")
    if pipeline.mode == "dual":
        print(
            f"Draft:   {pipeline.draft_provider} / {pipeline.draft_model}",
        )
        print(
            f"Review:  {pipeline.review_provider} / {pipeline.review_model}",
        )
        print(
            f"Roles:   HAIKESI_LLM_DRAFT={pipeline.draft_provider} "
            f"HAIKESI_LLM_REVIEW={pipeline.review_provider}",
        )
    else:
        print(f"Model:   {pipeline.draft_provider} / {pipeline.model_label}")
    print(
        f"Thinking: {'ON' if llm_thinking_enabled() else 'OFF'} "
        f"| ReviewRounds: {rounds} "
        f"(HAIKESI_LLM_THINKING / HAIKESI_LLM_REVIEW_ROUNDS"
        f"{'; dual→min 1' if pipeline.mode == 'dual' else ''})",
    )
    try:
        from civ_mcp.llm_chat_session import chat_session_enabled, max_history_turns

        if chat_session_enabled():
            print(
                f"ChatSession: ON (per save) "
                f"history_turns={max_history_turns()} "
                f"(HAIKESI_LLM_CHAT_SESSION; "
                f"file=logs/decisions/<save>/llm_chat_session.json)",
            )
        else:
            print("ChatSession: OFF (stateless each pick)")
    except Exception as exc:  # noqa: BLE001
        print(f"ChatSession: (unavailable: {exc})")
    print(f"Mode: {mode} | Poll every {interval}s — Ctrl+C to stop\n")

    if mode in ("auto", "tuner"):
        if await _try_connect_tuner(conn):
            channel = "tuner"
            print(f"Channel=TUNER index={conn.haikesi_gameplay_index}")
        elif mode == "tuner":
            print("FAIL — FireTuner required")
            sys.exit(1)
        else:
            channel = "log"
            print("FireTuner unavailable — Channel=LOG")
    else:
        channel = "log"

    log_tailer = LuaLogExtAITailer(default_lua_log_path(), recover_pending=True)
    if channel == "log":
        print(f"tail={default_lua_log_path()} exists={default_lua_log_path().is_file()}")
        if log_tailer._recovered:  # noqa: SLF001
            print(f"Recovered unapplied dump: {log_tailer._recovered.get('request_id')}")

    last_handled_id: str | None = None
    # LOG 通道：同 request_id 重 dump（读档重选）也要再跑；用日志偏移去重
    last_handled_log_key: str | None = None
    try:
        while True:
            try:
                if channel == "tuner":
                    payload = await poll_pending_request(conn)
                    status = payload.get("status")
                    request_id = payload.get("request_id")
                    if status == "pending" and request_id and request_id != last_handled_id:
                        print(f"\n[{time.strftime('%H:%M:%S')}] New pending: {request_id}")
                        handled = await decide_and_submit_once(
                            conn,
                            gs,
                            draft_client,
                            pipeline.draft_model,
                            review_client=review_client,
                            review_model=review_model,
                            verbose=True,
                        )
                        if handled:
                            last_handled_id = request_id
                            print(f"[{time.strftime('%H:%M:%S')}] Submitted OK\n")
                    elif status == "none" and last_handled_id is not None:
                        last_handled_id = None
                else:
                    payload = log_tailer.poll_new_request()
                    if payload is not None:
                        request_id = str(payload.get("request_id") or "")
                        log_key = (
                            f"{request_id}@pos{payload.get('_log_pos', '')}"
                            f"@n{payload.get('_dump_seq', '')}"
                        )
                        if request_id and log_key != last_handled_log_key:
                            print(
                                f"\n[{time.strftime('%H:%M:%S')}] "
                                f"New pending (log): {request_id} key={log_key}"
                            )
                            handled = await decide_and_inject_log_channel(
                                draft_client,
                                pipeline.draft_model,
                                payload,
                                review_client=review_client,
                                review_model=review_model,
                                verbose=True,
                            )
                            if handled:
                                last_handled_log_key = log_key
                                last_handled_id = request_id
                                print(f"[{time.strftime('%H:%M:%S')}] Injected OK\n")
                            else:
                                print(
                                    f"[{time.strftime('%H:%M:%S')}] "
                                    f"Inject failed — will retry same dump if redumped\n"
                                )
            except ConnectionError as exc:
                print(f"[{time.strftime('%H:%M:%S')}] FireTuner disconnected: {exc}")
                if mode == "auto":
                    channel = "log"
                    log_tailer = LuaLogExtAITailer(default_lua_log_path())
                    print("  Falling back to LOG channel")
                    await asyncio.sleep(2)
                    continue
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
