-- ===========================================================================
-- Haikesi_Vampire_GamePlay.lua
-- Sanguine Pact relic stack: bloodline conversion and tyranny loyalty.
-- ===========================================================================

local SANGUINE_DUKE_RELIC = 'SANGUINEDUKERUNE'
local VAMPIRE_UNIT = 'UNIT_VAMPIRE'
local VAMPIRE_DUKE_UNIT = 'UNIT_NW_VAMPIRE_DUKE'
local TYRANNY_PROMOTION = 'PROMOTION_NW_VAMPIRE_DUKE_TYRANNY'
local DUKE_RANGED_SCALING_KEY = 'RANGED_COMBAT_STRENGTH_FOR_NW_VAMPIRE_DUKE'

local CONVERSION_DENOM = 100
local CONVERSION_CHANCE = 5
local TYRANNY_LOYALTY_DAMAGE = -20

local RelicsPropertyKey = 'PROP_NW_HAIKESI_RELICS'
local RelicsCountPropertyKey = 'PROP_NW_HAIKESI_RELIC_COUNT'
local RelicsSlotPropertyPrefix = 'PROP_NW_HAIKESI_RELIC_'
local LegacyRelicsCountPropertyKey = 'PROP_NW_HAIKESI_RELICS_COUNT'
local LegacyRelicsSlotPropertyPrefix = 'PROP_NW_HAIKESI_RELIC_SLOT_'

local g_UnitCache = {}
local g_KillHandled = {}

local function HV_Log(msg)
    print('[Haikesi Vampire] ' .. tostring(msg))
end

local function HV_GetRelicTypeFromIndex(index)
    if GameInfo.Haikesi_Relics == nil then return nil end
    for row in GameInfo.Haikesi_Relics() do
        if row.Index == index then
            return row.RelicType
        end
    end
    return nil
end

local function HV_PlayerHasRelic(pPlayer, relicType)
    if pPlayer == nil or relicType == nil then return false end

    local function checkSlots(countKey, prefix)
        local count = tonumber(pPlayer:GetProperty(countKey) or 0) or 0
        if count <= 0 then return false end
        for i = 1, count do
            if pPlayer:GetProperty(prefix .. i) == relicType then
                return true
            end
        end
        return false
    end

    if checkSlots(RelicsCountPropertyKey, RelicsSlotPropertyPrefix) then return true end
    if checkSlots(LegacyRelicsCountPropertyKey, LegacyRelicsSlotPropertyPrefix) then return true end

    local prop = pPlayer:GetProperty(RelicsPropertyKey) or ''
    if prop ~= '' then
        for idxStr in string.gmatch(prop, '[^|]+') do
            local idx = tonumber(idxStr)
            if idx ~= nil and HV_GetRelicTypeFromIndex(idx) == relicType then
                return true
            end
        end
    end
    return false
end

local function HV_GetUnit(playerID, unitID)
    if playerID == nil or unitID == nil then return nil end
    local pUnit = UnitManager.GetUnit(playerID, unitID)
    if pUnit ~= nil then return pUnit end
    local pPlayer = Players[playerID]
    if pPlayer == nil or pPlayer.GetUnits == nil then return nil end
    return pPlayer:GetUnits():FindID(unitID)
end

local function HV_GetUnitType(unit)
    if unit == nil then return nil end
    local unitInfo = GameInfo.Units[unit:GetType()]
    return unitInfo and unitInfo.UnitType or nil
end

local function HV_IsVampireLine(unit)
    local unitType = HV_GetUnitType(unit)
    return unitType == VAMPIRE_UNIT or unitType == VAMPIRE_DUKE_UNIT
end

local function HV_IsDuke(unit)
    return HV_GetUnitType(unit) == VAMPIRE_DUKE_UNIT
end

local function HV_SyncDukeRangedScaling(unit)
    if unit == nil or not HV_IsDuke(unit) then return end
    if unit.GetCombat == nil or unit.GetProperty == nil or unit.SetProperty == nil then return end

    local unitInfo = GameInfo.Units[VAMPIRE_DUKE_UNIT]
    local baseCombat = unitInfo and tonumber(unitInfo.Combat or 20) or 20
    local currentCombat = tonumber(unit:GetCombat() or baseCombat) or baseCombat
    local amount = math.max(0, currentCombat - baseCombat)
    local oldAmount = tonumber(unit:GetProperty(DUKE_RANGED_SCALING_KEY) or -1) or -1
    if oldAmount ~= amount then
        unit:SetProperty(DUKE_RANGED_SCALING_KEY, amount)
        HV_Log(string.format('duke ranged scaling P%d U%d combat=%d delta=%d',
            unit:GetOwner(), unit:GetID(), currentCombat, amount))
    end
