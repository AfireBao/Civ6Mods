-- ===========================================================================
-- Haikesi_Planter_GamePlay.lua
-- 种地仙人种植：从主 GamePlay 脚本拆出，避免 Firaxis Lua 5.1 主 chunk
-- local 寄存器上限（~200）导致 Haikesi_GamePlay_Script.lua 整文件加载失败。
-- ===========================================================================

local NW_FARM_IMMORTAL_UNIT = 'UNIT_NW_FARM_IMMORTAL'
local FARM_IMMORTAL_PLUS_RELIC = 'FARMIMMORTALPLUSRUNE'
local HERMETIC_SECRET_SOCIETY = 'SECRETSOCIETY_HERMETIC_ORDER'
local HERMETIC_GOVERNOR = 'GOVERNOR_HERMETIC_ORDER'
local HERMETIC_PROMOTION_1 = 'GOVERNOR_PROMOTION_HERMETIC_ORDER_1'
local HERMETIC_SYNC_PROP = 'PROP_NW_HAIKESI_IS_HERMETIC_ORDER'
local FARM_IMMORTAL_PLUS_GRANT_PROP = 'PROP_NW_FARM_IMMORTAL_PLUS_UNIT_GRANTED'
local LEY_LINE_YIELDS_APPLIED_PROP = 'PROP_NW_FARM_IMMORTAL_PLUS_LEY_LINE_BONUS_MODS_APPLIED'
local LEY_LINE_RESOURCE_TYPE = 'RESOURCE_LEY_LINE'
local LEY_LINE_BONUS_PLOT_PROP = 'NW_FARM_IMMORTAL_PLUS_LEY_LINE_BONUS'
local LINCOLN_RELIC = 'EMANCIPATIONPROCLAMATIONRUNE'
local LINCOLN_LEADER = 'LEADER_ABRAHAM_LINCOLN'
local LINCOLN_MELEE_ABILITY = 'ABILITY_LINCOLN_MELEE_UNITS'
local PLANTATION_IMPROVEMENT = 'IMPROVEMENT_PLANTATION'
local LINCOLN_HARVEST_PROXY_RESOURCE = 'RESOURCE_NW_EMANCIPATION_HARVEST_PROXY'
local LINCOLN_HARVEST_PENDING_PROP = 'PROP_NW_LINCOLN_HARVEST_PENDING'
local LINCOLN_HARVEST_X_PROP = 'PROP_NW_LINCOLN_HARVEST_X'
local LINCOLN_HARVEST_Y_PROP = 'PROP_NW_LINCOLN_HARVEST_Y'
local LINCOLN_HARVEST_OLD_RESOURCE_PROP = 'PROP_NW_LINCOLN_HARVEST_OLD_RESOURCE'
local LINCOLN_HARVEST_OLD_RESOURCE_COUNT_PROP = 'PROP_NW_LINCOLN_HARVEST_OLD_RESOURCE_COUNT'
local LINCOLN_HARVEST_OLD_IMPROVEMENT_PROP = 'PROP_NW_LINCOLN_HARVEST_OLD_IMPROVEMENT'
local LINCOLN_HARVEST_SPAWNED_UNIT_PROP = 'PROP_NW_LINCOLN_HARVEST_SPAWNED_UNIT'
local RelicsPropertyKey = 'PROP_NW_HAIKESI_RELICS'
local RelicsCountPropertyKey = 'PROP_NW_HAIKESI_RELIC_COUNT'
local RelicsSlotPropertyPrefix = 'PROP_NW_HAIKESI_RELIC_'
local g_LincolnPlantationResourceTypes = nil

local FARM_IMMORTAL_PLUS_LEY_LINE_YIELD_MODIFIERS = {
    'MODIFIER_NW_FARM_IMMORTAL_PLUS_LEY_LINE_BONUS_FOOD',
    'MODIFIER_NW_FARM_IMMORTAL_PLUS_LEY_LINE_BONUS_PRODUCTION',
    'MODIFIER_NW_FARM_IMMORTAL_PLUS_LEY_LINE_BONUS_SCIENCE'
}

local g_PlanterResourceValidImprovements = nil

local function Haikesi_GetRelicTypeFromIndex(index)
    if GameInfo.Haikesi_Relics == nil then
        return nil
    end
    for row in GameInfo.Haikesi_Relics() do
        if row.Index == index then
            return row.RelicType
        end
    end
    return nil
end

local function Haikesi_PlanterPlayerHasRelic(pPlayer, relicType)
    if pPlayer == nil or relicType == nil or relicType == '' then
        return false
    end
    local count = tonumber(pPlayer:GetProperty(RelicsCountPropertyKey) or 0) or 0
    if count > 0 then
        for i = 1, count do
            if pPlayer:GetProperty(RelicsSlotPropertyPrefix .. i) == relicType then
                return true
            end
        end
    end

    local prop = pPlayer:GetProperty(RelicsPropertyKey) or ''
    if prop ~= '' then
        for idxStr in string.gmatch(prop, '[^|]+') do
            local idx = tonumber(idxStr)
            if idx ~= nil and Haikesi_GetRelicTypeFromIndex(idx) == relicType then
                return true
            end
        end
    end
    return false
