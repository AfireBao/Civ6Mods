-- ===========================================================================
-- Haikesi_Planter_GamePlay.lua
-- 种地仙人种植：从主 GamePlay 脚本拆出，避免 Firaxis Lua 5.1 主 chunk
-- local 寄存器上限（~200）导致 Haikesi_GamePlay_Script.lua 整文件加载失败。
-- ===========================================================================

local NW_FARM_IMMORTAL_UNIT = 'UNIT_NW_FARM_IMMORTAL'

local g_PlanterResourceValidImprovements = nil

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

local function Haikesi_IsPlanterWhitelistResource(resourceIndex)
    if resourceIndex == nil or resourceIndex < 0 or GameInfo.Haikesi_PlanterResources == nil then
        return false
    end
    local resourceInfo = GameInfo.Resources[resourceIndex]
    if resourceInfo == nil then
        return false
    end
    for row in GameInfo.Haikesi_PlanterResources() do
        if row.ResourceType == resourceInfo.ResourceType then
            return true
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
    if not Haikesi_IsPlanterWhitelistResource(resourceIndex) then
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

    Haikesi_ConsumePlanterCharge(unit, chargeAbility)
    local resInfo = GameInfo.Resources[resourceIndex]
    print(string.format(
        '[Haikesi Planter] planted %s at (%d,%d) charge=%s',
        resInfo and resInfo.ResourceType or tostring(resourceIndex),
        plot:GetX(), plot:GetY(), tostring(chargeAbility)
    ))
end

local function InitializePlanter()
    Haikesi_PlanterBuildValidImprovementCache()
    GameEvents.HaikesiPlantResource.Add(HaikesiPlantResource)
    print('[Haikesi Planter] GamePlay ready (split from main script)')
end

Events.LoadScreenClose.Add(InitializePlanter)
