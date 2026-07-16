-- ===========================================================================
-- Haikesi_Barbarian_GamePlay.lua
-- 南蛮入侵 (NW_AI_BARBARIAN_INVASION)：从主 GamePlay 脚本拆出，避免寄存器超限。
-- ===========================================================================

local BARBARIAN_CAMP_IMPROVEMENT = 'IMPROVEMENT_BARBARIAN_CAMP'
local INVASION_CAMP_DISTANCE = 5
local INVASION_CAMPS_PER_PLAYER = 3
local INVASION_UNITS_PER_MISSING_CAMP = 3
local INVASION_NO_CAMP_UNIT_DISTANCE = 4
local INVASION_FALLBACK_UNIT_RADIUS = 3
-- 补兵成功后：50% 令该氏族对目标城市发动原版攻城行动（煽动近似）
local INVASION_REINFORCE_ASSAULT_CHANCE = 50
local BARBARIAN_CITY_ASSAULT_OPERATION = 'Barbarian City Assault'
local BARBARIAN_CAMP_MINIMUM_DISTANCE_ANOTHER_CAMP = 7
local BARBARIAN_CAMP_MINIMUM_DISTANCE_CITY = 4
local BARBARIAN_FALLBACK_UNIT = 'UNIT_WARRIOR'
local BARBARIAN_HORSE_RESOURCE = 'RESOURCE_HORSES'
local BARBARIAN_HORSE_RANGE = 3
local BARBARIAN_TRIBE_UNIT_RANGE = 3
-- CreateTribeOfType 返回的部落索引/类型缓存
-- 注意：GetTribeIndexAtLocation 仅 UI 可用，Gameplay 必须靠缓存/存档属性/附近单位反查
local g_BarbarianTribeIndexByPlot = {}
local g_BarbarianTribeTypeByPlot = {}
-- plot → TribeDisplayName 的 LOC key（如 LOC_BARBARIAN_CLAN_MELEE_OPEN_1）
local g_BarbarianTribeNameLocByPlot = {}
local BARB_TRIBE_MAP_PROP = 'PROP_NW_HAIKESI_BARB_TRIBE_MAP'
-- Gameplay 排队，UI 桥接取专名后发通知（GetTribeNameType 仅 UI 可靠）
local BARB_ASSAULT_NOTIFY_PROP = 'PROP_NW_HAIKESI_BARB_ASSAULT_NOTIFY'
local BARB_TRIBE_LOOKUP_RADIUS = 8
local HAIKESI_BARB_HORSEMAN_TAG = 'CLASS_HAIKESI_BARB_HORSEMAN'
local HAIKESI_BARB_HORSE_ARCHER_TAG = 'CLASS_HAIKESI_BARB_HORSE_ARCHER'
local HAIKESI_BARB_GALLEY_TAG = 'CLASS_HAIKESI_BARB_GALLEY'
local HAIKESI_BARB_QUADRIREME_TAG = 'CLASS_HAIKESI_BARB_QUADRIREME'
local BARBARIAN_HORSEMAN_UNIT = 'UNIT_BARBARIAN_HORSEMAN'
local BARBARIAN_HORSE_ARCHER_UNIT = 'UNIT_BARBARIAN_HORSE_ARCHER'
local BARBARIAN_GALLEY_UNIT = 'UNIT_GALLEY'
local BARBARIAN_QUADRIREME_UNIT = 'UNIT_QUADRIREME'

-- 本脚本独立 Gameplay VM，不能依赖主脚本 local
local CityFoundedTurnKey = 'PROP_NW_HAIKESI_CITY_FOUNDED_TURN'
local CityFoundedSequenceKey = 'PROP_NW_HAIKESI_CITY_FOUNDED_SEQUENCE'

local function PickRandomIndex(maxCount, reason)
    if maxCount <= 0 then
        return 0
    end
    if TerrainBuilder ~= nil and TerrainBuilder.GetRandomNumber ~= nil then
        return TerrainBuilder.GetRandomNumber(maxCount, reason)
    end
    return Game.GetRandNum(maxCount, reason) or 0
end

-- 与主脚本同逻辑：按 CityBuilt 跟踪的 turn/sequence 取最新城
local function GetNewestCityForPlayer(pPlayer)
    if pPlayer == nil then
        return nil
    end
    local pCities = pPlayer:GetCities()
    if pCities == nil then
        return nil
    end
    local newestCity = nil
    local newestTurn = -1
    local newestSequence = -1
    local newestCityID = -1
    for _, pCity in pCities:Members() do
        if pCity ~= nil then
            local foundedTurn = tonumber(pCity:GetProperty(CityFoundedTurnKey))
            local foundedSequence = tonumber(pCity:GetProperty(CityFoundedSequenceKey))
            local cityID = pCity:GetID()
            local hasTrackedTurn = foundedTurn ~= nil
            local newestHasTrackedTurn = newestTurn >= 0

            if (hasTrackedTurn and not newestHasTrackedTurn)
                or (hasTrackedTurn and newestHasTrackedTurn
                    and (foundedTurn > newestTurn
                        or (foundedTurn == newestTurn
                            and ((foundedSequence or -1) > newestSequence
                                or ((foundedSequence or -1) == newestSequence
                                    and cityID > newestCityID)))))
                or (not hasTrackedTurn and not newestHasTrackedTurn and cityID > newestCityID) then
                newestTurn = foundedTurn or -1
                newestSequence = foundedSequence or -1
                newestCityID = cityID
                newestCity = pCity
            end
        end
    end
    return newestCity
end

local function GetBarbarianCampImprovementIndex()
    local row = GameInfo.Improvements[BARBARIAN_CAMP_IMPROVEMENT]
    if row == nil then
        return nil
    end
    return row.Index
end

local function IsFarEnoughFromBarbarianCamps(pPlot, iBarbCampIndex)
    for plotIndex = 0, Map.GetPlotCount() - 1 do
        local pExistingPlot = Map.GetPlotByIndex(plotIndex)
        if pExistingPlot ~= nil
            and pExistingPlot:GetImprovementType() == iBarbCampIndex
            and Map.GetPlotDistance(
                pPlot:GetX(), pPlot:GetY(),
                pExistingPlot:GetX(), pExistingPlot:GetY())
                < BARBARIAN_CAMP_MINIMUM_DISTANCE_ANOTHER_CAMP then
            return false
        end
    end
    return true
end

