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

local function NotifyFloater(playerID, x, y, text)
    if text == nil or text == "" then return end
    local fn = ExposedMembers and ExposedMembers.Haikesi_TrinityShowFloater
    if type(fn) == "function" then
        pcall(fn, playerID, x, y, text)
        return
    end
    if LuaEvents ~= nil and LuaEvents.Haikesi_TrinityShowFloater ~= nil then
        LuaEvents.Haikesi_TrinityShowFloater(playerID, x, y, text)
        return
    end
    if Game ~= nil and Game.AddWorldViewText ~= nil then
        pcall(function()
            Game.AddWorldViewText({
                MessageType = 0,
                MessageText = text,
                PlotX = x,
                PlotY = y,
                Visibility = RevealedState and RevealedState.VISIBLE or 1,
            })
        end)
    end
end

local function OpenSlotMachineUI(playerID, x, y, resultCsv, rewardKey, floaterText)
    local fn = ExposedMembers and ExposedMembers.Haikesi_OpenTrinitySlotMachine
    if type(fn) == "function" then
        local ok, opened = pcall(fn, playerID, x, y, resultCsv, rewardKey or "NONE", floaterText or "")
        if not ok then
            TrinityLog("slot UI open failed via ExposedMembers: " .. tostring(opened))
        else
            TrinityLog("slot UI open via ExposedMembers opened=" .. tostring(opened))
        end
        return ok and opened == true
    end
    if LuaEvents ~= nil and LuaEvents.Haikesi_OpenTrinitySlotMachine ~= nil then
        local ok, err = pcall(function()
            LuaEvents.Haikesi_OpenTrinitySlotMachine(playerID, x, y, resultCsv, rewardKey or "NONE", floaterText or "")
        end)
        if not ok then
            TrinityLog("slot UI open failed via LuaEvents: " .. tostring(err))
            return false
        end
        TrinityLog("slot UI open via LuaEvents")
        return true
    end
    TrinityLog("slot UI open unavailable")
    return false
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

local function ApplySlotReward(playerID, x, y, results)
    local pPlayer = Players[playerID]
    if pPlayer == nil then return "NONE", nil end
    local counts = CountSymbols(results)
    if counts.JUAN >= 3 then
        local unitType = PickRandomNextEraTechUnit(playerID)
        local unit = InitUnitAt(playerID, unitType, x, y)
        TrinityLog(string.format("slot reward JUAN3 picked %s spawned=%s", tostring(unitType), tostring(unit ~= nil)))
        return "JUAN3", Locale.Lookup("LOC_HAIKESI_SLOT_MACHINE_RESULT_JUAN3")
    elseif counts.JUAN >= 2 then
        local unitType = PickRandomTechUnit(playerID, { 0, -1 })
        local unit = InitUnitAt(playerID, unitType, x, y)
        TrinityLog(string.format("slot reward JUAN2 picked %s spawned=%s", tostring(unitType), tostring(unit ~= nil)))
        return "JUAN2", Locale.Lookup("LOC_HAIKESI_SLOT_MACHINE_RESULT_JUAN2")
    elseif counts.LEAF >= 3 then
        local bundle = GetIncomeBundle(pPlayer, 1)
        bundle.science = bundle.science * 2
        bundle.culture = bundle.culture * 2
        bundle.gold = bundle.gold * 2
        bundle.faith = bundle.faith * 2
        ApplyIncomeBundle(pPlayer, bundle)
        return "LEAF3", string.format(
            "+%d [ICON_Science] +%d [ICON_Culture] +%d [ICON_Gold] +%d [ICON_Faith]",
            bundle.science, bundle.culture, bundle.gold, bundle.faith)
    elseif counts.LEAF >= 2 then
        local bundle = GetIncomeBundle(pPlayer, 5)
        ApplyIncomeBundle(pPlayer, bundle)
        return "LEAF2", string.format(
            "+%d [ICON_Science] +%d [ICON_Culture] +%d [ICON_Gold] +%d [ICON_Faith]",
            bundle.science, bundle.culture, bundle.gold, bundle.faith)
    elseif counts.XIANG >= 3 then
        local fn = ExposedMembers and ExposedMembers.Haikesi_SpawnBarbarianInvasionAtNewestCity
        if type(fn) == "function" then
            pcall(fn, playerID, playerID)
        end
        return "XIANG3", Locale.Lookup("LOC_HAIKESI_SLOT_MACHINE_RESULT_XIANG3")
    elseif counts.XIANG >= 2 then
        local fn = ExposedMembers and ExposedMembers.Haikesi_SpawnBarbarianEraMeleeNearNewestCity
        if type(fn) == "function" then
            pcall(fn, playerID, 2, 4)
        end
        return "XIANG2", Locale.Lookup("LOC_HAIKESI_SLOT_MACHINE_RESULT_XIANG2")
    end
    return "NONE", nil
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
        local rewardKey, floaterText = ApplySlotReward(playerID, x, y, results)
        TrinityLog("slot reward resolved key=" .. tostring(rewardKey) .. " floater=" .. tostring(floaterText))
        if not OpenSlotMachineUI(playerID, x, y, resultCsv, rewardKey, floaterText) then
            TrinityLog("slot UI fallback floater")
            NotifyFloater(playerID, x, y, floaterText)
        end
    end
end

local function Initialize()
    if ExposedMembers ~= nil then
        ExposedMembers.HaikesiTrinityRetire = HaikesiTrinityRetire
    end
    TrinityLog("GamePlay ready")
end

Events.LoadScreenClose.Add(Initialize)
