-- ===========================================================================
--	Copyright (c) 2018 Firaxis Games
--	Haikesi: recognize all PROMOTION_CLASS_ROCK_BAND units (not only UNIT_ROCK_BAND)
-- ===========================================================================

-- ===========================================================================
-- INCLUDE XP1 FILE
-- ===========================================================================
include("UnitPanel_Expansion1");

-- ===========================================================================
-- Builder lag fix only when Create Your Pantheon (Dev or Workshop) is active.
-- Without CP, keep vanilla GetUnitActionsTable (full yield preview).
-- ===========================================================================
local CREATE_PANTHEON_MOD_IDS = {
	"c3a8f1e4-7b2d-4a91-9e5c-6d0f8b4a2c17", -- CreatePantheon_Dev
	"b85e61c0-26b7-4098-81ba-8566b8537dcb", -- Workshop Create Your Pantheon
};

local function IsCreatePantheonActive()
	if Modding ~= nil then
		if type(Modding.IsModActive) == "function" then
			for _, modId in ipairs(CREATE_PANTHEON_MOD_IDS) do
				local ok, active = pcall(function()
					return Modding.IsModActive(modId);
				end);
				if ok and active then
					return true;
				end
			end
		end
		if type(Modding.GetActiveMods) == "function" then
			local ok, mods = pcall(function()
				return Modding.GetActiveMods();
			end);
			if ok and mods ~= nil then
				for _, mod in ipairs(mods) do
					local id = mod.Id or mod.id or mod.Handle;
					if id ~= nil then
						for _, want in ipairs(CREATE_PANTHEON_MOD_IDS) do
							if tostring(id) == want then
								return true;
							end
						end
					end
				end
			end
		end
	end
	-- DB fallback (CP inserts these; works even if Modding API unavailable)
	if GameInfo ~= nil then
		if GameInfo.BeliefClasses ~= nil
			and GameInfo.BeliefClasses["BELIEF_CLASS_CP_COMBO"] ~= nil then
			return true;
		end
		if GameInfo.Types ~= nil
			and GameInfo.Types["BELIEF_CLASS_CP_COMBO"] ~= nil then
			return true;
		end
	end
	return false;
end

if IsCreatePantheonActive() then
	include("Haikesi_GetUnitActionsTable_BuilderLag");
	print("[Haikesi UI] Create Pantheon detected -- builder lag UnitPanel patch on");
else
	print("[Haikesi UI] Create Pantheon not detected -- vanilla UnitPanel build actions");
end


-- ===========================================================================
--	Add to base tables
-- ===========================================================================
local BASE_InitSubjectData = InitSubjectData;
local BASE_GetBuildImprovementParameters = GetBuildImprovementParameters;
local BASE_ReadCustomUnitStats = ReadCustomUnitStats;
local Base_RealizeSpecializedViews = RealizeSpecializedViews;
local BASE_FilterUnitStatsFromUnitData = FilterUnitStatsFromUnitData;
local BASE_LateCheckOperationBeforeAdd = LateCheckOperationBeforeAdd;

-- ===========================================================================
local function IsRockBandUnitTypeName(unitTypeName:string)
	local unitInfo:table = GameInfo.Units[unitTypeName];
	return unitInfo ~= nil and unitInfo.PromotionClass == "PROMOTION_CLASS_ROCK_BAND";
end

-- ===========================================================================
--	OVERRIDE
--	Call base to get values and then XP2 related fields.
-- ===========================================================================
function InitSubjectData()
	local kSubjectData:table = BASE_InitSubjectData();
	kSubjectData.RockBandLevel	= -1;
	kSubjectData.AlbumSales		= 0;	
	kSubjectData.IsRockbandUnit	= false;
	return kSubjectData;	
end


-- ===========================================================================
--	OVERRIDE
--	Populate XP2 specific units that have custom stats.
-- ===========================================================================
function ReadCustomUnitStats( pUnit:table, kSubjectData:table )	
	kSubjectData = BASE_ReadCustomUnitStats(pUnit, kSubjectData );
	local unitTypeName = GameInfo.Units[kSubjectData.UnitType] and GameInfo.Units[kSubjectData.UnitType].UnitType or nil;
	if IsRockBandUnitTypeName(unitTypeName) then 
		kSubjectData.IsRockbandUnit = true;
		kSubjectData.RockBandLevel	= pUnit:GetRockBand():GetRockBandLevel();
		kSubjectData.AlbumSales		= pUnit:GetRockBand():GetAlbumSales();
	end
	-- 特工：面板显示实例名「憨豆」（类型名仍为 LOC_UNIT_NW_BEAN_NAME=特工）
	if unitTypeName == "UNIT_NW_BEAN" then
		kSubjectData.Name = "LOC_UNIT_NW_BEAN_INSTANCE_NAME";
	end

	return kSubjectData;
end


-- ===========================================================================
--	OVERRIDE
--	Is this hash representing an improvement to be built?
-- ===========================================================================
function IsBuildingImprovement( actionHash:number )
	return (actionHash == UnitOperationTypes.BUILD_IMPROVEMENT 
	  	or actionHash == UnitOperationTypes.BUILD_IMPROVEMENT_ADJACENT);
end


