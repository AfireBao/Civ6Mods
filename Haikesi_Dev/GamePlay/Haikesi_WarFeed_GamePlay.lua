-- Haikesi_WarFeed_GamePlay.lua
-- 弑杀蜂群 (WARFEEDRUNE): 击杀敌军 → 最近己方城市获得「生物质」限时 +粮
-- 每回合 + 战力×5% 食物，持续 10 回合（合计 ≈ 战力×50%）。
-- 实现（参考烧城增益）：隐藏建筑槽 CreateIncompleteBuilding / RemoveBuilding；
-- 每槽 Building_YieldChanges +1 粮；Property "pin:expire|..."；多击杀独立计时。

local WARFEED_RELIC = 'WARFEEDRUNE'
local BIOMASS_FPT_PERCENT = 5
local BIOMASS_DURATION_TURNS = 10
local BIOMASS_PIN_COUNT = 40
local BIOMASS_BUILDING_PREFIX = 'BUILDING_NW_WARFEED_BIOMASS_P'
-- 城 Property："pin:expire|pin:expire|..."（pin=1..40）
local BIOMASS_CITY_PROP = 'PROP_NW_WARFEED_BIOMASS'

local RelicsPropertyKey = 'PROP_NW_HAIKESI_RELICS'
local RelicsCountPropertyKey = 'PROP_NW_HAIKESI_RELICS_COUNT'
local RelicsSlotPropertyPrefix = 'PROP_NW_HAIKESI_RELIC_SLOT_'

local g_UnitCombatCache = {}
local g_FedKeys = {}
local g_BiomassBuildingIndex = {} -- pin -> Buildings.Index

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

local function WF_FindNearestCity(pPlayer, iX, iY)
    local bestCity, bestDist = nil, 999999
    for _, city in pPlayer:GetCities():Members() do
        if city ~= nil then
            local dist = Map.GetPlotDistance(iX, iY, city:GetX(), city:GetY())
            if dist < bestDist then
                bestDist = dist
                bestCity = city
            end
        end
    end
    return bestCity
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
    for pin = 1, BIOMASS_PIN_COUNT do
        local typeName = BIOMASS_BUILDING_PREFIX .. tostring(pin)
        local row = GameInfo.Buildings[typeName]
        if row == nil then
            print('[Haikesi WarFeed] missing building ' .. typeName)
            ok = false
        else
            g_BiomassBuildingIndex[pin] = row.Index
        end
    end
    return ok
end