local function IsFarEnoughFromCities(pPlot)
    for playerID = 0, 63 do
        local pPlayer = Players[playerID]
        if pPlayer ~= nil then
            local pCities = pPlayer:GetCities()
            if pCities ~= nil then
                for _, pCity in pCities:Members() do
                    if pCity ~= nil
                        and Map.GetPlotDistance(
                            pPlot:GetX(), pPlot:GetY(),
                            pCity:GetX(), pCity:GetY())
                            < BARBARIAN_CAMP_MINIMUM_DISTANCE_CITY then
                        return false
                    end
                end
            end
        end
    end
    return true
end

local function CanPlaceBarbarianCampWithVanillaSpacing(pPlot, iBarbCampIndex)
    return ImprovementBuilder.CanHaveImprovement(pPlot, iBarbCampIndex, -1)
        and IsFarEnoughFromBarbarianCamps(pPlot, iBarbCampIndex)
        and IsFarEnoughFromCities(pPlot)
end

local function GatherBarbarianCampPlotsAtDistance(centerX, centerY, distance, iBarbCampIndex, usedPlotIDs)
    local candidates = {}
    local candidatePlotIDs = {}
    for dx = -distance, distance do
        for dy = -distance, distance do
            local pPlot = Map.GetPlotXY(centerX, centerY, dx, dy)
            if pPlot ~= nil then
                local dist = Map.GetPlotDistance(centerX, centerY, pPlot:GetX(), pPlot:GetY())
                local plotID = pPlot:GetIndex()
                if dist == distance
                    and not usedPlotIDs[plotID]
                    and not candidatePlotIDs[plotID]
                    and pPlot:GetImprovementType() ~= iBarbCampIndex
                    and CanPlaceBarbarianCampWithVanillaSpacing(pPlot, iBarbCampIndex) then
                    candidatePlotIDs[plotID] = true
                    table.insert(candidates, pPlot)
                end
            end
        end
    end
    return candidates
end

local function GetBarbarianPlayer()
    if PlayerManager.GetAliveBarbarians ~= nil then
        for _, pBarb in ipairs(PlayerManager.GetAliveBarbarians()) do
            if pBarb ~= nil and pBarb:IsAlive() then
                return pBarb
            end
        end
    end
    for iPlayer = 0, 63 do
        local pPlayer = Players[iPlayer]
        if pPlayer ~= nil and pPlayer:IsBarbarian() and pPlayer:IsAlive() then
            return pPlayer
        end
    end
    return nil
end

local function IsBarbarianClansModeEnabled()
    local v = GameConfiguration.GetValue("GAMEMODE_BARBARIAN_CLANS")
    return v == true or v == 1 or v == "1"
end

local function CountBarbarianUnitsNear(centerX, centerY, radius)
    local pBarb = GetBarbarianPlayer()
    if pBarb == nil then return 0 end
    local n = 0
    local pUnits = pBarb:GetUnits()
    if pUnits == nil then return 0 end
    for _, pUnit in pUnits:Members() do
        if pUnit ~= nil then
            local dist = Map.GetPlotDistance(centerX, centerY, pUnit:GetX(), pUnit:GetY())
            if dist ~= nil and dist <= radius then
                n = n + 1
            end
        end
    end
    return n
end

local function PlotTouchesWaterOrCoast(pPlot)
    if pPlot == nil then return false end
    local ok, coastal = pcall(function()
        return pPlot:IsCoastalLand()
    end)
    if ok and coastal then return true end
    for dir = 0, 5 do
        local adj = Map.GetAdjacentPlot(pPlot:GetX(), pPlot:GetY(), dir)
        if adj ~= nil and adj:IsWater() then
            return true
        end
    end
    return false
end

local function PlotHasNearbyResource(pPlot, resourceType, range)
    local resourceRow = GameInfo.Resources[resourceType]
    if pPlot == nil or resourceRow == nil then return false end
    local resourceIndex = resourceRow.Index
    local x, y = pPlot:GetX(), pPlot:GetY()
    for dx = -range, range do
        for dy = -range, range do
            local pCheck = Map.GetPlotXY(x, y, dx, dy)
            if pCheck ~= nil
                and Map.GetPlotDistance(x, y, pCheck:GetX(), pCheck:GetY()) <= range
                and pCheck:GetResourceType() == resourceIndex then
                return true
            end
        end
    end
    return false
end

local function PlotHasNearbyFeatureClass(pPlot, featureType, range)
    local featureRow = GameInfo.Features[featureType]
    if pPlot == nil or featureRow == nil then return false end
    local featureIndex = featureRow.Index
    local x, y = pPlot:GetX(), pPlot:GetY()
    for dx = -range, range do
        for dy = -range, range do
            local pCheck = Map.GetPlotXY(x, y, dx, dy)
            if pCheck ~= nil
                and Map.GetPlotDistance(x, y, pCheck:GetX(), pCheck:GetY()) <= range
                and pCheck:GetFeatureType() == featureIndex then
                return true
            end
        end
    end
    return false
end

-- 按地块环境选择蛮族氏族类型（氏族模式用 CLAN_*，否则原版 TRIBE_*）
local function ResolveBarbarianTribeTypeForPlot(pPlot)
    local clans = IsBarbarianClansModeEnabled()
    if PlotTouchesWaterOrCoast(pPlot) then
        if clans and GameInfo.BarbarianTribes["TRIBE_CLAN_NAVAL"] ~= nil then
            return "TRIBE_CLAN_NAVAL"
        end
        if GameInfo.BarbarianTribes["TRIBE_NAVAL"] ~= nil then
            return "TRIBE_NAVAL"
        end
    end
    if PlotHasNearbyResource(pPlot, BARBARIAN_HORSE_RESOURCE, BARBARIAN_HORSE_RANGE) then
        if clans then
            if PlotHasNearbyFeatureClass(pPlot, "FEATURE_JUNGLE", 1)
                and GameInfo.BarbarianTribes["TRIBE_CLAN_CAVALRY_JUNGLE"] ~= nil then
                return "TRIBE_CLAN_CAVALRY_JUNGLE"
            end
            if GameInfo.BarbarianTribes["TRIBE_CLAN_CAVALRY_OPEN"] ~= nil then
                return "TRIBE_CLAN_CAVALRY_OPEN"
            end
        end
        if GameInfo.BarbarianTribes["TRIBE_CAVALRY"] ~= nil then
            return "TRIBE_CAVALRY"
        end
    end
    if clans then
        if PlotHasNearbyFeatureClass(pPlot, "FEATURE_FOREST", 0)
            and GameInfo.BarbarianTribes["TRIBE_CLAN_MELEE_FOREST"] ~= nil then
            return "TRIBE_CLAN_MELEE_FOREST"
        end
        local okHills, isHills = pcall(function() return pPlot:IsHills() end)
        if okHills and isHills and GameInfo.BarbarianTribes["TRIBE_CLAN_MELEE_HILLS"] ~= nil then
            return "TRIBE_CLAN_MELEE_HILLS"
        end
        if GameInfo.BarbarianTribes["TRIBE_CLAN_MELEE_OPEN"] ~= nil then
            return "TRIBE_CLAN_MELEE_OPEN"
        end
    end
    if GameInfo.BarbarianTribes["TRIBE_MELEE"] ~= nil then
        return "TRIBE_MELEE"
    end
    return nil
