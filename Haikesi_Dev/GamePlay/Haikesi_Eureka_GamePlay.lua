-- ===========================================================================
-- Haikesi_Eureka_GamePlay.lua
-- 小丑学院 / 尤里卡：建筑建成时触发随机科技提升。
-- ===========================================================================

local CLOWN_COLLEGE_RELIC = 'CLOWNCOLLEGERUNE'
local EUREKA_RELIC = 'EUREKARUNE'
local HAPPY_ACCIDENT_RELIC = 'HAPPYACCIDENTRUNE'

local RelicsCountPropertyKey = 'PROP_NW_HAIKESI_RELIC_COUNT'
local RelicsSlotPropertyPrefix = 'PROP_NW_HAIKESI_RELIC_'

local BUILDING_LIBRARY = 'BUILDING_LIBRARY'
local BUILDING_UNIVERSITY = 'BUILDING_UNIVERSITY'
local BUILDING_RESEARCH_LAB = 'BUILDING_RESEARCH_LAB'

local CLOWN_FIRST_PROP_PREFIX = 'PROP_NW_HAIKESI_CLOWN_FIRST_EUREKA_'
local EUREKA_LIBRARY_CITY_PROP = 'PROP_NW_HAIKESI_EUREKA_LIBRARY_GRANTED'

local g_BuildingTypeByIndex = {}
local g_TechsWithBoost = {}
local g_CivicsWithBoost = {}

local function EurekaLog(fmt, ...)
    print(string.format('[Haikesi Eureka] ' .. fmt, ...))
end

local function PlayerHasRelic(pPlayer, relicType)
    if pPlayer == nil or relicType == nil then return false end

    local count = tonumber(pPlayer:GetProperty(RelicsCountPropertyKey) or 0) or 0
    for i = 1, count do
        local stored = pPlayer:GetProperty(RelicsSlotPropertyPrefix .. tostring(i))
        if stored == relicType then
            return true
        end
    end
    return false
end

local function BuildCaches()
    if next(g_BuildingTypeByIndex) == nil then
        for row in GameInfo.Buildings() do
            g_BuildingTypeByIndex[row.Index] = row.BuildingType
        end
    end

    if (next(g_TechsWithBoost) == nil or next(g_CivicsWithBoost) == nil) and GameInfo.Boosts ~= nil then
        for row in GameInfo.Boosts() do
            if row.TechnologyType ~= nil then
                g_TechsWithBoost[row.TechnologyType] = true
            end
            if row.CivicType ~= nil then
                g_CivicsWithBoost[row.CivicType] = true
            end
        end
    end
end

local function PickRandomIndex(maxCount, reason)
    if maxCount <= 0 then return nil end
    if TerrainBuilder ~= nil and TerrainBuilder.GetRandomNumber ~= nil then
        return TerrainBuilder.GetRandomNumber(maxCount, reason)
    end
    return Game.GetRandNum(maxCount, reason) or 0
end

local function CollectBoostCandidates(pPlayerTechs, requireCanResearch)
    local candidates = {}
    for tech in GameInfo.Technologies() do
        local hasBoost = g_TechsWithBoost[tech.TechnologyType] == true
        local alreadyKnown = pPlayerTechs:HasTech(tech.Index)
        local alreadyBoosted = pPlayerTechs:HasBoostBeenTriggered(tech.Index)
        local canResearch = true
        if requireCanResearch and pPlayerTechs.CanResearch ~= nil then
            canResearch = pPlayerTechs:CanResearch(tech.Index)
        end
        if hasBoost and not alreadyKnown and not alreadyBoosted and canResearch then
            table.insert(candidates, tech)
        end
    end
    return candidates
end