end

local function Haikesi_LincolnUnitHasTag(unitType, wantedTag)
    if unitType == nil or wantedTag == nil or GameInfo.TypeTags == nil then
        return false
    end
    for row in GameInfo.TypeTags() do
        if row.Type == unitType and row.Tag == wantedTag then
            return true
        end
    end
    return false
end

local function Haikesi_LincolnIsBuilder(unit)
    local unitInfo = unit and GameInfo.Units[unit:GetType()] or nil
    return unitInfo ~= nil
        and Haikesi_LincolnUnitHasTag(unitInfo.UnitType, 'CLASS_BUILDER')
end

local function Haikesi_LincolnPlayerIsEligible(playerID, pPlayer)
    local config = PlayerConfigurations[playerID]
    return pPlayer ~= nil
        and config ~= nil
        and config:GetLeaderTypeName() == LINCOLN_LEADER
        and Haikesi_PlanterPlayerHasRelic(pPlayer, LINCOLN_RELIC)
end

local function Haikesi_LincolnIsPlantationResourceType(resourceType)
    if resourceType == nil or resourceType == '' or GameInfo.Improvement_ValidResources == nil then
        return false
    end
    if g_LincolnPlantationResourceTypes == nil then
        g_LincolnPlantationResourceTypes = {}
        for row in GameInfo.Improvement_ValidResources() do
            if row.ImprovementType == PLANTATION_IMPROVEMENT then
                g_LincolnPlantationResourceTypes[row.ResourceType] = true
            end
        end
    end
    return g_LincolnPlantationResourceTypes[resourceType] == true
end

local function Haikesi_LincolnIsPlantationResource(plot, playerID)
    if plot == nil or plot:GetOwner() ~= playerID then
        return false, nil
    end
    local resourceInfo = GameInfo.Resources[plot:GetResourceType()]
    return resourceInfo ~= nil
        and (resourceInfo.ResourceClassType == 'RESOURCECLASS_LUXURY'
            or resourceInfo.ResourceClassType == 'RESOURCECLASS_BONUS')
        and Haikesi_LincolnIsPlantationResourceType(resourceInfo.ResourceType), resourceInfo
end

local function Haikesi_LincolnHasTech(pPlayer, techType)
    if techType == nil or techType == '' then return true end
    local techInfo = GameInfo.Technologies[techType]
    local techs = pPlayer and pPlayer:GetTechs() or nil
    return techInfo ~= nil and techs ~= nil and techs:HasTech(techInfo.Index)
end

local function Haikesi_LincolnHasCivic(pPlayer, civicType)
    if civicType == nil or civicType == '' then return true end
    local civicInfo = GameInfo.Civics[civicType]
    local culture = pPlayer and pPlayer:GetCulture() or nil
    return civicInfo ~= nil and culture ~= nil and culture:HasCivic(civicInfo.Index)
end

local function Haikesi_LincolnMeleeIsAvailable(pPlayer, unitInfo)
    if unitInfo == nil
        or unitInfo.PromotionClass ~= 'PROMOTION_CLASS_MELEE'
        or unitInfo.Domain ~= 'DOMAIN_LAND'
        or unitInfo.FormationClass ~= 'FORMATION_CLASS_LAND_COMBAT'
        or unitInfo.TraitType ~= nil
        or (tonumber(unitInfo.Combat) or 0) <= 0
        or (tonumber(unitInfo.Cost) or -1) < 0 then
        return false
    end
    if not Haikesi_LincolnHasTech(pPlayer, unitInfo.PrereqTech)
        or not Haikesi_LincolnHasCivic(pPlayer, unitInfo.PrereqCivic) then
        return false
    end
    if unitInfo.MandatoryObsoleteTech ~= nil
        and unitInfo.MandatoryObsoleteTech ~= ''
        and Haikesi_LincolnHasTech(pPlayer, unitInfo.MandatoryObsoleteTech) then
        return false
    end
    if unitInfo.MandatoryObsoleteCivic ~= nil
        and unitInfo.MandatoryObsoleteCivic ~= ''
        and Haikesi_LincolnHasCivic(pPlayer, unitInfo.MandatoryObsoleteCivic) then
        return false
    end
    return true
end

local function Haikesi_LincolnGetBestMeleeType(pPlayer)
    local bestType = nil
    local bestCombat = -1
    local bestCost = -1
    for unitInfo in GameInfo.Units() do
        if Haikesi_LincolnMeleeIsAvailable(pPlayer, unitInfo) then
            local combat = tonumber(unitInfo.Combat) or 0
            local cost = tonumber(unitInfo.Cost) or 0
            if combat > bestCombat or (combat == bestCombat and cost > bestCost) then
                bestType = unitInfo.UnitType
                bestCombat = combat
                bestCost = cost
            end
        end
    end
    return bestType
end

