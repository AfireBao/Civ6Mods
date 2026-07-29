-- ===========================================================================
-- Copyright (c) 2018 Firaxis Games
-- Haikesi: add Death Cult devour target selection.
-- ===========================================================================

include("WorldInput_Expansion1");

XP1_LateInitialize = LateInitialize;

InterfaceModeTypes.DEATH_CULT_DEVOUR = DB.MakeHash("INTERFACEMODE_DEATH_CULT_DEVOUR");

local ZOMBIE_UNIT = "UNIT_NW_ZOMBIE";
local FORM_CORPS_DIRECTION_OVERLAY_NAME = "FormCorps";

local g_deathCultSourcePlayerID = -1;
local g_deathCultSourceUnitID = -1;
local g_deathCultRestoreYieldIcons = false;

local function HKS_GetUnitType(unit)
	if unit == nil then return nil; end
	local unitInfo = GameInfo.Units[unit:GetUnitType()];
	return unitInfo and unitInfo.UnitType or nil;
end

local function HKS_IsZombie(unit)
	return HKS_GetUnitType(unit) == ZOMBIE_UNIT;
end

local function HKS_IsLandCombat(unit)
	local unitInfo = unit ~= nil and GameInfo.Units[unit:GetUnitType()] or nil;
	return unitInfo ~= nil and unitInfo.FormationClass == "FORMATION_CLASS_LAND_COMBAT";
end

local function HKS_GetTargetUnitInPlot(playerID, sourceUnit, plot)
	if sourceUnit == nil or plot == nil then return nil; end
	local unitList = Units.GetUnitsInPlotLayerID(plot:GetX(), plot:GetY(), MapLayers.ANY);
	if unitList == nil then return nil; end
	for _, unit in ipairs(unitList) do
		if unit ~= nil
			and unit:GetOwner() == playerID
			and unit:GetID() ~= sourceUnit:GetID()
			and HKS_IsLandCombat(unit)
			and not HKS_IsZombie(unit)
			and Map.GetPlotDistance(sourceUnit:GetX(), sourceUnit:GetY(), unit:GetX(), unit:GetY()) == 1 then
			return unit;
		end
	end
	return nil;
end

local function HKS_GetDevourSourceUnit()
	if g_deathCultSourcePlayerID < 0 or g_deathCultSourceUnitID < 0 then return nil; end
	local pPlayer = Players[g_deathCultSourcePlayerID];
	if pPlayer == nil or pPlayer:GetUnits() == nil then return nil; end
	return pPlayer:GetUnits():FindID(g_deathCultSourceUnitID);
end

local function HKS_HideYieldIconsForDevour()
	g_deathCultRestoreYieldIcons = UserConfiguration ~= nil
		and UserConfiguration.ShowMapYield ~= nil
		and UserConfiguration.ShowMapYield();
	if g_deathCultRestoreYieldIcons and LuaEvents.PlotInfo_HideYieldIcons ~= nil then
		LuaEvents.PlotInfo_HideYieldIcons();
	end
end

local function HKS_RestoreYieldIconsAfterDevour()
	if g_deathCultRestoreYieldIcons and LuaEvents.PlotInfo_ShowYieldIcons ~= nil then
		LuaEvents.PlotInfo_ShowYieldIcons();
	end
	g_deathCultRestoreYieldIcons = false;
end

local function HKS_GetDevourTargetPlots(sourceUnit)
	local targetPlots = {};
	if sourceUnit == nil then return targetPlots; end

	local playerID = sourceUnit:GetOwner();
	local pPlayer = Players[playerID];
	if pPlayer == nil or pPlayer:GetUnits() == nil then return targetPlots; end

	for _, unit in pPlayer:GetUnits():Members() do
		if unit ~= nil
			and unit:GetID() ~= sourceUnit:GetID()
			and HKS_IsLandCombat(unit)
			and not HKS_IsZombie(unit)
			and Map.GetPlotDistance(sourceUnit:GetX(), sourceUnit:GetY(), unit:GetX(), unit:GetY()) == 1 then
			table.insert(targetPlots, unit:GetPlotId());
		end
	end
	return targetPlots;
end

