-- ===========================================================================
-- Haikesi_Trinity_GamePlay.lua
-- 三位一体：娟 -> 翔 -> 捞叶 -> 娟 + slot machine.
-- ===========================================================================

local UNIT_JUAN = "UNIT_NW_JUAN"
local UNIT_XIANG = "UNIT_NW_XIANG"
local UNIT_LAOYE = "UNIT_NW_LAOYE"

local SLOT_JUAN = "JUAN"
local SLOT_XIANG = "XIANG"
local SLOT_LEAF = "LEAF"
local SLOT_SYMBOLS = { SLOT_JUAN, SLOT_XIANG, SLOT_LEAF }
local NAVAL_REWARD_WATER_SEARCH_RADIUS = 20

-- Gameplay publishes a fully snapshotted slot result through player
-- properties.  The UI polls it on its own next frame and sends only the
-- sequence number back through EXECUTE_SCRIPT when the popup is closed.
local SLOT_PENDING_SEQUENCE_PROP = "PROP_NW_TRINITY_SLOT_PENDING_SEQUENCE_V2"
local SLOT_SETTLED_SEQUENCE_PROP = "PROP_NW_TRINITY_SLOT_SETTLED_SEQUENCE_V2"
local SLOT_RESULTS_PROP = "PROP_NW_TRINITY_SLOT_RESULTS_V2"
local SLOT_REWARD_KEY_PROP = "PROP_NW_TRINITY_SLOT_REWARD_KEY_V2"
local SLOT_X_PROP = "PROP_NW_TRINITY_SLOT_X_V2"
local SLOT_Y_PROP = "PROP_NW_TRINITY_SLOT_Y_V2"
local SLOT_UNIT_TYPE_PROP = "PROP_NW_TRINITY_SLOT_UNIT_TYPE_V2"
local SLOT_SCIENCE_PROP = "PROP_NW_TRINITY_SLOT_SCIENCE_V2"
local SLOT_CULTURE_PROP = "PROP_NW_TRINITY_SLOT_CULTURE_V2"
local SLOT_GOLD_PROP = "PROP_NW_TRINITY_SLOT_GOLD_V2"
local SLOT_FAITH_PROP = "PROP_NW_TRINITY_SLOT_FAITH_V2"
local SLOT_FLOATER_PROP = "PROP_NW_TRINITY_SLOT_FLOATER_V2"

local function TrinityLog(msg)
    print("[Haikesi Trinity] " .. tostring(msg))
end

local function RandomIndex(maxExclusive, label)
    if maxExclusive == nil or maxExclusive <= 0 then
        return 0
    end
    if Game ~= nil and Game.GetRandNum ~= nil then
        return Game.GetRandNum(maxExclusive, label or "Haikesi Trinity")
    end
    TrinityLog("Game.GetRandNum missing; deterministic fallback used for " .. tostring(label))
    return 0
end

local function GetUnitTypeName(unit)
    if unit == nil then return nil end
    local row = GameInfo.Units[unit:GetType()]
    return row and row.UnitType or nil
end

local function FinishMoves(unit)
    if unit == nil then return end
    if UnitManager ~= nil and UnitManager.FinishMoves ~= nil then
        pcall(UnitManager.FinishMoves, unit)
    end
end

local function IsNavalUnitType(unitType)
    local unitRow = unitType and GameInfo.Units[unitType] or nil
    return unitRow ~= nil and unitRow.Domain == "DOMAIN_SEA"
end

local function TryInitUnitAtPlot(playerID, unitType, pPlot, exhaustMoves)
    if pPlot == nil then
        return nil
    end
    local ok, newUnit = pcall(UnitManager.InitUnit, playerID, unitType, pPlot:GetX(), pPlot:GetY())
    if ok and newUnit ~= nil then
        if exhaustMoves == true then
            FinishMoves(newUnit)
        end
        return newUnit
    end
    return nil
end

local function GetPlayerCitiesByDistance(pPlayer, x, y)
    local cities = {}
    if pPlayer == nil or pPlayer:GetCities() == nil then
        return cities
    end
    for _, city in pPlayer:GetCities():Members() do
        if city ~= nil then
            table.insert(cities, {
                city = city,
                dist = Map.GetPlotDistance(x, y, city:GetX(), city:GetY()),
                id = city:GetID()
            })
        end
    end
    table.sort(cities, function(a, b)
        if a.dist == b.dist then
            return a.id < b.id
        end
        return a.dist < b.dist
    end)
    return cities
