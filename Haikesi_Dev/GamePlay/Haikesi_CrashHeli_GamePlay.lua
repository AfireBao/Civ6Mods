-- ===========================================================================
-- Haikesi_CrashHeli_GamePlay.lua
-- 铝翼坠毁 (CRASHHELICOPTERUNE)：
-- 单位由 SQL 宫殿城 Grant 原版 UNIT_HELICOPTER（与娟/种地仙人同款，建都后落地）。
-- 本脚本只给「期望赠送」的那一架打坠毁 Property，并处理移动坠毁 AOE。
-- ===========================================================================

local HELI_UNIT_TYPE = 'UNIT_HELICOPTER'
local CRASH_PROP = 'PROP_NW_HAIKESI_CRASH_HELI'
-- 选卡后置 1：下一架新增的直升机（或已有未标记的首都机）打坠毁标
local EXPECT_PROP = 'PROP_NW_HAIKESI_CRASH_HELI_EXPECT'
local CRASH_CHANCE_DENOM = 10 -- 1/10 = 10%
local EXPLOSION_RADIUS = 1
local EXPLOSION_DAMAGE = 50
local MAX_UNIT_DAMAGE = 100

local g_HeliIndex = nil
local g_Exploding = false

local function GetHeliIndex()
    if g_HeliIndex ~= nil then
        return g_HeliIndex
    end
    local row = GameInfo.Units[HELI_UNIT_TYPE]
    if row == nil then
        return nil
    end
    g_HeliIndex = row.Index
    return g_HeliIndex
end

local function IsHelicopter(pUnit)
    if pUnit == nil then
        return false
    end
    local idx = GetHeliIndex()
    return idx ~= nil and pUnit:GetType() == idx
end

local function IsMarkedCrashHeli(pUnit)
    if pUnit == nil then
        return false
    end
    local prop = pUnit:GetProperty(CRASH_PROP)
    return prop == true or prop == 1
end

local function PlayerExpectsCrashMark(pPlayer)
    if pPlayer == nil then
        return false
    end
    local prop = pPlayer:GetProperty(EXPECT_PROP)
    return prop == true or prop == 1
end

local function MarkCrashHeli(pUnit, iPlayer, reason)
    if pUnit == nil then
        return false
    end
    pUnit:SetProperty(CRASH_PROP, 1)
    local pPlayer = Players[iPlayer]
    if pPlayer ~= nil then
        pPlayer:SetProperty(EXPECT_PROP, 0)
    end
    print(string.format(
        '[Haikesi CrashHeli] marked UNIT_HELICOPTER#%d P%d reason=%s',
        pUnit:GetID(), iPlayer, tostring(reason)))
    return true
end

-- 选卡后：SQL 可能已立刻赠机，扫一遍首都/己方未标记直升机并打标；否则保持 EXPECT 等 UnitAddedToMap
function Haikesi_ApplyCrashHeliRelic(iPlayer)
    local pPlayer = Players[iPlayer]
    if pPlayer == nil then
        print('[Haikesi CrashHeli] Apply skip — invalid player')
        return false
    end
    pPlayer:SetProperty(EXPECT_PROP, 1)

    local units = pPlayer:GetUnits()
    if units == nil then
        print(string.format('[Haikesi CrashHeli] EXPECT set P%d — wait UnitAddedToMap', iPlayer))
        return true
    end

    -- 优先首都格上的未标记直升机（宫殿 Grant 落点）
    local capX, capY = nil, nil
    local cities = pPlayer:GetCities()
    if cities ~= nil then
        local pCapital = cities:GetCapitalCity()
        if pCapital ~= nil then
            capX, capY = pCapital:GetX(), pCapital:GetY()
        end
    end

    -- 只标首都格未标记机；若有多架（已有机 + SQL 刚赠），取 ID 最大（通常为刚落地的赠送机）
    -- 勿 fallback 到非首都机：会清 EXPECT，导致随后宫殿 Grant 的机永远无坠毁标
    local best = nil
    local bestId = -1
    if capX ~= nil then
        for _, unit in units:Members() do
            if IsHelicopter(unit) and not IsMarkedCrashHeli(unit) then
                if unit:GetX() == capX and unit:GetY() == capY then
                    local uid = unit:GetID() or -1
                    if uid > bestId then
                        best = unit
                        bestId = uid
                    end
                end
            end
        end
    end
    if best ~= nil then
        return MarkCrashHeli(best, iPlayer, 'apply-capital')
    end

    print(string.format(
        '[Haikesi CrashHeli] EXPECT set P%d — no heli yet (SQL grant after palace city)',
        iPlayer))
    return true
end

local function OnUnitAddedToMap(playerID, unitID)
    local pPlayer = Players[playerID]
    if not PlayerExpectsCrashMark(pPlayer) then
        return
    end
    local pUnit = pPlayer:GetUnits():FindID(unitID)
    if not IsHelicopter(pUnit) or IsMarkedCrashHeli(pUnit) then
        return
    end
    MarkCrashHeli(pUnit, playerID, 'UnitAddedToMap')
