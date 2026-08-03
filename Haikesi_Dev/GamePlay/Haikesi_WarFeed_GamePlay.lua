-- Haikesi_WarFeed_GamePlay.lua
-- 弑杀蜂群 (WARFEEDRUNE): 击杀敌军 → 按距离向未满己方城市分配「生物质」限时 +粮
-- 每回合 + 战力×5% 食物，持续 10 回合（合计 ≈ 战力×50%）。
-- 实现（参考烧城增益）：每城用一个总量档位隐藏建筑表示当前 +粮；
-- Property "amount:expire|..." 保存独立计时批次，单城满 +40 后继续查询下一城。

local WARFEED_RELIC = 'WARFEEDRUNE'
local BIOMASS_FPT_PERCENT = 5
local BIOMASS_DURATION_TURNS = 10
local BIOMASS_MAX_FOOD = 40
local BIOMASS_BUILDING_PREFIX = 'BUILDING_NW_WARFEED_BIOMASS_P'
-- V2 Property: "amount:expire|amount:expire|..."; kill batches expire independently.
local BIOMASS_CITY_PROP = 'PROP_NW_WARFEED_BIOMASS_V2'
local BIOMASS_LEGACY_CITY_PROP = 'PROP_NW_WARFEED_BIOMASS'

local RelicsPropertyKey = 'PROP_NW_HAIKESI_RELICS'
local RelicsCountPropertyKey = 'PROP_NW_HAIKESI_RELICS_COUNT'
local RelicsSlotPropertyPrefix = 'PROP_NW_HAIKESI_RELIC_SLOT_'

local g_UnitCombatCache = {}
local g_FedKeys = {}
local g_BiomassBuildingIndex = {} -- total food level -> Buildings.Index

local WARFEED_MORSEL_UNIT = 'UNIT_NW_WARFEED_MORSEL'
local WARFEED_MORSEL_PROP = 'PROP_NW_WARFEED_MORSEL'
local g_MorselUnitIndex = nil

local function WF_CacheKey(killedPlayerID, killedUnitID)
    return tostring(killedPlayerID) .. ':' .. tostring(killedUnitID) .. ':' .. tostring(Game.GetCurrentGameTurn())
end

local function WF_GetRelicTypeFromIndex(index)
    for row in GameInfo.Haikesi_Relics() do
        if row.Index == index then
            return row.RelicType
        end
    end
    return nil
end

local function WF_PlayerHasRelic(pPlayer)
    if pPlayer == nil then return false end
    local count = tonumber(pPlayer:GetProperty(RelicsCountPropertyKey) or 0) or 0
    if count > 0 then
        for i = 1, count do
            if pPlayer:GetProperty(RelicsSlotPropertyPrefix .. i) == WARFEED_RELIC then
                return true
            end
        end
    end
    local legacy = pPlayer:GetProperty(RelicsPropertyKey) or ""
    if legacy ~= "" then
        for idxStr in string.gmatch(legacy, "[^|]+") do
            local idx = tonumber(idxStr)
            if idx ~= nil and WF_GetRelicTypeFromIndex(idx) == WARFEED_RELIC then
                return true
            end
        end
    end
    return false
end

local function WF_UnitTypeCombatStrength(unitType)
    local info = GameInfo.Units[unitType]
    if info == nil then return 0 end
    local cs = info.Combat or 0
    if cs <= 0 then cs = info.RangedCombat or 0 end
    if cs <= 0 then cs = info.Bombard or 0 end
    return cs
end

local function WF_RememberUnit(playerID, unitID)
    if playerID == nil or unitID == nil then return end
    local pUnit = UnitManager.GetUnit(playerID, unitID)
    if pUnit == nil then
        pUnit = Players[playerID] and Players[playerID]:GetUnits():FindID(unitID)
    end
    if pUnit == nil then return end
    local typeIndex = pUnit:GetType()
    local x, y = pUnit:GetX(), pUnit:GetY()
    if x == nil or x < 0 then return end
    if g_UnitCombatCache[playerID] == nil then
        g_UnitCombatCache[playerID] = {}
    end
    g_UnitCombatCache[playerID][unitID] = {
        typeIndex = typeIndex,
        x = x,
        y = y,
        combat = WF_UnitTypeCombatStrength(typeIndex),
    }
