-- ===========================================================================
-- Haikesi_DeathCult_GamePlay.lua
-- Death Cult / Necromilitarism dynamic zombie effects.
-- ===========================================================================

local DEATH_CULT_RELIC = 'DEATHCULTRUNE'
local NECROMILITARISM_RELIC = 'NECROMILITARISMRUNE'
local ZOMBIE_UNIT = 'UNIT_NW_ZOMBIE'
local HERETIC_PROJECT = 'PROJECT_NW_HERETIC_SACRIFICE'
local PROJECT_UNLOCK_BUILDING = 'BUILDING_NW_DEATH_CULT_PROJECT_UNLOCK'
local PROJECT_AVAILABILITY_MODIFIER = 'MODIFIER_NW_DEATH_CULT_UNLOCK_HERETIC_SACRIFICE_V2'
local PROJECT_AVAILABILITY_ATTACHED_PROPERTY = 'PROP_NW_DEATH_CULT_PROJECT_AVAILABILITY_V2_ATTACHED'
local PROJECT_COMPLETION_PROPERTY = 'PROP_NW_HERETIC_SACRIFICE_COMPLETED_V2'
local PROJECT_PROCESSED_PROPERTY = 'PROP_NW_HERETIC_SACRIFICE_PROCESSED_V2'

local MUTATION_PROPERTY = 'PROP_NW_ZOMBIE_MUTATION'
local MUTATION_EFFECT_PROPERTY = 'PROP_NW_ZOMBIE_MUTATION_EFFECT_V2'
local MUTATION_APPLIED_PROPERTY = 'PROP_NW_ZOMBIE_MUTATION_APPLIED_V2'
local MUTATION_COMBAT_ATTACHED_PROPERTY = 'PROP_NW_ZOMBIE_MUTATION_COMBAT_V2_ATTACHED'
local MUTATION_COMBAT_MODIFIER = 'MODIFIER_NW_ZOMBIE_MUTATION_PLAYER_COMBAT_V2'
local MUTATION_INCREMENT_MODIFIER = 'MODIFIER_NW_ZOMBIE_MUTATION_INCREMENT_V2'
local PENDING_SPAWNS_PROPERTY = 'PROP_NW_ZOMBIE_PENDING_SPAWNS'
local BASE_MODIFIERS_ATTACHED_PROPERTY = 'PROP_NW_DEATH_CULT_BASE_MODIFIERS_ATTACHED'
local BASE_MODIFIERS = {
    'MODIFIER_NW_DEATH_CULT_WAR_WEARINESS',
    'MODIFIER_NW_DEATH_CULT_GROWTH',
}

local RESURRECT_CHANCE = 33

local RelicsCountPropertyKey = 'PROP_NW_HAIKESI_RELIC_COUNT'
local RelicsSlotPropertyPrefix = 'PROP_NW_HAIKESI_RELIC_'

local g_UnitCache = {}
local g_KillHandled = {}
local g_ProjectUnlockBuildingIndex = nil

local function DC_Log(msg)
    print('[Haikesi DeathCult] ' .. tostring(msg))
end

local function DC_PlayerHasRelic(pPlayer, relicType)
    if pPlayer == nil or relicType == nil then return false end

    local function checkSlots(countKey, prefix)
        local count = tonumber(pPlayer:GetProperty(countKey) or 0) or 0
        for i = 1, count do
            if pPlayer:GetProperty(prefix .. i) == relicType then
                return true
            end
        end
        return false
    end

    return checkSlots(RelicsCountPropertyKey, RelicsSlotPropertyPrefix)
end

local function DC_EnsureProjectAvailability(playerID)
    local pPlayer = Players[playerID]
    if pPlayer == nil or not DC_PlayerHasRelic(pPlayer, DEATH_CULT_RELIC) then
        return false
    end
    if tonumber(pPlayer:GetProperty(PROJECT_AVAILABILITY_ATTACHED_PROPERTY) or 0) == 1 then
        return true
    end
    if type(pPlayer.AttachModifierByID) ~= 'function' then
        DC_Log('ERROR: AttachModifierByID missing for project availability')
        return false
    end
    local ok, err = pcall(function()
        pPlayer:AttachModifierByID(PROJECT_AVAILABILITY_MODIFIER)
    end)
    if not ok then
        DC_Log('ERROR: attach project availability failed P' .. tostring(playerID) .. ': ' .. tostring(err))
        return false
    end
    pPlayer:SetProperty(PROJECT_AVAILABILITY_ATTACHED_PROPERTY, 1)
    DC_Log('attached Death Cult project availability for P' .. tostring(playerID))
    return true
end

local function DC_GetProjectUnlockBuildingIndex()
    if g_ProjectUnlockBuildingIndex ~= nil then
        return g_ProjectUnlockBuildingIndex
    end
    local buildingInfo = GameInfo.Buildings[PROJECT_UNLOCK_BUILDING]
    if buildingInfo == nil then
        DC_Log('ERROR: missing ' .. PROJECT_UNLOCK_BUILDING)
        return nil
    end
    g_ProjectUnlockBuildingIndex = buildingInfo.Index
    return g_ProjectUnlockBuildingIndex