function OnMouseBuildImprovementAdjacentEnd(pInputStruct)
	if g_isMouseDragging then
		g_isMouseDragging = false;
	elseif IsSelectionAllowedAt(UI.GetCursorPlotID()) then
		BuildImprovementAdjacent(pInputStruct);
	end
	EndDragMap();
	g_isMouseDownInWorld = false;
	return true;
end

function BuildImprovementAdjacent(pInputStruct)
	local plotID = UI.GetCursorPlotID();
	if Map.IsPlot(plotID) then
		local plot = Map.GetPlotByIndex(plotID);

		local tParameters = {};
		tParameters[UnitOperationTypes.PARAM_X] = plot:GetX();
		tParameters[UnitOperationTypes.PARAM_Y] = plot:GetY();
		tParameters[UnitOperationTypes.PARAM_IMPROVEMENT_TYPE] = UI.GetInterfaceModeParameter(UnitOperationTypes.PARAM_IMPROVEMENT_TYPE);

		local pSelectedUnit = UI.GetHeadSelectedUnit();
		if UnitManager.CanStartOperation(pSelectedUnit, UnitOperationTypes.BUILD_IMPROVEMENT_ADJACENT, nil, tParameters) then
			UnitManager.RequestOperation(pSelectedUnit, UnitOperationTypes.BUILD_IMPROVEMENT_ADJACENT, tParameters);
			UI.SetInterfaceMode(InterfaceModeTypes.SELECTION);
		end
	end
	return true;
end

function OnInterfaceModeChange_BuildImprovementAdjacent(eNewMode)
	UIManager:SetUICursor(CursorTypes.RANGE_ATTACK);
	local pSelectedUnit = UI.GetHeadSelectedUnit();
	local eOperation = UI.GetInterfaceModeParameter(UnitOperationTypes.PARAM_OPERATION_TYPE);
	local tParameters = {};
	tParameters[UnitOperationTypes.PARAM_IMPROVEMENT_TYPE] = UI.GetInterfaceModeParameter(UnitOperationTypes.PARAM_IMPROVEMENT_TYPE);
	local tResults = UnitManager.GetOperationTargets(pSelectedUnit, eOperation, tParameters);
	local allPlots = tResults[UnitOperationResults.PLOTS];
	if allPlots then
		g_targetPlots = allPlots;
		if table.count(g_targetPlots) ~= 0 then
			local pOverlay = UILens.GetOverlay("PlacementValidOverlay");
			if pOverlay ~= nil then
				pOverlay:CreateSprites(g_targetPlots, "Placement_Valid", 0);
			end
		end
	end
end

function OnInterfaceModeLeave_BuildImprovementAdjacent(eNewMode)
	UIManager:SetUICursor(CursorTypes.NORMAL);
	local pOverlay = UILens.GetOverlay("PlacementValidOverlay");
	if pOverlay ~= nil then
		pOverlay:ClearAll();
	end
end

function OnMouseMoveJumpEnd(pInputStruct)
	if g_isMouseDragging then
		g_isMouseDragging = false;
	elseif IsSelectionAllowedAt(UI.GetCursorPlotID()) then
		MoveJump(pInputStruct);
	end
	EndDragMap();
	g_isMouseDownInWorld = false;
	return true;
end

function MoveJump(pInputStruct)
	local plotID = UI.GetCursorPlotID();
	if Map.IsPlot(plotID) then
		local plot = Map.GetPlotByIndex(plotID);

		local tParameters = {};
		tParameters[UnitCommandTypes.PARAM_X] = plot:GetX();
		tParameters[UnitCommandTypes.PARAM_Y] = plot:GetY();

		local pSelectedUnit = UI.GetHeadSelectedUnit();
		if UnitManager.CanStartCommand(pSelectedUnit, UnitCommandTypes.MOVE_JUMP, tParameters) then
			UnitManager.RequestCommand(pSelectedUnit, UnitCommandTypes.MOVE_JUMP, tParameters);
			UI.SetInterfaceMode(InterfaceModeTypes.SELECTION);
		end
	end
	return true;
end

