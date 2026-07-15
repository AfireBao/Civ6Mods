"""Smoke test for Haikesi external AI relic protocol via FireTuner.

Usage: uv run python scripts/test_haikesi_ai.py

Requires Civ 6 running with Haikesi mod, EnableTuner=1, and optionally
a pending external AI request (human confirmed a hex with EXTERNAL_AI on).
"""

from __future__ import annotations

import asyncio
import sys

sys.path.insert(0, "src")

from civ_mcp.connection import GameConnection
from civ_mcp.lua import haikesi as haikesi_lua


async def main() -> None:
    conn = GameConnection()
    print("=== Haikesi External AI Protocol Test ===\n")
    try:
        await conn.connect()
    except ConnectionError as exc:
        print(f"FAIL — {exc}")
        sys.exit(1)

    print(f"Haikesi_GamePlay_Script state index: {conn.haikesi_gameplay_index}")
    if conn.haikesi_gameplay_index is None:
        print("FAIL — Haikesi mod GamePlay state not found")
        sys.exit(1)

    print("\n1. Polling pending request...")
    lines = await conn.execute_haikesi(haikesi_lua.build_get_ai_request_lua())
    payload = haikesi_lua.format_ai_request_json(lines)
    print(payload)

    parsed = haikesi_lua.parse_ai_request_lines(lines)
    if parsed.get("status") != "pending":
        print("\n(no pending request — confirm a human hex in-game with EXTERNAL_AI enabled)")
        await conn.disconnect()
        return

    request_id = parsed["request_id"]
    ai_players = parsed.get("ai_players", [])
    if not ai_players:
        print("\nFAIL — pending request has no AI players")
        sys.exit(1)

    choices: dict[str, str] = {}
    reasons: dict[str, str] = {}
    for ai in ai_players:
        if not ai["options"]:
            continue
        pid = str(ai["player_id"])
        relic = ai["options"][0]
        choices[pid] = relic
        label = ai.get("player_name") or ai.get("civ_label") or pid
        catalog = haikesi_lua.get_ai_relic_catalog()
        relic_name = catalog.get(relic, {}).get("name", relic)
        reasons[pid] = f"测试提交：{label} 需要 {relic_name} 以适应当前局势"

    print(f"\n2. Submitting test choices for request {request_id!r}...")
    submit_lines = await conn.execute_haikesi(
        haikesi_lua.build_submit_ai_choices_lua(request_id, choices, reasons)
    )
    print(haikesi_lua.summarize_submit_result(submit_lines))

    print("\n3. Re-polling (should be none)...")
    lines2 = await conn.execute_haikesi(haikesi_lua.build_get_ai_request_lua())
    print(haikesi_lua.format_ai_request_json(lines2))

    await conn.disconnect()
    print("\n=== Test complete ===")


if __name__ == "__main__":
    asyncio.run(main())
