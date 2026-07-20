-- Create Pantheon Dev: God of Miracles via event + devotion cache (A+C)
-- Skips Permanent COLLECTION_PLAYER_DISTRICTS GRANT_BUILDING modifiers.
-- Recomputes only districts near changed plots; grants only on threshold cross / missing building.

local MIRACLE_POWER = "GOD_OF_MIRACLES"
local SPARK_POWER = "DIVINE_SPARK"
local HOUSING_POWER = "RELIGIOUS_SETTLEMENTS"
local WINE_POWER = "GOD_OF_WINE"
local PROP_ACTIVE = "PROP_CP_MIRACLES"
local PROP_GODHOOD = "PROP_CP_GODHOOD"
local PROP_POWER = "PROP_CP_POWER"
local PROP_ASUNA = "PROP_CP_MIRACLES_ASUNA"
local PROP_DEBUG = "PROP_CP_DEBUG" -- 1/nil = log on (Dev default on); 0 = off
local PROP_DEVOTION = "PROP_CP_DEVOTION_TRACK" -- Lua writes PROP_CP_DEV_* for spark/housing/wine/miracles
local CACHE_KEY_PREFIX = "PROP_CP_DEV_" -- + GodhoodType on district plot
local PROP_MIRACLE_PENDING = "PROP_CP_MIRACLE_PENDING" -- retry after district completion / failed grant

-- Default thresholds (devotion points). EARTH uses appeal with *2 in original SQL.
local DEFAULT_MIRACLE_POINTS = 6

local m_godhoodDefs = nil -- godhoodType -> { class, matches = { {param1, points}, ... }, appealMul }
local m_tier1ByDistrict = nil -- districtType -> { buildingIndex, ... }
local m_tier1Replacements = nil -- base buildingType -> { {index, traitType}, ... }
local m_miraclePlayers = {} -- playerID -> true (grant buildings)
local m_devotionPlayers = {} -- playerID -> true (update PROP_CP_DEV_* for exclusive-band SQL)

-- Districts with several prerequisite-free buildings need a deterministic
-- default. Civilization-specific replacements still take priority over these.
local TIER1_DEFAULT_BY_DISTRICT = {
	DISTRICT_CITY_CENTER = "BUILDING_MONUMENT",
	DISTRICT_ENCAMPMENT = "BUILDING_STABLE", -- Mongolia receives the Ordu.
	DISTRICT_NEIGHBORHOOD = "BUILDING_FOOD_MARKET",
}

local function DebugEnabled()
	local v = Game.GetProperty(PROP_DEBUG)
	if v == 0 or v == "0" then
		return false
	end
	return true -- default ON for Dev
end