function OnInterfaceModeChange_MoveJump(eNewMode)
	UIManager:SetUICursor(CursorTypes.RANGE_ATTACK);
	local pSelectedUnit = UI.GetHeadSelectedUnit();
	local tResults = UnitManager.GetCommandTargets(pSelectedUnit, UnitCommandTypes.MOVE_JUMP);
	local allPlots = tResults[CityCommandResults.PLOTS];
	if allPlots then
		g_targetPlots = {};
		for i, modifier in ipairs(tResults[CityCommandResults.PLOTS]) do
			table.insert(g_targetPlots, allPlots[i]);
		end

		if table.count(g_targetPlots) ~= 0 then
			UILens.ToggleLayerOn(g_HexColoringMovement);
			UILens.SetLayerHexesArea(g_HexColoringMovement, Game.GetLocalPlayer(), g_targetPlots);
		end
	end
end

function OnInterfaceModeLeave_MoveJump(eNewMode)
	UIManager:SetUICursor(CursorTypes.NORMAL);
	UILens.ToggleLayerOff(g_HexColoringMovement);
	UILens.ClearLayerHexes(g_HexColoringMovement);
end

function OnMouseDeathCultDevourEnd(pInputStruct)
	if g_isMouseDragging then
		g_isMouseDragging = false;
	elseif IsSelectionAllowedAt(UI.GetCursorPlotID()) then
		DeathCultDevourTarget(pInputStruct);
	end
	EndDragMap();
	g_isMouseDownInWorld = false;
	return true;
end

function DeathCultDevourTarget(pInputStruct)
	local plotID = UI.GetCursorPlotID();
	if not Map.IsPlot(plotID) then return true; end

	local plot = Map.GetPlotByIndex(plotID);
	local pSourceUnit = HKS_GetDevourSourceUnit();
	if pSourceUnit == nil or not HKS_IsZombie(pSourceUnit) or pSourceUnit:GetMovesRemaining() <= 0 then
		UI.SetInterfaceMode(InterfaceModeTypes.SELECTION);
		return true;
	end

	local playerID = pSourceUnit:GetOwner();
	local targetUnit = HKS_GetTargetUnitInPlot(playerID, pSourceUnit, plot);
	if targetUnit ~= nil then
		local param = {};
		param["OnStart"] = "HaikesiSelectRelic";
		param["DeathCultDevour"] = "1";
		param["UnitID"] = pSourceUnit:GetID();
		param["TargetUnitID"] = targetUnit:GetID();
		param["TargetX"] = targetUnit:GetX();
		param["TargetY"] = targetUnit:GetY();
		UI.RequestPlayerOperation(playerID, PlayerOperations.EXECUTE_SCRIPT, param);
		print("[Haikesi DeathCult UI] devour confirmed source=" .. tostring(pSourceUnit:GetID())
			.. " target=" .. tostring(targetUnit:GetID()));
		UI.SetInterfaceMode(InterfaceModeTypes.SELECTION);
	end
	return true;
end

function OnInterfaceModeChange_DeathCultDevour(eNewMode)
	UIManager:SetUICursor(CursorTypes.RANGE_ATTACK);
	local pSelectedUnit = UI.GetHeadSelectedUnit();
	if pSelectedUnit == nil or not HKS_IsZombie(pSelectedUnit) or pSelectedUnit:GetMovesRemaining() <= 0 then
		UI.SetInterfaceMode(InterfaceModeTypes.SELECTION);
		return;
	end

	g_deathCultSourcePlayerID = pSelectedUnit:GetOwner();
	g_deathCultSourceUnitID = pSelectedUnit:GetID();
	g_targetPlots = HKS_GetDevourTargetPlots(pSelectedUnit);
	HKS_HideYieldIconsForDevour();
	if #g_targetPlots > 0 then
		UILens.ToggleLayerOn(g_HexColoringPlacement);
		UILens.SetLayerHexesArea(g_HexColoringPlacement, pSelectedUnit:GetOwner(), g_targetPlots);

		local waves = {};
		for _, plotID in ipairs(g_targetPlots) do
			table.insert(waves, {
				pos1 = plotID,
				pos2 = pSelectedUnit:GetPlotId(),
				color = UI.GetColorValueFromHexLiteral(0xFFFFFFFF),
				speed = 2,
				type = "CIVILIZATION_UNKNOWN"
			});
		end
		local pOverlay = UILens.GetOverlay(FORM_CORPS_DIRECTION_OVERLAY_NAME);
		if pOverlay ~= nil then
			pOverlay:CreateLinearWaves(waves);
		end
	end