end

local function ResolveTribeNameRow(nameType)
    if nameType == nil then return nil end
    local row = GameInfo.BarbarianTribeNames[nameType]
    if row ~= nil then return row end
    if type(nameType) == "number" then
        for r in GameInfo.BarbarianTribeNames() do
            if r.Index == nameType then
                return r
            end
        end
    end
    return nil
end

-- 取氏族专名 LOC（Quiet Fox 等）；Gameplay 下 GetTribeNameType 偶发失败
local function CaptureTribeNameLoc(iTribe)
    if iTribe == nil or iTribe < 0 then return nil end
    local pBarbManager = Game.GetBarbarianManager()
    if pBarbManager == nil or pBarbManager.GetTribeNameType == nil then
        return nil
    end
    local ok, nameType = pcall(function()
        return pBarbManager:GetTribeNameType(iTribe)
    end)
    if not ok or nameType == nil then
        return nil
    end
    if type(nameType) == "number" and nameType < 0 then
        return nil
    end
    local nameRow = ResolveTribeNameRow(nameType)
    if nameRow ~= nil and nameRow.TribeDisplayName ~= nil then
        return nameRow.TribeDisplayName
    end
    return nil
end

local function PersistBarbarianTribeMap()
    local parts = {}
    for plotIndex, iTribe in pairs(g_BarbarianTribeIndexByPlot) do
        if iTribe ~= nil and iTribe >= 0 then
            local tType = g_BarbarianTribeTypeByPlot[plotIndex] or ""
            local nameLoc = g_BarbarianTribeNameLocByPlot[plotIndex] or ""
            table.insert(parts, string.format(
                "%d:%d:%s:%s", plotIndex, iTribe, tType, nameLoc))
        end
    end
    table.sort(parts)
    Game:SetProperty(BARB_TRIBE_MAP_PROP, table.concat(parts, "|"))
end

-- 丢掉已无蛮寨地块上的过期映射
local function PruneBarbarianTribeMap()
    local iBarbCampIndex = GetBarbarianCampImprovementIndex()
    if iBarbCampIndex == nil then return end
    local dead = {}
    for plotIndex, _ in pairs(g_BarbarianTribeIndexByPlot) do
        local pPlot = Map.GetPlotByIndex(plotIndex)
        if pPlot == nil or pPlot:GetImprovementType() ~= iBarbCampIndex then
            table.insert(dead, plotIndex)
        end
    end
    for _, plotIndex in ipairs(dead) do
        g_BarbarianTribeIndexByPlot[plotIndex] = nil
        g_BarbarianTribeTypeByPlot[plotIndex] = nil
        g_BarbarianTribeNameLocByPlot[plotIndex] = nil
    end
end

-- 从存档合并映射；属性为空时绝不清空内存（同会话上一波建营的索引还在）
local function LoadBarbarianTribeMap()
    local raw = Game:GetProperty(BARB_TRIBE_MAP_PROP) or ""
    local iBarbCampIndex = GetBarbarianCampImprovementIndex()
    if raw ~= "" and iBarbCampIndex ~= nil then
        for entry in string.gmatch(raw, "[^|]+") do
            local plotStr, tribeStr, tType, nameLoc = string.match(
                entry, "^(%d+):(%-?%d+):([^:]*):(.*)$")
            if plotStr == nil then
                plotStr, tribeStr, tType = string.match(entry, "^(%d+):(%-?%d+):(.*)$")
                nameLoc = ""
            end
            local plotIndex = tonumber(plotStr)
            local iTribe = tonumber(tribeStr)
            if plotIndex ~= nil and iTribe ~= nil and iTribe >= 0 then
                local pPlot = Map.GetPlotByIndex(plotIndex)
                if pPlot ~= nil and pPlot:GetImprovementType() == iBarbCampIndex then
                    g_BarbarianTribeIndexByPlot[plotIndex] = iTribe
                    if tType ~= nil and tType ~= "" then
                        g_BarbarianTribeTypeByPlot[plotIndex] = tType
                    end
                    if nameLoc ~= nil and nameLoc ~= "" then
                        g_BarbarianTribeNameLocByPlot[plotIndex] = nameLoc
                    end
                end
            end
        end
    end
    PruneBarbarianTribeMap()
end

local function CacheBarbarianTribeIndex(plotIndex, iTribe, tribeType, doPersist)
    if plotIndex ~= nil and iTribe ~= nil and iTribe >= 0 then
        g_BarbarianTribeIndexByPlot[plotIndex] = iTribe
        if g_BarbarianTribeNameLocByPlot[plotIndex] == nil then
            local nameLoc = CaptureTribeNameLoc(iTribe)
            if nameLoc ~= nil then
                g_BarbarianTribeNameLocByPlot[plotIndex] = nameLoc
            end
        end
    end
    if plotIndex ~= nil and tribeType ~= nil then
        g_BarbarianTribeTypeByPlot[plotIndex] = tribeType
    end
    if doPersist ~= false then
        PersistBarbarianTribeMap()
    end
end

local function ResolveTribeTypeRowAtCamp(pCamp, iTribe)
    if pCamp ~= nil then
        local cachedType = g_BarbarianTribeTypeByPlot[pCamp:GetIndex()]
        if cachedType ~= nil and GameInfo.BarbarianTribes[cachedType] ~= nil then
            return GameInfo.BarbarianTribes[cachedType], cachedType
        end
    end
    if iTribe == nil or iTribe < 0 then
        return nil, nil
    end
    local pBarbManager = Game.GetBarbarianManager()
    if pBarbManager == nil then
        return nil, nil
    end
    if pBarbManager.GetTribeType ~= nil then
        local ok, eTribeType = pcall(function()
            return pBarbManager:GetTribeType(iTribe)
        end)
        if ok and eTribeType ~= nil and GameInfo.BarbarianTribes[eTribeType] ~= nil then
            return GameInfo.BarbarianTribes[eTribeType], eTribeType
        end
    end
    if pBarbManager.GetTribeNameType ~= nil then
        local ok, nameType = pcall(function()
            return pBarbManager:GetTribeNameType(iTribe)
        end)
        if ok and nameType ~= nil then
            local nameRow = GameInfo.BarbarianTribeNames[nameType]
            local tribeType = nameRow and nameRow.TribeType or nil
            if tribeType ~= nil and GameInfo.BarbarianTribes[tribeType] ~= nil then
                return GameInfo.BarbarianTribes[tribeType], tribeType
            end
        end
    end
    return nil, nil