end

local function GatherWaterPlotsNearCity(city, radius)
    local candidates = {}
    local seen = {}
    if city == nil then
        return candidates
    end
    local centerX = city:GetX()
    local centerY = city:GetY()
    for dx = -radius, radius do
        for dy = -radius, radius do
            local pPlot = Map.GetPlotXY(centerX, centerY, dx, dy)
            if pPlot ~= nil then
                local plotID = pPlot:GetIndex()
                local dist = Map.GetPlotDistance(centerX, centerY, pPlot:GetX(), pPlot:GetY())
                if dist <= radius
                    and not seen[plotID]
                    and pPlot:IsWater()
                    and not pPlot:IsImpassable()
                    and CityManager.GetCityAt(pPlot:GetX(), pPlot:GetY()) == nil then
                    seen[plotID] = true
                    table.insert(candidates, { plot = pPlot, dist = dist, index = plotID })
                end
            end
        end
    end
    table.sort(candidates, function(a, b)
        if a.dist == b.dist then
            return a.index < b.index
        end
        return a.dist < b.dist
    end)
    return candidates
end

local function InitNavalUnitNearPlayerCity(playerID, unitType, x, y, exhaustMoves)
    local pPlayer = Players[playerID]
    if pPlayer == nil then
        return nil
    end

    local originPlot = Map.GetPlot(x, y)
    if originPlot ~= nil and originPlot:IsWater() and not originPlot:IsImpassable() then
        local newUnit = TryInitUnitAtPlot(playerID, unitType, originPlot, exhaustMoves)
        if newUnit ~= nil then
            TrinityLog(string.format("spawned naval reward %s for P%d at original water (%d,%d)",
                unitType, playerID, originPlot:GetX(), originPlot:GetY()))
            return newUnit
        end
    end

    local cities = GetPlayerCitiesByDistance(pPlayer, x, y)
    for _, entry in ipairs(cities) do
        for _, candidate in ipairs(GatherWaterPlotsNearCity(entry.city, NAVAL_REWARD_WATER_SEARCH_RADIUS)) do
            local pPlot = candidate.plot
            local newUnit = TryInitUnitAtPlot(playerID, unitType, pPlot, exhaustMoves)
            if newUnit ~= nil then
                TrinityLog(string.format(
                    "spawned naval reward %s for P%d near city %d at (%d,%d)",
                    unitType, playerID, entry.id, pPlot:GetX(), pPlot:GetY()))
                return newUnit
            end
        end
    end

    TrinityLog(string.format("failed to spawn naval reward %s for P%d: no valid water plot within %d of player cities",
        tostring(unitType), playerID, NAVAL_REWARD_WATER_SEARCH_RADIUS))
    return nil
end

local function InitUnitAt(playerID, unitType, x, y, exhaustMoves)
    if unitType == nil or GameInfo.Units[unitType] == nil then
        return nil
    end
    if IsNavalUnitType(unitType) then
        return InitNavalUnitNearPlayerCity(playerID, unitType, x, y, exhaustMoves)
    end
    local newUnit = TryInitUnitAtPlot(playerID, unitType, Map.GetPlot(x, y), exhaustMoves)
    if newUnit ~= nil then
        return newUnit
    end
    local pPlayer = Players[playerID]
    local pCapital = pPlayer and pPlayer:GetCities():GetCapitalCity() or nil
    newUnit = TryInitUnitAtPlot(playerID, unitType, pCapital and Map.GetPlot(pCapital:GetX(), pCapital:GetY()) or nil, exhaustMoves)
    if newUnit == nil then
        TrinityLog(string.format("failed to spawn reward %s for P%d at (%s,%s) or capital",
            tostring(unitType), playerID, tostring(x), tostring(y)))
    end
    return newUnit
end

