-- ===========================================================================
-- Haikesi_RiverFlood_GamePlay.lua
-- 仇水连汛 (NW_AI_RIVER_FLOOD)：
-- 对触发者关系最差的最多 3 名存活主要文明，收集其城市附近可泛滥命名河；
-- 选中后从下一 TurnBegin 起连续 5 回合，每回合对这些河 ApplyEvent 官方洪水。
-- 强度：70% 千年洪水 / 30% 重大洪水。未接触文明 DEFAULT_REL_SCORE=0。
-- ===========================================================================

local FLOOD_DURATION_TURNS = 5
local WORST_TARGET_COUNT = 3
local CITY_RIVER_RADIUS = 3
local DEFAULT_REL_SCORE = 0 -- 未接触
local FLOOD_1000_YEAR_CHANCE = 70 -- 其余为 MAJOR

local PROP_REMAIN = 'PROP_NW_AI_RIVER_FLOOD_REMAIN'
local PROP_OWNER = 'PROP_NW_AI_RIVER_FLOOD_OWNER'
local PROP_RIVERS = 'PROP_NW_AI_RIVER_FLOOD_RIVERS'

local DIPlo_STATE_SCORE = {
    WAR = -100,
    DENOUNCED = -60,
    UNFRIENDLY = -30,
    NEUTRAL = 0,
    FRIENDLY = 25,
    DECLARED_FRIEND = 40,
    ALLIED = 60,
}

local function PickRoll(denom, tag)
    if TerrainBuilder ~= nil and TerrainBuilder.GetRandomNumber ~= nil then
        return TerrainBuilder.GetRandomNumber(denom, tag)
    end
    if Game ~= nil and Game.GetRandNum ~= nil then
        return Game.GetRandNum(denom, tag) or 0
    end
    return math.random(0, denom - 1)
end

local function HasMetPlayer(fromId, towardId)
    local pFrom = Players[fromId]
    if pFrom == nil then
        return false
    end
    local met = false
    pcall(function()
        local d = pFrom:GetDiplomacy()
        if d ~= nil and d.HasMet ~= nil then
            met = d:HasMet(towardId) == true
        end
    end)
    return met
end

local function ReadUiDipScore(fromId, towardId)
    local key = tostring(fromId) .. '_' .. tostring(towardId)
    local packed = nil
    if ExposedMembers ~= nil and ExposedMembers.Haikesi_UIDipByPair ~= nil then
        packed = ExposedMembers.Haikesi_UIDipByPair[key]
    end
    if packed == nil or tostring(packed) == '' then
        packed = Game:GetProperty('PROP_NW_HAIKESI_UI_DIP_' .. key)
    end
    if packed == nil or tostring(packed) == '' then
        return nil
    end
    local _, sc = string.match(tostring(packed), '^([^;]*);([^;]*);')
    return tonumber(sc)
end

local function ResolveDiploStateScore(fromId, towardId)
    local name = nil
    pcall(function()
        local d = Players[fromId]:GetDiplomacy()
        if d == nil then
            return
        end
        if d.IsAtWarWith and d:IsAtWarWith(towardId) then
            name = 'WAR'
        elseif d.HasAllied and d:HasAllied(towardId) then
            name = 'ALLIED'
        elseif d.HasDeclaredFriendship and d:HasDeclaredFriendship(towardId) then
            name = 'DECLARED_FRIEND'
        end
    end)
    if name == nil then
        pcall(function()
            local ai = Players[fromId]:GetDiplomaticAI()
            if ai == nil then
                return
            end
            if ai.GetDiplomaticState ~= nil then
                local st = ai:GetDiplomaticState(towardId)
                if type(st) == 'string' then
                    name = tostring(st):gsub('^DIPLO_STATE_', '')
                elseif st ~= nil and GameInfo.DiplomaticStates[st] ~= nil then
                    local row = GameInfo.DiplomaticStates[st]
                    if row.StateType ~= nil then
                        name = tostring(row.StateType):gsub('^DIPLO_STATE_', '')
                    end
                end
            end
        end)
    end
    if name ~= nil and DIPlo_STATE_SCORE[name] ~= nil then
        return DIPlo_STATE_SCORE[name]
    end
    return nil
end