end

local function WF_TakeCachedUnit(playerID, unitID)
    local byPlayer = g_UnitCombatCache[playerID]
    if byPlayer == nil then return nil end
    local entry = byPlayer[unitID]
    byPlayer[unitID] = nil
    return entry
end

local function WF_GetCitiesByDistance(pPlayer, iX, iY)
    local cities = {}
    for _, city in pPlayer:GetCities():Members() do
        if city ~= nil then
            local dist = Map.GetPlotDistance(iX, iY, city:GetX(), city:GetY())
            cities[#cities + 1] = {
                city = city,
                distance = tonumber(dist) or 999999,
                cityID = tonumber(city:GetID()) or 999999,
            }
        end
    end
    table.sort(cities, function(a, b)
        if a.distance ~= b.distance then
            return a.distance < b.distance
        end
        return a.cityID < b.cityID
    end)
    return cities
end

local function WF_GetMorselUnitIndex()
    if g_MorselUnitIndex ~= nil then return g_MorselUnitIndex end
    local row = GameInfo.Units[WARFEED_MORSEL_UNIT]
    if row == nil then return nil end
    g_MorselUnitIndex = row.Index
    return g_MorselUnitIndex
end

local function WF_IsLegacyMorsel(u, morselIdx)
    if u == nil then return false end
    local marked = u:GetProperty(WARFEED_MORSEL_PROP)
    if marked == true or marked == 1 then return true end
    return morselIdx ~= nil and u:GetType() == morselIdx
end

