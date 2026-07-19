
GameEvents = ExposedMembers.GameEvents
Utils = ExposedMembers.DA and ExposedMembers.DA.Utils

-- Weighted pantheon AI: terrain/resource fit + downweight God of Miracles.
-- Draw only from Top-K by score (default 8) to avoid long-tail mismatch picks.
-- Civ6 Lua has no goto — do not use ::labels:: (CP_AI failed to load with them).
-- Logs: [CP_AI] in Lua.log. Game.SetProperty('PROP_CP_AI_DEBUG', 0) to silence.

local MIRACLE_POWER = "GOD_OF_MIRACLES"
local MIRACLE_WEIGHT = 0.08
local BASE_WEIGHT = 1.0
local TOP_N_LOG = 8
-- Weighted draw only among the K highest-scoring combos (kills rank-130 long-tail picks).
local TOP_K = 8
local PROP_DEBUG = "PROP_CP_AI_DEBUG"
-- Cap how much one terrain/resource signal can boost a godhood (avoids polar Aurora wipeouts).
local TERRAIN_BONUS_CAP = 3.5
local RESOURCE_BONUS_CAP = 3.0

local function DebugEnabled()
	local v = Game.GetProperty(PROP_DEBUG)
	if v == 0 or v == "0" then
		return false
	end
	return true
end