local function GetNewestCityForPlayer(pPlayer)
    if pPlayer == nil or pPlayer:GetCities() == nil then
        return nil
    end
    local newest = nil
    local newestTurn = -1
    local newestID = -1
    for _, city in pPlayer:GetCities():Members() do
        local founded = 0
        if city ~= nil and city.GetProperty ~= nil then
            founded = tonumber(city:GetProperty("PROP_NW_HAIKESI_CITY_FOUNDED_TURN")) or 0
        end
        local cityID = city and city:GetID() or -1
        if newest == nil or founded > newestTurn or (founded == newestTurn and cityID > newestID) then
            newest = city
            newestTurn = founded
            newestID = cityID
        end
    end
    return newest
end

local function GetEraType(offset)
    offset = tonumber(offset) or 0
    local eraIndex = 0
    if Game ~= nil and Game.GetEras ~= nil and Game.GetEras() ~= nil then
        eraIndex = tonumber(Game.GetEras():GetCurrentEra()) or 0
    end
    local row = GameInfo.Eras[eraIndex + offset] or GameInfo.Eras[eraIndex]
    return row and row.EraType or "ERA_ANCIENT"
end

local function GetEraTypeOrNil(offset)
    offset = tonumber(offset) or 0
    local eraIndex = 0
    if Game ~= nil and Game.GetEras ~= nil and Game.GetEras() ~= nil then
        eraIndex = tonumber(Game.GetEras():GetCurrentEra()) or 0
    end
    local row = GameInfo.Eras[eraIndex + offset]
    return row and row.EraType or nil
end

local function BuildUnitPoolForEra(playerID, eraType)
    local pool = {}
    for row in GameInfo.Units() do
        local prereqTech = row.PrereqTech
        local tech = prereqTech and GameInfo.Technologies[prereqTech] or nil
        local combat = (tonumber(row.Combat) or 0) + (tonumber(row.RangedCombat) or 0) + (tonumber(row.Bombard) or 0)
        if tech ~= nil
            and tech.EraType == eraType
            and combat > 0
            and row.Domain ~= "DOMAIN_AIR"
            and row.FormationClass ~= "FORMATION_CLASS_CIVILIAN"
            and (row.TraitType == nil or row.TraitType == "")
            and (row.MustPurchase == nil or row.MustPurchase == false or row.MustPurchase == 0) then
            table.insert(pool, row.UnitType)
        end
    end
    return pool
end