-- 触发者 fromId 对 towardId 的关系分；越低越差。未接触 → DEFAULT_REL_SCORE
local function GetRelationshipScore(fromId, towardId)
    if not HasMetPlayer(fromId, towardId) then
        return DEFAULT_REL_SCORE
    end
    local uiScore = ReadUiDipScore(fromId, towardId)
    if uiScore ~= nil then
        return uiScore
    end
    local score = nil
    pcall(function()
        local ai = Players[fromId]:GetDiplomaticAI()
        if ai == nil then
            return
        end
        if ai.GetDiplomaticScore ~= nil then
            local s = ai:GetDiplomaticScore(towardId)
            if s ~= nil then
                score = tonumber(s)
            end
        end
        if score == nil and ai.GetDiplomaticModifiers ~= nil then
            local mods = ai:GetDiplomaticModifiers(towardId)
            if mods ~= nil then
                local sum = 0
                for _, mod in ipairs(mods) do
                    sum = sum + (mod.Score or 0)
                end
                score = sum
            end
        end
    end)
    if score ~= nil then
        return score
    end
    local stateScore = ResolveDiploStateScore(fromId, towardId)
    if stateScore ~= nil then
        return stateScore
    end
    return DEFAULT_REL_SCORE
end

local function PickWorstRelatedPlayers(ownerId, maxCount)
    local ranked = {}
    for _, pOther in ipairs(PlayerManager.GetAliveMajors()) do
        if pOther ~= nil and not pOther:IsBarbarian() then
            local oid = pOther:GetID()
            if oid ~= ownerId then
                local score = GetRelationshipScore(ownerId, oid)
                local met = HasMetPlayer(ownerId, oid)
                table.insert(ranked, { id = oid, score = score, met = met })
            end
        end
    end
    table.sort(ranked, function(a, b)
        if a.score ~= b.score then
            return a.score < b.score
        end
        return a.id < b.id
    end)
    local out = {}
    for i = 1, math.min(maxCount, #ranked) do
        table.insert(out, ranked[i])
    end
    return out
end

local function AddRiverAtPlot(x, y, riverSet, riverList)
    if RiverManager == nil or RiverManager.GetRiverForFloodplain == nil then
        return
    end
    local eRiver = RiverManager.GetRiverForFloodplain(x, y)
    if eRiver == nil or eRiver < 0 then
        return
    end
    -- ApplyEvent.NamedRiver 使用 NamedRivers.Index；GetRiverForFloodplain 返回可交给 GetFloodplainPlots 的河 ID
    local namedIndex = eRiver
    if RiverManager.GetRiverType ~= nil then
        local ok, rType = pcall(function()
            return RiverManager.GetRiverType(eRiver)
        end)
        if ok and rType ~= nil and GameInfo.NamedRivers ~= nil then
            local row = GameInfo.NamedRivers[rType]
            if row ~= nil and row.Index ~= nil then
                namedIndex = row.Index
            end
        end
    end
    if riverSet[namedIndex] then
        return
    end
    -- 仅保留可取到泛滥格的河
    if RiverManager.GetFloodplainPlots ~= nil then
        local plots = RiverManager.GetFloodplainPlots(eRiver)
        if plots == nil then
            plots = RiverManager.GetFloodplainPlots(namedIndex)
        end
        if plots == nil then
            return
        end
    end
    riverSet[namedIndex] = true
    table.insert(riverList, namedIndex)
end

local function CollectRiversForPlayer(playerID)
    local riverSet = {}
    local riverList = {}
    local pPlayer = Players[playerID]
    if pPlayer == nil then
        return riverList
    end
    local cities = pPlayer:GetCities()
    if cities == nil then
        return riverList
    end
    for _, city in cities:Members() do
        if city ~= nil then
            local cx, cy = city:GetX(), city:GetY()
            for dx = -CITY_RIVER_RADIUS, CITY_RIVER_RADIUS do
                for dy = -CITY_RIVER_RADIUS, CITY_RIVER_RADIUS do
                    if Map.GetPlotDistance(cx, cy, cx + dx, cy + dy) <= CITY_RIVER_RADIUS then
                        local plot = Map.GetPlot(cx + dx, cy + dy)
                        if plot ~= nil and plot:GetOwner() == playerID then
                            local can = true
                            if RiverManager ~= nil and RiverManager.CanBeFlooded ~= nil then
                                can = RiverManager.CanBeFlooded(plot) == true
                            end
                            if can then
                                AddRiverAtPlot(plot:GetX(), plot:GetY(), riverSet, riverList)
                            end
                        end
                    end
                end
            end
        end
    end
    return riverList
end

local function SerializeInts(list)
    if list == nil or #list == 0 then
        return ''
    end
    local parts = {}
    for _, v in ipairs(list) do
        table.insert(parts, tostring(v))
    end
    return table.concat(parts, ',')
end

local function DeserializeInts(str)
    local list = {}
    if str == nil or str == '' then
        return list
    end
    for token in string.gmatch(tostring(str), '[^,]+') do
        local n = tonumber(token)
        if n ~= nil then
            table.insert(list, n)
        end
    end
    return list
end

local function ResolveFloodEventIndex()
    local roll = PickRoll(100, 'HaikesiRiverFlood')
    local key = 'RANDOM_EVENT_FLOOD_MAJOR'
    if roll < FLOOD_1000_YEAR_CHANCE then
        key = 'RANDOM_EVENT_FLOOD_1000_YEAR'
    end
    local row = GameInfo.RandomEvents[key]
    if row == nil then
        return nil, key
    end
    return row.Index, key
end

local function FireFloodBurst(ownerId, riverList, reason)
    if GameRandomEvents == nil or GameRandomEvents.ApplyEvent == nil then
        print('[Haikesi RiverFlood] ApplyEvent unavailable')
        return 0
    end
    if riverList == nil or #riverList == 0 then
        print(string.format(
            '[Haikesi RiverFlood] skip P%d reason=%s — no rivers',
            ownerId, tostring(reason)))
        return 0
    end
    print(string.format(
        '[Haikesi RiverFlood] start P%d rivers=%d reason=%s turn=%s',
        ownerId, #riverList, tostring(reason), tostring(Game.GetCurrentGameTurn())))
    local applied = 0
    for i, riverIndex in ipairs(riverList) do
        local eventIndex, eventKey = ResolveFloodEventIndex()
        if eventIndex == nil then
            print('[Haikesi RiverFlood] missing event ' .. tostring(eventKey))
        else
            local kEvent = {
                EventType = eventIndex,
                NamedRiver = riverIndex,
            }
            local ok, err = pcall(function()
                GameRandomEvents.ApplyEvent(kEvent)
            end)
            if ok then
                applied = applied + 1
                print(string.format(
                    '[Haikesi RiverFlood] ApplyEvent #%d/%d river=%s %s',
                    i, #riverList, tostring(riverIndex), tostring(eventKey)))
            else
                print(string.format(
                    '[Haikesi RiverFlood] ApplyEvent #%d failed: %s',
                    i, tostring(err)))
            end
        end
    end
    print(string.format(
        '[Haikesi RiverFlood] done P%d applied=%d/%d reason=%s',
        ownerId, applied, #riverList, tostring(reason)))
    return applied
end

function Haikesi_ApplyRiverFloodRelic(iPlayer)
    local targets = PickWorstRelatedPlayers(iPlayer, WORST_TARGET_COUNT)
    local riverSet = {}
    local riverList = {}
    local targetDesc = {}
    for _, t in ipairs(targets) do
        table.insert(targetDesc, string.format(
            'P%d(score=%s,met=%s)', t.id, tostring(t.score), tostring(t.met)))
        local rivers = CollectRiversForPlayer(t.id)
        for _, r in ipairs(rivers) do
            if not riverSet[r] then
                riverSet[r] = true
                table.insert(riverList, r)
            end
        end
    end

    print(string.format(
        '[Haikesi RiverFlood] targets=[%s] rivers=%d owner=P%d',
        table.concat(targetDesc, ','), #riverList, iPlayer))

    Game:SetProperty(PROP_REMAIN, FLOOD_DURATION_TURNS)
    Game:SetProperty(PROP_OWNER, iPlayer)
    Game:SetProperty(PROP_RIVERS, SerializeInts(riverList))
    print(string.format(
        '[Haikesi RiverFlood] scheduled from next turn duration=%d rivers=%s',
        FLOOD_DURATION_TURNS, SerializeInts(riverList)))
    return true
end

local function OnTurnBegin()
    local remain = tonumber(Game:GetProperty(PROP_REMAIN) or 0) or 0
    if remain <= 0 then
        return
    end
    local owner = tonumber(Game:GetProperty(PROP_OWNER) or -1) or -1
    local rivers = DeserializeInts(Game:GetProperty(PROP_RIVERS) or '')
    FireFloodBurst(owner, rivers, 'turn-' .. tostring(remain))
    remain = remain - 1
    Game:SetProperty(PROP_REMAIN, remain)
    if remain <= 0 then
        Game:SetProperty(PROP_OWNER, nil)
        Game:SetProperty(PROP_RIVERS, nil)
        print('[Haikesi RiverFlood] follow-up complete')
    else
        print(string.format('[Haikesi RiverFlood] follow-up remain=%d', remain))
    end
end

local function InitializeRiverFlood()
    if ExposedMembers ~= nil then
        ExposedMembers.Haikesi_ApplyRiverFloodRelic = Haikesi_ApplyRiverFloodRelic
    end
    Events.TurnBegin.Add(OnTurnBegin)
    print('[Haikesi RiverFlood] GamePlay ready (next-turn 5-flood, unmet=DEFAULT_REL_SCORE)')
end

Events.LoadScreenClose.Add(InitializeRiverFlood)