end

function OnInterfaceModeLeave_DeathCultDevour(eNewMode)
	UIManager:SetUICursor(CursorTypes.NORMAL);
	UILens.ToggleLayerOff(g_HexColoringPlacement);
	UILens.ClearLayerHexes(g_HexColoringPlacement);
	local pOverlay = UILens.GetOverlay(FORM_CORPS_DIRECTION_OVERLAY_NAME);
	if pOverlay ~= nil then
		pOverlay:ResetAllWaves();
	end
	HKS_RestoreYieldIconsAfterDevour();
	g_targetPlots = {};
	g_deathCultSourcePlayerID = -1;
	g_deathCultSourceUnitID = -1;
end

function LateInitialize()
	XP1_LateInitialize();

	InterfaceModeMessageHandler[InterfaceModeTypes.BUILD_IMPROVEMENT_ADJACENT] = {};
	InterfaceModeMessageHandler[InterfaceModeTypes.BUILD_IMPROVEMENT_ADJACENT][INTERFACEMODE_ENTER] = OnInterfaceModeChange_BuildImprovementAdjacent;
	InterfaceModeMessageHandler[InterfaceModeTypes.BUILD_IMPROVEMENT_ADJACENT][INTERFACEMODE_LEAVE] = OnInterfaceModeLeave_BuildImprovementAdjacent;
	InterfaceModeMessageHandler[InterfaceModeTypes.BUILD_IMPROVEMENT_ADJACENT][MouseEvents.LButtonUp] = OnMouseBuildImprovementAdjacentEnd;
	InterfaceModeMessageHandler[InterfaceModeTypes.BUILD_IMPROVEMENT_ADJACENT][KeyEvents.KeyUp] = OnPlacementKeyUp;

	InterfaceModeMessageHandler[InterfaceModeTypes.MOVE_JUMP] = {};
	InterfaceModeMessageHandler[InterfaceModeTypes.MOVE_JUMP][INTERFACEMODE_ENTER] = OnInterfaceModeChange_MoveJump;
	InterfaceModeMessageHandler[InterfaceModeTypes.MOVE_JUMP][INTERFACEMODE_LEAVE] = OnInterfaceModeLeave_MoveJump;
	InterfaceModeMessageHandler[InterfaceModeTypes.MOVE_JUMP][MouseEvents.LButtonUp] = OnMouseMoveJumpEnd;
	InterfaceModeMessageHandler[InterfaceModeTypes.MOVE_JUMP][KeyEvents.KeyUp] = OnPlacementKeyUp;

	InterfaceModeMessageHandler[InterfaceModeTypes.DEATH_CULT_DEVOUR] = {};
	InterfaceModeMessageHandler[InterfaceModeTypes.DEATH_CULT_DEVOUR][INTERFACEMODE_ENTER] = OnInterfaceModeChange_DeathCultDevour;
	InterfaceModeMessageHandler[InterfaceModeTypes.DEATH_CULT_DEVOUR][INTERFACEMODE_LEAVE] = OnInterfaceModeLeave_DeathCultDevour;
	InterfaceModeMessageHandler[InterfaceModeTypes.DEATH_CULT_DEVOUR][MouseEvents.LButtonUp] = OnMouseDeathCultDevourEnd;
	InterfaceModeMessageHandler[InterfaceModeTypes.DEATH_CULT_DEVOUR][KeyEvents.KeyUp] = OnPlacementKeyUp;

	if g_isTouchEnabled then
		InterfaceModeMessageHandler[InterfaceModeTypes.BUILD_IMPROVEMENT_ADJACENT][MouseEvents.PointerUp] = OnMouseBuildImprovementAdjacentEnd;
		InterfaceModeMessageHandler[InterfaceModeTypes.MOVE_JUMP][MouseEvents.PointerUp] = OnMouseMoveJumpEnd;
		InterfaceModeMessageHandler[InterfaceModeTypes.DEATH_CULT_DEVOUR][MouseEvents.PointerUp] = OnMouseDeathCultDevourEnd;
	end

	print("[Haikesi DeathCult UI] devour interface mode ready");
end