local function WF_ParsePinEntries(raw)
    local list = {}
    if raw == nil or raw == '' then return list end
    for piece in string.gmatch(tostring(raw), '[^|]+') do
        local pinStr, expStr = string.match(piece, '^(%d+):(%-?%d+)$')
        local pin = tonumber(pinStr)
        local exp = tonumber(expStr)
        if pin ~= nil and pin >= 1 and pin <= BIOMASS_PIN_COUNT and exp ~= nil then
            list[#list + 1] = { pin = pin, expire = exp }
        end
    end
    return list
end

local function WF_SerializePinEntries(list)
    if list == nil or #list == 0 then return '' end
    local parts = {}
    for i = 1, #list do
        parts[#parts + 1] = tostring(list[i].pin) .. ':' .. tostring(list[i].expire)
    end
    return table.concat(parts, '|')
end

local function WF_UsedPinSet(list)
    local used = {}
    for i = 1, #list do
        used[list[i].pin] = true
    end
    return used
end

local function WF_AddBiomassPin(pCity, pin)
    if pCity == nil then return false end
    local buildingIndex = g_BiomassBuildingIndex[pin]
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

local function WF_RemoveBiomassPin(pCity, pin)
    if pCity == nil then return false end
    local buildingIndex = g_BiomassBuildingIndex[pin]
    if buildingIndex == nil then return false end
    local bld = pCity:GetBuildings()
    if bld == nil then return false end
    if not bld:HasBuilding(buildingIndex) then
        return true
    end
    local ok = pcall(function()
        bld:RemoveBuilding(buildingIndex)
    end)
    return ok
end

local function WF_ExpireCityBiomass(pCity)
    if pCity == nil then return end
    local now = Game.GetCurrentGameTurn()
    local list = WF_ParsePinEntries(pCity:GetProperty(BIOMASS_CITY_PROP))
    if #list == 0 then
        -- 无 Property 但可能残留建筑（读档/旧方案）
        local bld = pCity:GetBuildings()
        if bld ~= nil then
            for pin = 1, BIOMASS_PIN_COUNT do
                local idx = g_BiomassBuildingIndex[pin]
                if idx ~= nil and bld:HasBuilding(idx) then
                    WF_RemoveBiomassPin(pCity, pin)
                end
            end
        end
        return
    end

    local keep = {}
    local removed = 0
    for i = 1, #list do
        local e = list[i]
        if now >= e.expire then
            if WF_RemoveBiomassPin(pCity, e.pin) then
                removed = removed + 1
            end
        else
            keep[#keep + 1] = e
        end
    end
    pCity:SetProperty(BIOMASS_CITY_PROP, WF_SerializePinEntries(keep))
    if removed > 0 then
        print(string.format(
            '[Haikesi WarFeed] expired %d biomass pins on %s (turn=%d, left=%d)',
            removed, Locale.Lookup(pCity:GetName()), now, #keep))
    end
end

local function WF_ExpirePlayerBiomass(playerID)
    local pPlayer = Players[playerID]
    if pPlayer == nil then return end
    for _, city in pPlayer:GetCities():Members() do
        WF_ExpireCityBiomass(city)
    end
end

-- 占用空闲 pin 槽，各 +1 粮建筑，共用同一 expireTurn
local function WF_ApplyBiomassBuff(pCity, foodPerTurn)
    if pCity == nil or foodPerTurn <= 0 then return false, 'nil-city' end
    if not WF_CacheBiomassBuildingIndices() then
        return false, 'no-biomass-buildings'
    end

    local now = Game.GetCurrentGameTurn()
    local expireTurn = now + BIOMASS_DURATION_TURNS
    local list = WF_ParsePinEntries(pCity:GetProperty(BIOMASS_CITY_PROP))
    local used = WF_UsedPinSet(list)

    local granted = 0
    for pin = 1, BIOMASS_PIN_COUNT do
        if granted >= foodPerTurn then break end
        if not used[pin] then
            if WF_AddBiomassPin(pCity, pin) then
                list[#list + 1] = { pin = pin, expire = expireTurn }
                used[pin] = true
                granted = granted + 1
            end
        end
    end

    pCity:SetProperty(BIOMASS_CITY_PROP, WF_SerializePinEntries(list))
    if granted <= 0 then
        return false, 'no-free-pins'
    end
    local msg = string.format(
        'Biomass +%d food/t x%d turns (expire T%d, pins=%d/%d)',
        granted, BIOMASS_DURATION_TURNS, expireTurn, #list, BIOMASS_PIN_COUNT)
    if granted < foodPerTurn then
        msg = msg .. string.format(' capped(want %d)', foodPerTurn)
    end
    return true, msg
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

    local pCity = WF_FindNearestCity(pKiller, iX, iY)
    if pCity == nil then
        print('[Haikesi WarFeed] skip: killer has no cities')
        return
    end

    g_FedKeys[dedupe] = true

    local granted, how = WF_ApplyBiomassBuff(pCity, foodPerTurn)

    local floaterX, floaterY = iX, iY
    if pKillerUnit ~= nil then
        local kx, ky = pKillerUnit:GetX(), pKillerUnit:GetY()
        if kx ~= nil and kx >= 0 then
            floaterX, floaterY = kx, ky
        end
    end
    WF_NotifyFoodFloater(killerPlayerID, floaterX, floaterY, foodPerTurn)

    print(string.format(
        '[Haikesi WarFeed] %s P%d kill biomass +%d food/t x%d (str=%d) city=%s granted=%s via=%s',
        tostring(sourceTag), killerPlayerID, foodPerTurn, BIOMASS_DURATION_TURNS, strength,
        Locale.Lookup(pCity:GetName()), tostring(granted), tostring(how)))
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
        '[Haikesi WarFeed] GamePlay bridge ready (dummy-building biomass %d%%/t x%d turns, pins=%d)',
        BIOMASS_FPT_PERCENT, BIOMASS_DURATION_TURNS, BIOMASS_PIN_COUNT))
end

Events.LoadScreenClose.Add(InitializeWarFeed)