end

local function DC_IsHolySiteDistrictType(districtType)
    if districtType == 'DISTRICT_HOLY_SITE' then return true end
    if GameInfo.DistrictReplaces == nil then return false end
    for row in GameInfo.DistrictReplaces() do
        if row.CivUniqueDistrictType == districtType
            and row.ReplacesDistrictType == 'DISTRICT_HOLY_SITE' then
            return true
        end
    end
    return false
end

local function DC_GetCompletedHolySitePlot(city)
    if city == nil or city.GetDistricts == nil then return nil end
    local districts = city:GetDistricts()
    if districts == nil or districts.Members == nil then return nil end

    local ok, result = pcall(function()
        for _, district in districts:Members() do
            local districtInfo = GameInfo.Districts[district:GetType()]
            if districtInfo ~= nil and DC_IsHolySiteDistrictType(districtInfo.DistrictType) then
                if district.IsComplete == nil or district:IsComplete() then
                    if district.GetX ~= nil and district.GetY ~= nil then
                        return Map.GetPlot(district:GetX(), district:GetY())
                    end
                end
            end
        end
        return nil
    end)
    if not ok then
        DC_Log('ERROR: failed to find completed Holy Site: ' .. tostring(result))
        return nil
    end
    return result
end

local function DC_SetCityProjectUnlock(city, shouldHave, holySitePlot)
    if city == nil or city.GetBuildings == nil then return false end
    local buildingIndex = DC_GetProjectUnlockBuildingIndex()
    if buildingIndex == nil then return false end

    local buildings = city:GetBuildings()
    if buildings == nil or buildings.HasBuilding == nil then return false end

    local hasBuilding = buildings:HasBuilding(buildingIndex)
    if shouldHave then
        if holySitePlot == nil then return false end
        if hasBuilding then return false end

        local queue = city:GetBuildQueue()
        if queue == nil or queue.CreateIncompleteBuilding == nil then
            DC_Log('ERROR: cannot grant project unlock building')
            return false
        end
        local ok, err = pcall(function()
            queue:CreateIncompleteBuilding(buildingIndex, holySitePlot:GetIndex(), 100)
        end)
        if not ok then
            DC_Log('ERROR: grant project unlock building failed: ' .. tostring(err))
            return false
        end
        return buildings:HasBuilding(buildingIndex)
    end

    if not hasBuilding then return false end
    if buildings.RemoveBuilding == nil then return false end
    local ok, err = pcall(function()
        buildings:RemoveBuilding(buildingIndex)
    end)
    if not ok then
        DC_Log('ERROR: remove project unlock building failed: ' .. tostring(err))
        return false
    end
    return true
end

function Haikesi_RefreshDeathCultProjectUnlocks(playerID)
    local pPlayer = Players[playerID]
    if pPlayer == nil or pPlayer.GetCities == nil then return 0 end

    local hasDeathCult = DC_PlayerHasRelic(pPlayer, DEATH_CULT_RELIC)
    if hasDeathCult then
        DC_EnsureProjectAvailability(playerID)
    end
    local changed = 0
    local cities = pPlayer:GetCities()
    if cities == nil or cities.Members == nil then return 0 end

    for _, city in cities:Members() do
        local holySitePlot = DC_GetCompletedHolySitePlot(city)
        local shouldHave = hasDeathCult and holySitePlot ~= nil
        if DC_SetCityProjectUnlock(city, shouldHave, holySitePlot) then
            changed = changed + 1
        end
    end
    if changed > 0 then
        DC_Log(string.format('refreshed project unlocks P%d cities=%d hasDeathCult=%s',
            playerID, changed, tostring(hasDeathCult)))
    end
    return changed
end

local function DC_EnsureDeathCultBaseModifiers(playerID)
    local pPlayer = Players[playerID]
    if pPlayer == nil or not DC_PlayerHasRelic(pPlayer, DEATH_CULT_RELIC) then
        return
    end
    if tonumber(pPlayer:GetProperty(BASE_MODIFIERS_ATTACHED_PROPERTY) or 0) == 1 then
        return
    end
    if type(pPlayer.AttachModifierByID) ~= 'function' then
        return
    end

    for _, modifierId in ipairs(BASE_MODIFIERS) do
        local ok, err = pcall(function()
            pPlayer:AttachModifierByID(modifierId)
        end)
        if not ok then
            DC_Log('ERROR: failed to attach ' .. tostring(modifierId) .. ' for player '
                .. tostring(playerID) .. ': ' .. tostring(err))
            return
        end
    end
    pPlayer:SetProperty(BASE_MODIFIERS_ATTACHED_PROPERTY, 1)
    DC_Log('attached Death Cult base modifiers for player ' .. tostring(playerID))
end