end

-- 世界是否已有人解锁某科技（用于判断能否走原版时代进阶兵种）
local function IsAnyMajorHasTech(techType)
    local techRow = GameInfo.Technologies[techType]
    if techRow == nil then return false end
    for _, pMajor in ipairs(PlayerManager.GetAliveMajors()) do
        if pMajor ~= nil then
            local pTechs = pMajor:GetTechs()
            if pTechs ~= nil and pTechs:HasTech(techRow.Index) then
                return true
            end
        end
    end
    return false
end

local function PushSpawnJob(jobs, primaryTag, earlyTag, earlyUnitType, count)
    if count <= 0 then return end
    table.insert(jobs, {
        tag = primaryTag,
        fallbackTag = earlyTag,
        unitType = earlyUnitType,
        count = count,
    })
end

-- 优先原版氏族 MeleeTag/RangedTag（随科技进阶）；远古未解锁时用早期独占 Tag 兜底
local function BuildTribeUnitSpawnJobs(pCamp, iTribe, count)
    local jobs = {}
    if count <= 0 then return jobs end
    local tribeRow = ResolveTribeTypeRowAtCamp(pCamp, iTribe)
    if tribeRow == nil and pCamp ~= nil then
        local guessedType = ResolveBarbarianTribeTypeForPlot(pCamp)
        tribeRow = guessedType and GameInfo.BarbarianTribes[guessedType] or nil
        if guessedType ~= nil then
            CacheBarbarianTribeIndex(pCamp:GetIndex(), iTribe, guessedType)
        end
    end
    local meleeTag = (tribeRow and tribeRow.MeleeTag) or "CLASS_MELEE"
    local rangedTag = tribeRow and tribeRow.RangedTag or nil
    local percentRanged = 0
    if tribeRow ~= nil and tribeRow.PercentRangedUnits ~= nil then
        percentRanged = tonumber(tribeRow.PercentRangedUnits) or 0
    end

    local rangedCount = 0
    if percentRanged > 0 and rangedTag ~= nil then
        rangedCount = math.floor(count * percentRanged / 100)
    end
    local meleeCount = count - rangedCount

    if meleeTag == "CLASS_LIGHT_CAVALRY" then
        -- 有骑术后走原版 CLASS_*（骑手→骑兵→直升机…）；否则强制早期蛮族骑手/弓骑手
        local useVanilla = IsAnyMajorHasTech("TECH_HORSEBACK_RIDING")
        if useVanilla then
            PushSpawnJob(jobs, meleeTag, HAIKESI_BARB_HORSEMAN_TAG,
                BARBARIAN_HORSEMAN_UNIT, meleeCount)
            PushSpawnJob(jobs, rangedTag or "CLASS_MOBILE_RANGED",
                HAIKESI_BARB_HORSE_ARCHER_TAG, BARBARIAN_HORSE_ARCHER_UNIT, rangedCount)
        else
            PushSpawnJob(jobs, HAIKESI_BARB_HORSEMAN_TAG, meleeTag,
                BARBARIAN_HORSEMAN_UNIT, meleeCount)
            PushSpawnJob(jobs, HAIKESI_BARB_HORSE_ARCHER_TAG,
                rangedTag or "CLASS_RANGED_CAVALRY", BARBARIAN_HORSE_ARCHER_UNIT, rangedCount)
        end
        return jobs
    end

    if meleeTag == "CLASS_NAVAL_MELEE" then
        local useVanillaMelee = IsAnyMajorHasTech("TECH_SAILING")
        local useVanillaRanged = IsAnyMajorHasTech("TECH_SHIPBUILDING")
        if useVanillaMelee then
            PushSpawnJob(jobs, meleeTag, HAIKESI_BARB_GALLEY_TAG,
                BARBARIAN_GALLEY_UNIT, meleeCount)
        else
            PushSpawnJob(jobs, HAIKESI_BARB_GALLEY_TAG, meleeTag,
                BARBARIAN_GALLEY_UNIT, meleeCount)
        end
        if rangedCount > 0 then
            if useVanillaRanged then
                PushSpawnJob(jobs, rangedTag or "CLASS_NAVAL_RANGED",
                    HAIKESI_BARB_QUADRIREME_TAG, BARBARIAN_QUADRIREME_UNIT, rangedCount)
            else
                PushSpawnJob(jobs, HAIKESI_BARB_QUADRIREME_TAG,
                    rangedTag or "CLASS_NAVAL_RANGED", BARBARIAN_QUADRIREME_UNIT, rangedCount)
            end
        end
        return jobs
    end

    -- 近战等：完全交给原版 Tag
    PushSpawnJob(jobs, meleeTag, nil, nil, meleeCount)
    if rangedCount > 0 and rangedTag ~= nil then
        PushSpawnJob(jobs, rangedTag, nil, nil, rangedCount)
    end
    return jobs
end

-- 从营地附近已有蛮族单位反查部落索引（Gameplay 可用；GetTribeIndexAtLocation 仅 UI）
local function FindTribeIndexFromNearbyUnits(pCamp, radius)
    if pCamp == nil then return nil end
    local pBarb = GetBarbarianPlayer()
    if pBarb == nil then return nil end
    local pUnits = pBarb:GetUnits()
    if pUnits == nil then return nil end
    local campX, campY = pCamp:GetX(), pCamp:GetY()
    local bestTribe, bestDist = nil, math.huge
    for _, pUnit in pUnits:Members() do
        if pUnit ~= nil and pUnit.GetBarbarianTribeIndex ~= nil then
            local ok, iTribe = pcall(function()
                return pUnit:GetBarbarianTribeIndex()
            end)
            if ok and iTribe ~= nil and iTribe >= 0 then
                local dist = Map.GetPlotDistance(campX, campY, pUnit:GetX(), pUnit:GetY())
                if dist ~= nil and dist <= radius and dist < bestDist then
                    bestTribe = iTribe
                    bestDist = dist
                    if bestDist == 0 then
                        break
                    end
                end
            end
        end
    end
    return bestTribe