local function Haikesi_LincolnPlotHasBlockingUnit(playerID, plot)
    if plot == nil then return true end
    local x = plot:GetX()
    local y = plot:GetY()
    for checkPlayerID = 0, 63 do
        local checkPlayer = Players[checkPlayerID]
        local units = checkPlayer and checkPlayer:GetUnits() or nil
        if units ~= nil then
            for _, checkUnit in units:Members() do
                if checkUnit ~= nil and checkUnit:GetX() == x and checkUnit:GetY() == y then
                    local checkInfo = GameInfo.Units[checkUnit:GetType()]
                    if checkPlayerID ~= playerID
                        or (checkInfo ~= nil and checkInfo.FormationClass == 'FORMATION_CLASS_LAND_COMBAT') then
                        return true
                    end
                end
            end
        end
    end
    return false
end

local function Haikesi_LincolnCanSpawnMelee(playerID, plot)
    if plot == nil or plot:IsWater() or plot:IsImpassable() then
        return false
    end
    local owner = plot:GetOwner()
    if owner ~= -1 and owner ~= playerID then
        return false
    end
    return not Haikesi_LincolnPlotHasBlockingUnit(playerID, plot)
end

local function Haikesi_LincolnFindSpawnPlot(playerID, x, y)
    local plot = Map.GetPlot(x, y)
    if Haikesi_LincolnCanSpawnMelee(playerID, plot) then
        return plot
    end
    for direction = 0, 5 do
        local adjacent = Map.GetAdjacentPlot(x, y, direction)
        if Haikesi_LincolnCanSpawnMelee(playerID, adjacent) then
            return adjacent
        end
    end
    return nil
end

local function Haikesi_LincolnClearPendingHarvest(unit)
    if unit == nil then return end
    unit:SetProperty(LINCOLN_HARVEST_PENDING_PROP, nil)
    unit:SetProperty(LINCOLN_HARVEST_X_PROP, nil)
    unit:SetProperty(LINCOLN_HARVEST_Y_PROP, nil)
    unit:SetProperty(LINCOLN_HARVEST_OLD_RESOURCE_PROP, nil)
    unit:SetProperty(LINCOLN_HARVEST_OLD_RESOURCE_COUNT_PROP, nil)
    unit:SetProperty(LINCOLN_HARVEST_OLD_IMPROVEMENT_PROP, nil)
    unit:SetProperty(LINCOLN_HARVEST_SPAWNED_UNIT_PROP, nil)
end

local function Haikesi_LincolnStorePendingHarvest(unit, x, y, oldResource, oldResourceCount, oldImprovement, spawnedUnitID)
    unit:SetProperty(LINCOLN_HARVEST_PENDING_PROP, 1)
    unit:SetProperty(LINCOLN_HARVEST_X_PROP, x)
    unit:SetProperty(LINCOLN_HARVEST_Y_PROP, y)
    unit:SetProperty(LINCOLN_HARVEST_OLD_RESOURCE_PROP, oldResource)
    unit:SetProperty(LINCOLN_HARVEST_OLD_RESOURCE_COUNT_PROP, oldResourceCount)
    unit:SetProperty(LINCOLN_HARVEST_OLD_IMPROVEMENT_PROP, oldImprovement)
    unit:SetProperty(LINCOLN_HARVEST_SPAWNED_UNIT_PROP, spawnedUnitID)
end

local function Haikesi_GetPlayerSecretSocietyType(pPlayer)
    if pPlayer == nil or pPlayer.GetGovernors == nil or GameInfo.SecretSocieties == nil then
        return nil, nil
    end
    local governors = pPlayer:GetGovernors()
    if governors == nil or governors.GetSecretSociety == nil then
        return nil, nil
    end
    local rawSociety = governors:GetSecretSociety()
    if rawSociety == nil then
        return nil, nil
    end

    if type(rawSociety) == 'string' then
        local societyInfo = GameInfo.SecretSocieties[rawSociety]
        if societyInfo ~= nil then
            return societyInfo.SecretSocietyType or rawSociety, rawSociety
        end
        return rawSociety, rawSociety
    end

    local societyInfo = GameInfo.SecretSocieties[rawSociety]
    if societyInfo ~= nil then
        return societyInfo.SecretSocietyType, rawSociety
    end

    if type(rawSociety) == 'number' then
        for row in GameInfo.SecretSocieties() do
            if row.Index == rawSociety or row.Hash == rawSociety or row.SecretSocietyHash == rawSociety then
                return row.SecretSocietyType, rawSociety
            end
        end
    end
    return nil, rawSociety
end