local function DC_GetUnit(playerID, unitID)
    if playerID == nil or unitID == nil then return nil end
    local pUnit = UnitManager.GetUnit(playerID, unitID)
    if pUnit ~= nil then return pUnit end
    local pPlayer = Players[playerID]
    if pPlayer == nil or pPlayer.GetUnits == nil then return nil end
    return pPlayer:GetUnits():FindID(unitID)
end

local function DC_GetUnitInfo(unit)
    if unit == nil then return nil end
    return GameInfo.Units[unit:GetType()]
end

local function DC_GetUnitType(unit)
    local unitInfo = DC_GetUnitInfo(unit)
    return unitInfo and unitInfo.UnitType or nil
end

local function DC_IsZombie(unit)
    return DC_GetUnitType(unit) == ZOMBIE_UNIT
end

local function DC_IsLandCombatUnit(unit)
    local unitInfo = DC_GetUnitInfo(unit)
    return unitInfo ~= nil and unitInfo.FormationClass == 'FORMATION_CLASS_LAND_COMBAT'
end

local function DC_GetCombat(unit)
    local unitInfo = DC_GetUnitInfo(unit)
    if unitInfo == nil then return 0 end
    return tonumber(unitInfo.Combat or unitInfo.RangedCombat or 0) or 0
end

local function DC_Rand(maxCount, reason)
    if maxCount == nil or maxCount <= 0 then return 0 end
    if Game.GetRandNum ~= nil then
        return Game.GetRandNum(maxCount, reason or 'HaikesiDeathCult') or 0
    end
    return math.random(0, maxCount - 1)
end

local function DC_IsValidMapLocation(x, y)
    return x ~= nil and y ~= nil and x >= 0 and y >= 0 and Map.GetPlot(x, y) ~= nil
end

local function DC_PlotHasBlockingUnit(playerID, x, y)
    for checkPlayerID = 0, 63 do
        local pPlayer = Players[checkPlayerID]
        if pPlayer ~= nil and pPlayer.GetUnits ~= nil then
            local units = pPlayer:GetUnits()
            if units ~= nil then
                for _, unit in units:Members() do
                    if unit ~= nil and unit:GetX() == x and unit:GetY() == y then
                        if checkPlayerID ~= playerID or DC_IsLandCombatUnit(unit) then
                            return true
                        end
                    end
                end
            end
        end
    end
    return false
end

local function DC_PlotCanSpawnZombie(playerID, pPlot)
    if pPlot == nil or pPlot:IsWater() or pPlot:IsImpassable() then
        return false
    end
    return not DC_PlotHasBlockingUnit(playerID, pPlot:GetX(), pPlot:GetY())
end

local function DC_FindSpawnPlot(playerID, x, y, radius)
    if not DC_IsValidMapLocation(x, y) then return nil end
    radius = radius or 2
    local center = Map.GetPlot(x, y)
    if DC_PlotCanSpawnZombie(playerID, center) then return center end

    local visited = {}
    local frontier = { center }
    visited[tostring(x) .. ',' .. tostring(y)] = true
    for _ = 1, radius do
        local nextFrontier = {}
        for _, plot in ipairs(frontier) do
            for dir = 0, 5 do
                local adj = Map.GetAdjacentPlot(plot:GetX(), plot:GetY(), dir)
                if adj ~= nil then
                    local key = tostring(adj:GetX()) .. ',' .. tostring(adj:GetY())
                    if not visited[key] then
                        visited[key] = true
                        if DC_PlotCanSpawnZombie(playerID, adj) then
                            return adj
                        end
                        table.insert(nextFrontier, adj)
                    end
                end
            end
        end
        frontier = nextFrontier
    end
    return nil
end

local function DC_GetMutation(pPlayer)
    if pPlayer == nil then return 0 end
    return tonumber(pPlayer:GetProperty(MUTATION_PROPERTY) or 0) or 0
end

local function DC_EnsureMutationEffects(playerID)
    local pPlayer = Players[playerID]
    if pPlayer == nil or not DC_PlayerHasRelic(pPlayer, DEATH_CULT_RELIC) then return end
    if type(pPlayer.AttachModifierByID) ~= 'function' then return end

    if tonumber(pPlayer:GetProperty(MUTATION_COMBAT_ATTACHED_PROPERTY) or 0) ~= 1 then
        local ok, err = pcall(function()
            pPlayer:AttachModifierByID(MUTATION_COMBAT_MODIFIER)
        end)
        if not ok then
            DC_Log('ERROR: mutation combat modifier attach failed P' .. tostring(playerID) .. ': ' .. tostring(err))
            return
        end
        pPlayer:SetProperty(MUTATION_COMBAT_ATTACHED_PROPERTY, 1)
    end

    local target = math.max(0, DC_GetMutation(pPlayer))
    local applied = math.max(0, tonumber(pPlayer:GetProperty(MUTATION_APPLIED_PROPERTY) or 0) or 0)
    local attached = 0
    while applied < target do
        local ok, err = pcall(function()
            pPlayer:AttachModifierByID(MUTATION_INCREMENT_MODIFIER)
        end)
        if not ok then
            DC_Log('ERROR: mutation increment attach failed P' .. tostring(playerID) .. ': ' .. tostring(err))
            break
        end
        applied = applied + 1
        attached = attached + 1
        pPlayer:SetProperty(MUTATION_APPLIED_PROPERTY, applied)
    end

    local effectValue = tonumber(pPlayer:GetProperty(MUTATION_EFFECT_PROPERTY) or 0) or 0
    if attached > 0 or effectValue ~= target then
        DC_Log(string.format('mutation effects P%d target=%d applied=%d effect=%d attached=%d',
            playerID, target, applied, effectValue, attached))
    end