local function PickRandomTechUnit(playerID, eraOffsets)
    local pool = {}
    local seen = {}
    for _, eraOffset in ipairs(eraOffsets or { 0 }) do
        local eraType = GetEraTypeOrNil(eraOffset)
        if eraType ~= nil then
            for _, unitType in ipairs(BuildUnitPoolForEra(playerID, eraType)) do
                if not seen[unitType] then
                    seen[unitType] = true
                    table.insert(pool, unitType)
                end
            end
        end
    end
    if #pool == 0 then
        return "UNIT_WARRIOR"
    end
    return pool[RandomIndex(#pool, "Haikesi Trinity random tech unit") + 1]
end

local function PickRandomNextEraTechUnit(playerID)
    if GetEraTypeOrNil(1) ~= nil then
        return PickRandomTechUnit(playerID, { 1 })
    end
    return PickRandomTechUnit(playerID, { 0 })
end

local function GetIncomeBundle(pPlayer, divisor)
    divisor = tonumber(divisor) or 10
    local techs = pPlayer and pPlayer:GetTechs() or nil
    local culture = pPlayer and pPlayer:GetCulture() or nil
    local treasury = pPlayer and pPlayer:GetTreasury() or nil
    local religion = pPlayer and pPlayer:GetReligion() or nil
    local scienceRate, cultureRate, goldRate, faithRate = 0, 0, 0, 0
    -- Sejong uses current yield rate as the base; mirror that per-turn rate here.
    if techs ~= nil then pcall(function() scienceRate = techs:GetScienceYield() end) end
    if culture ~= nil then pcall(function() cultureRate = culture:GetCultureYield() end) end
    if treasury ~= nil then
        pcall(function() goldRate = treasury:GetGoldYield() - treasury:GetTotalMaintenance() end)
    end
    if religion ~= nil then pcall(function() faithRate = religion:GetFaithYield() end) end
    return {
        science = math.max(0, math.floor((tonumber(scienceRate) or 0) / divisor)),
        culture = math.max(0, math.floor((tonumber(cultureRate) or 0) / divisor)),
        gold = math.max(0, math.floor((tonumber(goldRate) or 0) / divisor)),
        faith = math.max(0, math.floor((tonumber(faithRate) or 0) / divisor)),
    }
end

local function ApplyIncomeBundle(pPlayer, bundle)
    if pPlayer == nil or bundle == nil then return end
    local rewards = {
        { yieldType = "YIELD_SCIENCE", amount = bundle.science },
        { yieldType = "YIELD_CULTURE", amount = bundle.culture },
        { yieldType = "YIELD_GOLD", amount = bundle.gold },
        { yieldType = "YIELD_FAITH", amount = bundle.faith },
    }
    for _, reward in ipairs(rewards) do
        local amount = tonumber(reward.amount) or 0
        local yieldInfo = GameInfo.Yields[reward.yieldType]
        if yieldInfo ~= nil and amount > 0 then
            TrinityLog(string.format("slot income grant begin yield=%s amount=%d", reward.yieldType, amount))
            local ok, err = pcall(function()
                -- Firaxis scripted unit commands use Player:GrantYield here.  It safely
                -- handles science/culture completion while an EXECUTE_SCRIPT is active.
                pPlayer:GrantYield(yieldInfo.Index, amount)
            end)
            TrinityLog(string.format("slot income grant end yield=%s ok=%s err=%s",
                reward.yieldType, tostring(ok), ok and "" or tostring(err)))
        end
    end
end

local function CountSymbols(results)
    local counts = { JUAN = 0, XIANG = 0, LEAF = 0 }
    for _, sym in ipairs(results) do
        counts[sym] = (counts[sym] or 0) + 1
    end
    return counts
end

local function RollSlotResults()
    local results = {}
    for i = 1, 3 do
        results[i] = SLOT_SYMBOLS[RandomIndex(#SLOT_SYMBOLS, "Haikesi Trinity slot roll") + 1]
    end
    return results
end

local function BuildSlotRewardPlan(playerID, results)
    local pPlayer = Players[playerID]
    local plan = {
        key = "NONE",
        unitType = "",
        science = 0,
        culture = 0,
        gold = 0,
        faith = 0,
        floater = "",
    }
    if pPlayer == nil then return plan end
    local counts = CountSymbols(results)
    if counts.JUAN >= 3 then
        plan.key = "JUAN3"
        plan.unitType = PickRandomNextEraTechUnit(playerID)
        plan.floater = Locale.Lookup("LOC_HAIKESI_SLOT_MACHINE_RESULT_JUAN3")
    elseif counts.JUAN >= 2 then
        plan.key = "JUAN2"
        plan.unitType = PickRandomTechUnit(playerID, { 0, -1 })
        plan.floater = Locale.Lookup("LOC_HAIKESI_SLOT_MACHINE_RESULT_JUAN2")
    elseif counts.LEAF >= 3 then
        local bundle = GetIncomeBundle(pPlayer, 1)
        plan.key = "LEAF3"
        plan.science = bundle.science * 2
        plan.culture = bundle.culture * 2
        plan.gold = bundle.gold * 2
        plan.faith = bundle.faith * 2
        plan.floater = string.format(
            "+%d [ICON_Science] +%d [ICON_Culture] +%d [ICON_Gold] +%d [ICON_Faith]",
            plan.science, plan.culture, plan.gold, plan.faith)
    elseif counts.LEAF >= 2 then
        local bundle = GetIncomeBundle(pPlayer, 5)
        plan.key = "LEAF2"
        plan.science = bundle.science
        plan.culture = bundle.culture
        plan.gold = bundle.gold
        plan.faith = bundle.faith
        plan.floater = string.format(
            "+%d [ICON_Science] +%d [ICON_Culture] +%d [ICON_Gold] +%d [ICON_Faith]",
            plan.science, plan.culture, plan.gold, plan.faith)
    elseif counts.XIANG >= 3 then
        plan.key = "XIANG3"
        plan.floater = Locale.Lookup("LOC_HAIKESI_SLOT_MACHINE_RESULT_XIANG3")
    elseif counts.XIANG >= 2 then
        plan.key = "XIANG2"
        plan.floater = Locale.Lookup("LOC_HAIKESI_SLOT_MACHINE_RESULT_XIANG2")
    end
    return plan
end

local function PublishPendingSlot(pPlayer, playerID, x, y, resultCsv, plan)
    local pending = tonumber(pPlayer:GetProperty(SLOT_PENDING_SEQUENCE_PROP) or 0) or 0
    local settled = tonumber(pPlayer:GetProperty(SLOT_SETTLED_SEQUENCE_PROP) or 0) or 0
    local sequence = math.max(pending, settled) + 1

    -- Publish payload first and sequence last so UI never observes a partial
    -- transaction on the frame where the result becomes visible.
    pPlayer:SetProperty(SLOT_RESULTS_PROP, resultCsv)
    pPlayer:SetProperty(SLOT_REWARD_KEY_PROP, plan.key)
    pPlayer:SetProperty(SLOT_X_PROP, x)
    pPlayer:SetProperty(SLOT_Y_PROP, y)
    pPlayer:SetProperty(SLOT_UNIT_TYPE_PROP, plan.unitType)
    pPlayer:SetProperty(SLOT_SCIENCE_PROP, plan.science)
    pPlayer:SetProperty(SLOT_CULTURE_PROP, plan.culture)
    pPlayer:SetProperty(SLOT_GOLD_PROP, plan.gold)
    pPlayer:SetProperty(SLOT_FAITH_PROP, plan.faith)
    pPlayer:SetProperty(SLOT_FLOATER_PROP, plan.floater)
    pPlayer:SetProperty(SLOT_PENDING_SEQUENCE_PROP, sequence)
    TrinityLog(string.format(
        "slot pending published P%d seq=%d results=%s reward=%s unit=%s yields=%d/%d/%d/%d",
        playerID, sequence, tostring(resultCsv), tostring(plan.key), tostring(plan.unitType),
        plan.science, plan.culture, plan.gold, plan.faith))
    return sequence
end

local function ApplyPublishedSlotReward(playerID, pPlayer, rewardKey, x, y)
    if rewardKey == "JUAN3" or rewardKey == "JUAN2" then
        local unitType = tostring(pPlayer:GetProperty(SLOT_UNIT_TYPE_PROP) or "")
        local unit = InitUnitAt(playerID, unitType, x, y)
        TrinityLog(string.format("slot settle %s picked=%s spawned=%s",
            rewardKey, tostring(unitType), tostring(unit ~= nil)))
    elseif rewardKey == "LEAF3" or rewardKey == "LEAF2" then
        ApplyIncomeBundle(pPlayer, {
            science = tonumber(pPlayer:GetProperty(SLOT_SCIENCE_PROP) or 0) or 0,
            culture = tonumber(pPlayer:GetProperty(SLOT_CULTURE_PROP) or 0) or 0,
            gold = tonumber(pPlayer:GetProperty(SLOT_GOLD_PROP) or 0) or 0,
            faith = tonumber(pPlayer:GetProperty(SLOT_FAITH_PROP) or 0) or 0,
        })
    elseif rewardKey == "XIANG3" then
        local fn = ExposedMembers and ExposedMembers.Haikesi_SpawnBarbarianInvasionAtNewestCity
        if type(fn) == "function" then
            local ok, err = pcall(fn, playerID, playerID)
            TrinityLog("slot settle XIANG3 ok=" .. tostring(ok) .. " err=" .. tostring(ok and "" or err))
        else
            TrinityLog("slot settle XIANG3 unavailable")
        end
    elseif rewardKey == "XIANG2" then
        local fn = ExposedMembers and ExposedMembers.Haikesi_SpawnBarbarianEraMeleeNearNewestCity
        if type(fn) == "function" then
            local ok, err = pcall(fn, playerID, 2, 4)
            TrinityLog("slot settle XIANG2 ok=" .. tostring(ok) .. " err=" .. tostring(ok and "" or err))
        else
            TrinityLog("slot settle XIANG2 unavailable")
        end
    end
end

function HaikesiTrinitySettle(playerID, param)
    local pPlayer = Players[playerID]
    local requested = param and tonumber(param.TrinitySlotSequence) or nil
    if pPlayer == nil or requested == nil then
        TrinityLog("slot settle rejected: invalid player/sequence")
        return false
    end

    local pending = tonumber(pPlayer:GetProperty(SLOT_PENDING_SEQUENCE_PROP) or 0) or 0
    local settled = tonumber(pPlayer:GetProperty(SLOT_SETTLED_SEQUENCE_PROP) or 0) or 0
    if requested <= settled then
        TrinityLog(string.format("slot settle duplicate ignored P%d requested=%d settled=%d",
            playerID, requested, settled))
        return true
    end
    if requested ~= pending then
        TrinityLog(string.format("slot settle rejected P%d requested=%d pending=%d settled=%d",
            playerID, requested, pending, settled))
        return false
    end

    local rewardKey = tostring(pPlayer:GetProperty(SLOT_REWARD_KEY_PROP) or "NONE")
    local x = tonumber(pPlayer:GetProperty(SLOT_X_PROP) or -1) or -1
    local y = tonumber(pPlayer:GetProperty(SLOT_Y_PROP) or -1) or -1
    TrinityLog(string.format("slot settle begin P%d seq=%d reward=%s", playerID, requested, rewardKey))
    ApplyPublishedSlotReward(playerID, pPlayer, rewardKey, x, y)
    pPlayer:SetProperty(SLOT_SETTLED_SEQUENCE_PROP, requested)
    TrinityLog(string.format("slot settle complete P%d seq=%d reward=%s", playerID, requested, rewardKey))
    return true
end

function HaikesiTrinityRetire(playerID, param)
    if param == nil then
        TrinityLog("invalid retire param")
        return
    end
    local pPlayer = Players[playerID]
    local units = pPlayer and pPlayer:GetUnits() or nil
    local unitID = tonumber(param.UnitID)
    if units == nil or unitID == nil then
        TrinityLog("invalid retire player/unit")
        return
    end
    local unit = units:FindID(unitID)
    if unit == nil then
        TrinityLog("retire unit not found: " .. tostring(unitID))
        return
    end
    local fromType = tostring(param.FromUnitType or "")
    local toType = tostring(param.ToUnitType or "")
    local actualType = GetUnitTypeName(unit)
    if actualType ~= fromType then
        TrinityLog("retire type mismatch actual=" .. tostring(actualType) .. " param=" .. tostring(fromType))
        return
    end
    local expectedTo = nil
    if fromType == UNIT_JUAN then expectedTo = UNIT_XIANG end
    if fromType == UNIT_XIANG then expectedTo = UNIT_LAOYE end
    if fromType == UNIT_LAOYE then expectedTo = UNIT_JUAN end
    if expectedTo == nil or toType ~= expectedTo then
        TrinityLog("retire route rejected " .. tostring(fromType) .. " -> " .. tostring(toType))
        return
    end
    if fromType == UNIT_LAOYE then
        local pending = tonumber(pPlayer:GetProperty(SLOT_PENDING_SEQUENCE_PROP) or 0) or 0
        local settled = tonumber(pPlayer:GetProperty(SLOT_SETTLED_SEQUENCE_PROP) or 0) or 0
        if pending > settled then
            TrinityLog(string.format("retire rejected: unresolved slot P%d pending=%d settled=%d",
                playerID, pending, settled))
            return
        end
    end
    if unit:GetMovesRemaining() <= 0 then
        TrinityLog("retire rejected: no moves")
        return
    end

    local x, y = unit:GetX(), unit:GetY()
    UnitManager.Kill(unit, false)
    local newUnit = InitUnitAt(playerID, toType, x, y, true)
    TrinityLog(string.format("retired P%d %s -> %s at (%d,%d) new=%s",
        playerID, fromType, toType, x, y, tostring(newUnit ~= nil)))

    if fromType == UNIT_LAOYE then
        local results = RollSlotResults()
        local resultCsv = table.concat(results, ",")
        TrinityLog("slot rolled P" .. tostring(playerID) .. " results=" .. resultCsv)
        local plan = BuildSlotRewardPlan(playerID, results)
        PublishPendingSlot(pPlayer, playerID, x, y, resultCsv, plan)
    end
end

local function Initialize()
    if ExposedMembers ~= nil then
        ExposedMembers.HaikesiTrinityRetire = HaikesiTrinityRetire
        ExposedMembers.HaikesiTrinitySettle = HaikesiTrinitySettle
    end
    TrinityLog("GamePlay ready")
end

Events.LoadScreenClose.Add(Initialize)