-- ===========================================================================
--	OVERRIDE
--	Obtain the parameters for a building improvement.
--	actionHash, the hash of the type of the operation type
--	pUnit, the unit doing the operation
-- ===========================================================================
function GetBuildImprovementParameters(actionHash, pUnit)
	if actionHash == UnitOperationTypes.BUILD_IMPROVEMENT_ADJACENT then
		return {};	-- no parameters
	end
	return BASE_GetBuildImprovementParameters(actionHash, pUnit);
end

-- ===========================================================================
--	OVERRIDE
--	Returns: Callback function, Disabled state
-- ===========================================================================
function GetBuildImprovementCallback( actionHash :number, isDisabledIn:boolean )
	local callbackFn	:ifunction = OnUnitActionClicked_BuildImprovement;
	local isDisabled	:boolean = isDisabledIn;
	if (actionHash == UnitOperationTypes.BUILD_IMPROVEMENT_ADJACENT) then
		callbackFn = OnUnitActionClicked_BuildImprovementAdjacent;
		isDisabledModified = false;
	else
		callbackFn = OnUnitActionClicked_BuildImprovement;
		isDisabledModified = isDisabled;
	end
	return callbackFn, isDisabledModified;
end

-- ===========================================================================
function AddUpgradeResourceCost( pUnit:table )
	local toolTipString:string = "";
	if (GameInfo.Units_XP2~= nil) then
		local upgradeResource, upgradeResourceCost = pUnit:GetUpgradeResourceCost();
		if (upgradeResource ~= nil and upgradeResource >= 0) then
			local resourceName:string = Locale.Lookup(GameInfo.Resources[upgradeResource].Name);
			local resourceIcon = "[ICON_" .. GameInfo.Resources[upgradeResource].ResourceType .. "]";
			toolTipString = "[NEWLINE]" .. Locale.Lookup("LOC_UNITOPERATION_UPGRADE_RESOURCE_INFO", upgradeResourceCost, resourceIcon, resourceName)
		end
	end
	return toolTipString;
end

-- ===========================================================================
-- UnitAction<BuildImprovementAdjacent> was clicked.
-- ===========================================================================
function OnUnitActionClicked_BuildImprovementAdjacent( improvementHash, dummy )
	if (g_isOkayToProcess) then
		local pSelectedUnit = UI.GetHeadSelectedUnit();
		if (pSelectedUnit ~= nil) then
			local tParameters = {};
			tParameters[UnitOperationTypes.PARAM_IMPROVEMENT_TYPE] = improvementHash;
			tParameters[UnitOperationTypes.PARAM_OPERATION_TYPE] = UnitOperationTypes.BUILD_IMPROVEMENT_ADJACENT;
			UI.SetInterfaceMode(InterfaceModeTypes.BUILD_IMPROVEMENT_ADJACENT, tParameters);
		end
		ContextPtr:RequestRefresh();
	end
end

-- ===========================================================================
function RockbandView( kData:table )
	if kData.IsRockbandUnit == false then return; end
	-- TODO: populate with rock band information if using a custom view (may want to remove stats data entries)
end


-- ===========================================================================
--	OVERRIDE
-- ===========================================================================
function FilterUnitStatsFromUnitData( kUnitData:table, ignoreStatType:number )
	local kData:table= BASE_FilterUnitStatsFromUnitData( kUnitData, ignoreStatType );

	if kUnitData.IsRockbandUnit then 
		table.insert(kData, {Value = kUnitData.AlbumSales,		Type = "ActionCharges",	Label = "LOC_HUD_UNIT_PANEL_ROCK_BAND_ALBUM_SALES",	FontIcon="[ICON_Charges_Large]",		IconName="ICON_STAT_RECORD_SALES"});
		table.insert(kData, {Value = kUnitData.RockBandLevel,	Type = "SpreadCharges", Label = "LOC_HUD_UNIT_PANEL_ROCK_BAND_LEVEL",		FontIcon="[ICON_ReligionStat_Large]",	IconName="ICON_STAT_ROCKBAND_LEVEL"});
	end

	local pPlayer : table = Players[kUnitData.Owner];
	if (pPlayer ~= nil) then
		local pUnit : table = pPlayer:GetUnits():FindID(kUnitData.UnitID);
		if(GameInfo.Units[pUnit:GetUnitType()].ParkCharges > 0)then
			table.insert(kData, {Value = pUnit:GetParkCharges(), Type = "ParkCharges", Label = "LOC_HUD_UNIT_PANEL_PARK_CHARGES", FontIcon = "[ICON_Charges_Large]", IconName = "ICON_BUILD_CHARGES"});
		end
	end

	

	return kData;
end

-- ===========================================================================
function RealizeSpecializedViews( kData:table )
	Base_RealizeSpecializedViews(kData);
	RockbandView(kData);
end

-- ===========================================================================
-- Override the unit operation icon for XP2 railroads.
-- ===========================================================================
function LateCheckOperationBeforeAdd( tResults: table, kActionsTable: table, actionHash:number, isDisabled:boolean, tooltipString:string, overrideIcon:string )
	if (tResults[UnitOperationResults.ROUTE_TYPE] ~= nil and tResults[UnitOperationResults.ROUTE_TYPE] == "ROUTE_RAILROAD") then
		overrideIcon = "ICON_ROUTE_RAILROAD";
		return isDisabled, tooltipString, overrideIcon;
	end

	-- Not a railroad, fall through to the base version.
	return BASE_LateCheckOperationBeforeAdd( tResults, kActionsTable, actionHash, isDisabled, tooltipString, overrideIcon );
end