end

local function DC_ChangeMutation(playerID, amount)
    local pPlayer = Players[playerID]
    if pPlayer == nil then return end
    local value = DC_GetMutation(pPlayer) + (amount or 0)
    pPlayer:SetProperty(MUTATION_PROPERTY, value)
    DC_Log(string.format('P%d mutation=%d', playerID, value))
end

local function DC_HealUnit(unit, amount)
    if unit == nil or amount == nil or amount <= 0 then return end
    if unit.GetDamage ~= nil and unit.SetDamage ~= nil then
        local damage = unit:GetDamage()
        unit:SetDamage(math.max(0, damage - amount))
    elseif unit.ChangeDamage ~= nil then
        unit:ChangeDamage(-amount)
    end
end

local function DC_FinishMoves(unit)
    if unit == nil then return end
    if UnitManager.FinishMoves ~= nil then
        pcall(UnitManager.FinishMoves, unit)
    elseif type(unit.GetMovesRemaining) == 'function' and type(unit.ChangeMovesRemaining) == 'function' then
        pcall(function() unit:ChangeMovesRemaining(-unit:GetMovesRemaining()) end)
    end
end

local function DC_SpawnZombie(playerID, x, y)
    if GameInfo.Units[ZOMBIE_UNIT] == nil then return false end
    local plot = DC_FindSpawnPlot(playerID, x, y, 3)
    if plot == nil then
        DC_Log(string.format('spawn failed: no valid plot near %s,%s for P%d', tostring(x), tostring(y), playerID))
        return false
    end
    local ok, unit = pcall(UnitManager.InitUnit, playerID, ZOMBIE_UNIT, plot:GetX(), plot:GetY())
    if ok and unit ~= nil then
        if unit.SetDamage ~= nil then unit:SetDamage(0) end
        DC_Log(string.format('spawn zombie P%d at %d,%d', playerID, plot:GetX(), plot:GetY()))
        return true
    end
    DC_Log('UnitManager.InitUnit zombie failed: ' .. tostring(unit))
    return false
end

local function DC_NotifyFloater(playerID, x, y, text)
    if text == nil or text == '' then return end
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

local function DC_CacheUnit(playerID, unitID)
    local unit = DC_GetUnit(playerID, unitID)
    if unit == nil then return end
    local x, y = unit:GetX(), unit:GetY()
    local unitType = DC_GetUnitType(unit)
    if not DC_IsValidMapLocation(x, y) or unitType == nil then return end
    if g_UnitCache[playerID] == nil then g_UnitCache[playerID] = {} end
    g_UnitCache[playerID][unitID] = { x = x, y = y, unitType = unitType }
end

local function DC_TakeCachedUnit(playerID, unitID)
    local byPlayer = g_UnitCache[playerID]
    if byPlayer == nil then return nil end
    local entry = byPlayer[unitID]
    byPlayer[unitID] = nil
    return entry
end

local function DC_ParsePending(prop)
    local entries = {}
    prop = tostring(prop or '')
    for token in string.gmatch(prop, '[^;]+') do
        local turnStr, xStr, yStr = string.match(token, '^(%-?%d+),(%-?%d+),(%-?%d+)$')
        local turn, x, y = tonumber(turnStr), tonumber(xStr), tonumber(yStr)
        if turn ~= nil and x ~= nil and y ~= nil then
            table.insert(entries, { turn = turn, x = x, y = y })
        end
    end
    return entries
end

local function DC_SerializePending(entries)
    local parts = {}
    for _, entry in ipairs(entries) do
        table.insert(parts, tostring(entry.turn) .. ',' .. tostring(entry.x) .. ',' .. tostring(entry.y))
    end
    return table.concat(parts, ';')
end

local function DC_AddPendingSpawn(playerID, x, y)
    local pPlayer = Players[playerID]
    if pPlayer == nil then return end
    local entries = DC_ParsePending(pPlayer:GetProperty(PENDING_SPAWNS_PROPERTY))
    table.insert(entries, {
        turn = (Game.GetCurrentGameTurn and Game.GetCurrentGameTurn() or 0) + 1,
        x = x,
        y = y
    })
    pPlayer:SetProperty(PENDING_SPAWNS_PROPERTY, DC_SerializePending(entries))
    DC_Log(string.format('queued infection P%d at %d,%d', playerID, x, y))