local function CPAILog(...)
	if not DebugEnabled() then
		return
	end
	local parts = { "[CP_AI]" }
	for i = 1, select("#", ...) do
		parts[#parts + 1] = tostring(select(i, ...))
	end
	print(table.concat(parts, " "))
end

local function DistinctColumn(rows, key)
	local out = {}
	local seen = {}
	if rows == nil then
		return out
	end
	for _, row in ipairs(rows) do
		local v = row[key]
		if v ~= nil and not seen[v] then
			seen[v] = true
			out[#out + 1] = v
		end
	end
	return out
end

local function AnalyzePlayerMap(playerID)
	local s = {
		plots = 0,
		coast = 0,
		desert = 0,
		tundra = 0,
		jungle = 0,
		forest = 0,
		marsh = 0,
		flood = 0,
		geo = 0,
		fishRes = 0,
		quarryRes = 0,
		pastureRes = 0,
		campRes = 0,
		plantRes = 0,
		mineRes = 0,
		cities = 0,
	}
	local player = Players[playerID]
	if player == nil then
		return s
	end
	s.cities = player:GetCities():GetCount()

	local fishBoat = GameInfo.Improvements["IMPROVEMENT_FISHING_BOATS"]
	local fishBoatIdx = fishBoat and fishBoat.Index or -1

	for i = 0, Map.GetPlotCount() - 1 do
		local plot = Map.GetPlotByIndex(i)
		if plot ~= nil and plot:GetOwner() == playerID then
			s.plots = s.plots + 1
			local t = plot:GetTerrainType()
			local f = plot:GetFeatureType()
			local r = plot:GetResourceType()
			local imp = plot:GetImprovementType()

			if plot:IsCoastalLand() or plot:IsWater() then
				s.coast = s.coast + 1
			end

			local terr = t >= 0 and GameInfo.Terrains[t] or nil
			if terr then
				local tt = terr.TerrainType
				if tt == "TERRAIN_DESERT" or tt == "TERRAIN_DESERT_HILLS" or tt == "TERRAIN_DESERT_MOUNTAIN" then
					s.desert = s.desert + 1
				elseif tt == "TERRAIN_TUNDRA" or tt == "TERRAIN_TUNDRA_HILLS" or tt == "TERRAIN_TUNDRA_MOUNTAIN" then
					s.tundra = s.tundra + 1
				end
			end

			local feat = f >= 0 and GameInfo.Features[f] or nil
			if feat then
				local ft = feat.FeatureType
				if ft == "FEATURE_JUNGLE" then
					s.jungle = s.jungle + 1
				elseif ft == "FEATURE_FOREST" then
					s.forest = s.forest + 1
				elseif ft == "FEATURE_MARSH" then
					s.marsh = s.marsh + 1
				elseif ft == "FEATURE_FLOODPLAINS" or ft == "FEATURE_FLOODPLAINS_GRASSLAND"
					or ft == "FEATURE_FLOODPLAINS_PLAINS" or ft == "FEATURE_FLOODPLAINS_DESERT" then
					s.flood = s.flood + 1
				elseif ft == "FEATURE_GEOTHERMAL_FISSURE" or ft == "FEATURE_VOLCANIC_SOIL" then
					s.geo = s.geo + 1
				elseif ft == "FEATURE_OASIS" then
					s.marsh = s.marsh + 1
				end
			end

			if imp == fishBoatIdx then
				s.fishRes = s.fishRes + 2
			end

			local res = r >= 0 and GameInfo.Resources[r] or nil
			if res then
				local rt = res.ResourceType
				if rt == "RESOURCE_FISH" or rt == "RESOURCE_CRABS" or rt == "RESOURCE_WHALES"
					or rt == "RESOURCE_PEARLS" or rt == "RESOURCE_TURTLES" then
					s.fishRes = s.fishRes + 1
					s.coast = s.coast + 1
				elseif rt == "RESOURCE_STONE" or rt == "RESOURCE_MARBLE" or rt == "RESOURCE_GYPSUM"
					or rt == "RESOURCE_DIAMONDS" then
					s.quarryRes = s.quarryRes + 1
				elseif rt == "RESOURCE_CATTLE" or rt == "RESOURCE_SHEEP" or rt == "RESOURCE_HORSES" then
					s.pastureRes = s.pastureRes + 1
				elseif rt == "RESOURCE_DEER" or rt == "RESOURCE_FURS" or rt == "RESOURCE_IVORY"
					or rt == "RESOURCE_TRUFFLES" then
					s.campRes = s.campRes + 1
				elseif rt == "RESOURCE_BANANAS" or rt == "RESOURCE_CITRUS" or rt == "RESOURCE_COFFEE"
					or rt == "RESOURCE_COTTON" or rt == "RESOURCE_COCOA" or rt == "RESOURCE_DYES"
					or rt == "RESOURCE_INCENSE" or rt == "RESOURCE_SILK" or rt == "RESOURCE_SPICES"
					or rt == "RESOURCE_SUGAR" or rt == "RESOURCE_TEA" or rt == "RESOURCE_TOBACCO"
					or rt == "RESOURCE_WINE" or rt == "RESOURCE_OLIVES" then
					s.plantRes = s.plantRes + 1
				elseif rt == "RESOURCE_IRON" or rt == "RESOURCE_NITER" or rt == "RESOURCE_COAL"
					or rt == "RESOURCE_ALUMINUM" or rt == "RESOURCE_URANIUM" or rt == "RESOURCE_COPPER"
					or rt == "RESOURCE_SILVER" or rt == "RESOURCE_GOLD" or rt == "RESOURCE_MERCURY"
					or rt == "RESOURCE_JADE" or rt == "RESOURCE_AMBER" or rt == "RESOURCE_SALT" then
					s.mineRes = s.mineRes + 1
				end
			end
		end
	end
	return s
end

-- Diminishing bonus from a raw count (share of empire plots when plots>0).
local function FitBonus(count, plots, perTile, cap)
	if count == nil or count <= 0 then
		return 0
	end
	local linear = count * perTile
	if plots ~= nil and plots > 0 then
		-- Mix absolute signal with share so huge polar empires don't explode.
		local share = count / plots
		linear = (count * perTile * 0.35) + (share * 4.0)
	end
	if linear > cap then
		return cap
	end
	return linear
end

local function ScoreGodhood(gh, s)
	local w = BASE_WEIGHT
	local plots = s.plots
	if gh == "GOD_OF_THE_SEA" then
		local fit = s.coast + s.fishRes
		if fit == 0 then
			w = 0.2
		else
			w = w + FitBonus(s.coast, plots, 0.25, TERRAIN_BONUS_CAP)
			w = w + FitBonus(s.fishRes, plots, 0.5, RESOURCE_BONUS_CAP)
		end
	elseif gh == "DESERT_FOLKLORE" then
		w = (s.desert == 0) and 0.2 or (w + FitBonus(s.desert, plots, 0.35, TERRAIN_BONUS_CAP))
	elseif gh == "DANCE_OF_THE_AURORA" then
		w = (s.tundra == 0) and 0.2 or (w + FitBonus(s.tundra, plots, 0.35, TERRAIN_BONUS_CAP))
	elseif gh == "SACRED_PATH" then
		w = (s.jungle == 0) and 0.25 or (w + FitBonus(s.jungle, plots, 0.35, TERRAIN_BONUS_CAP))
	elseif gh == "ORAL_TRADITION" then
		w = (s.forest == 0) and 0.25 or (w + FitBonus(s.forest, plots, 0.3, TERRAIN_BONUS_CAP))
	elseif gh == "GODDESS_OF_FIRE" then
		w = (s.geo == 0) and 0.2 or (w + FitBonus(s.geo, plots, 1.2, RESOURCE_BONUS_CAP))
	elseif gh == "LADY_OF_THE_REEDS_AND_MARSHES" then
		local fit = s.marsh + s.flood
		w = (fit == 0) and 0.25
			or (w + FitBonus(s.marsh, plots, 0.45, TERRAIN_BONUS_CAP) + FitBonus(s.flood, plots, 0.35, TERRAIN_BONUS_CAP))
	elseif gh == "STONE_CIRCLES" then
		w = (s.quarryRes == 0) and 0.3 or (w + FitBonus(s.quarryRes, plots, 0.9, RESOURCE_BONUS_CAP))
	elseif gh == "GOD_OF_THE_OPEN_SKY" then
		w = (s.pastureRes == 0) and 0.3 or (w + FitBonus(s.pastureRes, plots, 0.9, RESOURCE_BONUS_CAP))
	elseif gh == "GODDESS_OF_THE_HUNT" then
		w = (s.campRes == 0) and 0.3 or (w + FitBonus(s.campRes, plots, 0.9, RESOURCE_BONUS_CAP))
	elseif gh == "GODDESS_OF_FESTIVALS" then
		w = (s.plantRes == 0) and 0.3 or (w + FitBonus(s.plantRes, plots, 0.9, RESOURCE_BONUS_CAP))
	elseif gh == "RELIGIOUS_IDOLS" then
		w = (s.mineRes == 0) and 0.35 or (w + FitBonus(s.mineRes, plots, 0.7, RESOURCE_BONUS_CAP))
	elseif gh == "EARTH_GODDESS" or gh == "GOD_OF_BEAUTY" then
		w = w + 0.8
	end
	if w < 0.1 then
		w = 0.1
	end
	return w
end

local function ScorePower(pw, s)
	local w = BASE_WEIGHT
	if pw == MIRACLE_POWER then
		return MIRACLE_WEIGHT
	elseif pw == "DIVINE_SPARK" then
		w = w + 1.2
	elseif pw == "RELIGIOUS_SETTLEMENTS" then
		-- Was +1.5 early → 2.50, highest of all powers; × godhood filled Top-K with 家神.
		-- Keep a mild early expansion nudge, but below Divine Spark (2.2) and ≈ craftsmen (2.0).
		w = w + (s.cities <= 2 and 0.85 or 0.45)
	elseif pw == "CITY_PATRON_GODDESS" then
		w = w + (s.cities <= 3 and 1.0 or 0.5)
	elseif pw == "GOD_OF_CRAFTSMEN" or pw == "SHENNONG" or pw == "GGV" then
		w = w + 1.0
	elseif pw == "FERTILITY_RITES" or pw == "INITIATION_RITES" then
		w = w + 0.7
	elseif pw == "MONUMENT_TO_THE_GODS" then
		w = w + 0.6
	elseif pw == "GOD_OF_WINE" then
		w = w + 0.5
	end
	if w < 0.1 then
		w = 0.1
	end
	return w
end

-- Soft penalty if other majors already took this power (prevents all-AI 家神).
local function PowerDiversityMul(powerType, gReligion)
	local used = 0
	for _, player in ipairs(PlayerManager.GetAliveMajors()) do
		local pr = player:GetReligion()
		if pr ~= nil then
			local pan = pr:GetPantheon()
			if pan ~= nil and pan >= 0 and GameInfo.Beliefs[pan] then
				local bt = GameInfo.Beliefs[pan].BeliefType
				local pw = bt:match("_WITH_(.+)$")
				if pw == powerType then
					used = used + 1
				end
			end
		end
	end
	if used <= 0 then
		return 1.0
	end
	-- 1 taken → 0.4, 2 → ~0.25, still allow duplicates if terrain strongly prefers it
	return 1.0 / (1.0 + used * 1.5)
end

-- Soft penalty if other majors already founded a pantheon with this godhood.
-- Hard floor: once a godhood is taken, exclude from Top-K candidates (mul → 0).
-- (Engine Aurora stacking is blocked separately via BELIEF_CLASS_CP_COMBO.)
local function GodhoodDiversityMul(godhoodType, gReligion)
	local used = 0
	for _, player in ipairs(PlayerManager.GetAliveMajors()) do
		local pr = player:GetReligion()
		if pr ~= nil then
			local pan = pr:GetPantheon()
			if pan ~= nil and pan >= 0 and GameInfo.Beliefs[pan] then
				local bt = GameInfo.Beliefs[pan].BeliefType
				local gh = bt:match("^BELIEF_(.+)_WITH_")
				if gh == godhoodType then
					used = used + 1
				end
			end
		end
	end
	if used <= 0 then
		return 1.0
	end
	-- Already taken: keep out of Top-K (engine was stacking Aurora copies).
	return 0
end

local function PlayerIsAI(playerID)
	local player = Players[playerID]
	if player == nil then
		return false
	end
	-- Prefer live ExposedMembers (UI may patch later); never require Utils at file-load time.
	local u = ExposedMembers.DA and ExposedMembers.DA.Utils
	if u ~= nil and type(u.IsAI) == "function" then
		return u.IsAI(playerID)
	end
	return player:IsAI()
end

local function WeightedPickFrom(entries)
	local total = 0
	for _, e in ipairs(entries) do
		total = total + e.w
	end
	if total <= 0 or #entries == 0 then
		return nil, 0
	end
	local roll = Game.GetRandNum(1000000, "CP_AI_Weighted") / 1000000.0 * total
	local acc = 0
	for _, e in ipairs(entries) do
		acc = acc + e.w
		if roll <= acc then
			return e, total
		end
	end
	return entries[#entries], total
end

-- Sort by weight desc, keep Top-K, then weighted-random inside that pool only.
local function WeightedPickTopK(entries, k)
	if entries == nil or #entries == 0 then
		return nil, 0, {}
	end
	local sorted = {}
	for i, e in ipairs(entries) do
		sorted[i] = e
	end
	table.sort(sorted, function(a, b)
		return a.w > b.w
	end)
	local n = math.min(k or TOP_K, #sorted)
	local pool = {}
	for i = 1, n do
		pool[i] = sorted[i]
	end
	local pick, total = WeightedPickFrom(pool)
	return pick, total, pool
end

local function LogMapStats(playerID, stats, faith, threshold)
	CPAILog(
		"stats p",
		playerID,
		"faith",
		faith,
		"/",
		threshold,
		"cities",
		stats.cities,
		"plots",
		stats.plots,
		"coast",
		stats.coast,
		"desert",
		stats.desert,
		"tundra",
		stats.tundra,
		"jungle",
		stats.jungle,
		"forest",
		stats.forest,
		"marsh+flood",
		stats.marsh + stats.flood,
		"geo",
		stats.geo,
		"fish",
		stats.fishRes,
		"quarry",
		stats.quarryRes,
		"pasture",
		stats.pastureRes,
		"camp",
		stats.campRes,
		"plant",
		stats.plantRes,
		"mine",
		stats.mineRes
	)
end

local function LogComponentScores(godhoodList, powerList, stats, gReligion)
	local ghParts = {}
	for _, t in ipairs(godhoodList) do
		local base = ScoreGodhood(t, stats)
		local mul = GodhoodDiversityMul(t, gReligion)
		ghParts[#ghParts + 1] = t
			.. "="
			.. string.format("%.2f", base)
			.. (mul < 1 and string.format("x%.2f", mul) or "")
	end
	CPAILog("godhoodScores", table.concat(ghParts, " | "))

	local pwParts = {}
	for _, t in ipairs(powerList) do
		local base = ScorePower(t, stats)
		local mul = PowerDiversityMul(t, gReligion)
		pwParts[#pwParts + 1] = t
			.. "="
			.. string.format("%.2f", base)
			.. (mul < 1 and string.format("x%.2f", mul) or "")
	end
	CPAILog("powerScores", table.concat(pwParts, " | "))
end

local function LogTopCandidates(pool, total, pick, fullCount)
	if pool == nil or #pool == 0 or total <= 0 then
		return
	end
	local n = math.min(TOP_N_LOG, #pool)
	CPAILog(
		"pool",
		fullCount or #pool,
		"→ TopK",
		#pool,
		"totalW",
		string.format("%.1f", total),
		"top" .. n
	)
	for i = 1, n do
		local e = pool[i]
		local pct = 100.0 * e.w / total
		local mark = (pick ~= nil and e.tag == pick.tag) and " <--PICK" or ""
		CPAILog(
			string.format("  #%d", i),
			e.tag,
			"w",
			string.format("%.2f", e.w),
			string.format("(%.1f%%)", pct),
			"gh",
			string.format("%.2f", e.gw),
			"pw",
			string.format("%.2f", e.pw) .. mark
		)
	end
	if pick ~= nil then
		local rank = 0
		for i, e in ipairs(pool) do
			if e.tag == pick.tag then
				rank = i
				break
			end
		end
		local pct = 100.0 * pick.w / total
		CPAILog(
			"chosen",
			pick.tag,
			"rank",
			rank,
			"/",
			#pool,
			"(of",
			fullCount or #pool,
			")",
			"w",
			string.format("%.2f", pick.w),
			string.format("p=%.2f%%", pct)
		)
	end
end

local function TryChooseForPlayer(player, playerID, godhoodList, powerList, gReligion)
	if not PlayerIsAI(playerID) then
		return
	end

	local pReligion = player:GetReligion()
	if pReligion == nil then
		return
	end
	local iPantheon = pReligion:GetPantheon()
	if iPantheon ~= nil and iPantheon ~= -1 then
		return
	end

	local iFaithBalance = pReligion:GetFaithBalance()
	local param = GameInfo.GlobalParameters["RELIGION_PANTHEON_MIN_FAITH"]
	local iFaithThreshold = param and tonumber(param.Value) or 25
	local faithYield = 0
	if type(pReligion.GetFaithYield) == "function" then
		faithYield = pReligion:GetFaithYield() or 0
	end
	-- Claim early / on projected hit (yield may apply after PlayerTurnActivated).
	local projected = iFaithBalance + faithYield
	if iFaithBalance <= iFaithThreshold - 10 and projected < iFaithThreshold then
		return
	end

	local stats = AnalyzePlayerMap(playerID)
	LogMapStats(playerID, stats, iFaithBalance, iFaithThreshold)
	LogComponentScores(godhoodList, powerList, stats, gReligion)

	local entries = {}
	local seenBelief = {}
	for _, ghType in ipairs(godhoodList) do
		local gScore = ScoreGodhood(ghType, stats) * GodhoodDiversityMul(ghType, gReligion)
		if gScore > 0 then
			for _, pwType in ipairs(powerList) do
				local beliefType = "BELIEF_" .. ghType .. "_WITH_" .. pwType
				if not seenBelief[beliefType] then
					seenBelief[beliefType] = true
					local beliefInfo = GameInfo.Beliefs[beliefType]
					if beliefInfo ~= nil and not gReligion:HasBeenFounded(beliefInfo.Index) then
						local pScore = ScorePower(pwType, stats) * PowerDiversityMul(pwType, gReligion)
						local w = gScore * pScore
						entries[#entries + 1] = {
							idx = beliefInfo.Index,
							w = w,
							tag = beliefType,
							gw = gScore,
							pw = pScore,
						}
					end
				end
			end
		end
	end

	if #entries == 0 then
		CPAILog("AI", playerID, "no available combinations")
		return
	end

	local fullCount = #entries
	local pick, total, pool = WeightedPickTopK(entries, TOP_K)
	LogTopCandidates(pool, total, pick, fullCount)

	if pick ~= nil then
		CPAILog("FoundPantheon", "p", playerID, pick.tag)
		gReligion:FoundPantheon(playerID, pick.idx)
	end
end

local function BuildGodhoodPowerLists()
	local Godhoods = DistinctColumn(DB.Query("SELECT GodhoodType FROM Godhood"), "GodhoodType")
	local Powers = DistinctColumn(DB.Query("SELECT PowerType FROM Power"), "PowerType")
	return Godhoods, Powers
end

function AIChoosePantheon()
	local Godhoods, Powers = BuildGodhoodPowerLists()
	if #Godhoods == 0 or #Powers == 0 then
		CPAILog("WARN empty Godhood/Power tables")
		return
	end

	local gReligion = Game.GetReligion()
	for _, player in ipairs(PlayerManager.GetAliveMajors()) do
		TryChooseForPlayer(player, player:GetID(), Godhoods, Powers, gReligion)
	end
end

-- Beat engine auto-pick: run at the start of each AI's turn (TurnBegin alone is too late).
local function OnPlayerTurnActivated(playerID, firstTime)
	if not PlayerIsAI(playerID) then
		return
	end
	local Godhoods, Powers = BuildGodhoodPowerLists()
	if #Godhoods == 0 or #Powers == 0 then
		return
	end
	local player = Players[playerID]
	if player == nil then
		return
	end
	TryChooseForPlayer(player, playerID, Godhoods, Powers, Game.GetReligion())
end

-- Human chooser + shared founding path (combos are not BELIEF_CLASS_PANTHEON).
GameEvents.CP_FoundPantheon.Add(function(playerID, beliefIndex)
	if playerID == nil or beliefIndex == nil then
		return
	end
	local player = Players[playerID]
	if player == nil then
		return
	end
	local pReligion = player:GetReligion()
	if pReligion == nil then
		return
	end
	local pan = pReligion:GetPantheon()
	if pan ~= nil and pan ~= -1 then
		return
	end
	local info = GameInfo.Beliefs[beliefIndex]
	CPAILog("CP_FoundPantheon", "p", playerID, info and info.BeliefType or beliefIndex)
	Game.GetReligion():FoundPantheon(playerID, beliefIndex)
end)

Events.LoadGameViewStateDone.Add(function()
	Events.TurnBegin.Add(AIChoosePantheon)
	if Events.PlayerTurnActivated then
		Events.PlayerTurnActivated.Add(OnPlayerTurnActivated)
	end
	CPAILog(
		"script loaded OK. godhoods=",
		tostring(#DistinctColumn(DB.Query("SELECT GodhoodType FROM Godhood"), "GodhoodType")),
		"TopK=",
		tostring(TOP_K),
		"hook=TurnBegin+PlayerTurnActivated+CP_FoundPantheon",
		"comboClass=CP_COMBO",
		"Debug ON; SetProperty('" .. PROP_DEBUG .. "', 0) to silence."
	)
end)