local function Haikesi_PlayerIsHermeticOrder(pPlayer)
    if pPlayer ~= nil and pPlayer:GetProperty(HERMETIC_SYNC_PROP) == 1 then
        return true, 'ui-sync'
    end

    local societyType = Haikesi_GetPlayerSecretSocietyType(pPlayer)
    if societyType == HERMETIC_SECRET_SOCIETY then
        return true, 'secret-society'
    end

    if pPlayer == nil or pPlayer.GetGovernors == nil then
        return false, 'no-governor-api'
    end
    local governors = pPlayer:GetGovernors()
    local governorInfo = GameInfo.Governors and GameInfo.Governors[HERMETIC_GOVERNOR] or nil
    if governors == nil or governorInfo == nil then
        return false, 'no-hermetic-governor'
    end

    local hasGovernor = false
    if governors.HasGovernor ~= nil then
        local ok, result = pcall(governors.HasGovernor, governors, governorInfo.Hash)
        hasGovernor = ok and result == true
    end

    local promotionInfo = GameInfo.GovernorPromotions and GameInfo.GovernorPromotions[HERMETIC_PROMOTION_1] or nil
    if governors.GetGovernorList ~= nil then
        local okList, _, governorList = pcall(governors.GetGovernorList, governors)
        if okList and governorList ~= nil then
            for _, governor in ipairs(governorList) do
                if governor ~= nil and governor.GetType ~= nil and governor:GetType() == governorInfo.Index then
                    if hasGovernor then
                        return true, 'governor'
                    end
                    if promotionInfo ~= nil and governor.HasPromotion ~= nil
                        and governor:HasPromotion(promotionInfo.Index) then
                        return true, 'governor-promotion'
                    end
                end
            end
        end
    end

    if hasGovernor then
        return true, 'governor-hash'
    end
    return false, 'none'
end

local function Haikesi_MarkFarmImmortalPlusLeyLinePlots()
    if GameInfo.Resources == nil or Map == nil or Map.GetPlotCount == nil then
        return 0
    end
    local leyLineInfo = GameInfo.Resources[LEY_LINE_RESOURCE_TYPE]
    if leyLineInfo == nil then
        return 0
    end

    local marked = 0
    for plotIndex = 0, Map.GetPlotCount() - 1 do
        local pPlot = Map.GetPlotByIndex(plotIndex)
        if pPlot ~= nil
            and pPlot:GetResourceType() == leyLineInfo.Index
            and pPlot:GetProperty(LEY_LINE_BONUS_PLOT_PROP) ~= 1 then
            pPlot:SetProperty(LEY_LINE_BONUS_PLOT_PROP, 1)
            marked = marked + 1
        end
    end
    return marked
end

local function Haikesi_CountFarmImmortals(pPlayer)
    if pPlayer == nil or pPlayer.GetUnits == nil then
        return 0
    end
    local units = pPlayer:GetUnits()
    if units == nil then
        return 0
    end
    local count = 0
    for _, unit in units:Members() do
        local unitInfo = unit ~= nil and GameInfo.Units[unit:GetType()] or nil
        if unitInfo ~= nil and unitInfo.UnitType == NW_FARM_IMMORTAL_UNIT then
            count = count + 1
        end
    end
    return count
end

local function Haikesi_PlotBlocksFarmImmortal(playerID, x, y)
    for checkPlayerID = 0, 63 do
        local pPlayer = Players[checkPlayerID]
        if pPlayer ~= nil and pPlayer.GetUnits ~= nil then
            local units = pPlayer:GetUnits()
            if units ~= nil then
                for _, unit in units:Members() do
                    if unit ~= nil and unit:GetX() == x and unit:GetY() == y then
                        local unitInfo = GameInfo.Units[unit:GetType()]
                        if checkPlayerID ~= playerID
                            or (unitInfo ~= nil and unitInfo.FormationClass == 'FORMATION_CLASS_CIVILIAN') then
                            return true
                        end
                    end
                end
            end
        end
    end
    return false
end

local function Haikesi_CanPlaceFarmImmortalAtPlot(playerID, pPlot)
    if pPlot == nil or pPlot:IsWater() or pPlot:IsImpassable() then
        return false
    end
    return not Haikesi_PlotBlocksFarmImmortal(playerID, pPlot:GetX(), pPlot:GetY())
end

local function Haikesi_FindFarmImmortalSpawnPlot(playerID, pCity)
    if pCity == nil then
        return nil
    end
    local centerX, centerY = pCity:GetX(), pCity:GetY()
    local cityPlot = Map.GetPlot(centerX, centerY)
    if Haikesi_CanPlaceFarmImmortalAtPlot(playerID, cityPlot) then
        return cityPlot
    end
    for radius = 1, 2 do
        for dx = -radius, radius do
            for dy = -radius, radius do
                local pPlot = Map.GetPlotXY(centerX, centerY, dx, dy)
                if pPlot ~= nil
                    and Map.GetPlotDistance(centerX, centerY, pPlot:GetX(), pPlot:GetY()) == radius
                    and Haikesi_CanPlaceFarmImmortalAtPlot(playerID, pPlot) then
                    return pPlot
                end
            end
        end
    end
    return nil
end