end

local function DC_ProcessPendingSpawns(playerID)
    local pPlayer = Players[playerID]
    if pPlayer == nil then return end
    local currentTurn = Game.GetCurrentGameTurn and Game.GetCurrentGameTurn() or 0
    local entries = DC_ParsePending(pPlayer:GetProperty(PENDING_SPAWNS_PROPERTY))
    if #entries == 0 then return end
    local keep = {}
    for _, entry in ipairs(entries) do
        if entry.turn <= currentTurn then
            local spawned = DC_SpawnZombie(playerID, entry.x, entry.y)
            DC_Log(string.format('processed infection P%d turn=%d at %d,%d spawned=%s',
                playerID, currentTurn, entry.x, entry.y, tostring(spawned)))
        else
            table.insert(keep, entry)
        end
    end
    pPlayer:SetProperty(PENDING_SPAWNS_PROPERTY, DC_SerializePending(keep))
end

local function DC_CountHereticFollowers(city, foundedReligion)
    if city == nil or foundedReligion == nil or foundedReligion < 0 then return 0 end
    local religion = city:GetReligion()
    if religion == nil or religion.GetReligionsInCity == nil then return 0 end
    local ok, rows = pcall(function() return religion:GetReligionsInCity() end)
    if not ok or rows == nil then return 0 end

    local count = 0
    for _, row in pairs(rows) do
        local religionType = tonumber(row.Religion or row.ReligionType or -1) or -1
        local followers = tonumber(row.Followers or row.NumFollowers or 0) or 0
        if religionType >= 0 and religionType ~= foundedReligion then
            count = count + followers
        end
    end
    return count
end

local function DC_TryClearOtherReligions(city, foundedReligion)
    local religion = city ~= nil and city:GetReligion() or nil
    if religion == nil or foundedReligion == nil or foundedReligion < 0 then return end
    if type(religion.RemoveOtherReligions) == 'function' then
        pcall(function() religion:RemoveOtherReligions(foundedReligion) end)
    elseif type(religion.RemoveAllOtherReligions) == 'function' then
        pcall(function() religion:RemoveAllOtherReligions(foundedReligion) end)
    end
end

local function DC_SacrificePopulationForZombies(playerID, city, amount)
    if city == nil or amount == nil or amount <= 0 then return 0 end
    local spawned = 0
    for _ = 1, amount do
        if city:GetPopulation() <= 1 then break end
        local ok = pcall(function() city:ChangePopulation(-1) end)
        if ok then
            if DC_SpawnZombie(playerID, city:GetX(), city:GetY()) then
                spawned = spawned + 1
            else
                -- Keep population and zombie conversion atomic when every
                -- nearby plot is blocked or unit creation fails.
                pcall(function() city:ChangePopulation(1) end)
                break
            end
        else
            break
        end
    end
    return spawned
end

local function DC_ResolveHereticSacrifice(playerID, city, completionNumber, source)
    local pPlayer = Players[playerID]
    if pPlayer == nil or city == nil then return 0 end

    local foundedReligion = -1
    local pReligion = pPlayer:GetReligion()
    if pReligion ~= nil and pReligion.GetReligionTypeCreated ~= nil then
        foundedReligion = pReligion:GetReligionTypeCreated()
    end

    local extraHeretics = DC_CountHereticFollowers(city, foundedReligion)
    local total = 1 + extraHeretics
    local populationBefore = city:GetPopulation()
    local spawned = DC_SacrificePopulationForZombies(playerID, city, total)
    DC_TryClearOtherReligions(city, foundedReligion)
    if spawned > 0 then
        DC_NotifyFloater(playerID, city:GetX(), city:GetY(),
            '+' .. tostring(spawned) .. ' ' .. Locale.Lookup('LOC_UNIT_NW_ZOMBIE_NAME'))
    end
    DC_Log(string.format(
        'project resolved source=%s P%d city=%d completion=%d heretics=%d requested=%d pop=%d->%d spawned=%d',
        tostring(source), playerID, city:GetID(), completionNumber,
        extraHeretics, total, populationBefore, city:GetPopulation(), spawned))
    return spawned
end

local function DC_ProcessCityProjectCompletions(playerID, city, source)
    if city == nil then return 0 end
    local completed = math.max(0, math.floor(tonumber(city:GetProperty(PROJECT_COMPLETION_PROPERTY) or 0) or 0))
    local processed = math.max(0, math.floor(tonumber(city:GetProperty(PROJECT_PROCESSED_PROPERTY) or 0) or 0))
    if completed <= processed then return 0 end

    local pPlayer = Players[playerID]
    if pPlayer == nil or not DC_PlayerHasRelic(pPlayer, DEATH_CULT_RELIC) then
        city:SetProperty(PROJECT_PROCESSED_PROPERTY, completed)
        DC_Log(string.format(
            'ignored %d project completion(s) without Death Cult P%d city=%d source=%s',
            completed - processed, playerID, city:GetID(), tostring(source)))
        return 0
    end

    local totalSpawned = 0
    for completionNumber = processed + 1, completed do
        totalSpawned = totalSpawned
            + DC_ResolveHereticSacrifice(playerID, city, completionNumber, source)
        city:SetProperty(PROJECT_PROCESSED_PROPERTY, completionNumber)
    end
    return totalSpawned