end

-- 解析营地部落索引：存档映射 > 内存缓存 > 附近氏族单位；绝不清营重建
local function ResolveTribeIndexAtCamp(pCamp)
    if pCamp == nil then return nil end
    local plotIndex = pCamp:GetIndex()
    local cached = g_BarbarianTribeIndexByPlot[plotIndex]
    if cached ~= nil and cached >= 0 then
        return cached
    end

    -- UI-only API，Gameplay 下通常失败；保留尝试以兼容
    local pBarbManager = Game.GetBarbarianManager()
    if pBarbManager ~= nil and pBarbManager.GetTribeIndexAtLocation ~= nil then
        local ok, iTribe = pcall(function()
            return pBarbManager:GetTribeIndexAtLocation(pCamp:GetX(), pCamp:GetY())
        end)
        if ok and iTribe ~= nil and iTribe >= 0 then
            CacheBarbarianTribeIndex(plotIndex, iTribe, nil, true)
            return iTribe
        end
    end

    local fromUnit = FindTribeIndexFromNearbyUnits(pCamp, BARB_TRIBE_LOOKUP_RADIUS)
    if fromUnit ~= nil then
        CacheBarbarianTribeIndex(plotIndex, fromUnit, nil, true)
        return fromUnit
    end
    return nil
end

-- 用附近已入族蛮兵给尚未缓存的营地补索引（应对读档/热更后内存空）
local function RebuildTribeIndexFromNearbyUnits(iBarbCampIndex)
    if iBarbCampIndex == nil then return 0 end
    local filled = 0
    for plotIndex = 0, Map.GetPlotCount() - 1 do
        local pPlot = Map.GetPlotByIndex(plotIndex)
        if pPlot ~= nil
            and pPlot:GetImprovementType() == iBarbCampIndex
            and g_BarbarianTribeIndexByPlot[plotIndex] == nil then
            local fromUnit = FindTribeIndexFromNearbyUnits(pPlot, BARB_TRIBE_LOOKUP_RADIUS)
            if fromUnit ~= nil then
                CacheBarbarianTribeIndex(plotIndex, fromUnit, nil, false)
                filled = filled + 1
            end
        end
    end
    if filled > 0 then
        PersistBarbarianTribeMap()
    end
    return filled
end

-- 氏族模式下孤儿营：在原格 CreateTribeOfType 绑定索引（不先清营，避免拆寨）
local function EnsureTribeIndexAtCamp(pCamp)
    local iTribe = ResolveTribeIndexAtCamp(pCamp)
    if iTribe ~= nil then
        return iTribe
    end
    if pCamp == nil or not IsBarbarianClansModeEnabled() then
        return nil
    end
    local pBarbManager = Game.GetBarbarianManager()
    if pBarbManager == nil or pBarbManager.CreateTribeOfType == nil then
        return nil
    end
    local tribeType = g_BarbarianTribeTypeByPlot[pCamp:GetIndex()]
        or ResolveBarbarianTribeTypeForPlot(pCamp)
    local tribeRow = tribeType and GameInfo.BarbarianTribes[tribeType] or nil
    if tribeRow == nil then
        return nil
    end
    local ok, newTribe = pcall(function()
        return pBarbManager:CreateTribeOfType(tribeRow.Index, pCamp:GetIndex())
    end)
    if ok and newTribe ~= nil and type(newTribe) == "number" and newTribe >= 0 then
        CacheBarbarianTribeIndex(pCamp:GetIndex(), newTribe, tribeType, true)
        print(string.format(
            "[Haikesi GamePlay] BARBARIAN_INVASION ensureTribe=%s tribeIdx=%s at (%d,%d)",
            tostring(tribeType), tostring(newTribe), pCamp:GetX(), pCamp:GetY()))
        return newTribe
    end
    return nil
end

local function PlaceBarbarianCampAtPlot(pPlot, iBarbCampIndex)
    if pPlot == nil or iBarbCampIndex == nil then
        return false, nil
    end
    local pBarbManager = Game.GetBarbarianManager()
    if pBarbManager ~= nil and pBarbManager.CreateTribeOfType ~= nil then
        local tribeType = ResolveBarbarianTribeTypeForPlot(pPlot)
        local tribeRow = tribeType and GameInfo.BarbarianTribes[tribeType] or nil
        if tribeRow ~= nil then
            ImprovementBuilder.SetImprovementType(pPlot, -1, -1)
            local ok, iTribe = pcall(function()
                return pBarbManager:CreateTribeOfType(tribeRow.Index, pPlot:GetIndex())
            end)
            if ok and pPlot:GetImprovementType() == iBarbCampIndex then
                CacheBarbarianTribeIndex(pPlot:GetIndex(), iTribe, tribeType, true)
                print(string.format(
                    "[Haikesi GamePlay] BARBARIAN_INVASION camp+tribe=%s tribeIdx=%s at (%d,%d) clans=%s",
                    tostring(tribeType), tostring(iTribe),
                    pPlot:GetX(), pPlot:GetY(), tostring(IsBarbarianClansModeEnabled())))
                return true, iTribe
            end
        end
    end
    ImprovementBuilder.SetImprovementType(pPlot, iBarbCampIndex, -1)
    if pPlot:GetImprovementType() == iBarbCampIndex then
        return true, nil
    end
    return false, nil
end

local function GatherBarbarianCampsSorted(centerX, centerY, iBarbCampIndex)
    local camps = {}
    for plotIndex = 0, Map.GetPlotCount() - 1 do
        local pPlot = Map.GetPlotByIndex(plotIndex)
        if pPlot ~= nil and pPlot:GetImprovementType() == iBarbCampIndex then
            table.insert(camps, {
                plot = pPlot,
                dist = Map.GetPlotDistance(centerX, centerY, pPlot:GetX(), pPlot:GetY()),
                index = plotIndex,
            })
        end
    end
    table.sort(camps, function(a, b)
        if a.dist == b.dist then
            return a.index < b.index
        end
        return a.dist < b.dist
    end)
    local plots = {}
    for _, entry in ipairs(camps) do
        table.insert(plots, entry.plot)
    end
    return plots, camps
end

