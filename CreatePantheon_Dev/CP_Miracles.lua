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

-- Default thresholds (devotion points). EARTH uses appeal with *2 in original SQL.
local DEFAULT_MIRACLE_POINTS = 6

local m_godhoodDefs = nil -- godhoodType -> { class, matches = { {param1, points}, ... }, appealMul }
local m_tier1ByDistrict = nil -- districtType -> { buildingIndex, ... }
local m_miraclePlayers = {} -- playerID -> true (grant buildings)
local m_devotionPlayers = {} -- playerID -> true (update PROP_CP_DEV_* for exclusive-band SQL)

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
	local hasPrereq = {}
	for row in GameInfo.BuildingPrereqs() do
		hasPrereq[row.Building] = true
	end
	for row in GameInfo.Buildings() do
		if row.PrereqDistrict ~= nil
			and row.InternalOnly ~= true
			and row.MustPurchase ~= true
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

-- Devotion score for one godhood at a district plot (ring 0..1), matching SQL WITHIN_1 semantics.
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
	consider(districtPlot)
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

local function GrantTier1ForDistrict(playerID, city, district)
	BuildTier1Map()
	if city == nil or district == nil then
		return
	end
	local dInfo = GameInfo.Districts[district:GetType()]
	if dInfo == nil then
		return
	end
	local list = m_tier1ByDistrict[dInfo.DistrictType]
	if list == nil then
		CPLog("no tier1 for", dInfo.DistrictType)
		return
	end
	local buildings = city:GetBuildings()
	local queue = city:GetBuildQueue()
	for _, bIndex in ipairs(list) do
		local bRow = GameInfo.Buildings[bIndex]
		local bName = bRow and bRow.BuildingType or tostring(bIndex)
		if not buildings:HasBuilding(bIndex) then
			CPLog("GRANT", "player", playerID, "city", city:GetID(),
				"district", dInfo.DistrictType, "building", bName)
			queue:CreateBuilding(bIndex)
		else
			CPLog("skip already has", bName)
		end
	end
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

-- Core C+A: recompute one district for one godhood; grant only on band cross or forceGrant
local function RefreshDistrictGodhood(playerID, city, district, godhoodType, forceGrant)
	local plot = Map.GetPlot(district:GetX(), district:GetY())
	if plot == nil then
		return
	end
	local threshold = MiracleThreshold(godhoodType)
	local oldScore = GetCachedDevotion(plot, godhoodType)
	local newScore = ComputeDevotion(plot, godhoodType)
	local oldBand = (oldScore == nil) and -1 or Band(oldScore, threshold)
	local newBand = Band(newScore, threshold)

	-- C: only cache when score changes; spark still needs property even on first write.
	-- When oldScore is nil (never cached), always write.
	if oldScore == newScore and oldScore ~= nil and not forceGrant then
		CPLog("cache hit", "p", playerID, "gh", godhoodType,
			"xy", plot:GetX(), plot:GetY(), "dev", newScore, "noop")
		return
	end

	SetCachedDevotion(plot, godhoodType, newScore)
	CPLog("devotion", "p", playerID, "gh", godhoodType,
		"xy", plot:GetX(), plot:GetY(),
		"old", tostring(oldScore), "->", newScore,
		"band", oldBand, "->", newBand, "thr", threshold)

	-- Building grants only for God of Miracles; housing/wine/spark only need the property.
	if not PlayerHasMiracles(playerID) then
		return
	end

	-- City center: write PROP_CP_DEV_* for housing/wine, but never grant miracle buildings.
	local dInfo = GameInfo.Districts[district:GetType()]
	if dInfo ~= nil and dInfo.DistrictType == "DISTRICT_CITY_CENTER" then
		return
	end

	-- C: only meaningful when crossing into active band, or forced (new district / load)
	if newBand == 1 and (oldBand < 1 or forceGrant) then
		CPLog("threshold crossed / force → grant", "p", playerID, "gh", godhoodType)
		GrantTier1ForDistrict(playerID, city, district)
	elseif oldBand ~= newBand then
		CPLog("band change no grant", "p", playerID, "oldBand", oldBand, "newBand", newBand)
	else
		CPLog("score change within same band — skipped grant")
	end
end

local function RefreshDistrict(playerID, city, district, forceGrant)
	for _, gh in ipairs(GodhoodsForPlayer(playerID)) do
		RefreshDistrictGodhood(playerID, city, district, gh, forceGrant)
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
-- Divine Spark uses mutually exclusive LO/HI SQL bands (never two GPP mods at once).
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
			"SELECT ModifierId, ModifierType, SubjectRequirementSetId FROM Modifiers WHERE ModifierId LIKE 'CPDS_"
				.. godhoodType
				.. "_DISTRICT_HARBOR%'"
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
					"(base1+sqlSpark",
					spark,
					") LO/HI exclusive"
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

function OnDistrictAdded(playerID, districtID, cityID, districtX, districtY)
	if not PlayerTracksDevotion(playerID) then
		return
	end
	local city = CityManager.GetCity(playerID, cityID)
	if city == nil then
		return
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
	if district ~= nil then
		CPLog("DistrictAdded", "p", playerID, "xy", districtX, districtY)
		RefreshDistrict(playerID, city, district, true)
	else
		CPLog("DistrictAdded unresolved", "p", playerID, "xy", districtX, districtY, "→ FullScan")
		FullScanPlayer(playerID, "district_added_fallback")
	end
end

Events.DistrictAddedToMap.Add(OnDistrictAdded)

local function RescanAllMiraclePlayers(reason)
	BuildGodhoodDefs()
	BuildTier1Map()
	m_miraclePlayers = {}
	m_devotionPlayers = {}
	for _, player in ipairs(PlayerManager.GetAliveMajors()) do
		local pid = player:GetID()
		local pw = player:GetProperty(PROP_POWER)
		if player:GetProperty(PROP_ACTIVE) == 1 then
			m_miraclePlayers[pid] = true
			m_devotionPlayers[pid] = true
			player:SetProperty(PROP_DEVOTION, 1)
			FullScanPlayer(pid, reason)
		elseif pw == SPARK_POWER then
			m_devotionPlayers[pid] = true
			player:SetProperty(PROP_DEVOTION, 1)
			FullScanPlayer(pid, reason .. "_spark")
		elseif pw == MIRACLE_POWER
			or (player:GetProperty(PROP_ASUNA) == 1 and player:GetProperty(PROP_GODHOOD) ~= nil) then
			if pw == MIRACLE_POWER or player:GetProperty(PROP_ASUNA) == 1 then
				player:SetProperty(PROP_ACTIVE, 1)
				player:SetProperty(PROP_DEVOTION, 1)
				m_miraclePlayers[pid] = true
				m_devotionPlayers[pid] = true
				FullScanPlayer(pid, reason .. "_recover")
			end
		end
	end
end

Events.LoadGameViewStateDone.Add(function()
	CPLog("LoadGameViewStateDone")
	EnsureAllComboModifiers()
	RescanAllMiraclePlayers("load")
end)

CPLog("script loaded (event+cache). Debug default ON; Game.SetProperty('" .. PROP_DEBUG .. "', 0) to silence.")