end

local function DC_ProcessPlayerProjectCompletions(playerID, source)
    local pPlayer = Players[playerID]
    if pPlayer == nil or pPlayer.GetCities == nil then return 0 end
    local cities = pPlayer:GetCities()
    if cities == nil or cities.Members == nil then return 0 end
    local totalSpawned = 0
    for _, city in cities:Members() do
        totalSpawned = totalSpawned + DC_ProcessCityProjectCompletions(playerID, city, source)
    end
    return totalSpawned
end

function Haikesi_OnDeathCultCityProjectCompleted(playerID, cityID, projectID)
    local projectInfo = GameInfo.Projects[projectID]
    local projectType = projectInfo and projectInfo.ProjectType or tostring(projectID)
    if projectType ~= HERETIC_PROJECT then return end
    local pPlayer = Players[playerID]
    local cities = pPlayer ~= nil and pPlayer:GetCities() or nil
    local city = cities ~= nil and cities:FindID(cityID) or nil
    DC_Log(string.format('CityProjectCompleted P%s city=%s project=%s counter=%s',
        tostring(playerID), tostring(cityID), tostring(projectType),
        tostring(city and city:GetProperty(PROJECT_COMPLETION_PROPERTY) or nil)))
    DC_ProcessCityProjectCompletions(playerID, city, 'CityProjectCompleted')
end

local function DC_OnCityProductionCompleted(playerID, cityID)
    local pPlayer = Players[playerID]
    local cities = pPlayer ~= nil and pPlayer:GetCities() or nil
    local city = cities ~= nil and cities:FindID(cityID) or nil
    DC_ProcessCityProjectCompletions(playerID, city, 'CityProductionCompleted')
end

local function DC_HandleUnitDeath(killedPlayerID, killedUnitID, killerPlayerID, killerUnitID, x, y, source)
    if killedPlayerID == nil or killedUnitID == nil then return end

    local key = tostring(Game.GetCurrentGameTurn()) .. ':' .. tostring(killedPlayerID) .. ':' .. tostring(killedUnitID)
    if g_KillHandled[key] then return end

    local cached = DC_TakeCachedUnit(killedPlayerID, killedUnitID)
    if not DC_IsValidMapLocation(x, y) and cached ~= nil then
        x, y = cached.x, cached.y
    end

    local killedUnit = DC_GetUnit(killedPlayerID, killedUnitID)
    local killedWasZombie = false
    local killedWasLandCombat = false
    if killedUnit ~= nil then
        if not DC_IsValidMapLocation(x, y) then
            local unitX, unitY = killedUnit:GetX(), killedUnit:GetY()
            if DC_IsValidMapLocation(unitX, unitY) then
                x, y = unitX, unitY
            end
        end
        killedWasZombie = DC_IsZombie(killedUnit)
        killedWasLandCombat = DC_IsLandCombatUnit(killedUnit)
    elseif cached ~= nil then
        killedWasZombie = cached.unitType == ZOMBIE_UNIT
        local info = GameInfo.Units[cached.unitType]
        killedWasLandCombat = info ~= nil and info.FormationClass == 'FORMATION_CLASS_LAND_COMBAT'
    else
        DC_Log(string.format('death deferred source=%s killed=P%s/U%s: unit and cache unavailable',
            tostring(source), tostring(killedPlayerID), tostring(killedUnitID)))
        return
    end

    if not DC_IsValidMapLocation(x, y) then
        DC_Log(string.format('death deferred source=%s killed=P%d/U%d: location unavailable',
            tostring(source), killedPlayerID, killedUnitID))
        return
    end

    g_KillHandled[key] = true
    DC_Log(string.format('death source=%s killed=P%d/U%d zombie=%s landCombat=%s killer=P%s/U%s at=%s,%s',
        tostring(source), killedPlayerID, killedUnitID, tostring(killedWasZombie),
        tostring(killedWasLandCombat), tostring(killerPlayerID), tostring(killerUnitID),
        tostring(x), tostring(y)))

    if killedWasZombie then
        DC_ChangeMutation(killedPlayerID, 1)
    end

    local killedPlayer = Players[killedPlayerID]
    if killedPlayer ~= nil and killedWasLandCombat and not killedWasZombie and DC_PlayerHasRelic(killedPlayer, NECROMILITARISM_RELIC) then
        local roll = DC_Rand(100, 'HaikesiZombieResurrection')
        if DC_IsValidMapLocation(x, y) and roll < RESURRECT_CHANCE then
            local spawned = DC_SpawnZombie(killedPlayerID, x, y)
            DC_Log(string.format('resurrection P%d roll=%d chance=%d spawned=%s',
                killedPlayerID, roll, RESURRECT_CHANCE, tostring(spawned)))
        else
            DC_Log(string.format('resurrection skipped P%d validPlot=%s roll=%d chance=%d',
                killedPlayerID, tostring(DC_IsValidMapLocation(x, y)), roll, RESURRECT_CHANCE))
        end
    end

    if killerPlayerID == nil or killerUnitID == nil or killerPlayerID == killedPlayerID then return end
    local killerPlayer = Players[killerPlayerID]
    if killerPlayer == nil or not DC_PlayerHasRelic(killerPlayer, NECROMILITARISM_RELIC) then return end

    local killerUnit = DC_GetUnit(killerPlayerID, killerUnitID)
    if killerUnit ~= nil and DC_IsZombie(killerUnit) and DC_IsValidMapLocation(x, y) then
        local roll = DC_Rand(100, 'HaikesiZombieInfection')
        if roll < RESURRECT_CHANCE then
            DC_AddPendingSpawn(killerPlayerID, x, y)
            DC_Log(string.format('infection P%d roll=%d chance=%d queued=true',
                killerPlayerID, roll, RESURRECT_CHANCE))
        else
            DC_Log(string.format('infection P%d roll=%d chance=%d queued=false',
                killerPlayerID, roll, RESURRECT_CHANCE))
        end
    else
        DC_Log(string.format('infection skipped killer=P%d/U%s zombie=%s validPlot=%s',
            killerPlayerID, tostring(killerUnitID), tostring(DC_IsZombie(killerUnit)),
            tostring(DC_IsValidMapLocation(x, y))))
    end