local function GatherBarbarianUnitPlots(centerX, centerY, radius, requireWater)
    local candidates = {}
    local candidatePlotIDs = {}
    for dx = -radius, radius do
        for dy = -radius, radius do
            local pPlot = Map.GetPlotXY(centerX, centerY, dx, dy)
            if pPlot ~= nil then
                local dist = Map.GetPlotDistance(centerX, centerY, pPlot:GetX(), pPlot:GetY())
                local plotID = pPlot:GetIndex()
                local terrainOk
                if requireWater then
                    terrainOk = pPlot:IsWater() and not pPlot:IsLake()
                else
                    terrainOk = (not pPlot:IsWater()) and (not pPlot:IsImpassable())
                end
                if dist <= radius
                    and not candidatePlotIDs[plotID]
                    and terrainOk
                    and CityManager.GetCityAt(pPlot:GetX(), pPlot:GetY()) == nil then
                    candidatePlotIDs[plotID] = true
                    table.insert(candidates, pPlot)
                end
            end
        end
    end
    table.sort(candidates, function(a, b)
        local distanceA = Map.GetPlotDistance(centerX, centerY, a:GetX(), a:GetY())
        local distanceB = Map.GetPlotDistance(centerX, centerY, b:GetX(), b:GetY())
        if distanceA == distanceB then
            return a:GetIndex() < b:GetIndex()
        end
        return distanceA < distanceB
    end)
    return candidates
end

local function IsNavalDomainUnit(unitType)
    local unitRow = unitType and GameInfo.Units[unitType] or nil
    return unitRow ~= nil and unitRow.Domain == "DOMAIN_SEA"
end

local function SpawnBarbarianUnitsAtCampFallback(pCamp, count, unitType)
    local pBarb = GetBarbarianPlayer()
    local unitRow = GameInfo.Units[unitType or BARBARIAN_FALLBACK_UNIT]
        or GameInfo.Units[BARBARIAN_FALLBACK_UNIT]
    if pBarb == nil or unitRow == nil or pCamp == nil or count <= 0 then
        return 0
    end
    local needWater = IsNavalDomainUnit(unitRow.UnitType or unitType)
    local candidates = GatherBarbarianUnitPlots(
        pCamp:GetX(), pCamp:GetY(),
        needWater and BARBARIAN_TRIBE_UNIT_RANGE or INVASION_FALLBACK_UNIT_RADIUS,
        needWater)
    local spawned = 0
    for _, pPlot in ipairs(candidates) do
        if spawned >= count then break end
        local pUnit = pBarb:GetUnits():Create(unitRow.Index, pPlot:GetX(), pPlot:GetY())
        if pUnit ~= nil then
            spawned = spawned + 1
        end
    end
    return spawned
end

local function CreateTribeUnitsWithTag(pBarbManager, iTribe, tag, count, plotIndex)
    if pBarbManager == nil or iTribe == nil or tag == nil or count <= 0 then
        return false
    end
    local ok = pcall(function()
        pBarbManager:CreateTribeUnits(
            iTribe, tag, count, plotIndex, BARBARIAN_TRIBE_UNIT_RANGE)
    end)
    return ok
end

-- CreateTribeUnits：优先原版氏族 Tag（时代进阶），不足再用早期 Tag / 指定单位兜底
local function SpawnBarbarianUnitsAtCamp(pCamp, count)
    if pCamp == nil or count <= 0 then
        return 0
    end
    local pBarbManager = Game.GetBarbarianManager()
    local iTribe = ResolveTribeIndexAtCamp(pCamp)
    local jobs = BuildTribeUnitSpawnJobs(pCamp, iTribe, count)
    local totalSpawned = 0

    if pBarbManager ~= nil
        and iTribe ~= nil and iTribe >= 0
        and pBarbManager.CreateTribeUnits ~= nil
        and #jobs > 0 then
        for _, job in ipairs(jobs) do
            local before = CountBarbarianUnitsNear(
                pCamp:GetX(), pCamp:GetY(), BARBARIAN_TRIBE_UNIT_RANGE + 1)
            local tagUsed = job.tag
            local ok = CreateTribeUnitsWithTag(
                pBarbManager, iTribe, job.tag, job.count, pCamp:GetIndex())
            local after = CountBarbarianUnitsNear(
                pCamp:GetX(), pCamp:GetY(), BARBARIAN_TRIBE_UNIT_RANGE + 1)
            local spawned = ok and math.max(0, after - before) or 0

            if spawned < job.count and job.fallbackTag ~= nil then
                before = CountBarbarianUnitsNear(
                    pCamp:GetX(), pCamp:GetY(), BARBARIAN_TRIBE_UNIT_RANGE + 1)
                tagUsed = job.fallbackTag
                ok = CreateTribeUnitsWithTag(
                    pBarbManager, iTribe, job.fallbackTag, job.count - spawned,
                    pCamp:GetIndex())
                after = CountBarbarianUnitsNear(
                    pCamp:GetX(), pCamp:GetY(), BARBARIAN_TRIBE_UNIT_RANGE + 1)
                local extra = ok and math.max(0, after - before) or 0
                spawned = spawned + extra
            end
            -- 氏族模式只用 CreateTribeUnits（Units:Create 无法挂氏族）
            if spawned < job.count
                and job.unitType ~= nil
                and not IsBarbarianClansModeEnabled() then
                local extra = SpawnBarbarianUnitsAtCampFallback(
                    pCamp, job.count - spawned, job.unitType)
                spawned = spawned + extra
                tagUsed = job.unitType
            end

            totalSpawned = totalSpawned + spawned
            print(string.format(
                "[Haikesi GamePlay] BARBARIAN_INVASION tribeUnits camp(%d,%d) "
                    .. "tribe=%s tag=%s req=%d got=%d",
                pCamp:GetX(), pCamp:GetY(), tostring(iTribe), tostring(tagUsed),
                job.count, spawned))
        end
        return totalSpawned
    end

    print(string.format(
        "[Haikesi GamePlay] BARBARIAN_INVASION skip camp(%d,%d): no tribe index (avoid clanless Create)",
        pCamp:GetX(), pCamp:GetY()))

    -- 非氏族模式才允许 Units:Create 回退
    if not IsBarbarianClansModeEnabled() then
        for _, job in ipairs(jobs) do
            if job.unitType ~= nil then
                totalSpawned = totalSpawned + SpawnBarbarianUnitsAtCampFallback(
                    pCamp, job.count, job.unitType)
            else
                totalSpawned = totalSpawned + SpawnBarbarianUnitsAtCampFallback(
                    pCamp, job.count, BARBARIAN_FALLBACK_UNIT)
            end
        end
        if totalSpawned == 0 then
            totalSpawned = SpawnBarbarianUnitsAtCampFallback(
                pCamp, count, BARBARIAN_FALLBACK_UNIT)
        end
    end
    return totalSpawned
end