local function Haikesi_GrantFarmImmortalPlusUnit(playerID, pPlayer)
    if pPlayer == nil then
        return false
    end
    if pPlayer:GetProperty(FARM_IMMORTAL_PLUS_GRANT_PROP) == 1 then
        return true
    end
    if Haikesi_CountFarmImmortals(pPlayer) >= 2 then
        pPlayer:SetProperty(FARM_IMMORTAL_PLUS_GRANT_PROP, 1)
        return true
    end

    local cities = pPlayer:GetCities()
    local capital = cities ~= nil and cities:GetCapitalCity() or nil
    local plot = Haikesi_FindFarmImmortalSpawnPlot(playerID, capital)
    if plot == nil then
        print('[Haikesi Planter] FARMIMMORTALPLUS grant failed: no spawn plot for Player' .. tostring(playerID))
        return false
    end

    local ok, newUnit = pcall(UnitManager.InitUnit, playerID, NW_FARM_IMMORTAL_UNIT, plot:GetX(), plot:GetY())
    if ok and newUnit ~= nil then
        pPlayer:SetProperty(FARM_IMMORTAL_PLUS_GRANT_PROP, 1)
        print(string.format(
            '[Haikesi Planter] FARMIMMORTALPLUS granted unit at (%d,%d) for Player%s',
            plot:GetX(), plot:GetY(), tostring(playerID)))
        return true
    end
    print('[Haikesi Planter] FARMIMMORTALPLUS grant error: ' .. tostring(newUnit))
    return false
end

function Haikesi_ApplyFarmImmortalPlusRelic(playerID)
    local pPlayer = Players[playerID]
    if pPlayer == nil then
        return false
    end
    if not Haikesi_PlanterPlayerHasRelic(pPlayer, FARM_IMMORTAL_PLUS_RELIC) then
        return false
    end
    Haikesi_GrantFarmImmortalPlusUnit(playerID, pPlayer)
    local isHermetic, hermeticReason = Haikesi_PlayerIsHermeticOrder(pPlayer)
    if not isHermetic then
        local societyType, rawSociety = Haikesi_GetPlayerSecretSocietyType(pPlayer)
        print(string.format(
            '[Haikesi Planter] FARMIMMORTALPLUS skipped Player%s: secret society raw=%s resolved=%s hermetic=%s',
            tostring(playerID), tostring(rawSociety), tostring(societyType), tostring(hermeticReason)
        ))
        return false
    end
    local marked = Haikesi_MarkFarmImmortalPlusLeyLinePlots()
    if pPlayer:GetProperty(LEY_LINE_YIELDS_APPLIED_PROP) == 1 then
        if marked > 0 then
            print('[Haikesi Planter] FARMIMMORTALPLUS marked ley line plots: ' .. tostring(marked))
        end
        return true
    end
    for _, modId in ipairs(FARM_IMMORTAL_PLUS_LEY_LINE_YIELD_MODIFIERS) do
        pPlayer:AttachModifierByID(modId)
    end
    pPlayer:SetProperty(LEY_LINE_YIELDS_APPLIED_PROP, 1)
    print('[Haikesi Planter] FARMIMMORTALPLUS ley line yields attached for Player' .. tostring(playerID)
        .. ' via ' .. tostring(hermeticReason)
        .. ', marked=' .. tostring(marked))
    return true
end

function HaikesiSyncSecretSociety(playerID, params)
    local pPlayer = Players[playerID]
    if pPlayer == nil then
        return
    end
    local isHermetic = params ~= nil and tonumber(params.IsHermetic or 0) == 1
    pPlayer:SetProperty(HERMETIC_SYNC_PROP, isHermetic and 1 or 0)
    print(string.format(
        '[Haikesi Planter] secret society sync Player%s hermetic=%s society=%s raw=%s',
        tostring(playerID),
        tostring(isHermetic),
        tostring(params and params.SocietyType or nil),
        tostring(params and params.RawSociety or nil)
    ))
    if isHermetic then
        Haikesi_ApplyFarmImmortalPlusRelic(playerID)
    end
end

local function Haikesi_PlanterBuildValidImprovementCache()
    g_PlanterResourceValidImprovements = {}
    for row in GameInfo.Improvement_ValidResources() do
        local resRow = GameInfo.Resources[row.ResourceType]
        local impRow = GameInfo.Improvements[row.ImprovementType]
        if resRow ~= nil and impRow ~= nil then
            local resIndex = resRow.Index
            if g_PlanterResourceValidImprovements[resIndex] == nil then
                g_PlanterResourceValidImprovements[resIndex] = {}
            end
            g_PlanterResourceValidImprovements[resIndex][impRow.Index] = true
        end
    end
end

local function Haikesi_PlanterIsRestorableImprovement(impIndex, resourceIndex)
    if impIndex == nil or impIndex < 0 or resourceIndex == nil or resourceIndex < 0 then
        return false
    end
    if g_PlanterResourceValidImprovements == nil then
        Haikesi_PlanterBuildValidImprovementCache()
    end
    local valid = g_PlanterResourceValidImprovements[resourceIndex]
    return valid ~= nil and valid[impIndex] == true
end