end

local function HV_SyncPlayerDukes(playerID)
    local pPlayer = Players[playerID]
    if pPlayer == nil or pPlayer.GetUnits == nil then return end
    for _, unit in pPlayer:GetUnits():Members() do
        HV_SyncDukeRangedScaling(unit)
    end
end

local function HV_UnitHasPromotion(unit, promotionType)
    if unit == nil or promotionType == nil then return false end
    local promotionInfo = GameInfo.UnitPromotions[promotionType]
    if promotionInfo == nil then return false end
    local exp = unit:GetExperience()
    if exp == nil or exp.HasPromotion == nil then return false end
    return exp:HasPromotion(promotionInfo.Index)
end

local function HV_CacheUnit(playerID, unitID)
    local unit = HV_GetUnit(playerID, unitID)
    if unit == nil then return end
    local x, y = unit:GetX(), unit:GetY()
    if x == nil or x < 0 then return end
    if g_UnitCache[playerID] == nil then
        g_UnitCache[playerID] = {}
    end
    g_UnitCache[playerID][unitID] = { x = x, y = y }
end

local function HV_TakeCachedPlot(playerID, unitID)
    local byPlayer = g_UnitCache[playerID]
    if byPlayer == nil then return nil end
    local entry = byPlayer[unitID]
    byPlayer[unitID] = nil
    return entry
end

local function HV_Rand(maxCount, reason)
    if maxCount == nil or maxCount <= 0 then return 0 end
    if Game.GetRandNum ~= nil then
        return Game.GetRandNum(maxCount, reason or 'HaikesiVampire') or 0
    end
    return math.random(0, maxCount - 1)
end

local function HV_FindSpawnPlot(playerID, x, y)
    local pPlot = Map.GetPlot(x, y)
    if pPlot ~= nil and not pPlot:IsWater() and not pPlot:IsImpassable() then
        return pPlot
    end

    for dir = 0, 5 do
        local adj = Map.GetAdjacentPlot(x, y, dir)
        if adj ~= nil and not adj:IsWater() and not adj:IsImpassable() then
            return adj
        end
    end
    return nil
end

local function HV_SpawnVampire(playerID, x, y)
    local unitInfo = GameInfo.Units[VAMPIRE_UNIT]
    if unitInfo == nil then return false end
    local plot = HV_FindSpawnPlot(playerID, x, y)
    if plot == nil then return false end
    local ok, newUnit = pcall(UnitManager.InitUnit, playerID, VAMPIRE_UNIT, plot:GetX(), plot:GetY())
    if ok and newUnit ~= nil then
        if newUnit.SetDamage ~= nil then
            newUnit:SetDamage(0)
        elseif newUnit.ChangeDamage ~= nil and newUnit.GetDamage ~= nil then
            newUnit:ChangeDamage(-newUnit:GetDamage())
        end
        HV_Log(string.format('P%d vampire conversion at %d,%d', playerID, plot:GetX(), plot:GetY()))
        return true
    end
    return false
end

local function HV_ApplyTyranny(killerPlayerID, killedPlayerID, x, y)
    if x == nil or y == nil then return end
    local plot = Map.GetPlot(x, y)
    if plot == nil or plot:GetOwner() == killerPlayerID or plot:GetOwner() < 0 then return end

    local city = nil
    if Cities ~= nil and Cities.GetPlotPurchaseCity ~= nil then
        city = Cities.GetPlotPurchaseCity(plot)
    end
    if city == nil and CityManager ~= nil and plot:GetOwner() ~= nil then
        local owner = plot:GetOwner()
        local pOwner = Players[owner]
        if pOwner ~= nil and pOwner.GetCities ~= nil then
            local bestDist = 999999
            for _, checkCity in pOwner:GetCities():Members() do
                local dist = Map.GetPlotDistance(x, y, checkCity:GetX(), checkCity:GetY())
                if dist < bestDist then
                    bestDist = dist
                    city = checkCity
                end
            end
        end
    end

    if city ~= nil and city:GetOwner() ~= killerPlayerID and city.ChangeLoyalty ~= nil then
        city:ChangeLoyalty(TYRANNY_LOYALTY_DAMAGE)
        HV_Log(string.format('P%d tyranny loyalty %d city=%s',
            killerPlayerID, TYRANNY_LOYALTY_DAMAGE, Locale.Lookup(city:GetName())))
    end
end