-- 复用原版煽动通知图标：仅人类被打时入队，由 UI 桥接取专名后发送
local function NotifyBarbarianInvasionAssault(
    triggerPlayerID, iTribe, targetPlayerID, targetCityID, pCamp)
    local pTarget = Players[targetPlayerID]
    if pTarget == nil or not pTarget:IsHuman() then
        return
    end
    if triggerPlayerID == nil or iTribe == nil or targetCityID == nil then
        return
    end

    local campX = -1
    local campY = -1
    if pCamp ~= nil then
        campX = pCamp:GetX() or -1
        campY = pCamp:GetY() or -1
    end
    local entry = string.format(
        "%d;%d;%d;%d;%d;%d",
        triggerPlayerID, iTribe, targetPlayerID, targetCityID, campX, campY)
    local queue = Game:GetProperty(BARB_ASSAULT_NOTIFY_PROP) or ""
    if queue == "" then
        queue = entry
    else
        queue = queue .. "|" .. entry
    end
    Game:SetProperty(BARB_ASSAULT_NOTIFY_PROP, queue)
    print(string.format(
        "[Haikesi GamePlay] BARBARIAN_INVASION notifyQueued tribe=%s -> human=%s city=%s camp(%d,%d)",
        tostring(iTribe), tostring(targetPlayerID), tostring(targetCityID),
        campX, campY))
end

-- 令氏族对指定城市发动攻城（Gameplay 可用；不扣城邦点、不花金币）
local function TryOrderTribeAssaultCity(
    iTribe, targetPlayerID, targetCityID, pCamp, triggerPlayerID)
    if iTribe == nil or iTribe < 0
        or targetPlayerID == nil or targetCityID == nil then
        return false
    end
    local pBarbManager = Game.GetBarbarianManager()
    if pBarbManager == nil or pBarbManager.StartOperationWithCityTarget == nil then
        return false
    end
    local ok, result = pcall(function()
        return pBarbManager:StartOperationWithCityTarget(
            iTribe, BARBARIAN_CITY_ASSAULT_OPERATION, targetPlayerID, targetCityID)
    end)
    local campX = (pCamp ~= nil) and pCamp:GetX() or -1
    local campY = (pCamp ~= nil) and pCamp:GetY() or -1
    print(string.format(
        "[Haikesi GamePlay] BARBARIAN_INVASION assault tribe=%s -> player=%s city=%s "
            .. "camp(%d,%d) ok=%s result=%s",
        tostring(iTribe), tostring(targetPlayerID), tostring(targetCityID),
        campX, campY, tostring(ok), tostring(result)))
    local success = ok == true and (result == true or result == nil)
    if success then
        NotifyBarbarianInvasionAssault(
            triggerPlayerID, iTribe, targetPlayerID, targetCityID, pCamp)
    end
    return success
end