end

function Haikesi_OnDeathCultUnitKilledInCombat(killedPlayerID, killedUnitID, killerPlayerID, killerUnitID)
    DC_HandleUnitDeath(killedPlayerID, killedUnitID, killerPlayerID, killerUnitID, nil, nil, 'UnitKilledInCombat')
end

function Haikesi_OnDeathCultCombatOccurred(attackerPlayerID, attackerUnitID, defenderPlayerID, defenderUnitID)
    if attackerPlayerID == nil or defenderPlayerID == nil then return end
    if attackerPlayerID == defenderPlayerID then return end

    local atk = DC_GetUnit(attackerPlayerID, attackerUnitID)
    local def = DC_GetUnit(defenderPlayerID, defenderUnitID)

    local function dying(unit)
        if unit == nil then return false end
        if unit.IsDead ~= nil and unit:IsDead() then return true end
        if unit.IsDelayedDeath ~= nil and unit:IsDelayedDeath() then return true end
        return false
    end

    if dying(def) then
        DC_CacheUnit(defenderPlayerID, defenderUnitID)
        DC_HandleUnitDeath(defenderPlayerID, defenderUnitID, attackerPlayerID, attackerUnitID,
            def:GetX(), def:GetY(), 'OnCombatOccurred')
    end
    if dying(atk) then
        DC_CacheUnit(attackerPlayerID, attackerUnitID)
        DC_HandleUnitDeath(attackerPlayerID, attackerUnitID, defenderPlayerID, defenderUnitID,
            atk:GetX(), atk:GetY(), 'OnCombatOccurred')
    end
end

local function DC_FindDevourTarget(playerID, zombie)
    if zombie == nil then return nil end
    local x, y = zombie:GetX(), zombie:GetY()
    local pPlayer = Players[playerID]
    if pPlayer == nil or pPlayer.GetUnits == nil then return nil end
    local units = pPlayer:GetUnits()
    if units == nil then return nil end

    local bestUnit = nil
    local bestCombat = -1
    for _, unit in units:Members() do
        if unit ~= nil and unit:GetID() ~= zombie:GetID() and DC_IsLandCombatUnit(unit) and not DC_IsZombie(unit) then
            local dist = Map.GetPlotDistance(x, y, unit:GetX(), unit:GetY())
            if dist == 1 then
                local combat = DC_GetCombat(unit)
                if combat > bestCombat then
                    bestCombat = combat
                    bestUnit = unit
                end
            end
        end
    end
    return bestUnit, bestCombat
end

local function DC_IsValidDevourTarget(playerID, zombie, target)
    if zombie == nil or target == nil then return false end
    if target:GetOwner() ~= playerID then return false end
    if target:GetID() == zombie:GetID() then return false end
    if not DC_IsLandCombatUnit(target) or DC_IsZombie(target) then return false end
    return Map.GetPlotDistance(zombie:GetX(), zombie:GetY(), target:GetX(), target:GetY()) == 1
end

