-- ===========================================================================
-- Haikesi_AI_Diplomacy_GamePlay.lua
-- AI diplomatic relic effects that need Gameplay-side target selection.
-- ===========================================================================

local MUSTER_UNIT_COUNT = 5
local MUSTER_SPAWN_RADIUS = 5

local function AIDiploLog(message)
    print('[Haikesi AI Diplomacy] ' .. tostring(message))
end

local function IsMetCityState(pPlayer, cityStateID)
    if pPlayer == nil or cityStateID == nil then return false end
    local diplomacy = pPlayer:GetDiplomacy()
    if diplomacy == nil or diplomacy.HasMet == nil then return false end
    local ok, met = pcall(function() return diplomacy:HasMet(cityStateID) end)
    return ok and met == true
end

local function GetBestCityStateForPlayer(pPlayer)
    if pPlayer == nil then return nil, 0 end
    local playerID = pPlayer:GetID()
    local bestPlayer = nil
    local bestEnvoys = -1

    for cityStateID = 0, 63 do
        local pCityState = Players[cityStateID]
        if pCityState ~= nil and pCityState:IsAlive() then
            local influence = pCityState:GetInfluence()
            local canReceive = false
            if influence ~= nil and influence.CanReceiveInfluence ~= nil then
                local ok, value = pcall(function() return influence:CanReceiveInfluence() end)
                canReceive = ok and value == true
            end
            if canReceive and IsMetCityState(pPlayer, cityStateID) then
                local envoys = 0
                local ok, value = pcall(function() return influence:GetTokensReceived(playerID) end)
                if ok and type(value) == 'number' then
                    envoys = value
                end
                if bestPlayer == nil
                    or envoys > bestEnvoys
                    or (envoys == bestEnvoys and cityStateID < bestPlayer:GetID()) then
                    bestPlayer = pCityState
                    bestEnvoys = envoys
                end
            end
        end
    end
    return bestPlayer, math.max(0, bestEnvoys)
end

local function GetUnitUnlockEraIndex(unitRow)
    if unitRow == nil then return nil end
    if unitRow.PrereqTech ~= nil then
        local tech = GameInfo.Technologies[unitRow.PrereqTech]
        local era = tech ~= nil and GameInfo.Eras[tech.EraType] or nil
        if era ~= nil then return era.Index end
    end
    if unitRow.PrereqCivic ~= nil then
        local civic = GameInfo.Civics[unitRow.PrereqCivic]
        local era = civic ~= nil and GameInfo.Eras[civic.EraType] or nil
        if era ~= nil then return era.Index end
    end
    return nil
end

local function BuildLandCombatUnitPool(eraIndex)
    local pool = {}
    for row in GameInfo.Units() do
        local combat = math.max(
            tonumber(row.Combat) or 0,
            tonumber(row.RangedCombat) or 0,
            tonumber(row.Bombard) or 0)
        if combat > 0
            and row.Domain == 'DOMAIN_LAND'
            and row.FormationClass == 'FORMATION_CLASS_LAND_COMBAT'
            and (row.TraitType == nil or row.TraitType == '')
            and (row.MustPurchase == nil or row.MustPurchase == false or row.MustPurchase == 0)
            and (row.CanTrain == nil or row.CanTrain == true or row.CanTrain == 1)
            and GetUnitUnlockEraIndex(row) == eraIndex then
            table.insert(pool, row.UnitType)
        end
    end
    table.sort(pool)
    return pool
end

local function GetCurrentEraUnitPool()
    local eraIndex = 0
    local eras = Game.GetEras and Game.GetEras() or nil
    if eras ~= nil and eras.GetCurrentEra ~= nil then
        eraIndex = tonumber(eras:GetCurrentEra()) or 0
    end
    for index = eraIndex, 0, -1 do
        local pool = BuildLandCombatUnitPool(index)
        if #pool > 0 then
            return pool, index, eraIndex
        end
    end
    return { 'UNIT_WARRIOR' }, 0, eraIndex
end

