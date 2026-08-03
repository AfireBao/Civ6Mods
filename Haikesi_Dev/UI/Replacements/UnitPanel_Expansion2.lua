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

local HAIKESI_RELICS_COUNT_PROPERTY_KEY = "PROP_NW_HAIKESI_RELIC_COUNT";
local HAIKESI_RELICS_SLOT_PROPERTY_PREFIX = "PROP_NW_HAIKESI_RELIC_";
local HAIKESI_LINCOLN_RELIC = "EMANCIPATIONPROCLAMATIONRUNE";
local HAIKESI_LINCOLN_LEADER = "LEADER_ABRAHAM_LINCOLN";
local HAIKESI_LINCOLN_HARVEST_PROXY = "RESOURCE_NW_EMANCIPATION_HARVEST_PROXY";
local g_HaikesiLincolnPlantationResourceTypes:table = nil;
local g_HaikesiLincolnPendingHarvest:table = nil;

InterfaceModeTypes.DEATH_CULT_DEVOUR = InterfaceModeTypes.DEATH_CULT_DEVOUR or DB.MakeHash("INTERFACEMODE_DEATH_CULT_DEVOUR");

local function HaikesiPlayerHasRelic(playerID:number, relicType:string)
	local pPlayer = Players[playerID];
	if pPlayer == nil or relicType == nil then return false; end

	local function checkSlots(countKey:string, prefix:string)
		local count:number = tonumber(pPlayer:GetProperty(countKey) or 0) or 0;
		for i:number = 1, count do
			if pPlayer:GetProperty(prefix .. i) == relicType then
				return true;
			end
		end
		return false;
	end

	return checkSlots(HAIKESI_RELICS_COUNT_PROPERTY_KEY, HAIKESI_RELICS_SLOT_PROPERTY_PREFIX);
end

local function HaikesiUnitTypeHasTag(unitType:string, wantedTag:string)
	if unitType == nil or wantedTag == nil or GameInfo.TypeTags == nil then return false; end
	for row in GameInfo.TypeTags() do
		if row.Type == unitType and row.Tag == wantedTag then
			return true;
		end
	end
	return false;
end

local function HaikesiIsLincolnPlantationResourceType(resourceType:string)
	if resourceType == nil or GameInfo.Improvement_ValidResources == nil then return false; end
	if g_HaikesiLincolnPlantationResourceTypes == nil then
		g_HaikesiLincolnPlantationResourceTypes = {};
		for row in GameInfo.Improvement_ValidResources() do
			if row.ImprovementType == "IMPROVEMENT_PLANTATION" then
				g_HaikesiLincolnPlantationResourceTypes[row.ResourceType] = true;
			end
		end
	end
	return g_HaikesiLincolnPlantationResourceTypes[resourceType] == true;
end

local function HaikesiGetLincolnHarvestResource(pUnit:table)
	if pUnit == nil or pUnit:GetBuildCharges() <= 0 then return nil; end
	local playerID:number = pUnit:GetOwner();
	local config:table = PlayerConfigurations[playerID];
	if config == nil
		or config:GetLeaderTypeName() ~= HAIKESI_LINCOLN_LEADER
		or not HaikesiPlayerHasRelic(playerID, HAIKESI_LINCOLN_RELIC) then
		return nil;
	end

	local unitInfo:table = GameInfo.Units[pUnit:GetUnitType()];
	if unitInfo == nil or not HaikesiUnitTypeHasTag(unitInfo.UnitType, "CLASS_BUILDER") then
		return nil;
	end
	local irrigationInfo:table = GameInfo.Technologies["TECH_IRRIGATION"];
	local player:table = Players[playerID];
	local techs:table = player ~= nil and player:GetTechs() or nil;
	if irrigationInfo == nil or techs == nil or not techs:HasTech(irrigationInfo.Index) then
		return nil;
	end

	local plot:table = Map.GetPlot(pUnit:GetX(), pUnit:GetY());
	if plot == nil or plot:GetOwner() ~= playerID then return nil; end
	local resourceInfo:table = GameInfo.Resources[plot:GetResourceType()];
	if resourceInfo == nil
		or (resourceInfo.ResourceClassType ~= "RESOURCECLASS_LUXURY"
			and resourceInfo.ResourceClassType ~= "RESOURCECLASS_BONUS")
		or not HaikesiIsLincolnPlantationResourceType(resourceInfo.ResourceType) then
		return nil;
	end
	return resourceInfo;
end

local function HaikesiRemoveActionByUserTag(actionsTable:table, userTag:number)
	if actionsTable == nil or userTag == nil then return; end
	for _, category in pairs(actionsTable) do
		if type(category) == "table" then
			for i:number = #category, 1, -1 do
				if category[i] ~= nil and category[i].userTag == userTag then
					table.remove(category, i);
				end
			end
		end
	end
end

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
local BASE_GetUnitActionsTable = GetUnitActionsTable;
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

