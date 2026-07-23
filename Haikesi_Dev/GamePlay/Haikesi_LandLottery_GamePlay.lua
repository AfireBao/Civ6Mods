-- ===========================================================================
-- Haikesi_LandLottery_GamePlay.lua
-- LANDLOTTERYRUNE 盲盒地脉：地块级随机「地形层」产出（地貌/资源不动）
-- 新纳入版图的地块：一律等到回合结束/下回合初再随机（避免获得时+过回合各一次叠层）
-- ===========================================================================

local LANDLOTTERYRUNE = 'LANDLOTTERYRUNE'
local LL_PLAYER_PROP = 'PROP_NW_HAIKESI_LANDLOTTERY'
local LL_ACTIVE = 'NW_HAIKESI_LL_ACTIVE'
local LL_FOR = 'NW_HAIKESI_LL_FOR'
local LL_BUDGET_FLOOR = 2
local LL_BITS = { 4, 2, 1 }
local LL_YIELD_KEYS = { 'YIELD_FOOD', 'YIELD_PRODUCTION', 'YIELD_GOLD', 'YIELD_FAITH' }

local RelicsCountPropertyKey = 'PROP_NW_HAIKESI_RELIC_COUNT'
local RelicsSlotPropertyPrefix = 'PROP_NW_HAIKESI_RELIC_'
local RelicsPropertyKey = 'PROP_NW_HAIKESI_RELICS'

-- 待随机：plotIndex -> iPlayer（仅回合边界处理）
local g_PendingPlots = {}
-- 建城等：回合边界扫描该玩家「尚未 ACTIVE」的已拥有格
local g_PendingPlayerScan = {}

local function LL_Log(fmt, ...)
    print(string.format("[Haikesi LandLottery] " .. fmt, ...))
end

local function LL_Rand(maxCount, reason)
    if maxCount <= 0 then return 0 end
    if TerrainBuilder ~= nil and TerrainBuilder.GetRandomNumber ~= nil then
        return TerrainBuilder.GetRandomNumber(maxCount, reason)
    end
    if Game.GetRandNum ~= nil then
        return Game.GetRandNum(maxCount, reason) or 0
    end
    -- 禁止 math.random：各端结果会分叉导致联机不同步
    LL_Log("WARN sync RNG missing; return 0 (%s)", tostring(reason))
    return 0
end

local function LL_PropTruthy(value)
    return value == true or value == 1 or value == "1" or tonumber(value) == 1
end

local function LL_GetRelicTypeFromIndex(index)
    for row in GameInfo.Haikesi_Relics() do
        if row.Index == index then
            return row.RelicType
        end
    end
    return nil
end

local function LL_PlayerHasRelic(pPlayer)
    if pPlayer == nil then return false end
    if LL_PropTruthy(pPlayer:GetProperty(LL_PLAYER_PROP)) then return true end
    local count = tonumber(pPlayer:GetProperty(RelicsCountPropertyKey) or 0) or 0
    if count > 0 then
        for i = 1, count do
            if pPlayer:GetProperty(RelicsSlotPropertyPrefix .. i) == LANDLOTTERYRUNE then
                return true
            end
        end
    end
    local legacy = pPlayer:GetProperty(RelicsPropertyKey) or ""
    if legacy ~= "" then
        for idxStr in string.gmatch(legacy, "[^|]+") do
            local idx = tonumber(idxStr)
            if idx ~= nil and LL_GetRelicTypeFromIndex(idx) == LANDLOTTERYRUNE then
                return true
            end
        end
    end
    return false
end

local function LL_GetTerrainBudget(terrainType)
    local total = 0
    for row in GameInfo.Terrain_YieldChanges() do
        if row.TerrainType == terrainType then
            total = total + (tonumber(row.YieldChange) or 0)
        end
    end
    if total < LL_BUDGET_FLOOR then
        total = LL_BUDGET_FLOOR
    end
    return total
end

-- 必须用 false 清 true，避免二次随机叠层
local function LL_ClearPlotYieldProps(pPlot)
    if pPlot == nil then return end
    for _, yieldType in ipairs(LL_YIELD_KEYS) do
        for _, bit in ipairs(LL_BITS) do
            pPlot:SetProperty('NW_HAIKESI_LL_' .. yieldType .. '_' .. tostring(bit), false)
        end
    end
    pPlot:SetProperty(LL_ACTIVE, false)
    pPlot:SetProperty(LL_FOR, 0)
end

local function LL_WriteYieldProps(pPlot, yieldsTable)
    for yieldType, value in pairs(yieldsTable) do
        local remain = tonumber(value) or 0
        if remain > 0 then
            for _, bit in ipairs(LL_BITS) do
                if remain >= bit then
                    remain = remain - bit
                    pPlot:SetProperty('NW_HAIKESI_LL_' .. yieldType .. '_' .. tostring(bit), true)
                end
            end
        end
    end
end