function HaikesiDeathCultDevour(playerID, param)
    local pPlayer = Players[playerID]
    if pPlayer == nil or not DC_PlayerHasRelic(pPlayer, NECROMILITARISM_RELIC) then return end
    if param == nil or param.UnitID == nil then return end

    local zombie = DC_GetUnit(playerID, tonumber(param.UnitID))
    if zombie == nil or not DC_IsZombie(zombie) then return end
    if zombie.GetMovesRemaining ~= nil and zombie:GetMovesRemaining() <= 0 then return end

    local target = nil
    local heal = nil
    local hasExplicitTarget = param.TargetUnitID ~= nil
    if hasExplicitTarget then
        local requestedTarget = DC_GetUnit(playerID, tonumber(param.TargetUnitID))
        if DC_IsValidDevourTarget(playerID, zombie, requestedTarget) then
            if param.TargetX ~= nil and param.TargetY ~= nil then
                local tx = tonumber(param.TargetX)
                local ty = tonumber(param.TargetY)
                if requestedTarget:GetX() == tx and requestedTarget:GetY() == ty then
                    target = requestedTarget
                end
            else
                target = requestedTarget
            end
            if target ~= nil then
                heal = DC_GetCombat(target)
            end
        else
            DC_Log('devour requested target rejected')
        end
    end
    if hasExplicitTarget and target == nil then
        return
    end
    if target == nil then
        target, heal = DC_FindDevourTarget(playerID, zombie)
    end
    if target == nil then
        DC_Log('devour skipped: no adjacent friendly land combat target')
        return
    end

    local targetUnitID = target:GetID()
    local tx, ty = target:GetX(), target:GetY()
    DC_CacheUnit(playerID, targetUnitID)
    local ok = pcall(function() UnitManager.Kill(target, false) end)
    if not ok then
        DC_Log('devour failed: UnitManager.Kill target failed')
        return
    end
    DC_HandleUnitDeath(playerID, targetUnitID, playerID, zombie:GetID(), tx, ty, 'Devour')
    DC_HealUnit(zombie, heal)
    DC_FinishMoves(zombie)
    DC_NotifyFloater(playerID, tx, ty, '+' .. tostring(heal) .. ' [ICON_Damaged]')
    DC_Log(string.format('P%d zombie devoured unit for %d heal', playerID, heal))
end

local function DC_OnUnitAddedToMap(playerID, unitID)
    DC_CacheUnit(playerID, unitID)
end

local function DC_OnUnitMoved(playerID, unitID)
    DC_CacheUnit(playerID, unitID)
end

local function DC_OnPlayerTurnActivated(playerID, bIsFirstTime)
    if not bIsFirstTime then return end
    g_KillHandled = {}
    DC_EnsureDeathCultBaseModifiers(playerID)
    DC_EnsureMutationEffects(playerID)
    Haikesi_RefreshDeathCultProjectUnlocks(playerID)
    DC_ProcessPlayerProjectCompletions(playerID, 'PlayerTurnActivated')
    DC_ProcessPendingSpawns(playerID)
end

local function DC_CacheAllUnits()
    for playerID = 0, 63 do
        local pPlayer = Players[playerID]
        if pPlayer ~= nil and pPlayer.GetUnits ~= nil then
            local units = pPlayer:GetUnits()
            if units ~= nil then
                for _, unit in units:Members() do
                    DC_CacheUnit(playerID, unit:GetID())
                end
            end
        end
    end
end

local function InitializeHaikesiDeathCult()
    if Events.CityProjectCompleted ~= nil then
        Events.CityProjectCompleted.Add(Haikesi_OnDeathCultCityProjectCompleted)
    else
        DC_Log('ERROR: Events.CityProjectCompleted missing')
    end
    if Events.CityProductionCompleted ~= nil then
        Events.CityProductionCompleted.Add(DC_OnCityProductionCompleted)
    else
        DC_Log('WARNING: Events.CityProductionCompleted missing; using turn fallback')
    end
    if Events.UnitKilledInCombat ~= nil then
        Events.UnitKilledInCombat.Add(Haikesi_OnDeathCultUnitKilledInCombat)
    end
    if GameEvents ~= nil and GameEvents.OnCombatOccurred ~= nil then
        GameEvents.OnCombatOccurred.Add(Haikesi_OnDeathCultCombatOccurred)
    end
    if Events.UnitAddedToMap ~= nil then
        Events.UnitAddedToMap.Add(DC_OnUnitAddedToMap)
    end
    if Events.UnitMoved ~= nil then
        Events.UnitMoved.Add(DC_OnUnitMoved)
    end
    if Events.PlayerTurnActivated ~= nil then
        Events.PlayerTurnActivated.Add(DC_OnPlayerTurnActivated)
    end
    if ExposedMembers ~= nil then
        ExposedMembers.HaikesiDeathCultDevour = HaikesiDeathCultDevour
        ExposedMembers.Haikesi_RefreshDeathCultProjectUnlocks = Haikesi_RefreshDeathCultProjectUnlocks
    end
    DC_CacheAllUnits()
    DC_Log('initialized; city project unlock refresh deferred to player turn')
end

Events.LoadScreenClose.Add(InitializeHaikesiDeathCult)