function GetUnitActionsTable(pUnit)
	local actionsTable = BASE_GetUnitActionsTable(pUnit);
	if pUnit == nil or actionsTable == nil or pUnit:GetMovesRemaining() <= 0 then
		return actionsTable;
	end

	local unitInfo = GameInfo.Units[pUnit:GetUnitType()];
	local unitType = unitInfo and unitInfo.UnitType or nil;
	local trinityRetireTarget = nil;
	local trinityRetireName = nil;
	if unitType == "UNIT_NW_JUAN" then
		trinityRetireTarget = "UNIT_NW_XIANG";
		trinityRetireName = "LOC_HAIKESI_TRINITY_RETIRE_TO_XIANG_NAME";
	elseif unitType == "UNIT_NW_XIANG" then
		trinityRetireTarget = "UNIT_NW_LAOYE";
		trinityRetireName = "LOC_HAIKESI_TRINITY_RETIRE_TO_LAOYE_NAME";
	elseif unitType == "UNIT_NW_LAOYE" then
		trinityRetireTarget = "UNIT_NW_JUAN";
		trinityRetireName = "LOC_HAIKESI_TRINITY_RETIRE_TO_JUAN_NAME";
	end
	if trinityRetireTarget ~= nil then
		local retireAction = {
			CategoryInUI = "INPLACE",
			Icon = (GameInfo.Units[trinityRetireTarget] ~= nil and "ICON_" .. trinityRetireTarget) or "ICON_UNITOPERATION_SLEEP",
			Sound = "Confirm_Dedication"
		};
		local toolTipString = Locale.Lookup(trinityRetireName)
			.. "[NEWLINE]" .. Locale.Lookup("LOC_HAIKESI_TRINITY_RETIRE_DESCRIPTION");
		local callback = function()
			local param = {};
			param["OnStart"] = "HaikesiSelectRelic";
			param["TrinityRetire"] = "1";
			param["UnitID"] = pUnit:GetID();
			param["FromUnitType"] = unitType;
			param["ToUnitType"] = trinityRetireTarget;
			UI.RequestPlayerOperation(pUnit:GetOwner(), PlayerOperations.EXECUTE_SCRIPT, param);
		end
		AddActionToTable(actionsTable, retireAction, false, toolTipString, 991731, callback, nil, nil, retireAction.Icon);
	end
	if unitType == "UNIT_NW_ZOMBIE" and pUnit:GetMovesRemaining() > 0 and HaikesiPlayerHasRelic(pUnit:GetOwner(), "NECROMILITARISMRUNE") then
		local devourAction = {
			CategoryInUI = "INPLACE",
			Icon = "ICON_HAIKESI_UNITOPERATION_DEVOUR",
			Sound = "Confirm_Dedication"
		};
		local toolTipString = Locale.Lookup("LOC_HAIKESI_ZOMBIE_DEVOUR_NAME")
			.. "[NEWLINE]" .. Locale.Lookup("LOC_HAIKESI_ZOMBIE_DEVOUR_DESCRIPTION");
		local callback = function()
			if UI.GetInterfaceMode() == InterfaceModeTypes.DEATH_CULT_DEVOUR then
				UI.SetInterfaceMode(InterfaceModeTypes.SELECTION);
			else
				UI.SetInterfaceMode(InterfaceModeTypes.DEATH_CULT_DEVOUR);
			end
			ContextPtr:RequestRefresh();
		end
		AddActionToTable(actionsTable, devourAction, false, toolTipString, 991732, callback, nil, nil, devourAction.Icon);
	end
	local lincolnResource:table = HaikesiGetLincolnHarvestResource(pUnit);
	if lincolnResource ~= nil then
		-- Bananas already expose the vanilla harvest button. Replace it with the
		-- relic action so harvesting bananas cannot bypass the free-unit effect.
		HaikesiRemoveActionByUserTag(actionsTable, UnitOperationTypes.HARVEST_RESOURCE);
		local harvestAction:table = {
			CategoryInUI = "INPLACE",
			Icon = "ICON_UNITOPERATION_HARVEST_RESOURCE",
			Sound = "Build_Improvement_2D"
		};
		local toolTipString:string = Locale.Lookup("LOC_HAIKESI_LINCOLN_HARVEST_NAME")
			.. "：" .. Locale.Lookup(lincolnResource.Name)
			.. "[NEWLINE]" .. Locale.Lookup("LOC_HAIKESI_LINCOLN_HARVEST_DESCRIPTION");
		local callback = function()
			g_HaikesiLincolnPendingHarvest = {
				PlayerID = pUnit:GetOwner(),
				UnitID = pUnit:GetID(),
				X = pUnit:GetX(),
				Y = pUnit:GetY()
			};
			UI.RequestPlayerOperation(pUnit:GetOwner(), PlayerOperations.EXECUTE_SCRIPT, {
				OnStart = "HaikesiLincolnHarvest",
				UnitID = pUnit:GetID(),
				X = pUnit:GetX(),
				Y = pUnit:GetY(),
				ResourceType = lincolnResource.ResourceType
			});
			SimUnitSystem.SetAnimationState(pUnit, "ACTION_1", "IDLE");
			UI.PlaySound("Build_Improvement_2D");
		end
		AddActionToTable(actionsTable, harvestAction, false, toolTipString, 991733, callback, nil, nil, harvestAction.Icon);
	end
	return actionsTable;
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
	if unitTypeName == "UNIT_NW_VAMPIRE_DUKE" then
		local rangedCombat:number = 5;
		local pPlayer:table = Players[pUnit:GetOwner()];
		local pPlayerTechs:table = pPlayer ~= nil and pPlayer:GetTechs() or nil;
		local function HasDukeRangedTech(techType:string)
			local techInfo:table = GameInfo.Technologies[techType];
			return pPlayerTechs ~= nil and techInfo ~= nil and pPlayerTechs:HasTech(techInfo.Index);
		end
		if HasDukeRangedTech("TECH_ADVANCED_BALLISTICS") then
			rangedCombat = 40;
		elseif HasDukeRangedTech("TECH_BALLISTICS") then
			rangedCombat = 30;
		elseif HasDukeRangedTech("TECH_MACHINERY") then
			rangedCombat = 20;
		elseif HasDukeRangedTech("TECH_ARCHERY") then
			rangedCombat = 10;
		end
		kSubjectData.RangedCombat = rangedCombat;
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