local function LL_RollYields(budget)
    local yields = {
        YIELD_FOOD = 0,
        YIELD_PRODUCTION = 0,
        YIELD_GOLD = 0,
        YIELD_FAITH = 0,
    }
    for _ = 1, budget do
        local key = LL_YIELD_KEYS[1 + LL_Rand(#LL_YIELD_KEYS, 'HaikesiLLYield')]
        yields[key] = yields[key] + 1
    end
    return yields
end

local function LL_IsMountainPlot(pPlot)
    if pPlot == nil then return true end
    if pPlot.IsMountain ~= nil then
        local ok, result = pcall(function() return pPlot:IsMountain() end)
        if ok and result then return true end
    end
    local terrainInfo = GameInfo.Terrains[pPlot:GetTerrainType()]
    if terrainInfo ~= nil and terrainInfo.Mountain then
        return true
    end
    return false
end

local function LL_ShouldSkipPlot(pPlot)
    if pPlot == nil then return true end
    if pPlot:IsImpassable() then return true end
    if LL_IsMountainPlot(pPlot) then return true end
    local districtType = pPlot:GetDistrictType()
    if districtType ~= nil and districtType ~= -1 then
        local distInfo = GameInfo.Districts[districtType]
        if distInfo ~= nil and distInfo.DistrictType ~= 'DISTRICT_CITY_CENTER' then
            return true
        end
    end
    return false
end

local function LL_RandomizePlot(pPlot, iPlayer, force)
    if LL_ShouldSkipPlot(pPlot) then return false end
    if pPlot:GetOwner() ~= iPlayer then return false end

    local forOwner = tonumber(pPlot:GetProperty(LL_FOR) or 0) or 0
    local active = LL_PropTruthy(pPlot:GetProperty(LL_ACTIVE))
    if (not force) and active and forOwner == (iPlayer + 1) then
        return false
    end

    local terrainInfo = GameInfo.Terrains[pPlot:GetTerrainType()]
    if terrainInfo == nil then return false end
    local terrainType = terrainInfo.TerrainType
    local budget = LL_GetTerrainBudget(terrainType)
    if budget <= 0 then return false end

    LL_ClearPlotYieldProps(pPlot)
    local yields = LL_RollYields(budget)
    LL_WriteYieldProps(pPlot, yields)
    pPlot:SetProperty(LL_ACTIVE, true)
    pPlot:SetProperty(LL_FOR, iPlayer + 1)
    return true
end

local function LL_ForEachOwnedPlot(iPlayer, callback)
    local count = Map.GetPlotCount()
    for plotIndex = 0, count - 1 do
        local pPlot = Map.GetPlotByIndex(plotIndex)
        if pPlot ~= nil and pPlot:GetOwner() == iPlayer then
            callback(pPlot)
        end
    end
end

function Haikesi_LandLottery_RandomizePlayer(iPlayer, force)
    local pPlayer = Players[iPlayer]
    if pPlayer == nil or not LL_PlayerHasRelic(pPlayer) then
        return 0
    end
    local n = 0
    local seen = 0
    LL_ForEachOwnedPlot(iPlayer, function(pPlot)
        seen = seen + 1
        if LL_RandomizePlot(pPlot, iPlayer, force == true) then
            n = n + 1
        end
    end)
    LL_Log("P%d owned=%d randomized=%d force=%s", iPlayer, seen, n, tostring(force == true))
    return n
end

local function LL_QueuePlot(iPlayer, pPlot)
    if pPlot == nil or iPlayer == nil then return end
    g_PendingPlots[pPlot:GetIndex()] = iPlayer
end

local function LL_QueuePlayerScan(iPlayer)
    if iPlayer == nil then return end
    g_PendingPlayerScan[iPlayer] = true
end

-- 回合边界：只处理队列中的新格；已 ACTIVE 且归属正确的不重 roll
-- 待处理格必须按 plotIndex 排序后再 roll：pairs 无序会让各端同步 RNG 消费顺序分叉 → 联机不同步
local function LL_FlushPending(reasonTag)
    local queued = 0
    local scanPlayers = {}
    for iPlayer, _ in pairs(g_PendingPlayerScan) do
        table.insert(scanPlayers, iPlayer)
        g_PendingPlayerScan[iPlayer] = nil
    end
    table.sort(scanPlayers)
    for _, iPlayer in ipairs(scanPlayers) do
        local pPlayer = Players[iPlayer]
        if pPlayer ~= nil and LL_PlayerHasRelic(pPlayer) then
            LL_ForEachOwnedPlot(iPlayer, function(pPlot)
                local forOwner = tonumber(pPlot:GetProperty(LL_FOR) or 0) or 0
                local active = LL_PropTruthy(pPlot:GetProperty(LL_ACTIVE))
                if not (active and forOwner == (iPlayer + 1)) then
                    LL_QueuePlot(iPlayer, pPlot)
                end
            end)
        end
    end

    local pendingIndices = {}
    for plotIndex, _ in pairs(g_PendingPlots) do
        table.insert(pendingIndices, plotIndex)
    end
    table.sort(pendingIndices)

    local n = 0
    for _, plotIndex in ipairs(pendingIndices) do
        local iPlayer = g_PendingPlots[plotIndex]
        g_PendingPlots[plotIndex] = nil
        queued = queued + 1
        local pPlot = Map.GetPlotByIndex(plotIndex)
        if pPlot ~= nil and iPlayer ~= nil and pPlot:GetOwner() == iPlayer then
            if LL_RandomizePlot(pPlot, iPlayer, true) then
                n = n + 1
            end
        end
    end

    if queued > 0 or n > 0 then
        LL_Log("flush via=%s queued=%d randomized=%d", tostring(reasonTag), queued, n)
    end
end

local function LL_CountMappedModifiers()
    local n = 0
    if GameInfo.Haikesi_Relic_Modifiers == nil then
        return 0
    end
    for row in GameInfo.Haikesi_Relic_Modifiers() do
        if row.RelicType == LANDLOTTERYRUNE then
            n = n + 1
        end
    end
    return n
end

function Haikesi_ApplyLandLotteryRelic(iPlayer)
    local pPlayer = Players[iPlayer]
    if pPlayer == nil then
        LL_Log("Apply missing player %s", tostring(iPlayer))
        return
    end
    pPlayer:SetProperty(LL_PLAYER_PROP, 1)

    local mapped = LL_CountMappedModifiers()
    if mapped > 0 then
        LL_Log("Relic_Modifiers has %d LL rows; skip Lua Attach (avoid double negate)", mapped)
    else
        local nMod = 0
        for row in GameInfo.Modifiers() do
            local id = row.ModifierId
            if id ~= nil and string.sub(id, 1, 15) == 'MODIFIER_NW_LL_' then
                pPlayer:AttachModifierByID(id)
                nMod = nMod + 1
            end
        end
        LL_Log("SQL binding missing; Lua Attach LL modifiers: %d", nMod)
        if nMod <= 0 then
            LL_Log("WARN no MODIFIER_NW_LL_* in GameInfo — SQL failed to load")
        end
    end

    -- 选卡当下：只处理已拥有格（一次性）；之后新地一律等过回合
    local n = Haikesi_LandLottery_RandomizePlayer(iPlayer, true)
    LL_Log("Apply LANDLOTTERYRUNE P%d -> %d plots", iPlayer, n)
    if n <= 0 then
        LL_Log("WARN P%d randomized 0 plots — check ownership / skip rules", iPlayer)
    end
end

local function LL_OnCityTileOwnershipChanged(ownerPlayerID, cityID, iX, iY)
    local pPlayer = Players[ownerPlayerID]
    if pPlayer == nil or not LL_PlayerHasRelic(pPlayer) then return end
    local pPlot = Map.GetPlot(iX, iY)
    if pPlot == nil then return end
    if LL_ShouldSkipPlot(pPlot) then return end
    LL_QueuePlot(ownerPlayerID, pPlot)
    LL_Log("queue tile (%d,%d) P%d city=%d (wait turn boundary)", iX, iY, ownerPlayerID, cityID)
end

local function LL_OnCityInitialized(playerID, cityID)
    local pPlayer = Players[playerID]
    if pPlayer == nil or not LL_PlayerHasRelic(pPlayer) then return end
    LL_QueuePlayerScan(playerID)
    LL_Log("queue player-scan P%d city=%d (wait turn boundary)", playerID, cityID)
end

local function LL_OnLoadGameViewStateDone()
    for iPlayer = 0, 63 do
        local pPlayer = Players[iPlayer]
        if pPlayer ~= nil and pPlayer:IsMajor() and LL_PlayerHasRelic(pPlayer) then
            -- 读档补漏：只补尚未 ACTIVE 的格，不重 roll
            Haikesi_LandLottery_RandomizePlayer(iPlayer, false)
        end
    end
end

if Events.CityTileOwnershipChanged ~= nil then
    Events.CityTileOwnershipChanged.Add(LL_OnCityTileOwnershipChanged)
end
if Events.CityInitialized ~= nil then
    Events.CityInitialized.Add(LL_OnCityInitialized)
end
-- 只在 TurnEnd 刷一次，避免 TurnEnd+TurnBegin 各刷导致同一批地两遍
if Events.TurnEnd ~= nil then
    Events.TurnEnd.Add(function() LL_FlushPending("TurnEnd") end)
end
if Events.LoadGameViewStateDone ~= nil then
    Events.LoadGameViewStateDone.Add(LL_OnLoadGameViewStateDone)
end

if ExposedMembers ~= nil then
    ExposedMembers.Haikesi_ApplyLandLotteryRelic = Haikesi_ApplyLandLotteryRelic
    ExposedMembers.Haikesi_LandLottery_RandomizePlayer = Haikesi_LandLottery_RandomizePlayer
end

LL_Log("GamePlay bridge ready")