local function Haikesi_PlanterCanPlotHaveResource(pPlot, resourceIndex)
    if pPlot == nil or resourceIndex < 0 then
        return false
    end
    if pPlot:GetDistrictType() ~= -1 then
        return false
    end
    if pPlot:GetResourceType() ~= -1 then
        return false
    end

    local oldImp = pPlot:GetImprovementType()
    if oldImp ~= -1 and ImprovementBuilder ~= nil then
        ImprovementBuilder.SetImprovementType(pPlot, -1, -1)
    end

    local canHave = ResourceBuilder.CanHaveResource(pPlot, resourceIndex)

    if oldImp ~= -1 and ImprovementBuilder ~= nil then
        ImprovementBuilder.SetImprovementType(pPlot, oldImp, -1)
    end
    return canHave == true
end

local function Haikesi_PlanterPlaceResourceOnPlot(pPlot, resourceIndex, resourceCount)
    if pPlot == nil or resourceIndex < 0 then
        return false
    end
    local count = resourceCount or 1
    local oldImp = pPlot:GetImprovementType()
    if oldImp ~= -1 and ImprovementBuilder ~= nil then
        ImprovementBuilder.SetImprovementType(pPlot, -1, -1)
    end

    ResourceBuilder.SetResourceType(pPlot, resourceIndex, count)

    if pPlot:GetResourceType() ~= resourceIndex then
        if oldImp ~= -1 and ImprovementBuilder ~= nil then
            ImprovementBuilder.SetImprovementType(pPlot, oldImp, -1)
        end
        return false
    end

    if oldImp ~= -1
        and Haikesi_PlanterIsRestorableImprovement(oldImp, resourceIndex)
        and ImprovementBuilder ~= nil then
        ImprovementBuilder.SetImprovementType(pPlot, oldImp, -1)
    end
    return true
end

local function Haikesi_IsFarmImmortalUnit(unit)
    if unit == nil then
        return false
    end
    local unitInfo = GameInfo.Units[unit:GetType()]
    return unitInfo ~= nil and unitInfo.UnitType == NW_FARM_IMMORTAL_UNIT
end

local function Haikesi_IsPlanterWhitelistResource(resourceIndex, pPlayer)
    if resourceIndex == nil or resourceIndex < 0 or GameInfo.Haikesi_PlanterResources == nil then
        return false
    end
    local resourceInfo = GameInfo.Resources[resourceIndex]
    if resourceInfo == nil then
        return false
    end
    for row in GameInfo.Haikesi_PlanterResources() do
        if row.ResourceType == resourceInfo.ResourceType then
            local requiredRelic = row.RequiredRelic
            return requiredRelic == nil
                or requiredRelic == ''
                or Haikesi_PlanterPlayerHasRelic(pPlayer, requiredRelic)
        end
    end
    return false
end

local function Haikesi_IsValidPlanterPlot(plot, playerID)
    if plot == nil then
        return false
    end
    if plot:IsNaturalWonder() or plot:GetDistrictType() ~= -1 then
        return false
    end
    local owner = plot:GetOwner()
    if owner ~= -1 and owner ~= playerID then
        return false
    end
    if plot:GetResourceType() ~= -1 then
        return false
    end
    return true
end

local function Haikesi_FindPlanterChargeAbility(unit)
    local unitAbility = unit and unit:GetAbility() or nil
    if unitAbility == nil or GameInfo.Haikesi_PlanterChargeSlots == nil then
        return nil
    end
    for row in GameInfo.Haikesi_PlanterChargeSlots() do
        local abilityType = 'ABILITY_NW_PLANTER_CONSUMED_CHARGE_' .. row.Slot
        if unitAbility:GetAbilityCount(abilityType) == 0 then
            return abilityType
        end
    end
    return nil
end

local function Haikesi_ConsumePlanterCharge(unit, abilityType)
    local unitAbility = unit and unit:GetAbility() or nil
    if unitAbility == nil or abilityType == nil then
        return false
    end
    UnitManager.FinishMoves(unit)
    unitAbility:ChangeAbilityCount(abilityType, 1)
    return true
end

function HaikesiPlantResource(playerID, params)
    local player = Players[playerID]
    local unit = params and UnitManager.GetUnit(playerID, params.UnitID) or nil
    local plot = params and Map.GetPlot(params.X, params.Y) or nil
    local resourceIndex = params and tonumber(params.ResourceIndex) or nil

    if player == nil or not player:IsHuman() or unit == nil or plot == nil or resourceIndex == nil then
        print('[Haikesi Planter] canceled: invalid player/unit/plot/resource')
        return
    end
    if not Haikesi_IsFarmImmortalUnit(unit)
        or unit:GetX() ~= params.X
        or unit:GetY() ~= params.Y
        or unit:GetBuildCharges() <= 0
        or unit:GetMovesRemaining() <= 0 then
        print('[Haikesi Planter] canceled: invalid farm immortal state')
        return
    end
    if not Haikesi_IsPlanterWhitelistResource(resourceIndex, player) then
        print('[Haikesi Planter] canceled: resource not in whitelist')
        return
    end
    if not Haikesi_IsValidPlanterPlot(plot, playerID) then
        print('[Haikesi Planter] canceled: plot not eligible')
        return
    end
    if not Haikesi_PlanterCanPlotHaveResource(plot, resourceIndex) then
        print('[Haikesi Planter] canceled: CanHaveResource=false')
        return
    end

    local chargeAbility = Haikesi_FindPlanterChargeAbility(unit)
    if chargeAbility == nil then
        print('[Haikesi Planter] canceled: charge ability slots exhausted')
        return
    end

    local planted = Haikesi_PlanterPlaceResourceOnPlot(plot, resourceIndex, 1)
    if not planted then
        print('[Haikesi Planter] place failed resourceIndex=' .. tostring(resourceIndex))
        return
    end

    local resInfo = GameInfo.Resources[resourceIndex]
    if resInfo ~= nil and resInfo.ResourceType == LEY_LINE_RESOURCE_TYPE then
        plot:SetProperty(LEY_LINE_BONUS_PLOT_PROP, 1)
    end
    Haikesi_ConsumePlanterCharge(unit, chargeAbility)
    Haikesi_ApplyFarmImmortalPlusRelic(playerID)
    print(string.format(
        '[Haikesi Planter] planted %s at (%d,%d) charge=%s',
        resInfo and resInfo.ResourceType or tostring(resourceIndex),
        plot:GetX(), plot:GetY(), tostring(chargeAbility)
    ))