local function HV_ApplyKillEffects(killerPlayerID, killedPlayerID, killedUnitID, killerUnitID, x, y, source)
    if killerPlayerID == nil or killedPlayerID == nil then return end
    if killerPlayerID == killedPlayerID then return end

    local pKiller = Players[killerPlayerID]
    if pKiller == nil then return end

    local killerUnit = HV_GetUnit(killerPlayerID, killerUnitID)
    if killerUnit == nil or not HV_IsVampireLine(killerUnit) then return end

    if not (HV_PlayerHasRelic(pKiller, SANGUINE_DUKE_RELIC) and HV_IsDuke(killerUnit)) then
        return
    end

    local key = tostring(Game.GetCurrentGameTurn()) .. ':' .. tostring(killedPlayerID) .. ':' .. tostring(killedUnitID)
    if g_KillHandled[key] then return end
    g_KillHandled[key] = true

    if x == nil or y == nil then
        local cached = HV_TakeCachedPlot(killedPlayerID, killedUnitID)
        if cached ~= nil then
            x, y = cached.x, cached.y
        end
    end
    if x == nil or y == nil then
        x, y = killerUnit:GetX(), killerUnit:GetY()
    end

    if HV_Rand(CONVERSION_DENOM, 'HaikesiVampireConversion') < CONVERSION_CHANCE then
        HV_SpawnVampire(killerPlayerID, x, y)
    end
    if HV_UnitHasPromotion(killerUnit, TYRANNY_PROMOTION) then
        HV_ApplyTyranny(killerPlayerID, killedPlayerID, x, y)
    end

    HV_Log(string.format('%s P%d vampire kill effects at %s,%s',
        tostring(source), killerPlayerID, tostring(x), tostring(y)))
end

function Haikesi_OnVampireUnitKilledInCombat(killedPlayerID, killedUnitID, killerPlayerID, killerUnitID)
    HV_ApplyKillEffects(killerPlayerID, killedPlayerID, killedUnitID, killerUnitID, nil, nil, 'UnitKilledInCombat')
end

function Haikesi_OnVampireCombatOccurred(attackerPlayerID, attackerUnitID, defenderPlayerID, defenderUnitID)
    if attackerPlayerID == nil or defenderPlayerID == nil then return end
    if attackerPlayerID == defenderPlayerID then return end

    local atk = HV_GetUnit(attackerPlayerID, attackerUnitID)
    local def = HV_GetUnit(defenderPlayerID, defenderUnitID)

    local function dying(unit)
        if unit == nil then return false end
        if unit.IsDead ~= nil and unit:IsDead() then return true end
        if unit.IsDelayedDeath ~= nil and unit:IsDelayedDeath() then return true end
        return false
    end

    if dying(def) then
        HV_ApplyKillEffects(attackerPlayerID, defenderPlayerID, defenderUnitID, attackerUnitID,
            def:GetX(), def:GetY(), 'OnCombatOccurred')
    end
    if dying(atk) then
        HV_ApplyKillEffects(defenderPlayerID, attackerPlayerID, attackerUnitID, defenderUnitID,
            atk:GetX(), atk:GetY(), 'OnCombatOccurred')
    end
end

local function HV_OnUnitAddedToMap(playerID, unitID)
    HV_CacheUnit(playerID, unitID)
    HV_SyncDukeRangedScaling(HV_GetUnit(playerID, unitID))
end

local function HV_OnUnitMoved(playerID, unitID)
    HV_CacheUnit(playerID, unitID)
    HV_SyncDukeRangedScaling(HV_GetUnit(playerID, unitID))
end

local function HV_OnPlayerTurnActivated(playerID)
    g_KillHandled = {}
    HV_SyncPlayerDukes(playerID)
end

local function InitializeHaikesiVampire()
    if Events.UnitKilledInCombat ~= nil then
        Events.UnitKilledInCombat.Add(Haikesi_OnVampireUnitKilledInCombat)
    end
    if GameEvents ~= nil and GameEvents.OnCombatOccurred ~= nil then
        GameEvents.OnCombatOccurred.Add(Haikesi_OnVampireCombatOccurred)
    end
    if Events.UnitAddedToMap ~= nil then
        Events.UnitAddedToMap.Add(HV_OnUnitAddedToMap)
    end
    if Events.UnitMoved ~= nil then
        Events.UnitMoved.Add(HV_OnUnitMoved)
    end
    if Events.PlayerTurnActivated ~= nil then
        Events.PlayerTurnActivated.Add(HV_OnPlayerTurnActivated)
    end
    local maxMajorCivs = GameDefines and GameDefines.MAX_MAJOR_CIVS or 64
    for playerID = 0, maxMajorCivs - 1 do
        HV_SyncPlayerDukes(playerID)
    end
    HV_Log('initialized')
end

Events.LoadScreenClose.Add(InitializeHaikesiVampire)