-- ===========================================================================
-- The gameplay handler first prepares the hidden harvest proxy. Starting the
-- native harvest inside EXECUTE_SCRIPT is rejected because that player
-- operation is still active, so request HARVEST_RESOURCE only after it ends.
-- ===========================================================================
local function HaikesiOnPlayerOperationComplete(playerID:number, operation:number)
	local pending:table = g_HaikesiLincolnPendingHarvest;
	if pending == nil
		or operation ~= PlayerOperations.EXECUTE_SCRIPT
		or playerID ~= pending.PlayerID then
		return;
	end
	local pUnit:table = UnitManager.GetUnit(playerID, pending.UnitID);
	local pPlot:table = Map.GetPlot(pending.X, pending.Y);
	local proxyInfo:table = GameInfo.Resources[HAIKESI_LINCOLN_HARVEST_PROXY];
	if pUnit == nil
		or pPlot == nil
		or proxyInfo == nil
		or pUnit:GetX() ~= pending.X
		or pUnit:GetY() ~= pending.Y
		or pPlot:GetResourceType() ~= proxyInfo.Index then
		g_HaikesiLincolnPendingHarvest = nil;
		print("[Haikesi Lincoln UI] harvest preparation did not complete");
		ContextPtr:RequestRefresh();
		return;
	end

	local callOK, canStart, results = pcall(
		UnitManager.CanStartOperation,
		pUnit,
		UnitOperationTypes.HARVEST_RESOURCE,
		nil,
		false,
		OperationResultsTypes.NO_TARGETS
	);
	if callOK and canStart then
		UnitManager.RequestOperation(pUnit, UnitOperationTypes.HARVEST_RESOURCE);
		print(string.format(
			"[Haikesi Lincoln UI] native harvest requested for unit %d at (%d,%d)",
			pending.UnitID, pending.X, pending.Y
		));
	else
		g_HaikesiLincolnPendingHarvest = nil;
		UI.RequestPlayerOperation(playerID, PlayerOperations.EXECUTE_SCRIPT, {
			OnStart = "HaikesiLincolnHarvestRollback",
			UnitID = pending.UnitID
		});
		print(string.format(
			"[Haikesi Lincoln UI] native harvest unavailable; rollback requested (call=%s, canStart=%s, details=%s)",
			tostring(callOK), tostring(canStart), tostring(results)
		));
	end
	ContextPtr:RequestRefresh();
end

function HaikesiOnLincolnHarvestOperationDeactivated(playerID:number, unitID:number, operationID:number)
	local pending:table = g_HaikesiLincolnPendingHarvest;
	if pending == nil
		or operationID ~= UnitOperationTypes.HARVEST_RESOURCE
		or playerID ~= pending.PlayerID
		or unitID ~= pending.UnitID then
		return;
	end
	g_HaikesiLincolnPendingHarvest = nil;
	UI.RequestPlayerOperation(playerID, PlayerOperations.EXECUTE_SCRIPT, {
		OnStart = "HaikesiLincolnHarvestFinalize",
		UnitID = pending.UnitID,
		X = pending.X,
		Y = pending.Y
	});
	print(string.format(
		"[Haikesi Lincoln UI] native harvest completed; proxy cleanup requested at (%d,%d)",
		pending.X, pending.Y
	));
	ContextPtr:RequestRefresh();
end

Events.PlayerOperationComplete.Add(HaikesiOnPlayerOperationComplete);
Events.UnitOperationDeactivated.Add(HaikesiOnLincolnHarvestOperationDeactivated);
Events.UnitOperationsCleared.Add(HaikesiOnLincolnHarvestOperationDeactivated);