end

function HaikesiLincolnHarvest(playerID, params)
    local player = Players[playerID]
    local unit = params and UnitManager.GetUnit(playerID, tonumber(params.UnitID)) or nil
    local x = params and tonumber(params.X) or nil
    local y = params and tonumber(params.Y) or nil
    local plot = x ~= nil and y ~= nil and Map.GetPlot(x, y) or nil

    if not Haikesi_LincolnPlayerIsEligible(playerID, player)
        or unit == nil
        or plot == nil
        or not Haikesi_LincolnIsBuilder(unit)
        or unit:GetX() ~= x
        or unit:GetY() ~= y
        or unit:GetBuildCharges() <= 0
        or unit:GetMovesRemaining() <= 0 then
        print('[Haikesi Lincoln] harvest canceled: invalid player or builder state')
        return
    end

    local isPlantationResource, resourceInfo = Haikesi_LincolnIsPlantationResource(plot, playerID)
    if not isPlantationResource then
        print('[Haikesi Lincoln] harvest canceled: resource is not an owned plantation-type luxury/bonus resource')
        return
    end
    if params.ResourceType ~= nil and tostring(params.ResourceType) ~= resourceInfo.ResourceType then
        print('[Haikesi Lincoln] harvest canceled: resource changed before execution')
        return
    end
    if GameInfo.UnitAbilities == nil or GameInfo.UnitAbilities[LINCOLN_MELEE_ABILITY] == nil then
        print('[Haikesi Lincoln] harvest canceled: Lincoln melee ability unavailable')
        return
    end

    local meleeType = Haikesi_LincolnGetBestMeleeType(player)
    local spawnPlot = Haikesi_LincolnFindSpawnPlot(playerID, x, y)
    local harvestProxyInfo = GameInfo.Resources[LINCOLN_HARVEST_PROXY_RESOURCE]
    local harvestOperation = UnitOperationTypes and UnitOperationTypes.HARVEST_RESOURCE or nil
    if meleeType == nil or spawnPlot == nil or harvestProxyInfo == nil or harvestOperation == nil then
        print('[Haikesi Lincoln] harvest canceled: no melee type, spawn plot, harvest proxy, or harvest operation')
        return
    end

    local oldImprovement = plot:GetImprovementType()
    local oldResource = plot:GetResourceType()
    local oldResourceCount = math.max(1, tonumber(plot:GetResourceCount()) or 1)
    local ok, newUnit = pcall(
        UnitManager.InitUnit,
        playerID,
        meleeType,
        spawnPlot:GetX(),
        spawnPlot:GetY()
    )
    if not ok or newUnit == nil then
        print('[Haikesi Lincoln] harvest canceled: free melee spawn failed')
        return
    end

    local newAbility = newUnit:GetAbility()
    if newAbility == nil then
        pcall(UnitManager.Kill, newUnit, false)
        print('[Haikesi Lincoln] harvest canceled: spawned melee has no ability component')
        return
    end

    newAbility:ChangeAbilityCount(LINCOLN_MELEE_ABILITY, 1)

    -- Reuse the native harvest operation with a hidden proxy carrying equal Food/Gold rows,
    -- so both yields share the game's scaling, city targeting and harvest bonuses.
    ImprovementBuilder.SetImprovementType(plot, -1, -1)
    if oldResource ~= harvestProxyInfo.Index then
        ResourceBuilder.SetResourceType(plot, -1)
        ResourceBuilder.SetResourceType(plot, harvestProxyInfo.Index, 1)
    end
    if plot:GetImprovementType() ~= -1 or plot:GetResourceType() ~= harvestProxyInfo.Index then
        pcall(UnitManager.Kill, newUnit, false)
        ResourceBuilder.SetResourceType(plot, -1)
        ResourceBuilder.SetResourceType(plot, oldResource, oldResourceCount)
        ImprovementBuilder.SetImprovementType(plot, oldImprovement, playerID)
        print('[Haikesi Lincoln] harvest canceled: failed to prepare native food harvest')
        return
    end

    -- Do not nest HARVEST_RESOURCE inside the EXECUTE_SCRIPT player operation.
    -- The UI requests the native unit operation after PlayerOperationComplete.
    Haikesi_LincolnStorePendingHarvest(
        unit,
        x, y,
        oldResource,
        oldResourceCount,
        oldImprovement,
        newUnit:GetID()
    )
    print(string.format(
        '[Haikesi Lincoln] prepared %s for native equal food/gold harvest at (%d,%d), granted %s at (%d,%d)',
        resourceInfo.ResourceType,
        x, y,
        meleeType,
        spawnPlot:GetX(), spawnPlot:GetY()
    ))
