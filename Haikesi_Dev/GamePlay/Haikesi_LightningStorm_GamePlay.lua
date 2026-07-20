-- ===========================================================================
-- Haikesi_LightningStorm_GamePlay.lua
-- 闪电风暴 (NW_AI_LIGHTNING_STORM)：
-- 选中当回合不起暴；从下一 TurnBegin 起连续 10 个游戏回合各造一轮。
-- 经 GameRandomEvents.ApplyEvent（与工坊 More Natural Disaster 同路径）。
-- ===========================================================================

local STORM_EVENT_TYPES = {
    'RANDOM_EVENT_DUST_STORM_GRADIENT',
    'RANDOM_EVENT_DUST_STORM_HABOOB',
    'RANDOM_EVENT_BLIZZARD_SIGNIFICANT',
    'RANDOM_EVENT_BLIZZARD_CRIPPLING',
    'RANDOM_EVENT_TORNADO_FAMILY',
    'RANDOM_EVENT_TORNADO_OUTBREAK',
    'RANDOM_EVENT_HURRICANE_CAT_4',
    'RANDOM_EVENT_HURRICANE_CAT_5',
}

-- 选中后从下一游戏回合起，连续持续的游戏回合数
local STORM_DURATION_TURNS = 10
local PROP_REMAIN = 'PROP_NW_AI_LIGHTNING_STORM_REMAIN'
local PROP_OWNER = 'PROP_NW_AI_LIGHTNING_STORM_OWNER'

local function CountAliveMajorCivs()
    local n = 0
    if PlayerManager == nil or PlayerManager.GetAliveMajors == nil then
        return 0
    end
    for _, pPlayer in ipairs(PlayerManager.GetAliveMajors()) do
        if pPlayer ~= nil and not pPlayer:IsBarbarian() then
            n = n + 1
        end
    end
    return n
end

local function PickStormRoll(denom)
    if TerrainBuilder ~= nil and TerrainBuilder.GetRandomNumber ~= nil then
        return TerrainBuilder.GetRandomNumber(denom, 'HaikesiLightningStorm')
    end
    if Game ~= nil and Game.GetRandNum ~= nil then
        return Game.GetRandNum(denom, 'HaikesiLightningStorm') or 0
    end
    return math.random(0, denom - 1)
end

local function ResolveStormEventIndex()
    local roll = PickStormRoll(#STORM_EVENT_TYPES)
    local key = STORM_EVENT_TYPES[roll + 1]
    local row = GameInfo.RandomEvents[key]
    if row == nil then
        return nil, key
    end
    return row.Index, key
end

local function FireStormBurst(iPlayer, reason)
    if GameRandomEvents == nil or GameRandomEvents.ApplyEvent == nil then
        print('[Haikesi LightningStorm] ApplyEvent unavailable (need Gathering Storm)')
        return 0
    end

    local count = CountAliveMajorCivs()
    if count <= 0 then
        print(string.format(
            '[Haikesi LightningStorm] skip P%d reason=%s — no alive majors',
            iPlayer, tostring(reason)))
        return 0
    end

    print(string.format(
        '[Haikesi LightningStorm] start P%d storms=%d reason=%s turn=%s',
        iPlayer, count, tostring(reason), tostring(Game.GetCurrentGameTurn())))

    local applied = 0
    for i = 1, count do
        local eventIndex, eventKey = ResolveStormEventIndex()
        if eventIndex == nil then
            print('[Haikesi LightningStorm] missing RandomEvents row: ' .. tostring(eventKey))
        else
            local kEvent = { EventType = eventIndex }
            local ok, err = pcall(function()
                GameRandomEvents.ApplyEvent(kEvent)
            end)
            if ok then
                applied = applied + 1
                print(string.format(
                    '[Haikesi LightningStorm] ApplyEvent #%d/%d %s',
                    i, count, tostring(eventKey)))
            else
                print(string.format(
                    '[Haikesi LightningStorm] ApplyEvent #%d failed: %s',
                    i, tostring(err)))
            end
        end
    end

    print(string.format(
        '[Haikesi LightningStorm] done P%d applied=%d/%d reason=%s',
        iPlayer, applied, count, tostring(reason)))
    return applied
end

function Haikesi_ApplyLightningStormRelic(iPlayer)
    -- 不在选中当回合造暴；挂到下一游戏回合起连续 10 回合
    Game:SetProperty(PROP_REMAIN, STORM_DURATION_TURNS)
    Game:SetProperty(PROP_OWNER, iPlayer)
    print(string.format(
        '[Haikesi LightningStorm] scheduled from next turn duration=%d owner=P%d',
        STORM_DURATION_TURNS, iPlayer))
    return true
end

local function OnTurnBegin()
    local remain = tonumber(Game:GetProperty(PROP_REMAIN) or 0) or 0
    if remain <= 0 then
        return
    end
    local owner = tonumber(Game:GetProperty(PROP_OWNER) or -1) or -1
    FireStormBurst(owner, 'turn-' .. tostring(remain))
    remain = remain - 1
    Game:SetProperty(PROP_REMAIN, remain)
    if remain <= 0 then
        Game:SetProperty(PROP_OWNER, nil)
        print('[Haikesi LightningStorm] follow-up complete')
    else
        print(string.format('[Haikesi LightningStorm] follow-up remain=%d', remain))
    end
end

local function InitializeLightningStorm()
    if ExposedMembers ~= nil then
        ExposedMembers.Haikesi_ApplyLightningStormRelic = Haikesi_ApplyLightningStormRelic
    end
    Events.TurnBegin.Add(OnTurnBegin)
    print('[Haikesi LightningStorm] GamePlay ready (next-turn 10-burst)')
end

Events.LoadScreenClose.Add(InitializeLightningStorm)