-- 仅向能解析/绑定出部落索引的营地均分补兵（保证入族）
-- 补兵成功后按概率令该氏族进攻被入侵玩家的目标城市
local function SpawnBarbarianUnitsDistributed(
    campPlots, totalCount, targetPlayerID, targetCityID, triggerPlayerID)
    if campPlots == nil or #campPlots == 0 or totalCount <= 0 then
        return 0
    end
    local eligible = {}
    for _, pCamp in ipairs(campPlots) do
        local iTribe = EnsureTribeIndexAtCamp(pCamp)
        if iTribe ~= nil and iTribe >= 0 then
            table.insert(eligible, { plot = pCamp, tribe = iTribe })
        end
    end
    if #eligible == 0 then
        print("[Haikesi GamePlay] BARBARIAN_INVASION distributed: no camps with tribe index")
        return 0
    end
    if #eligible < #campPlots then
        print(string.format(
            "[Haikesi GamePlay] BARBARIAN_INVASION distributed: tribeCamps=%d/%d",
            #eligible, #campPlots))
    end
    local campCount = #eligible
    local base = math.floor(totalCount / campCount)
    local rem = totalCount % campCount
    local spawned = 0
    for i, entry in ipairs(eligible) do
        local n = base + ((i <= rem) and 1 or 0)
        if n > 0 then
            local got = SpawnBarbarianUnitsAtCamp(entry.plot, n)
            spawned = spawned + got
            if got > 0
                and targetPlayerID ~= nil
                and targetCityID ~= nil
                and PickRandomIndex(100, "Haikesi BarbInvasion reinforce assault")
                    < INVASION_REINFORCE_ASSAULT_CHANCE then
                TryOrderTribeAssaultCity(
                    entry.tribe, targetPlayerID, targetCityID, entry.plot,
                    triggerPlayerID)
            end
        end
    end
    return spawned
end

local function SpawnBarbarianUnitsAtCityDistance(centerX, centerY, distance, count)
    local pBarb = GetBarbarianPlayer()
    local unitRow = GameInfo.Units[BARBARIAN_FALLBACK_UNIT]
    if pBarb == nil or unitRow == nil or count <= 0 then
        return 0
    end

    local candidates = {}
    local candidatePlotIDs = {}
    for dx = -distance, distance do
        for dy = -distance, distance do
            local pPlot = Map.GetPlotXY(centerX, centerY, dx, dy)
            if pPlot ~= nil then
                local plotID = pPlot:GetIndex()
                if not candidatePlotIDs[plotID]
                    and Map.GetPlotDistance(centerX, centerY, pPlot:GetX(), pPlot:GetY()) == distance
                    and not pPlot:IsWater()
                    and not pPlot:IsImpassable()
                    and CityManager.GetCityAt(pPlot:GetX(), pPlot:GetY()) == nil then
                    candidatePlotIDs[plotID] = true
                    table.insert(candidates, pPlot)
                end
            end
        end
    end

    local spawned = 0
    while spawned < count and #candidates > 0 do
        local pickIdx = PickRandomIndex(#candidates, "Haikesi BarbInvasion city fallback unit") + 1
        local pPlot = candidates[pickIdx]
        table.remove(candidates, pickIdx)
        local pUnit = pBarb:GetUnits():Create(unitRow.Index, pPlot:GetX(), pPlot:GetY())
        if pUnit ~= nil then
            spawned = spawned + 1
        end
    end
    return spawned
end

local function SpawnBarbarianCampsAtDistance(
    centerX, centerY, iBarbCampIndex, usedPlotIDs, requestedCount)
    local spawnedCamps = {}
    local totalCandidates = 0

    while #spawnedCamps < requestedCount do
        -- 每成功放置一个营地后重新收集候选，确保新营地也参与 7 格间距检查。
        local candidates = GatherBarbarianCampPlotsAtDistance(
            centerX, centerY, INVASION_CAMP_DISTANCE, iBarbCampIndex, usedPlotIDs)
        totalCandidates = totalCandidates + #candidates
        if #candidates == 0 then
            break
        end

        local placedCamp = nil
        while #candidates > 0 and placedCamp == nil do
            local pickIdx = PickRandomIndex(#candidates, "Haikesi BarbInvasion camp") + 1
            local pPlot = candidates[pickIdx]
            table.remove(candidates, pickIdx)
            local plotID = pPlot:GetIndex()
            usedPlotIDs[plotID] = true

            if CanPlaceBarbarianCampWithVanillaSpacing(pPlot, iBarbCampIndex) then
                local placed = PlaceBarbarianCampAtPlot(pPlot, iBarbCampIndex)
                if placed then
                    placedCamp = pPlot
                    table.insert(spawnedCamps, pPlot)
                end
            end
        end
        if placedCamp == nil then
            break
        end
    end
    return spawnedCamps, totalCandidates
end

local function SpawnBarbarianUnitsForAllCities(pPlayer, distance, countPerCity)
    local totalSpawned = 0
    local pCities = pPlayer:GetCities()
    if pCities == nil then return 0 end

    for _, pCity in pCities:Members() do
        if pCity ~= nil then
            local spawned = SpawnBarbarianUnitsAtCityDistance(
                pCity:GetX(), pCity:GetY(), distance, countPerCity)
            totalSpawned = totalSpawned + spawned
            print(string.format(
                "[Haikesi GamePlay] BARBARIAN_INVASION no camps: player=%d city=%d "
                    .. "city(%d,%d) ring=%d units=%d",
                pPlayer:GetID(), pCity:GetID(), pCity:GetX(), pCity:GetY(), distance, spawned))
        end
    end
    return totalSpawned
end

function Haikesi_SpawnBarbarianInvasionCamps(triggeringAIPlayerID)
    local iBarbCampIndex = GetBarbarianCampImprovementIndex()
    if iBarbCampIndex == nil then
        print("[Haikesi GamePlay] BARBARIAN_INVASION missing improvement index")
        return
    end

    local usedPlotIDs = {}
    local totalCampsSpawned = 0
    local totalUnitsSpawned = 0
    local clansEnabled = IsBarbarianClansModeEnabled()
    -- 从存档合并 plot→tribe；勿整表清空（Gameplay 无 GetTribeIndexAtLocation）
    LoadBarbarianTribeMap()
    local rebuilt = 0
    if clansEnabled then
        rebuilt = RebuildTribeIndexFromNearbyUnits(iBarbCampIndex)
    end
    print(string.format(
        "[Haikesi GamePlay] BARBARIAN_INVASION start clansMode=%s cachedTribes=%d rebuilt=%d",
        tostring(clansEnabled),
        (function()
            local n = 0
            for _ in pairs(g_BarbarianTribeIndexByPlot) do n = n + 1 end
            return n
        end)(),
        rebuilt))

    for _, pPlayer in ipairs(PlayerManager.GetAliveMajors()) do
        if pPlayer ~= nil and not pPlayer:IsBarbarian() and pPlayer:GetID() ~= triggeringAIPlayerID then
            local pCity = GetNewestCityForPlayer(pPlayer)
            if pCity ~= nil then
                local centerX, centerY = pCity:GetX(), pCity:GetY()
                local spawnedCamps, candidateCount = SpawnBarbarianCampsAtDistance(
                    centerX, centerY, iBarbCampIndex, usedPlotIDs,
                    INVASION_CAMPS_PER_PLAYER)
                local spawnedCampCount = #spawnedCamps
                local missingCampCount = INVASION_CAMPS_PER_PLAYER - spawnedCampCount
                local spawnedUnits = 0

                totalCampsSpawned = totalCampsSpawned + spawnedCampCount

                -- 补兵仅在建营失败/不足时：按缺营数均分到已有蛮寨；无营则在城市环上生成
                if missingCampCount > 0 then
                    local requestedUnits = missingCampCount * INVASION_UNITS_PER_MISSING_CAMP
                    local campPlots, campMeta = GatherBarbarianCampsSorted(
                        centerX, centerY, iBarbCampIndex)
                    if #campPlots > 0 then
                        spawnedUnits = SpawnBarbarianUnitsDistributed(
                            campPlots, requestedUnits, pPlayer:GetID(), pCity:GetID(),
                            triggeringAIPlayerID)
                        local nearest = campMeta[1]
                        print(string.format(
                            "[Haikesi GamePlay] BARBARIAN_INVASION targetPlayer=%d city(%d,%d) "
                                .. "missingCamps=%d eligibleCamps=%d nearest(%d,%d) dist=%d "
                                .. "units=%d/%d (distributed)",
                            pPlayer:GetID(), centerX, centerY, missingCampCount, #campPlots,
                            nearest.plot:GetX(), nearest.plot:GetY(), nearest.dist,
                            spawnedUnits, requestedUnits))
                    else
                        spawnedUnits = SpawnBarbarianUnitsForAllCities(
                            pPlayer, INVASION_NO_CAMP_UNIT_DISTANCE,
                            INVASION_UNITS_PER_MISSING_CAMP)
                    end
                    totalUnitsSpawned = totalUnitsSpawned + spawnedUnits
                end

                if spawnedCampCount > 0 then
                    print(string.format(
                        "[Haikesi GamePlay] BARBARIAN_INVASION targetPlayer=%d city(%d,%d) "
                            .. "camps=%d/%d ring=%d candidateChecks=%d",
                        pPlayer:GetID(), centerX, centerY, spawnedCampCount,
                        INVASION_CAMPS_PER_PLAYER, INVASION_CAMP_DISTANCE, candidateCount))
                end
            end
        end
    end

    print(string.format(
        "[Haikesi GamePlay] BARBARIAN_INVASION total camps=%d units=%d",
        totalCampsSpawned, totalUnitsSpawned))
end

-- 各 AddGameplayScripts 互不共享 _G；经 ExposedMembers 供主脚本调用
local function InitializeBarbarianGamePlay()
    if ExposedMembers ~= nil then
        ExposedMembers.Haikesi_SpawnBarbarianInvasionCamps = Haikesi_SpawnBarbarianInvasionCamps
    end
    print("[Haikesi Barbarian] GamePlay bridge ready (ExposedMembers.Haikesi_SpawnBarbarianInvasionCamps)")
end

Events.LoadScreenClose.Add(InitializeBarbarianGamePlay)