end

function HaikesiLincolnHarvestRollback(playerID, params)
    local unit = params and UnitManager.GetUnit(playerID, tonumber(params.UnitID)) or nil
    if unit == nil or tonumber(unit:GetProperty(LINCOLN_HARVEST_PENDING_PROP) or 0) ~= 1 then
        print('[Haikesi Lincoln] harvest rollback skipped: no pending harvest')
        return
    end

    local x = tonumber(unit:GetProperty(LINCOLN_HARVEST_X_PROP))
    local y = tonumber(unit:GetProperty(LINCOLN_HARVEST_Y_PROP))
    local oldResource = tonumber(unit:GetProperty(LINCOLN_HARVEST_OLD_RESOURCE_PROP))
    local oldResourceCount = math.max(1, tonumber(unit:GetProperty(LINCOLN_HARVEST_OLD_RESOURCE_COUNT_PROP)) or 1)
    local oldImprovement = tonumber(unit:GetProperty(LINCOLN_HARVEST_OLD_IMPROVEMENT_PROP))
    local spawnedUnitID = tonumber(unit:GetProperty(LINCOLN_HARVEST_SPAWNED_UNIT_PROP))
    local plot = x ~= nil and y ~= nil and Map.GetPlot(x, y) or nil
    local spawnedUnit = spawnedUnitID ~= nil and UnitManager.GetUnit(playerID, spawnedUnitID) or nil

    if spawnedUnit ~= nil then
        pcall(UnitManager.Kill, spawnedUnit, false)
    end
    if plot ~= nil and oldResource ~= nil and oldImprovement ~= nil then
        ResourceBuilder.SetResourceType(plot, -1)
        ResourceBuilder.SetResourceType(plot, oldResource, oldResourceCount)
        ImprovementBuilder.SetImprovementType(plot, oldImprovement, playerID)
    end
    Haikesi_LincolnClearPendingHarvest(unit)
    print(string.format(
        '[Haikesi Lincoln] rolled back failed native harvest at (%s,%s)',
        tostring(x), tostring(y)
    ))
end

local function Haikesi_LincolnOnUnitOperationStarted(playerID, unitID, operationID)
    if operationID ~= UnitOperationTypes.HARVEST_RESOURCE then return end
    local unit = UnitManager.GetUnit(playerID, unitID)
    if unit == nil or tonumber(unit:GetProperty(LINCOLN_HARVEST_PENDING_PROP) or 0) ~= 1 then
        return
    end
    local x = tonumber(unit:GetProperty(LINCOLN_HARVEST_X_PROP))
    local y = tonumber(unit:GetProperty(LINCOLN_HARVEST_Y_PROP))
    local plot = x ~= nil and y ~= nil and Map.GetPlot(x, y) or nil
    local proxyInfo = GameInfo.Resources[LINCOLN_HARVEST_PROXY_RESOURCE]
    if plot ~= nil and proxyInfo ~= nil and plot:GetResourceType() == proxyInfo.Index then
        Haikesi_LincolnClearPendingHarvest(unit)
        print(string.format(
            '[Haikesi Lincoln] native harvest started at (%d,%d); pending state cleared',
            x, y
        ))
    end
end

local function InitializePlanter()
    Haikesi_PlanterBuildValidImprovementCache()
    GameEvents.HaikesiPlantResource.Add(HaikesiPlantResource)
    GameEvents.HaikesiLincolnHarvest.Add(HaikesiLincolnHarvest)
    GameEvents.HaikesiLincolnHarvestRollback.Add(HaikesiLincolnHarvestRollback)
    GameEvents.HaikesiSyncSecretSociety.Add(HaikesiSyncSecretSociety)
    if ExposedMembers ~= nil then
        ExposedMembers.Haikesi_ApplyFarmImmortalPlusRelic = Haikesi_ApplyFarmImmortalPlusRelic
    end
    Events.UnitOperationStarted.Add(Haikesi_LincolnOnUnitOperationStarted)
    print('[Haikesi Planter] GamePlay ready (split from main script)')
end

Events.LoadScreenClose.Add(InitializePlanter)
Events.PlayerTurnActivated.Add(function(playerID, isFirstTime)
    if isFirstTime then
        Haikesi_ApplyFarmImmortalPlusRelic(playerID)
    end
end)