local function GrantRandomTechBoost(pPlayer, reason)
    if pPlayer == nil then return false end
    local pPlayerTechs = pPlayer:GetTechs()
    if pPlayerTechs == nil or pPlayerTechs.TriggerBoost == nil then
        EurekaLog('ERROR: P%s tech API missing', tostring(pPlayer:GetID()))
        return false
    end

    BuildCaches()

    local candidates = CollectBoostCandidates(pPlayerTechs, true)
    if #candidates == 0 then
        candidates = CollectBoostCandidates(pPlayerTechs, false)
    end
    if #candidates == 0 then
        EurekaLog('P%d no available tech boost candidate (%s)', pPlayer:GetID(), tostring(reason))
        return false
    end

    local pick = PickRandomIndex(#candidates, 'Haikesi_Random_Tech_Boost_' .. tostring(reason)) or 0
    local tech = candidates[pick + 1]
    if tech == nil then return false end

    pPlayerTechs:TriggerBoost(tech.Index)
    EurekaLog('P%d triggered random eureka %s (%s)', pPlayer:GetID(), tostring(tech.TechnologyType), tostring(reason))
    return true
end

local function CollectCivicBoostCandidates(pPlayerCulture, requireCanTrigger)
    local candidates = {}
    for civic in GameInfo.Civics() do
        local hasBoost = g_CivicsWithBoost[civic.CivicType] == true
        local alreadyKnown = pPlayerCulture:HasCivic(civic.Index)
        local alreadyBoosted = pPlayerCulture:HasBoostBeenTriggered(civic.Index)
        local canTrigger = true
        if requireCanTrigger and pPlayerCulture.CanTriggerBoost ~= nil then
            canTrigger = pPlayerCulture:CanTriggerBoost(civic.Index)
        end
        if hasBoost and not alreadyKnown and not alreadyBoosted and canTrigger then
            table.insert(candidates, civic)
        end
    end
    return candidates
end

local function GrantRandomCivicBoost(pPlayer, reason)
    if pPlayer == nil then return false end
    local pPlayerCulture = pPlayer:GetCulture()
    if pPlayerCulture == nil or pPlayerCulture.TriggerBoost == nil then
        EurekaLog('ERROR: P%s culture API missing', tostring(pPlayer:GetID()))
        return false
    end

    BuildCaches()

    local candidates = CollectCivicBoostCandidates(pPlayerCulture, true)
    if #candidates == 0 then
        candidates = CollectCivicBoostCandidates(pPlayerCulture, false)
    end
    if #candidates == 0 then
        EurekaLog('P%d no available civic boost candidate (%s)', pPlayer:GetID(), tostring(reason))
        return false
    end

    local pick = PickRandomIndex(#candidates, 'Haikesi_Random_Civic_Boost_' .. tostring(reason)) or 0
    local civic = candidates[pick + 1]
    if civic == nil then return false end

    pPlayerCulture:TriggerBoost(civic.Index)
    EurekaLog('P%d triggered random inspiration %s (%s)', pPlayer:GetID(), tostring(civic.CivicType), tostring(reason))
    return true
end

local function GetNearestPlayerCity(pPlayer, x, y)
    if pPlayer == nil or x == nil or y == nil then return nil end
    local pCities = pPlayer:GetCities()
    if pCities == nil then return nil end

    local bestCity = nil
    local bestDistance = nil
    for _, pCity in pCities:Members() do
        if pCity ~= nil then
            local distance = Map.GetPlotDistance(x, y, pCity:GetX(), pCity:GetY())
            if bestDistance == nil or distance < bestDistance then
                bestDistance = distance
                bestCity = pCity
            end
        end
    end
    return bestCity
end

local function ResolveBuildingConstructedArgs(pPlayer, arg2, arg3, arg4, arg5)
    local buildingType = nil
    local pCity = nil

    if type(arg2) == 'string' then
        buildingType = arg2
        local x = tonumber(arg3)
        local y = tonumber(arg4)
        if x ~= nil and y ~= nil then
            pCity = CityManager.GetCityAt(x, y) or GetNearestPlayerCity(pPlayer, x, y)
        end
    else
        local cityID = tonumber(arg2)
        if cityID ~= nil then
            pCity = CityManager.GetCity(pPlayer:GetID(), cityID)
        end

        if type(arg3) == 'string' then
            buildingType = arg3
            local x = tonumber(arg4)
            local y = tonumber(arg5)
            if pCity == nil and x ~= nil and y ~= nil then
                pCity = CityManager.GetCityAt(x, y) or GetNearestPlayerCity(pPlayer, x, y)
            end
        else
            local buildingIndex = tonumber(arg3)
            if buildingIndex ~= nil then
                local buildingInfo = GameInfo.Buildings[buildingIndex]
                if buildingInfo ~= nil then
                    buildingType = buildingInfo.BuildingType
                end
            end
        end
    end

    return buildingType, pCity
end

local function OnBuildingConstructed(playerID, arg2, arg3, arg4, arg5)
    local pPlayer = Players[playerID]
    if pPlayer == nil or not pPlayer:IsMajor() then return end

    BuildCaches()
    local buildingType, pCity = ResolveBuildingConstructedArgs(pPlayer, arg2, arg3, arg4, arg5)
    if buildingType == nil then return end
    local buildingInfo = GameInfo.Buildings[buildingType]

    if PlayerHasRelic(pPlayer, CLOWN_COLLEGE_RELIC)
        and (buildingType == BUILDING_LIBRARY or buildingType == BUILDING_UNIVERSITY or buildingType == BUILDING_RESEARCH_LAB) then
        local propKey = CLOWN_FIRST_PROP_PREFIX .. buildingType
        if pPlayer:GetProperty(propKey) ~= 1 then
            pPlayer:SetProperty(propKey, 1)
            GrantRandomTechBoost(pPlayer, 'CLOWNCOLLEGE_' .. buildingType)
        end
    end

    if buildingType == BUILDING_LIBRARY and PlayerHasRelic(pPlayer, EUREKA_RELIC) then
        if pCity == nil then
            EurekaLog('P%d library eureka skipped: city unresolved', playerID)
            return
        end
        if pCity:GetProperty(EUREKA_LIBRARY_CITY_PROP) ~= 1 then
            pCity:SetProperty(EUREKA_LIBRARY_CITY_PROP, 1)
            GrantRandomTechBoost(pPlayer, 'EUREKARUNE_LIBRARY')
        end
    end

    if buildingInfo ~= nil
        and (buildingInfo.IsWonder == true or buildingInfo.IsWonder == 1)
        and PlayerHasRelic(pPlayer, HAPPY_ACCIDENT_RELIC) then
        GrantRandomCivicBoost(pPlayer, 'HAPPYACCIDENT_WONDER_' .. buildingType)
    end
end

local function InitializeEurekaGamePlay()
    BuildCaches()
    if GameEvents ~= nil and GameEvents.BuildingConstructed ~= nil then
        GameEvents.BuildingConstructed.Add(OnBuildingConstructed)
        EurekaLog('listening GameEvents.BuildingConstructed')
    else
        EurekaLog('ERROR: GameEvents.BuildingConstructed missing')
    end
end

Events.LoadScreenClose.Add(InitializeEurekaGamePlay)
