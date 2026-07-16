#!/usr/bin/env python3
"""Split Haikesi_GamePlay_Script.lua to fix Lua 5.1 register limit."""
from pathlib import Path

ROOT = Path(r"G:\Civ6Mods\Haikesi_Dev\GamePlay")
MAIN = ROOT / "Haikesi_GamePlay_Script.lua"

def main() -> None:
    text = MAIN.read_text(encoding="utf-8")
    lines = text.splitlines(keepends=True)

    barb_header = (
        "-- ===========================================================================\n"
        "-- Haikesi_Barbarian_GamePlay.lua\n"
        "-- 南蛮入侵 (NW_AI_BARBARIAN_INVASION)：从主 GamePlay 脚本拆出，避免寄存器超限。\n"
        "-- ===========================================================================\n\n"
    )
    barb_parts = lines[538:570] + ["\n"] + lines[1573:1580] + ["\n"] + lines[1891:2948]
    barb_body = "".join(barb_parts)
    barb_body = barb_body.replace(
        "local function Haikesi_SpawnBarbarianInvasionCamps",
        "function Haikesi_SpawnBarbarianInvasionCamps",
        1,
    )
    (ROOT / "Haikesi_Barbarian_GamePlay.lua").write_text(barb_header + barb_body, encoding="utf-8")

    tri_header = (
        "-- ===========================================================================\n"
        "-- Haikesi_TriTrade_GamePlay.lua\n"
        "-- 三角贸易 (TRIANGULARTRADERUNE)：从主 GamePlay 脚本拆出，避免寄存器超限。\n"
        "-- ===========================================================================\n\n"
    )
    tri_helpers = """\
local function ScaleTurnForGameSpeed(standardTurn)
    local speedType = GameConfiguration.GetGameSpeedType()
    local row = GameInfo.GameSpeeds[speedType]
    if row == nil then return standardTurn end
    return math.max(1, math.floor(standardTurn * row.CostMultiplier + 0.5))
end

local function ScalePopForGameSpeed(standardPop)
    local speedType = GameConfiguration.GetGameSpeedType()
    local row = GameInfo.GameSpeeds[speedType]
    if row == nil then return standardPop end
    return math.max(1, math.floor(standardPop * row.CostMultiplier + 0.5))
end

local function PickRandomIndex(maxCount, reason)
    if maxCount <= 0 then return 0 end
    if TerrainBuilder ~= nil and TerrainBuilder.GetRandomNumber ~= nil then
        return TerrainBuilder.GetRandomNumber(maxCount, reason)
    end
    return Game.GetRandNum(maxCount, reason) or 0
end

"""
    tri_body = "".join(lines[2949:3636])
    tri_body = tri_body.replace(
        "local function Haikesi_SyncTriTradeYieldModifiersAll()",
        "function Haikesi_SyncTriTradeYieldModifiersAll()",
        1,
    )
    tri_init = """
function Haikesi_ApplyTriangularTradeRelicEffect(iPlayer, pPlayer)
    if pPlayer == nil then return end
    pPlayer:SetProperty(TRI_TRADE_YIELD_MODS_PROP, 1)
    TriTradeLog(
        "relic enabled P%d turn=%d — route scan/logs via UI TriTrade_Bridge",
        iPlayer, Game.GetCurrentGameTurn()
    )
end

local function InitializeTriTrade()
    GameEvents.HaikesiTriTradeComplete.Add(HaikesiTriTradeComplete)
    ExposedMembers.HaikesiTriTradeCompleteFromUI = Haikesi_TriTradeCompleteFromUI
    Haikesi_SyncTriTradeYieldModifiersAll()
    print("[Haikesi TriTrade] GamePlay bridge ready")
end

Events.LoadScreenClose.Add(InitializeTriTrade)
"""
    (ROOT / "Haikesi_TriTrade_GamePlay.lua").write_text(
        tri_header + tri_helpers + tri_body + tri_init, encoding="utf-8"
    )

    new_lines = list(lines)
    del new_lines[2949:3636]
    del new_lines[1891:2948]
    del new_lines[1573:1580]
    del new_lines[538:570]
    MAIN.write_text("".join(new_lines), encoding="utf-8")
    print(f"main: {len(lines)} -> {len(new_lines)} lines")


if __name__ == "__main__":
    main()
