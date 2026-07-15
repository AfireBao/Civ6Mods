
--[[
-- Copyright (c) Firaxis Games 2018
-- Haikesi: recognize all PROMOTION_CLASS_ROCK_BAND units (not only UNIT_ROCK_BAND);
--          show Juan (UNIT_NW_JUAN) AOE range like Great Generals (AreaHighlightRadius).
--]]

-- ===========================================================================
-- INCLUDES
-- ===========================================================================
include("SelectedUnit");

-- Must match Haikesi_Modifier.sql NW_REQUIRES_JUAN_WITHIN_3 MaxDistance
local JUAN_AOE_RADIUS = 3;

-- ===========================================================================
local function IsRockBandPromotionUnit(unitTypeIndex)
	local unitInfo = GameInfo.Units[unitTypeIndex];
	return unitInfo ~= nil and unitInfo.PromotionClass == "PROMOTION_CLASS_ROCK_BAND";
end

-- Collect plot indices within radius (including the unit tile) for Great People lens
local function CollectAreaHighlightPlots(kUnit, radius)
	local plots = {};
	if kUnit == nil or radius == nil or radius < 0 then
		return plots;
	end
	local centerX = kUnit:GetX();
	local centerY = kUnit:GetY();
	for dx = -radius, radius do
		for dy = -radius, radius do
			local pPlot = Map.GetPlotXY(centerX, centerY, dx, dy);
			if pPlot ~= nil
				and Map.GetPlotDistance(centerX, centerY, pPlot:GetX(), pPlot:GetY()) <= radius then
				table.insert(plots, pPlot:GetIndex());
			end
		end
	end
	return plots;
end

-- ===========================================================================
-- OVERRIDE BASE FUNCTIONS
-- ===========================================================================
function RealizeGreatPersonLens(kUnit)
	UILens.ClearLayerHexes(m_HexColoringGreatPeople);
	if UILens.IsLayerOn(m_HexColoringGreatPeople) then
		UILens.ToggleLayerOff(m_HexColoringGreatPeople);
	end
	if kUnit ~= nil and (not UI.IsGameCoreBusy()) then
		local playerID = kUnit:GetOwner();
		if playerID == Game.GetLocalPlayer() then
			local kUnitArchaeology = kUnit:GetArchaeology();
			local kUnitGreatPerson = kUnit:GetGreatPerson();
			local kUnitRockBand = kUnit:GetRockBand();
			local bCanCauseDisasters = false;
			local unitInfo = GameInfo.Units[kUnit:GetUnitType()];
			local sUnitType = unitInfo and unitInfo.UnitType or nil;
			if (sUnitType ~= nil and GameInfo.Units_XP2[sUnitType] ~= nil and GameInfo.Units_XP2[sUnitType].CanCauseDisasters ~= nil) then
				bCanCauseDisasters = GameInfo.Units_XP2[sUnitType].CanCauseDisasters;
			end
			if kUnitGreatPerson ~= nil and kUnitGreatPerson:IsGreatPerson() then
				local greatPersonInfo = GameInfo.GreatPersonIndividuals[kUnitGreatPerson:GetIndividual()];
				local areaHighlightPlots = {};
				if (greatPersonInfo ~= nil and greatPersonInfo.AreaHighlightRadius ~= nil) then
					areaHighlightPlots = kUnitGreatPerson:GetAreaHighlightPlots();
				end
				local activationPlots = {};
				if (greatPersonInfo ~= nil and greatPersonInfo.ActionEffectTileHighlighting ~= nil and greatPersonInfo.ActionEffectTileHighlighting) then
					local rawActivationPlots = kUnitGreatPerson:GetActivationHighlightPlots();
					for _, plotIndex in ipairs(rawActivationPlots) do
						table.insert(activationPlots, {"Great_People", plotIndex});
					end
				end
				UILens.SetLayerHexesArea(m_HexColoringGreatPeople, playerID, areaHighlightPlots, activationPlots);
				UILens.ToggleLayerOn(m_HexColoringGreatPeople);
			elseif sUnitType == "UNIT_NW_JUAN" then
				-- Juan is not a Great Person; draw 0-3 aura with the same Great People lens
				local areaHighlightPlots = CollectAreaHighlightPlots(kUnit, JUAN_AOE_RADIUS);
				UILens.SetLayerHexesArea(m_HexColoringGreatPeople, playerID, areaHighlightPlots, {});
				UILens.ToggleLayerOn(m_HexColoringGreatPeople);
			elseif (kUnitArchaeology ~= nil and unitInfo ~= nil and unitInfo.ExtractsArtifacts == true) then
				local activationPlots = {};
				local rawActivationPlots = kUnitArchaeology:GetActivationHighlightPlots();
				for _, plotIndex in ipairs(rawActivationPlots) do
					table.insert(activationPlots, {"Great_People", plotIndex});
				end
				UILens.SetLayerHexesArea(m_HexColoringGreatPeople, playerID, {}, activationPlots);
				UILens.ToggleLayerOn(m_HexColoringGreatPeople);
			elseif unitInfo ~= nil and unitInfo.ParkCharges > 0 and kUnit:GetParkCharges() > 0 then
				local parkPlots = {};
				local rawParkPlots = Game.GetNationalParks():GetPossibleParkTiles(playerID);
				for _, plotIndex in ipairs(rawParkPlots) do
					table.insert(parkPlots, {"Great_People", plotIndex});
				end
				UILens.SetLayerHexesArea(m_HexColoringGreatPeople, playerID, {}, parkPlots);
				UILens.ToggleLayerOn(m_HexColoringGreatPeople);
			elseif kUnitRockBand ~= nil and IsRockBandPromotionUnit(kUnit:GetUnitType()) then
				local activationPlots = {};
				local rawActivationPlots = kUnitRockBand:GetActivationHighlightPlots();
				for _, plotIndex in ipairs(rawActivationPlots) do
					table.insert(activationPlots, {"Great_People", plotIndex});
				end
				UILens.SetLayerHexesArea(m_HexColoringGreatPeople, playerID, {}, activationPlots);
				UILens.ToggleLayerOn(m_HexColoringGreatPeople);
			elseif bCanCauseDisasters then
				local activationPlots = {};
				local rawActivationPlots = GameClimate.GetLocationsForPossibleTriggerableEvents(playerID);
				for _, plotIndex in ipairs(rawActivationPlots) do
					table.insert(activationPlots, {"Great_People", plotIndex});
				end
				UILens.SetLayerHexesArea(m_HexColoringGreatPeople, playerID, {}, activationPlots);
				UILens.ToggleLayerOn(m_HexColoringGreatPeople);
			end
		end
	end
end