local function CPLog(...)
	if not DebugEnabled() then
		return
	end
	local parts = { "[CP_Miracles]" }
	for i = 1, select("#", ...) do
		parts[#parts + 1] = tostring(select(i, ...))
	end
	print(table.concat(parts, " "))
end

local function BuildGodhoodDefs()
	if m_godhoodDefs ~= nil then
		return
	end
	m_godhoodDefs = {}
	local rows = DB.Query("SELECT GodhoodType, ghClass, ghParam1, ghParam2, ghParam3 FROM Godhood")
	if rows == nil then
		CPLog("WARN Godhood table empty")
		return
	end
	for _, row in ipairs(rows) do
		local gt = row.GodhoodType
		local def = m_godhoodDefs[gt]
		if def == nil then
			def = { class = row.ghClass, matches = {}, appealMul = 1 }
			if gt == "EARTH_GODDESS" then
				def.appealMul = 2 -- SQL: MinimumAppeal = threshold * 2
			end
			m_godhoodDefs[gt] = def
		end
		if row.ghClass == "APPEAL" then
			-- no match rows
		else
			table.insert(def.matches, {
				param1 = row.ghParam1,
				points = tonumber(row.ghParam2) or 0,
			})
		end
	end
	local n = 0
	for _ in pairs(m_godhoodDefs) do
		n = n + 1
	end
	CPLog("GodhoodDefs loaded", n)
end

local function BuildTier1Map()
	if m_tier1ByDistrict ~= nil then
		return
	end
	m_tier1ByDistrict = {}
	m_tier1Replacements = {}
	local hasPrereq = {}
	for row in GameInfo.BuildingPrereqs() do
		hasPrereq[row.Building] = true
	end
	for row in GameInfo.Buildings() do
		if row.PrereqDistrict ~= nil
			and row.PrereqDistrict ~= "DISTRICT_GOVERNMENT"
			and row.InternalOnly ~= true
			and row.MustPurchase ~= true
			and row.TraitType == nil
			and not hasPrereq[row.BuildingType]
		then
			local d = row.PrereqDistrict
			local dist = GameInfo.Districts[d]
			if dist ~= nil and dist.TraitType == nil then
				m_tier1ByDistrict[d] = m_tier1ByDistrict[d] or {}
				table.insert(m_tier1ByDistrict[d], row.Index)
			end
		end
	end
	-- Every civilization-specific district inherits the tier-1 buildings of the
	-- base district it replaces (Lavra -> Holy Site, Cothon -> Harbor, etc.).
	for row in GameInfo.DistrictReplaces() do
		local baseList = m_tier1ByDistrict[row.ReplacesDistrictType]
		if baseList ~= nil then
			m_tier1ByDistrict[row.CivUniqueDistrictType] = baseList
		end
	end
	-- If a civilization replaces a tier-1 building, grant its unique version.
	for row in GameInfo.BuildingReplaces() do
		local unique = GameInfo.Buildings[row.CivUniqueBuildingType]
		if unique ~= nil and unique.TraitType ~= nil then
			local list = m_tier1Replacements[row.ReplacesBuildingType]
			if list == nil then
				list = {}
				m_tier1Replacements[row.ReplacesBuildingType] = list
			end
			table.insert(list, { index = unique.Index, traitType = unique.TraitType })
		end
	end
	local n = 0
	for _ in pairs(m_tier1ByDistrict) do
		n = n + 1
	end
	CPLog("Tier1 map districts", n)
end

local function MiracleThreshold(godhoodType)
	local def = m_godhoodDefs and m_godhoodDefs[godhoodType]
	if def and def.class == "APPEAL" then
		return DEFAULT_MIRACLE_POINTS * (def.appealMul or 1)
	end
	return DEFAULT_MIRACLE_POINTS
end

local function PlotMatches(plot, match, class)
	if plot == nil or match == nil then
		return false
	end
	if class == "IMPROVEMENT" then
		local info = GameInfo.Improvements[match.param1]
		if info == nil then
			return false
		end
		return plot:GetImprovementType() == info.Index
	elseif class == "FEATURE" then
		local info = GameInfo.Features[match.param1]
		if info == nil then
			return false
		end
		return plot:GetFeatureType() == info.Index
	elseif class == "TERRAIN" then
		local info = GameInfo.Terrains[match.param1]
		if info == nil then
			return false
		end
		return plot:GetTerrainType() == info.Index
	end
	return false
end

-- District devotion comes only from adjacent plots. The district's underlying
-- tile has its separate tile-devotion value and must not feed the district.
local function ComputeDevotion(districtPlot, godhoodType)
	BuildGodhoodDefs()
	local def = m_godhoodDefs[godhoodType]
	if def == nil or districtPlot == nil then
		return 0
	end
	if def.class == "APPEAL" then
		return districtPlot:GetAppeal() or 0
	end
	local total = 0
	local cx, cy = districtPlot:GetX(), districtPlot:GetY()
	local function consider(p)
		if p == nil then
			return
		end
		for _, m in ipairs(def.matches) do
			if PlotMatches(p, m, def.class) then
				total = total + m.points
				break -- one match per tile
			end
		end
	end
	for dir = 0, DirectionTypes.NUM_DIRECTION_TYPES - 1 do
		consider(Map.GetAdjacentPlot(cx, cy, dir))
	end
	return total
end

local function CacheKey(godhoodType)
	return CACHE_KEY_PREFIX .. godhoodType
end

local function GetCachedDevotion(districtPlot, godhoodType)
	return districtPlot:GetProperty(CacheKey(godhoodType))
end

local function SetCachedDevotion(districtPlot, godhoodType, value)
	districtPlot:SetProperty(CacheKey(godhoodType), value)
	-- Mutually exclusive band flags for SQL (Inverse on PropertyMinimum is unreliable —
	-- LO+HI both firing caused (1+1+3)×2=10 admiral GPT).
	local v = value or 0
	districtPlot:SetProperty("PROP_CP_B24_LO_" .. godhoodType, (v >= 2 and v < 4) and 1 or 0)
	districtPlot:SetProperty("PROP_CP_B24_HI_" .. godhoodType, (v >= 4) and 1 or 0)
	districtPlot:SetProperty("PROP_CP_B35_LO_" .. godhoodType, (v >= 3 and v < 5) and 1 or 0)
	districtPlot:SetProperty("PROP_CP_B35_HI_" .. godhoodType, (v >= 5) and 1 or 0)
end

local function Band(score, threshold)
	if score >= threshold then
		return 1
	end
	return 0
end

local function DistrictIsComplete(district)
	if district == nil then
		return false
	end
	if type(district.IsComplete) ~= "function" then
		return true
	end
	local ok, complete = pcall(function()
		return district:IsComplete()
	end)
	return ok and complete == true
end

-- CreateBuilding bypasses the production queue, so Miracle must enforce unlocks itself.
local function PlayerMeetsBuildingUnlock(playerID, buildingRow)
	if buildingRow == nil then
		return false
	end
	local player = Players[playerID]
	if player == nil then
		return false
	end
	if buildingRow.PrereqTech ~= nil then
		local tech = GameInfo.Technologies[buildingRow.PrereqTech]
		local techs = player:GetTechs()
		if tech == nil or techs == nil or not techs:HasTech(tech.Index) then
			return false
		end
	end
	if buildingRow.PrereqCivic ~= nil then
		local civic = GameInfo.Civics[buildingRow.PrereqCivic]
		local culture = player:GetCulture()
		if civic == nil or culture == nil or not culture:HasCivic(civic.Index) then
			return false
		end
	end
	return true
end

local function ResolveTier1Building(playerID, baseIndex)
	local base = GameInfo.Buildings[baseIndex]
	if base == nil or m_tier1Replacements == nil then
		return baseIndex, false
	end
	local replacements = m_tier1Replacements[base.BuildingType]
	if replacements == nil then
		return baseIndex, false
	end
	local utils = ExposedMembers.DA and ExposedMembers.DA.Utils
	if utils ~= nil and type(utils.PlayerHasTrait) == "function" then
		for _, replacement in ipairs(replacements) do
			if utils.PlayerHasTrait(playerID, replacement.traitType) then
				return replacement.index, true
			end
		end
	end
	return baseIndex, false
end

local function ChooseTier1Building(playerID, districtType, list, buildings)
	local candidates = {}
	for _, baseIndex in ipairs(list) do
		local resolvedIndex, isUnique = ResolveTier1Building(playerID, baseIndex)
		local base = GameInfo.Buildings[baseIndex]
		local resolved = GameInfo.Buildings[resolvedIndex]
		if base ~= nil and resolved ~= nil then
			-- Respect a choice the player already made; never add another branch
			-- of Barracks/Stable afterward.
			if buildings:HasBuilding(resolvedIndex) or buildings:HasBuilding(baseIndex) then
				return nil, "already has " .. resolved.BuildingType
			end
			-- Skip locked options (Stable needs Horseback Riding; Barracks needs Bronze Working).
			if not PlayerMeetsBuildingUnlock(playerID, resolved) then
				CPLog("tier1 locked", resolved.BuildingType,
					"tech", tostring(resolved.PrereqTech),
					"civic", tostring(resolved.PrereqCivic))
			else
				table.insert(candidates, {
					index = resolvedIndex,
					baseType = base.BuildingType,
					buildingType = resolved.BuildingType,
					isUnique = isUnique,
					cost = tonumber(resolved.Cost) or 0,
				})
			end
		end
	end
	if #candidates == 0 then
		return nil, "prereq locked"
	end
	table.sort(candidates, function(a, b)
		if a.isUnique ~= b.isUnique then
			return a.isUnique
		end
		if a.cost ~= b.cost then
			return a.cost < b.cost
		end
		return a.buildingType < b.buildingType
	end)
	-- Unlocked unique replacement wins (Ordu once Horseback Riding is known).
	if candidates[1].isUnique then
		return candidates[1].index, "unique"
	end
	-- Encampment: Stable first if unlocked; otherwise Barracks via fallback.
	local preferredType = TIER1_DEFAULT_BY_DISTRICT[districtType]
	if preferredType ~= nil then
		for _, candidate in ipairs(candidates) do
			if candidate.baseType == preferredType then
				return candidate.index, "preset"
			end
		end
	end
	return candidates[1].index, "fallback"
end

-- Divine Spark v16: use hidden city-center buildings only as LO/HI markers.
-- The actual GPP comes from Lavra-style city modifiers in CP_Pantheons.sql.
local function SyncSparkCityMarker(playerID, city, district, godhoodType, score)
	local player = Players[playerID]
	if player == nil or city == nil or district == nil then
		return
	end
	if player:GetProperty(PROP_POWER) ~= SPARK_POWER
		or player:GetProperty(PROP_GODHOOD) ~= godhoodType then
		return
	end
	local dInfo = GameInfo.Districts[district:GetType()]
	if dInfo == nil then
		return
	end
	local suffix = string.gsub(dInfo.DistrictType, "^DISTRICT_", "")
	local lowInfo = GameInfo.Buildings["BUILDING_CP_SPARK_" .. suffix .. "_LO"]
	local highInfo = GameInfo.Buildings["BUILDING_CP_SPARK_" .. suffix .. "_HI"]
	if lowInfo == nil or highInfo == nil then
		-- Districts without a District_GreatPersonPoints row intentionally have no markers.
		return
	end

	local desiredLow = score >= 2 and score < 4
	local desiredHigh = score >= 4
	local buildings = city:GetBuildings()
	local queue = city:GetBuildQueue()
	local function setMarker(info, wanted)
		local has = buildings:HasBuilding(info.Index)
		if wanted and not has then
			queue:CreateBuilding(info.Index)
			CPLog("Spark city marker ADD", "p", playerID, "city", city:GetID(), info.BuildingType)
		elseif not wanted and has then
			buildings:RemoveBuilding(info.Index)
			CPLog("Spark city marker REMOVE", "p", playerID, "city", city:GetID(), info.BuildingType)
		end
	end
	-- Remove the opposite band first, so the two city GPP modifiers never overlap.
	if desiredHigh then
		setMarker(lowInfo, false)
		setMarker(highInfo, true)
	elseif desiredLow then
		setMarker(highInfo, false)
		setMarker(lowInfo, true)
	else
		setMarker(lowInfo, false)
		setMarker(highInfo, false)
	end
end

local function GrantTier1ForDistrict(playerID, city, district)
	BuildTier1Map()
	if city == nil or district == nil then
		return false
	end
	if not DistrictIsComplete(district) then
		CPLog("GRANT blocked; district incomplete")
		return false
	end
	local dInfo = GameInfo.Districts[district:GetType()]
	if dInfo == nil then
		return false
	end
	local list = m_tier1ByDistrict[dInfo.DistrictType]
	if list == nil then
		CPLog("no tier1 for", dInfo.DistrictType)
		return true
	end
	local buildings = city:GetBuildings()
	local queue = city:GetBuildQueue()
	local bIndex, reason = ChooseTier1Building(playerID, dInfo.DistrictType, list, buildings)
	if bIndex == nil then
		CPLog("skip tier1", dInfo.DistrictType, reason)
		-- Keep pending when every option is still locked; clear when already satisfied.
		if reason ~= nil and string.find(reason, "already has", 1, true) == 1 then
			return true
		end
		return false
	end
	local bRow = GameInfo.Buildings[bIndex]
	local bName = bRow and bRow.BuildingType or tostring(bIndex)
	CPLog("GRANT attempt", "player", playerID, "city", city:GetID(),
		"district", dInfo.DistrictType, "building", bName, "rule", reason)
	queue:CreateBuilding(bIndex)
	local granted = buildings:HasBuilding(bIndex)
	CPLog(granted and "GRANT verified" or "GRANT failed; pending retry",
		"player", playerID, "city", city:GetID(), "building", bName)
	return granted
end

local function GodhoodsForPlayer(playerID)
	local player = Players[playerID]
	if player == nil then
		return {}
	end
	if player:GetProperty(PROP_ASUNA) == 1 and player:GetProperty(PROP_POWER) == MIRACLE_POWER then
		BuildGodhoodDefs()
		local all = {}
		for gt, def in pairs(m_godhoodDefs) do
			if def.class == "IMPROVEMENT" or def.class == "FEATURE"
				or def.class == "TERRAIN" or def.class == "APPEAL" then
				table.insert(all, gt)
			end
		end
		return all
	end
	local gh = player:GetProperty(PROP_GODHOOD)
	if gh == nil then
		return {}
	end
	local pw = player:GetProperty(PROP_POWER)
	-- Miracles grants + exclusive-band powers need live PROP_CP_DEV_* on district plots.
	if pw == MIRACLE_POWER or pw == SPARK_POWER or pw == HOUSING_POWER or pw == WINE_POWER
		or player:GetProperty(PROP_DEVOTION) == 1 then
		return { gh }
	end
	if player:GetProperty(PROP_ASUNA) == 1 and player:GetProperty(PROP_ACTIVE) == 1 then
		return { gh }
	end
	return {}
end

local function PlayerHasMiracles(playerID)
	local player = Players[playerID]
	return player ~= nil and player:GetProperty(PROP_ACTIVE) == 1
end

local function PlayerTracksDevotion(playerID)
	local player = Players[playerID]
	if player == nil then
		return false
	end
	if m_devotionPlayers[playerID] then
		return true
	end
	local pw = player:GetProperty(PROP_POWER)
	return player:GetProperty(PROP_DEVOTION) == 1
		or pw == SPARK_POWER
		or pw == HOUSING_POWER
		or pw == WINE_POWER
		or player:GetProperty(PROP_ACTIVE) == 1
end

-- Core C+A: recompute one district for one godhood; grant only after completion.
-- districtReady=false: placement / under construction — cache devotion only.
-- districtReady=true: completed district — sync spark markers and attempt grants.
local function RefreshDistrictGodhood(playerID, city, district, godhoodType, forceGrant, districtReady)
	local plot = Map.GetPlot(district:GetX(), district:GetY())
	if plot == nil then
		return
	end
	if districtReady == nil then
		districtReady = DistrictIsComplete(district)
	end
	local pending = plot:GetProperty(PROP_MIRACLE_PENDING) == 1
	local threshold = MiracleThreshold(godhoodType)
	local oldScore = GetCachedDevotion(plot, godhoodType)
	local newScore = ComputeDevotion(plot, godhoodType)
	local oldBand = (oldScore == nil) and -1 or Band(oldScore, threshold)
	local newBand = Band(newScore, threshold)

	-- Cache hit: still fall through when a pending grant needs a completion retry.
	if oldScore == newScore and oldScore ~= nil and not forceGrant
		and not (pending and districtReady)
	then
		CPLog("cache hit", "p", playerID, "gh", godhoodType,
			"xy", plot:GetX(), plot:GetY(), "dev", newScore, "noop")
		return
	end

	SetCachedDevotion(plot, godhoodType, newScore)
	CPLog("devotion", "p", playerID, "gh", godhoodType,
		"xy", plot:GetX(), plot:GetY(),
		"old", tostring(oldScore), "->", newScore,
		"band", oldBand, "->", newBand, "thr", threshold,
		"ready", districtReady and 1 or 0)

	local dInfo = GameInfo.Districts[district:GetType()]
	local isCityCenter = dInfo ~= nil and dInfo.DistrictType == "DISTRICT_CITY_CENTER"

	-- Incomplete specialty district: never CreateBuilding; mark pending if eligible.
	if not districtReady then
		if PlayerHasMiracles(playerID) and not isCityCenter and newBand == 1 then
			plot:SetProperty(PROP_MIRACLE_PENDING, 1)
			CPLog("district incomplete; grant deferred", "p", playerID,
				"xy", plot:GetX(), plot:GetY(), "dev", newScore)
		else
			plot:SetProperty(PROP_MIRACLE_PENDING, nil)
		end
		return
	end

	SyncSparkCityMarker(playerID, city, district, godhoodType, newScore)

	if not PlayerHasMiracles(playerID) then
		return
	end
	if isCityCenter then
		plot:SetProperty(PROP_MIRACLE_PENDING, nil)
		return
	end
	if newBand ~= 1 then
		plot:SetProperty(PROP_MIRACLE_PENDING, nil)
		if oldBand ~= newBand then
			CPLog("band change no grant", "p", playerID, "oldBand", oldBand, "newBand", newBand)
		end
		return
	end

	-- Grant on threshold cross, completion/load force, or pending retry after failed CreateBuilding.
	if oldBand < 1 or forceGrant or pending then
		CPLog("threshold / complete / pending → grant", "p", playerID, "gh", godhoodType,
			"force", forceGrant and 1 or 0, "pending", pending and 1 or 0)
		local granted = GrantTier1ForDistrict(playerID, city, district)
		plot:SetProperty(PROP_MIRACLE_PENDING, granted and nil or 1)
	else
		CPLog("score change within same band — skipped grant")
	end
end

local function RefreshDistrict(playerID, city, district, forceGrant, districtReady)
	for _, gh in ipairs(GodhoodsForPlayer(playerID)) do
		RefreshDistrictGodhood(playerID, city, district, gh, forceGrant, districtReady)
	end
end

local PROP_MODS_ATTACHED = "PROP_CP_MODS_ATTACHED" -- exact-pair AttachModifier done

local function ModsAlreadyAttached(player)
	if player == nil then
		return false
	end
	local v = player:GetProperty(PROP_MODS_ATTACHED)
	return v == 1 or v == true or tonumber(v) == 1
end

local function MarkModsAttached(player)
	if player ~= nil then
		player:SetProperty(PROP_MODS_ATTACHED, 1)
	end
end

local function ForEachCity(player, fn)
	if player == nil then
		return
	end
	local cities = player:GetCities()
	if cities == nil then
		return
	end
	if type(cities.Members) == "function" then
		for _, city in cities:Members() do
			if city ~= nil then
				fn(city)
			end
		end
		return
	end
	local ok, n = pcall(function()
		return cities:GetCount()
	end)
	if not ok or n == nil then
		return
	end
	for i = 0, n - 1 do
		local city = nil
		if type(cities.GetCityByIndex) == "function" then
			city = cities:GetCityByIndex(i)
		elseif type(cities.FindID) == "function" and type(cities.GetIDAt) == "function" then
			city = cities:FindID(cities:GetIDAt(i))
		end
		if city ~= nil then
			fn(city)
		end
	end
end

-- Gameplay CityDistricts often lacks Members()/GetCount(). Prefer map scan.
local function ResolveCityForDistrict(playerID, district, plot)
	if district ~= nil and type(district.GetCity) == "function" then
		local ok, city = pcall(function()
			return district:GetCity()
		end)
		if ok and city ~= nil then
			return city
		end
	end
	if district ~= nil and type(district.GetCityID) == "function" then
		local ok, cityID = pcall(function()
			return district:GetCityID()
		end)
		if ok and cityID ~= nil then
			local city = CityManager.GetCity(playerID, cityID)
			if city ~= nil then
				return city
			end
		end
	end
	-- Fallback: owning city that contains this plot
	local player = Players[playerID]
	if player == nil then
		return nil
	end
	local found = nil
	ForEachCity(player, function(city)
		if found ~= nil or city == nil then
			return
		end
		local ok, owns = pcall(function()
			return city:GetOwnedPlots() -- may not exist
		end)
		-- Distance-to-center heuristic within working range
		local cx, cy = city:GetX(), city:GetY()
		if plot ~= nil and Map.GetPlotDistance(cx, cy, plot:GetX(), plot:GetY()) <= 3 then
			found = city
		end
	end)
	return found
end

local function IterPlayerDistricts(playerID, fn)
	local player = Players[playerID]
	if player == nil then
		return
	end
	local visited = {}
	for i = 0, Map.GetPlotCount() - 1 do
		local plot = Map.GetPlotByIndex(i)
		if plot ~= nil and plot:GetOwner() == playerID then
			local dtype = plot:GetDistrictType()
			if dtype ~= nil and dtype >= 0 then
				local dInfo = GameInfo.Districts[dtype]
				-- Include city center so housing/wine PROP_CP_DEV_* gates apply there too.
				if dInfo ~= nil and dInfo.DistrictType ~= "DISTRICT_WONDER" then
					local key = plot:GetX() .. "," .. plot:GetY()
					if not visited[key] then
						visited[key] = true
						local district = nil
						if CityManager ~= nil and type(CityManager.GetDistrictAt) == "function" then
							local ok, d = pcall(function()
								return CityManager.GetDistrictAt(plot:GetX(), plot:GetY())
							end)
							if ok then
								district = d
							end
						end
						-- Minimal stand-in if API missing: Refresh only needs GetX/GetY/GetType/IsPillaged
						if district == nil then
							district = {
								GetX = function()
									return plot:GetX()
								end,
								GetY = function()
									return plot:GetY()
								end,
								GetType = function()
									return dtype
								end,
								IsPillaged = function()
									return false
								end,
								IsComplete = function()
									return true
								end,
							}
						end
						local pillaged = false
						if type(district.IsPillaged) == "function" then
							pillaged = district:IsPillaged()
						end
						if not pillaged then
							-- Prefer completed districts only
							local complete = true
							if type(district.IsComplete) == "function" then
								complete = district:IsComplete()
							end
							if complete then
								local city = ResolveCityForDistrict(playerID, district, plot)
								if city ~= nil then
									fn(city, district)
								else
									CPLog("WARN no city for district", dInfo.DistrictType, "xy", plot:GetX(), plot:GetY())
								end
							end
						end
					end
				end
			end
		end
	end
end

local function FullScanPlayer(playerID, reason)
	if not PlayerTracksDevotion(playerID) then
		return
	end
	CPLog("FullScan", "p", playerID, "reason", reason)
	local n = 0
	local ok, err = pcall(function()
		IterPlayerDistricts(playerID, function(city, district)
			n = n + 1
			RefreshDistrict(playerID, city, district, true)
		end)
	end)
	if not ok then
		CPLog("FullScan ERROR", tostring(err))
	else
		CPLog("FullScan done", "p", playerID, "districts", n)
	end
end

local function PlotTouchesDistrict(px, py, district)
	local dx, dy = district:GetX(), district:GetY()
	if px == dx and py == dy then
		return true
	end
	-- ring-1 of district includes this plot?
	for dir = 0, DirectionTypes.NUM_DIRECTION_TYPES - 1 do
		local ap = Map.GetAdjacentPlot(dx, dy, dir)
		if ap ~= nil and ap:GetX() == px and ap:GetY() == py then
			return true
		end
	end
	return false
end

-- A: precise fan-out from changed plot → only nearby districts of devotion-tracked players
local function OnPlotDevotionMaybeChanged(px, py, reason)
	local touched = 0
	for playerID, _ in pairs(m_devotionPlayers) do
		if PlayerTracksDevotion(playerID) then
			IterPlayerDistricts(playerID, function(city, district)
				if PlotTouchesDistrict(px, py, district) then
					touched = touched + 1
					RefreshDistrict(playerID, city, district, false)
				end
			end)
		end
	end
	CPLog("PlotEvent", reason, "xy", px, py, "districtsTouched", touched)
end

local function RegisterMiraclePlayer(playerID, godhoodType, powerType, asuna)
	local player = Players[playerID]
	if player == nil then
		return
	end
	player:SetProperty(PROP_GODHOOD, godhoodType)
	player:SetProperty(PROP_POWER, powerType)
	player:SetProperty(PROP_ASUNA, asuna and 1 or 0)

	-- Exclusive-band powers + miracles gate on PROP_CP_DEV_* (no COLLECTION_COUNT in SQL).
	local wantsDevotion = (powerType == SPARK_POWER)
		or (powerType == HOUSING_POWER)
		or (powerType == WINE_POWER)
		or (powerType == MIRACLE_POWER)
		or (asuna == true)
	if wantsDevotion then
		player:SetProperty(PROP_DEVOTION, 1)
		m_devotionPlayers[playerID] = true
	else
		player:SetProperty(PROP_DEVOTION, 0)
		m_devotionPlayers[playerID] = nil
	end

	-- Miracles engine: power is GOD_OF_MIRACLES, or Asuna (all powers for godhood include miracles).
	local wantsMiracles = (powerType == MIRACLE_POWER) or (asuna == true)
	if not wantsMiracles then
		player:SetProperty(PROP_ACTIVE, 0)
		m_miraclePlayers[playerID] = nil
		CPLog("Register devotion-only", "p", playerID, godhoodType, powerType)
		if wantsDevotion then
			FullScanPlayer(playerID, "devotion_register")
		end
		return
	end

	player:SetProperty(PROP_ACTIVE, 1)
	m_miraclePlayers[playerID] = true
	CPLog("Register ON", "p", playerID, godhoodType, powerType, "asuna", asuna and 1 or 0)
	FullScanPlayer(playerID, "register")
end

-- UI → Gameplay (optional debug)
function OnCP_PantheonActivated(playerID, godhoodType, powerType, asunaFlag)
	CPLog("CP_PantheonActivated", playerID, godhoodType, powerType, asunaFlag)
	BuildGodhoodDefs()
	BuildTier1Map()
	RegisterMiraclePlayer(playerID, godhoodType, powerType, asunaFlag == 1 or asunaFlag == true)
end

GameEvents.CP_PantheonActivated.Add(OnCP_PantheonActivated)

-- Asuna: exact pair is attached above; extra OR-set modifiers attach here.
-- Skip exact pair + GOD_OF_MIRACLES (event path).
local function ApplyAsunaExtras(playerID, godhoodType, powerType)
	local Utils = ExposedMembers.DA and ExposedMembers.DA.Utils
	if Utils == nil or not Utils.PlayerHasTrait(playerID, "TRAIT_LEADER_QGG_ASUNA_DESCENDEDGODDESSOFCREATION") then
		return
	end
	local player = Players[playerID]
	if player == nil then
		return
	end
	local results = DB.Query("SELECT * FROM PantheonModifiers")
	if results == nil then
		return
	end
	local n = 0
	for _, row in ipairs(results) do
		if row.PowerType ~= MIRACLE_POWER then
			local samePair = (row.GodhoodType == godhoodType and row.PowerType == powerType)
			local orMatch = (row.GodhoodType == godhoodType or row.PowerType == powerType)
			if orMatch and not samePair then
				player:AttachModifierByID(row.ModifierId)
				n = n + 1
			end
		end
	end
	CPLog("Asuna extras attached", "p", playerID, "count", n)
end

-- Exact Godhood×Power modifiers via AttachModifier (original CP apply path).
-- Divine Spark uses Lavra-style city GPP gated by mutually exclusive marker buildings.
local function AttachExactPairModifiers(playerID, godhoodType, powerType)
	if powerType == MIRACLE_POWER then
		return 0
	end
	local player = Players[playerID]
	if player == nil then
		return 0
	end
	local results = DB.Query(
		"SELECT ModifierId FROM PantheonModifiers WHERE GodhoodType = '"
			.. godhoodType
			.. "' AND PowerType = '"
			.. powerType
			.. "'"
	)
	local n = 0
	if results ~= nil then
		for _, row in ipairs(results) do
			player:AttachModifierByID(row.ModifierId)
			n = n + 1
		end
	end
	CPLog("AttachExactPair", "p", playerID, godhoodType, powerType, "count", n)
	if powerType == SPARK_POWER and n > 0 then
		local sample = DB.Query(
			"SELECT ModifierId, ModifierType, SubjectRequirementSetId FROM Modifiers WHERE ModifierId LIKE 'CPCS_HARBOR_%'"
		)
		if sample ~= nil then
			for _, row in ipairs(sample) do
				CPLog("DS sample", row.ModifierId, row.ModifierType, tostring(row.SubjectRequirementSetId))
			end
		end
	end
	return n
end

-- Authoritative: after FoundPantheon.
local function LogSeaDivineSparkProbe(playerID, godhoodType)
	if godhoodType ~= "GOD_OF_THE_SEA" then
		return
	end
	BuildGodhoodDefs()
	local fish = GameInfo.Improvements["IMPROVEMENT_FISHING_BOATS"]
	local fishIdx = fish and fish.Index or -1
	local holy = GameInfo.Districts["DISTRICT_HOLY_SITE"]
	local holyIdx = holy and holy.Index or -1
	local harbor = GameInfo.Districts["DISTRICT_HARBOR"]
	local harborIdx = harbor and harbor.Index or -1
	local dockyard = GameInfo.Districts["DISTRICT_ROYAL_NAVY_DOCKYARD"]
	local dockIdx = dockyard and dockyard.Index or -1

	local function countAdjBoats(plot)
		local boats = 0
		local function countBoat(p)
			if p ~= nil and p:GetImprovementType() == fishIdx then
				boats = boats + 1
			end
		end
		countBoat(plot)
		for dir = 0, DirectionTypes.NUM_DIRECTION_TYPES - 1 do
			countBoat(Map.GetAdjacentPlot(plot:GetX(), plot:GetY(), dir))
		end
		return boats
	end

	local foundHarbor = 0
	local foundHoly = 0
	for i = 0, Map.GetPlotCount() - 1 do
		local plot = Map.GetPlotByIndex(i)
		if plot ~= nil and plot:GetOwner() == playerID then
			local dType = plot:GetDistrictType()
			if harborIdx >= 0 and (dType == harborIdx or (dockIdx >= 0 and dType == dockIdx)) then
				foundHarbor = foundHarbor + 1
				local boats = countAdjBoats(plot)
				local dev = ComputeDevotion(plot, godhoodType)
				local spark = 0
				if dev >= 2 then
					spark = spark + 1
				end
				if dev >= 4 then
					spark = spark + 2
				end
				CPLog(
					"PROBE Harbor",
					"xy",
					plot:GetX(),
					plot:GetY(),
					"adjBoats",
					boats,
					"devotion",
					dev,
					"expectAdmiral",
					1 + spark,
					"(base1+citySpark",
					spark,
					") Lavra-style LO/HI"
				)
			elseif holyIdx >= 0 and dType == holyIdx then
				foundHoly = foundHoly + 1
				local boats = countAdjBoats(plot)
				local dev = ComputeDevotion(plot, godhoodType)
				CPLog(
					"PROBE HolySite",
					"xy",
					plot:GetX(),
					plot:GetY(),
					"adjFishingBoats",
					boats,
					"devotion",
					dev,
					"need>=2 for +1 Prophet GPT (1 boat=3)"
				)
			end
		end
	end
	if foundHarbor == 0 then
		CPLog("PROBE Harbor none yet", "p", playerID)
	end
	if foundHoly == 0 then
		CPLog("PROBE HolySite none yet", "p", playerID)
	end
end

local function ApplyComboPantheonEffects(playerID, force)
	local player = Players[playerID]
	if player == nil then
		return
	end
	local already = ModsAlreadyAttached(player)
	-- Never re-AttachModifier (stacks). force only re-runs miracles/Asuna register.
	if already and not force then
		return
	end

	local pReligion = player:GetReligion()
	if pReligion == nil then
		return
	end
	local iPantheon = pReligion:GetPantheon()
	if iPantheon == nil or iPantheon == -1 then
		return
	end
	local beliefInfo = GameInfo.Beliefs[iPantheon]
	if beliefInfo == nil then
		return
	end
	local godhoodType, powerType = beliefInfo.BeliefType:match("^BELIEF_(.+)_WITH_(.+)$")
	if godhoodType == nil then
		player:SetProperty("PROP_PANTHEON_ACTIVATED", 1)
		MarkModsAttached(player)
		CPLog("ApplyCombo non-combo belief", beliefInfo.BeliefType)
		return
	end

	local Utils = ExposedMembers.DA and ExposedMembers.DA.Utils
	local isAsuna = Utils ~= nil
		and Utils.PlayerHasTrait(playerID, "TRAIT_LEADER_QGG_ASUNA_DESCENDEDGODDESSOFCREATION")

	CPLog("ApplyCombo", "p", playerID, godhoodType, powerType, "asuna", isAsuna and 1 or 0, "force", force and 1 or 0, "already", already and 1 or 0)
	if not already then
		AttachExactPairModifiers(playerID, godhoodType, powerType)
		MarkModsAttached(player)
	else
		CPLog("AttachExactPair skip (already attached)", "p", playerID)
	end
	local okProbe, errProbe = pcall(function()
		if powerType == "DIVINE_SPARK" then
			LogSeaDivineSparkProbe(playerID, godhoodType)
		end
	end)
	if not okProbe then
		CPLog("PROBE error", tostring(errProbe))
	end
	if not already then
		ApplyAsunaExtras(playerID, godhoodType, powerType)
	end
	BuildGodhoodDefs()
	BuildTier1Map()
	local okReg, errReg = pcall(function()
		RegisterMiraclePlayer(playerID, godhoodType, powerType, isAsuna)
	end)
	if not okReg then
		CPLog("RegisterMiraclePlayer ERROR", tostring(errReg))
	end
	player:SetProperty("PROP_PANTHEON_ACTIVATED", 1)
	MarkModsAttached(player)
end

local function OnPantheonFounded(playerID)
	ApplyComboPantheonEffects(playerID, false)
end

Events.PantheonFounded.Add(OnPantheonFounded)

-- Mid-game / hybrid-era saves: re-attach if flag missing (BeliefModifiers path was a no-op).
local function EnsureAllComboModifiers()
	for _, player in ipairs(PlayerManager.GetAliveMajors()) do
		local pid = player:GetID()
		local pr = player:GetReligion()
		if pr ~= nil then
			local pan = pr:GetPantheon()
			if pan ~= nil and pan >= 0 and GameInfo.Beliefs[pan] then
				local bt = GameInfo.Beliefs[pan].BeliefType
				if bt:match("^BELIEF_.+_WITH_.+$") then
					if not ModsAlreadyAttached(player) then
						CPLog("LoadEnsure attach missing mods", "p", pid, bt)
						ApplyComboPantheonEffects(pid, true)
					else
						local gh, pw = bt:match("^BELIEF_(.+)_WITH_(.+)$")
						if pw == "DIVINE_SPARK" then
							pcall(function()
								LogSeaDivineSparkProbe(pid, gh)
							end)
						end
					end
				end
			end
		end
	end
end

-- Map events (A)
function OnImprovementChanged(iX, iY, eImprovement, playerIndex)
	OnPlotDevotionMaybeChanged(iX, iY, "Improvement")
end

Events.ImprovementAddedToMap.Add(OnImprovementChanged)
Events.ImprovementRemovedFromMap.Add(OnImprovementChanged)

-- Feature chops (forest/jungle/marsh) also change devotion for FEATURE godhoods
local function OnFeatureChanged(iX, iY, eFeature)
	OnPlotDevotionMaybeChanged(iX, iY, "Feature")
end
if Events.FeatureAddedToMap then
	Events.FeatureAddedToMap.Add(OnFeatureChanged)
end
if Events.FeatureRemovedFromMap then
	Events.FeatureRemovedFromMap.Add(OnFeatureChanged)
end

local function ResolveDistrictForEvent(playerID, districtID, cityID, districtX, districtY)
	local city = CityManager.GetCity(playerID, cityID)
	if city == nil then
		return nil, nil
	end
	local district = nil
	local districts = city:GetDistricts()
	if districts ~= nil and type(districts.FindID) == "function" then
		district = districts:FindID(districtID)
	end
	if district == nil and CityManager ~= nil and type(CityManager.GetDistrictAt) == "function" then
		local ok, d = pcall(function()
			return CityManager.GetDistrictAt(districtX, districtY)
		end)
		if ok then
			district = d
		end
	end
	return city, district
end

-- Placement: cache devotion only. Do not grant until the district is complete.
function OnDistrictAdded(playerID, districtID, cityID, districtX, districtY)
	if not PlayerTracksDevotion(playerID) then
		return
	end
	local city, district = ResolveDistrictForEvent(playerID, districtID, cityID, districtX, districtY)
	if district ~= nil then
		local ready = DistrictIsComplete(district)
		CPLog("DistrictAdded", "p", playerID, "xy", districtX, districtY, "ready", ready and 1 or 0)
		-- Incomplete: forceGrant=false, districtReady=false → cache + pending only.
		-- Already complete (instant / repaired): force grant after recompute.
		RefreshDistrict(playerID, city, district, ready, ready)
	else
		CPLog("DistrictAdded unresolved", "p", playerID, "xy", districtX, districtY, "→ FullScan")
		FullScanPlayer(playerID, "district_added_fallback")
	end
end

-- Completion: recompute adjacent devotion, then grant if the threshold is met.
function OnDistrictBuildProgressChanged(playerID, districtID, cityID, districtX, districtY,
	districtType, era, civilization, percentComplete, appeal, isPillaged)
	if not PlayerTracksDevotion(playerID) then
		return
	end
	local city, district = ResolveDistrictForEvent(playerID, districtID, cityID, districtX, districtY)
	if district == nil then
		return
	end
	local ready = DistrictIsComplete(district)
		or (percentComplete ~= nil and tonumber(percentComplete) ~= nil and tonumber(percentComplete) >= 100)
	if not ready then
		return
	end
	CPLog("DistrictComplete", "p", playerID, "xy", districtX, districtY,
		"pct", tostring(percentComplete))
	RefreshDistrict(playerID, city, district, true, true)
end

Events.DistrictAddedToMap.Add(OnDistrictAdded)
if Events.DistrictBuildProgressChanged then
	Events.DistrictBuildProgressChanged.Add(OnDistrictBuildProgressChanged)
end

-- Retry Miracle grants when a tech/civic unlocks a previously locked tier-1 (e.g. Barracks → Stable).
local function OnUnlockMaybeRetryMiracle(playerID, reason)
	if not PlayerHasMiracles(playerID) then
		return
	end
	FullScanPlayer(playerID, reason)
end

if Events.ResearchCompleted then
	Events.ResearchCompleted.Add(function(playerID, techIndex)
		OnUnlockMaybeRetryMiracle(playerID, "tech")
	end)
end
if Events.CivicCompleted then
	Events.CivicCompleted.Add(function(playerID, civicIndex)
		OnUnlockMaybeRetryMiracle(playerID, "civic")
	end)
end

local function RescanAllMiraclePlayers(reason)
	BuildGodhoodDefs()
	BuildTier1Map()
	m_miraclePlayers = {}
	m_devotionPlayers = {}
	for _, player in ipairs(PlayerManager.GetAliveMajors()) do
		local pid = player:GetID()
		local pw = player:GetProperty(PROP_POWER)
		local asuna = player:GetProperty(PROP_ASUNA) == 1
		if player:GetProperty(PROP_ACTIVE) == 1 or pw == MIRACLE_POWER or asuna then
			-- Miracles (and Asuna) need grant + devotion rescan.
			player:SetProperty(PROP_ACTIVE, 1)
			player:SetProperty(PROP_DEVOTION, 1)
			m_miraclePlayers[pid] = true
			m_devotionPlayers[pid] = true
			FullScanPlayer(pid, reason)
		elseif pw == SPARK_POWER or pw == HOUSING_POWER or pw == WINE_POWER
			or player:GetProperty(PROP_DEVOTION) == 1
		then
			-- Divine Spark / Religious Settlements / God of Wine: rewrite band flags only.
			m_devotionPlayers[pid] = true
			player:SetProperty(PROP_DEVOTION, 1)
			FullScanPlayer(pid, reason .. "_devotion")
		end
	end
end

Events.LoadGameViewStateDone.Add(function()
	CPLog("LoadGameViewStateDone")
	EnsureAllComboModifiers()
	RescanAllMiraclePlayers("load")
end)

CPLog("script loaded (event+cache). Debug default ON; Game.SetProperty('" .. PROP_DEBUG .. "', 0) to silence.")