local function GatherSpawnPlots(cityStateID, capital)
    local candidates = {}
    local seen = {}
    if capital == nil then return candidates end
    local centerX, centerY = capital:GetX(), capital:GetY()

    for dx = -MUSTER_SPAWN_RADIUS, MUSTER_SPAWN_RADIUS do
        for dy = -MUSTER_SPAWN_RADIUS, MUSTER_SPAWN_RADIUS do
            local plot = Map.GetPlotXY(centerX, centerY, dx, dy)
            if plot ~= nil then
                local plotID = plot:GetIndex()
                local distance = Map.GetPlotDistance(centerX, centerY, plot:GetX(), plot:GetY())
                local owner = plot:GetOwner()
                if distance <= MUSTER_SPAWN_RADIUS
                    and not seen[plotID]
                    and not plot:IsWater()
                    and not plot:IsImpassable()
                    and (owner == cityStateID or owner == -1) then
                    seen[plotID] = true
                    table.insert(candidates, { plot = plot, distance = distance, index = plotID })
                end
            end
        end
    end

    table.sort(candidates, function(a, b)
        if a.distance == b.distance then
            return a.index < b.index
        end
        return a.distance < b.distance
    end)
    return candidates
end

local function SpawnMusterUnits(cityState, count)
    if cityState == nil then return 0 end
    local cities = cityState:GetCities()
    local capital = cities ~= nil and cities:GetCapitalCity() or nil
    if capital == nil then return 0 end

    local pool, usedEra, currentEra = GetCurrentEraUnitPool()
    local plots = GatherSpawnPlots(cityState:GetID(), capital)
    local spawned = 0

    for unitNumber = 1, count do
        local unitType = pool[(Game.GetRandNum(#pool, 'Haikesi AI Muster unit') or 0) + 1]
        local created = nil
        for _, entry in ipairs(plots) do
            local ok, unit = pcall(
                UnitManager.InitUnit,
                cityState:GetID(),
                unitType,
                entry.plot:GetX(),
                entry.plot:GetY())
            if ok and unit ~= nil then
                created = unit
                break
            end
        end
        if created ~= nil then
            spawned = spawned + 1
        else
            AIDiploLog(string.format(
                'muster spawn failed cityState=P%d unit=%s number=%d',
                cityState:GetID(), tostring(unitType), unitNumber))
        end
    end

    AIDiploLog(string.format(
        'muster units cityState=P%d spawned=%d/%d era=%d currentEra=%d pool=%d',
        cityState:GetID(), spawned, count, usedEra, currentEra, #pool))
    return spawned
end

function Haikesi_ApplyAIMusterForward(playerID)
    local pPlayer = Players[playerID]
    if pPlayer == nil then return false end
    local cityState, previousEnvoys = GetBestCityStateForPlayer(pPlayer)
    if cityState == nil then
        AIDiploLog('muster skipped P' .. tostring(playerID) .. ': no met city-state')
        return false
    end

    local influence = pPlayer:GetInfluence()
    local granted = 0
    if influence ~= nil and influence.GiveFreeTokenToPlayer ~= nil then
        for _ = 1, 3 do
            local ok = pcall(function()
                influence:GiveFreeTokenToPlayer(cityState:GetID())
            end)
            if ok then granted = granted + 1 end
        end
    end

    local spawned = SpawnMusterUnits(cityState, MUSTER_UNIT_COUNT)
    AIDiploLog(string.format(
        'muster applied P%d cityState=P%d previousEnvoys=%d granted=%d units=%d',
        playerID, cityState:GetID(), previousEnvoys, granted, spawned))
    return granted > 0 or spawned > 0
end

local function InitializeHaikesiAIDiplomacy()
    if ExposedMembers ~= nil then
        ExposedMembers.Haikesi_ApplyAIMusterForward = Haikesi_ApplyAIMusterForward
    end
    AIDiploLog('Gameplay ready')
end

Events.LoadScreenClose.Add(InitializeHaikesiAIDiplomacy)