local function WF_PurgeLegacyMorsels(playerID)
    local pPlayer = Players[playerID]
    if pPlayer == nil then return end
    local units = pPlayer:GetUnits()
    if units == nil then return end
    local morselIdx = WF_GetMorselUnitIndex()
    local toKill = {}
    for _, u in units:Members() do
        if WF_IsLegacyMorsel(u, morselIdx) then
            toKill[#toKill + 1] = u
        end
    end
    for i = 1, #toKill do
        pcall(function() UnitManager.Kill(toKill[i], false) end)
    end
    if #toKill > 0 then
        print(string.format(
            '[Haikesi WarFeed] purged %d legacy biomass units for P%d',
            #toKill, playerID))
    end
end

local function WF_CacheBiomassBuildingIndices()
    if next(g_BiomassBuildingIndex) ~= nil then return true end
    local ok = true
    for level = 1, BIOMASS_MAX_FOOD do
        local typeName = BIOMASS_BUILDING_PREFIX .. tostring(level)
        local row = GameInfo.Buildings[typeName]
        if row == nil then
            print('[Haikesi WarFeed] missing building ' .. typeName)
            ok = false
        else
            g_BiomassBuildingIndex[level] = row.Index
        end
    end
    return ok
end

local function WF_ParseBiomassEntries(raw)
    local list = {}
    if raw == nil or raw == '' then return list end
    for piece in string.gmatch(tostring(raw), '[^|]+') do
        local amountStr, expStr = string.match(piece, '^(%d+):(%-?%d+)$')
        local amount = tonumber(amountStr)
        local exp = tonumber(expStr)
        if amount ~= nil and amount > 0 and amount <= BIOMASS_MAX_FOOD and exp ~= nil then
            list[#list + 1] = { amount = amount, expire = exp }
        end
    end
    return list
end

local function WF_SerializeBiomassEntries(list)
    if list == nil or #list == 0 then return '' end
    local parts = {}
    for i = 1, #list do
        parts[#parts + 1] = tostring(list[i].amount) .. ':' .. tostring(list[i].expire)
    end
    return table.concat(parts, '|')
end

local function WF_TotalBiomass(list)
    local total = 0
    for i = 1, #list do
        total = total + (tonumber(list[i].amount) or 0)
    end
    return math.min(BIOMASS_MAX_FOOD, math.max(0, total))
end

local function WF_AddBiomassBuilding(pCity, level)
    if pCity == nil then return false end
    local buildingIndex = g_BiomassBuildingIndex[level]
    if buildingIndex == nil then return false end
    local bld = pCity:GetBuildings()
    if bld == nil then return false end
    if bld:HasBuilding(buildingIndex) then
        return true
    end
    local plot = Map.GetPlot(pCity:GetX(), pCity:GetY())
    if plot == nil then return false end
    local plotIndex = plot:GetIndex()
    local queue = pCity:GetBuildQueue()
    if queue == nil or queue.CreateIncompleteBuilding == nil then
        print('[Haikesi WarFeed] ERROR: CreateIncompleteBuilding missing')
        return false
    end
    local ok = pcall(function()
        queue:CreateIncompleteBuilding(buildingIndex, plotIndex, 100)
    end)
    return ok and bld:HasBuilding(buildingIndex)
end

local function WF_RemoveBiomassBuilding(pCity, level)
    if pCity == nil then return false end
    local buildingIndex = g_BiomassBuildingIndex[level]
    if buildingIndex == nil then return false end
    local bld = pCity:GetBuildings()
    if bld == nil then return false end
    if not bld:HasBuilding(buildingIndex) then
        return true
    end
    local ok = pcall(function()
        bld:RemoveBuilding(buildingIndex)
    end)
    return ok and not bld:HasBuilding(buildingIndex)
end

local function WF_RemoveAllBiomassBuildings(pCity)
    if pCity == nil then return 0 end
    local bld = pCity:GetBuildings()
    if bld == nil then return 0 end
    local removed = 0
    for level = 1, BIOMASS_MAX_FOOD do
        local idx = g_BiomassBuildingIndex[level]
        if idx ~= nil and bld:HasBuilding(idx) then
            if WF_RemoveBiomassBuilding(pCity, level) then
                removed = removed + 1
            end
        end
    end
    return removed
end

local function WF_SetBiomassLevelBuilding(pCity, level)
    if pCity == nil or not WF_CacheBiomassBuildingIndices() then return false end
    level = math.min(BIOMASS_MAX_FOOD, math.max(0, math.floor(tonumber(level) or 0)))
    local bld = pCity:GetBuildings()
    if bld == nil then return false end

    -- Add the aggregate building before deleting old levels. If creation fails,
    -- the city keeps its previous valid yield instead of losing the bonus.
    if level > 0 and not WF_AddBiomassBuilding(pCity, level) then
        -- Recovery for legacy/over-limit cities: free every biomass slot and
        -- retry once. Only biomass buildings are touched.
        WF_RemoveAllBiomassBuildings(pCity)
        if not WF_AddBiomassBuilding(pCity, level) then
            return false
        end
    end
    local clean = true
    for oldLevel = 1, BIOMASS_MAX_FOOD do
        if oldLevel ~= level then
            local idx = g_BiomassBuildingIndex[oldLevel]
            if idx ~= nil and bld:HasBuilding(idx) then
                if not WF_RemoveBiomassBuilding(pCity, oldLevel) then
                    clean = false
                end
            end
        end
    end
    return clean and (level == 0 or bld:HasBuilding(g_BiomassBuildingIndex[level]))
end

local function WF_MigrateLegacyCityBiomass(pCity)
    local raw = pCity:GetProperty(BIOMASS_LEGACY_CITY_PROP)
    local list = {}
    if raw ~= nil and raw ~= '' then
        local now = Game.GetCurrentGameTurn()
        local byExpire = {}
        for piece in string.gmatch(tostring(raw), '[^|]+') do
            local pinStr, expStr = string.match(piece, '^(%d+):(%-?%d+)$')
            local pin = tonumber(pinStr)
            local expire = tonumber(expStr)
            if pin ~= nil and pin >= 1 and pin <= BIOMASS_MAX_FOOD
                and expire ~= nil and now < expire then
                byExpire[expire] = (byExpire[expire] or 0) + 1
            end
        end
        for expire, amount in pairs(byExpire) do
            list[#list + 1] = { amount = amount, expire = expire }
        end
        table.sort(list, function(a, b) return a.expire < b.expire end)
        print(string.format(
            '[Haikesi WarFeed] migrated legacy biomass on %s: entries=%d total=%d',
            Locale.Lookup(pCity:GetName()), #list, WF_TotalBiomass(list)))
    end
    pCity:SetProperty(BIOMASS_LEGACY_CITY_PROP, nil)
    pCity:SetProperty(BIOMASS_CITY_PROP, WF_SerializeBiomassEntries(list))
    -- Legacy saves may already be at the city-center building limit. Remove
    -- every old +1 slot first so the single aggregate building can be created.
    local removedBuildings = WF_RemoveAllBiomassBuildings(pCity)
    local synced = WF_SetBiomassLevelBuilding(pCity, WF_TotalBiomass(list))
    if not synced then
        print('[Haikesi WarFeed] ERROR: failed to create aggregate biomass building after migration')
    elseif removedBuildings > 1 then
        print(string.format(
            '[Haikesi WarFeed] collapsed %d legacy biomass buildings into one on %s',
            removedBuildings, Locale.Lookup(pCity:GetName())))
    end
    return list
end

local function WF_LoadCityBiomass(pCity)
    local raw = pCity:GetProperty(BIOMASS_CITY_PROP)
    if raw ~= nil and raw ~= '' then
        if pCity:GetProperty(BIOMASS_LEGACY_CITY_PROP) ~= nil then
            pCity:SetProperty(BIOMASS_LEGACY_CITY_PROP, nil)
        end
        return WF_ParseBiomassEntries(raw)
    end
    if pCity:GetProperty(BIOMASS_LEGACY_CITY_PROP) ~= nil then
        return WF_MigrateLegacyCityBiomass(pCity)
    end
    return {}
end

local function WF_ExpireCityBiomass(pCity)
    if pCity == nil then return end
    local now = Game.GetCurrentGameTurn()
    local list = WF_LoadCityBiomass(pCity)

    local keep = {}
    local expiredFood = 0
    for i = 1, #list do
        local e = list[i]
        if now >= e.expire then
            expiredFood = expiredFood + e.amount
        else
            keep[#keep + 1] = e
        end
    end
    local total = WF_TotalBiomass(keep)
    pCity:SetProperty(BIOMASS_CITY_PROP, WF_SerializeBiomassEntries(keep))
    WF_SetBiomassLevelBuilding(pCity, total)
    if expiredFood > 0 then
        print(string.format(
            '[Haikesi WarFeed] expired %d biomass food on %s (turn=%d, left=%d)',
            expiredFood, Locale.Lookup(pCity:GetName()), now, total))
    end
end

local function WF_ExpirePlayerBiomass(playerID)
    local pPlayer = Players[playerID]
    if pPlayer == nil then return end
    for _, city in pPlayer:GetCities():Members() do
        WF_ExpireCityBiomass(city)
    end
end

-- Add one timed batch, then represent the active total with exactly one Pn building.
local function WF_ApplyBiomassBuff(pCity, foodPerTurn)
    if pCity == nil or foodPerTurn <= 0 then return false, 'nil-city', 0 end
    if not WF_CacheBiomassBuildingIndices() then
        return false, 'no-biomass-buildings', 0
    end

    WF_ExpireCityBiomass(pCity)
    local now = Game.GetCurrentGameTurn()
    local expireTurn = now + BIOMASS_DURATION_TURNS
    local list = WF_ParseBiomassEntries(pCity:GetProperty(BIOMASS_CITY_PROP))
    local currentTotal = WF_TotalBiomass(list)
    local granted = math.min(foodPerTurn, BIOMASS_MAX_FOOD - currentTotal)
    if granted <= 0 then
        return false, 'biomass-cap', 0
    end

    local merged = false
    for i = 1, #list do
        if list[i].expire == expireTurn then
            list[i].amount = list[i].amount + granted
            merged = true
            break
        end
    end
    if not merged then
        list[#list + 1] = { amount = granted, expire = expireTurn }
    end

    local newTotal = currentTotal + granted
    if not WF_SetBiomassLevelBuilding(pCity, newTotal) then
        return false, 'set-level-building-failed', 0
    end
    pCity:SetProperty(BIOMASS_CITY_PROP, WF_SerializeBiomassEntries(list))
    local msg = string.format(
        'Biomass +%d food/t x%d turns (expire T%d, total=%d/%d, entries=%d)',
        granted, BIOMASS_DURATION_TURNS, expireTurn,
        newTotal, BIOMASS_MAX_FOOD, #list)
    if granted < foodPerTurn then
        msg = msg .. string.format(' capped(want %d)', foodPerTurn)
    end
    return true, msg, granted
end

local function WF_NotifyFoodFloater(killerPlayerID, x, y, foodAmount)
    if x == nil or y == nil or foodAmount <= 0 then return end
    local fn = ExposedMembers and ExposedMembers.Haikesi_WarFeedShowFoodFloater
    if type(fn) == 'function' then
        pcall(fn, killerPlayerID, x, y, foodAmount)
        return
    end
    if LuaEvents ~= nil and LuaEvents.Haikesi_WarFeedShowFoodFloater ~= nil then
        LuaEvents.Haikesi_WarFeedShowFoodFloater(killerPlayerID, x, y, foodAmount)
        return
    end
    if Game ~= nil and Game.AddWorldViewText ~= nil then
        local sz = Locale.Lookup('LOC_WORLD_FOOD_INCREASE_FLOATER', foodAmount)
        pcall(function()
            Game.AddWorldViewText({
                MessageType = 0,
                MessageText = sz,
                PlotX = x,
                PlotY = y,
                Visibility = RevealedState and RevealedState.VISIBLE or 1,
            })
        end)
    end
end

local function WF_ApplyKillFood(killerPlayerID, killedPlayerID, killedUnitID, killerUnitID, sourceTag)
    if killerPlayerID == nil or killedPlayerID == nil then return end
    if killerPlayerID == killedPlayerID then return end

    local dedupe = WF_CacheKey(killedPlayerID, killedUnitID)
    if g_FedKeys[dedupe] then return end

    local pKiller = Players[killerPlayerID]
    if pKiller == nil or not pKiller:IsMajor() then return end
    if not WF_PlayerHasRelic(pKiller) then
        print(string.format(
            '[Haikesi WarFeed] %s kill P%d->P%d but killer has no WARFEEDRUNE',
            tostring(sourceTag), killedPlayerID, killerPlayerID))
        return
    end

    local strength, iX, iY = 0, nil, nil

    local pKilledUnit = UnitManager.GetUnit(killedPlayerID, killedUnitID)
    if pKilledUnit == nil and Players[killedPlayerID] ~= nil then
        pKilledUnit = Players[killedPlayerID]:GetUnits():FindID(killedUnitID)
    end
    if pKilledUnit ~= nil then
        strength = WF_UnitTypeCombatStrength(pKilledUnit:GetType())
        iX, iY = pKilledUnit:GetX(), pKilledUnit:GetY()
    else
        local cached = WF_TakeCachedUnit(killedPlayerID, killedUnitID)
        if cached ~= nil then
            strength = cached.combat or 0
            iX, iY = cached.x, cached.y
            print('[Haikesi WarFeed] using unit cache for kill')
        end
    end

    local pKillerUnit = nil
    if killerUnitID ~= nil then
        pKillerUnit = UnitManager.GetUnit(killerPlayerID, killerUnitID)
        if pKillerUnit == nil then
            pKillerUnit = pKiller:GetUnits():FindID(killerUnitID)
        end
    end
    if (iX == nil or iY == nil or iX < 0) and pKillerUnit ~= nil then
        iX, iY = pKillerUnit:GetX(), pKillerUnit:GetY()
    end

    if strength <= 0 then
        print(string.format(
            '[Haikesi WarFeed] %s skip: strength=0 killedP=%s unit=%s',
            tostring(sourceTag), tostring(killedPlayerID), tostring(killedUnitID)))
        return
    end
    if iX == nil or iY == nil or iX < 0 then
        print('[Haikesi WarFeed] skip: no plot for food grant')
        return
    end

    local foodPerTurn = math.floor(strength * BIOMASS_FPT_PERCENT / 100 + 0.5)
    if foodPerTurn <= 0 then
        print(string.format(
            '[Haikesi WarFeed] %s skip: fpt=0 str=%d', tostring(sourceTag), strength))
        return
    end

    local candidateCities = WF_GetCitiesByDistance(pKiller, iX, iY)
    if #candidateCities == 0 then
        print('[Haikesi WarFeed] skip: killer has no cities')
        return
    end

    g_FedKeys[dedupe] = true

    local remainingFood = foodPerTurn
    local grantedFood = 0
    local allocations = {}
    local failures = {}
    for i = 1, #candidateCities do
        if remainingFood <= 0 then break end
        local pCity = candidateCities[i].city
        local cityGranted, how, cityFood = WF_ApplyBiomassBuff(pCity, remainingFood)
        cityFood = tonumber(cityFood) or 0
        if cityFood > 0 then
            remainingFood = remainingFood - cityFood
            grantedFood = grantedFood + cityFood
            allocations[#allocations + 1] = string.format(
                '%s(+%d)', Locale.Lookup(pCity:GetName()), cityFood)
        elseif how ~= 'biomass-cap' then
            failures[#failures + 1] = string.format(
                '%s:%s', Locale.Lookup(pCity:GetName()), tostring(how))
            if how == 'no-biomass-buildings' then break end
        end
        if not cityGranted and cityFood > 0 then
            print(string.format(
                '[Haikesi WarFeed] WARNING: city reported failure after granting biomass: %s via=%s',
                Locale.Lookup(pCity:GetName()), tostring(how)))
        end
    end

    local floaterX, floaterY = iX, iY
    if pKillerUnit ~= nil then
        local kx, ky = pKillerUnit:GetX(), pKillerUnit:GetY()
        if kx ~= nil and kx >= 0 then
            floaterX, floaterY = kx, ky
        end
    end
    WF_NotifyFoodFloater(killerPlayerID, floaterX, floaterY, grantedFood or 0)

    local allocationText = '(all cities capped)'
    if #allocations > 0 then
        allocationText = table.concat(allocations, ', ')
    elseif #failures > 0 then
        allocationText = '(no city accepted biomass)'
    end
    local failureText = (#failures > 0) and (' failures=' .. table.concat(failures, ', ')) or ''
    print(string.format(
        '[Haikesi WarFeed] %s P%d kill biomass +%d/%d food/t x%d (str=%d) cities=%s remaining=%d%s',
        tostring(sourceTag), killerPlayerID, grantedFood or 0, foodPerTurn,
        BIOMASS_DURATION_TURNS, strength,
        allocationText, remainingFood, failureText))
end

function Haikesi_OnWarFeedUnitKilledInCombat(killedPlayerID, killedUnitID, killerPlayerID, killerUnitID)
    WF_ApplyKillFood(killerPlayerID, killedPlayerID, killedUnitID, killerUnitID, 'UnitKilledInCombat')
end

function Haikesi_OnWarFeedCombatOccurred(
    attackerPlayerID, attackerUnitID,
    defenderPlayerID, defenderUnitID,
    attackerDistrictID, defenderDistrictID)

    if attackerPlayerID == nil or defenderPlayerID == nil then return end
    if attackerPlayerID == defenderPlayerID then return end

    local pAttacker = Players[attackerPlayerID]
    local pDefender = Players[defenderPlayerID]
    if pAttacker == nil or pDefender == nil then return end

    local pAtk = (attackerUnitID ~= nil) and UnitManager.GetUnit(attackerPlayerID, attackerUnitID) or nil
    local pDef = (defenderUnitID ~= nil) and UnitManager.GetUnit(defenderPlayerID, defenderUnitID) or nil

    local function dying(u)
        if u == nil then return false end
        if u.IsDead ~= nil and u:IsDead() then return true end
        if u.IsDelayedDeath ~= nil and u:IsDelayedDeath() then return true end
        return false
    end

    if dying(pDef) then
        WF_ApplyKillFood(attackerPlayerID, defenderPlayerID, defenderUnitID, attackerUnitID, 'OnCombatOccurred')
    end
    if dying(pAtk) then
        WF_ApplyKillFood(defenderPlayerID, attackerPlayerID, attackerUnitID, defenderUnitID, 'OnCombatOccurred')
    end
end

local function OnUnitAddedToMap(playerID, unitID)
    local morselIdx = WF_GetMorselUnitIndex()
    local pUnit = UnitManager.GetUnit(playerID, unitID)
    if pUnit ~= nil and WF_IsLegacyMorsel(pUnit, morselIdx) then
        pcall(function() UnitManager.Kill(pUnit, false) end)
        return
    end
    WF_RememberUnit(playerID, unitID)
end

local function OnUnitMoved(playerID, unitID)
    WF_RememberUnit(playerID, unitID)
end

local function OnPlayerTurnActivated(playerID, bFirstTime)
    WF_PurgeLegacyMorsels(playerID)
    WF_ExpirePlayerBiomass(playerID)
end

-- UI 桥读取城市生物质 Property（UI 侧 city:GetProperty 偶发读不到）
function Haikesi_WarFeedGetCityBiomassProp(playerID, cityID)
    playerID = tonumber(playerID)
    cityID = tonumber(cityID)
    if playerID == nil or cityID == nil then
        return ''
    end
    local pPlayer = Players[playerID]
    if pPlayer == nil then
        return ''
    end
    local pCity = pPlayer:GetCities():FindID(cityID)
    if pCity == nil then
        return ''
    end
    return tostring(pCity:GetProperty(BIOMASS_CITY_PROP) or '')
end

local function InitializeWarFeed()
    WF_CacheBiomassBuildingIndices()

    if ExposedMembers ~= nil then
        ExposedMembers.Haikesi_WarFeedGetCityBiomassProp = Haikesi_WarFeedGetCityBiomassProp
    end

    if Events.UnitKilledInCombat ~= nil then
        Events.UnitKilledInCombat.Add(Haikesi_OnWarFeedUnitKilledInCombat)
        print('[Haikesi WarFeed] listening Events.UnitKilledInCombat')
    else
        print('[Haikesi WarFeed] ERROR: Events.UnitKilledInCombat missing')
    end

    if GameEvents ~= nil and GameEvents.OnCombatOccurred ~= nil then
        GameEvents.OnCombatOccurred.Add(Haikesi_OnWarFeedCombatOccurred)
        print('[Haikesi WarFeed] also listening GameEvents.OnCombatOccurred')
    end

    if Events.UnitAddedToMap ~= nil then
        Events.UnitAddedToMap.Add(OnUnitAddedToMap)
    end
    if Events.UnitMoved ~= nil then
        Events.UnitMoved.Add(OnUnitMoved)
    end
    if Events.PlayerTurnActivated ~= nil then
        Events.PlayerTurnActivated.Add(OnPlayerTurnActivated)
    end

    for pid = 0, 63 do
        local p = Players[pid]
        if p ~= nil and p:IsAlive() then
            WF_PurgeLegacyMorsels(pid)
            WF_ExpirePlayerBiomass(pid)
            local units = p:GetUnits()
            if units ~= nil then
                for _, u in units:Members() do
                    if u ~= nil and not WF_IsLegacyMorsel(u, WF_GetMorselUnitIndex()) then
                        WF_RememberUnit(pid, u:GetID())
                    end
                end
            end
        end
    end

    print(string.format(
        '[Haikesi WarFeed] GamePlay bridge ready (aggregate biomass %d%%/t x%d turns, levels=%d, max buildings/city=1)',
        BIOMASS_FPT_PERCENT, BIOMASS_DURATION_TURNS, BIOMASS_MAX_FOOD))
end

Events.LoadScreenClose.Add(InitializeWarFeed)