end

local function PickCrashRoll()
    if TerrainBuilder ~= nil and TerrainBuilder.GetRandomNumber ~= nil then
        return TerrainBuilder.GetRandomNumber(CRASH_CHANCE_DENOM, 'HaikesiCrashHeli')
    end
    return Game.GetRandNum(CRASH_CHANCE_DENOM, 'HaikesiCrashHeli') or 0
end

local function ApplyExplosionDamage(centerX, centerY, excludePlayerID, excludeUnitID)
    local damaged = 0
    local killed = 0
    for iPlayer = 0, 63 do
        local pPlayer = Players[iPlayer]
        if pPlayer ~= nil then
            local units = pPlayer:GetUnits()
            if units ~= nil then
                local toProcess = {}
                for _, unit in units:Members() do
                    if unit ~= nil then
                        local uid = unit:GetID()
                        if not (iPlayer == excludePlayerID and uid == excludeUnitID) then
                            local ux, uy = unit:GetX(), unit:GetY()
                            if Map.GetPlotDistance(centerX, centerY, ux, uy) <= EXPLOSION_RADIUS then
                                table.insert(toProcess, unit)
                            end
                        end
                    end
                end
                for _, unit in ipairs(toProcess) do
                    local cur = unit:GetDamage() or 0
                    local maxDmg = MAX_UNIT_DAMAGE
                    if unit.GetMaxDamage ~= nil then
                        maxDmg = unit:GetMaxDamage() or MAX_UNIT_DAMAGE
                    end
                    if cur + EXPLOSION_DAMAGE >= maxDmg then
                        UnitManager.Kill(unit, false)
                        killed = killed + 1
                    else
                        unit:ChangeDamage(EXPLOSION_DAMAGE)
                        damaged = damaged + 1
                    end
                end
            end
        end
    end
    return damaged, killed
end

local function NotifyExplosionVFX(x, y)
    -- UI / Gameplay 分属不同 Lua VM：优先走 ExposedMembers（UI Bridge 注册），LuaEvents 仅备用
    local fn = nil
    if ExposedMembers ~= nil then
        fn = ExposedMembers.Haikesi_CrashHeliPlayBoom
    end
    if type(fn) == 'function' then
        local ok, err = pcall(fn, x, y, EXPLOSION_DAMAGE)
        if not ok then
            print('[Haikesi CrashHeli] PlayBoom error: ' .. tostring(err))
        end
        return
    end
    if LuaEvents ~= nil then
        LuaEvents.Haikesi_CrashHeliExplode(x, y, EXPLOSION_DAMAGE)
        print('[Haikesi CrashHeli] PlayBoom fallback LuaEvents (ExposedMembers missing)')
        return
    end
    print('[Haikesi CrashHeli] PlayBoom skip — no UI bridge')
end

local function CrashExplode(pUnit, iPlayerID, crashX, crashY)
    if pUnit == nil or g_Exploding then
        return
    end
    g_Exploding = true
    -- 坠毁点：UnitMoved 刚进入的那一格（多格路径上掷中 10% 的那步）
    local x = crashX
    local y = crashY
    if x == nil or y == nil then
        x, y = pUnit:GetX(), pUnit:GetY()
    end
    local unitID = pUnit:GetID()
    print(string.format('[Haikesi CrashHeli] crash at (%d,%d) P%d unit#%d', x, y, iPlayerID, unitID))

    NotifyExplosionVFX(x, y)
    local damaged, killed = ApplyExplosionDamage(x, y, iPlayerID, unitID)
    print(string.format('[Haikesi CrashHeli] AOE damage=%d kill=%d', damaged, killed))

    UnitManager.Kill(pUnit, false)
    g_Exploding = false
end

function Haikesi_OnCrashHeliUnitMoved(iPlayerID, iUnitID, iX, iY, bVisible, iUnknown)
    if g_Exploding then
        return
    end
    local pPlayer = Players[iPlayerID]
    if pPlayer == nil then
        return
    end
    local pUnit = pPlayer:GetUnits():FindID(iUnitID)
    if not IsMarkedCrashHeli(pUnit) then
        return
    end
    -- Events.UnitMoved：路径上每进入一格触发一次；该格 10% 坠毁
    if PickCrashRoll() ~= 0 then
        return
    end
    CrashExplode(pUnit, iPlayerID, iX, iY)
end

local function InitializeCrashHeli()
    if ExposedMembers ~= nil then
        ExposedMembers.Haikesi_ApplyCrashHeliRelic = Haikesi_ApplyCrashHeliRelic
    end
    Events.UnitMoved.Add(Haikesi_OnCrashHeliUnitMoved)
    if Events.UnitAddedToMap ~= nil then
        Events.UnitAddedToMap.Add(OnUnitAddedToMap)
    end
    print('[Haikesi CrashHeli] GamePlay ready (SQL palace grant + Property mark)')
end

Events.LoadScreenClose.Add(InitializeCrashHeli)
