-- ===========================================================================
-- 种地仙人 — 独立种植入口（仅 UNIT_NW_FARM_IMMORTAL）
-- 策略 B：白名单 + UI 近似 / Gameplay CanHaveResource 校验
-- 借鉴 BP_ResourcePlanter 的 Launcher 挂载方式，不依赖、不要求启用该模组
-- ===========================================================================

local NW_FARM_IMMORTAL_UNIT:string = "UNIT_NW_FARM_IMMORTAL";
local NW_LAUNCHER_ICON:string = "ICON_UNITOPERATION_PLANT_FOREST";

local m_whitelist:table = nil;
local m_validTerrainsByResource:table = nil;
local m_validFeaturesByResource:table = nil;
local m_launcherAttached:boolean = false;

local function BuildCaches()
    if m_whitelist ~= nil then
        return;
    end
    m_whitelist = {};
    m_validTerrainsByResource = {};
    m_validFeaturesByResource = {};

    if GameInfo.Haikesi_PlanterResources ~= nil then
        for row in GameInfo.Haikesi_PlanterResources() do
            local info:table = GameInfo.Resources[row.ResourceType];
            if info ~= nil then
                local filterKey:string = nil;
                if info.ResourceClassType == "RESOURCECLASS_BONUS" then
                    filterKey = "BONUS";
                elseif info.ResourceClassType == "RESOURCECLASS_LUXURY" then
                    filterKey = "LUXURY";
                end
                if filterKey ~= nil then
                    table.insert(m_whitelist, {
                        Info = info,
                        FilterKey = filterKey,
                        Icon = "ICON_" .. info.ResourceType
                    });
                end
            end
        end
    end

    for row in GameInfo.Resource_ValidTerrains() do
        if m_validTerrainsByResource[row.ResourceType] == nil then
            m_validTerrainsByResource[row.ResourceType] = {};
        end
        m_validTerrainsByResource[row.ResourceType][row.TerrainType] = true;
    end
    for row in GameInfo.Resource_ValidFeatures() do
        if m_validFeaturesByResource[row.ResourceType] == nil then
            m_validFeaturesByResource[row.ResourceType] = {};
        end
        m_validFeaturesByResource[row.ResourceType][row.FeatureType] = true;
    end
end

local function IsFarmImmortal(pUnit:table)
    if pUnit == nil then return false; end
    local unitInfo:table = GameInfo.Units[pUnit:GetType()];
    return unitInfo ~= nil and unitInfo.UnitType == NW_FARM_IMMORTAL_UNIT;
end

local function HasUnlockedResource(resourceInfo:table, player:table)
    if resourceInfo == nil or player == nil then return false; end
    if resourceInfo.PrereqTech ~= nil then
        local techInfo:table = GameInfo.Technologies[resourceInfo.PrereqTech];
        local techs:table = player:GetTechs();
        if techs == nil or techInfo == nil or not techs:HasTech(techInfo.Index) then
            return false;
        end
    end
    if resourceInfo.PrereqCivic ~= nil then
        local civicInfo:table = GameInfo.Civics[resourceInfo.PrereqCivic];
        local culture:table = player:GetCulture();
        if culture == nil or civicInfo == nil or not culture:HasCivic(civicInfo.Index) then
            return false;
        end
    end
    return true;
end

local function IsCommonPlotValid(plot:table, playerID:number)
    if plot == nil then return false; end
    if plot:IsNaturalWonder() or plot:GetDistrictType() ~= -1 or plot:GetResourceType() ~= -1 then
        return false;
    end
    local owner:number = plot:GetOwner();
    return owner == -1 or owner == playerID;
end

-- UI 侧近似 CanHaveResource（Gameplay 仍以 ResourceBuilder.CanHaveResource 为准）
local function UICanHaveResource(plot:table, resourceType:string)
    if plot == nil or resourceType == nil then return false; end
    local terrainInfo:table = GameInfo.Terrains[plot:GetTerrainType()];
    if terrainInfo == nil then return false; end
    local terrainType:string = terrainInfo.TerrainType;
    local featureIndex:number = plot:GetFeatureType();
    local featureType:string = nil;
    if featureIndex ~= nil and featureIndex >= 0 then
        local featureInfo:table = GameInfo.Features[featureIndex];
        featureType = featureInfo and featureInfo.FeatureType or nil;
        if featureInfo ~= nil and featureInfo.NaturalWonder ~= 0 then
            return false;
        end
    end

    local terrainRules:table = m_validTerrainsByResource[resourceType];
    local featureRules:table = m_validFeaturesByResource[resourceType];
    local hasTerrain:boolean = terrainRules ~= nil;
    local hasFeature:boolean = featureRules ~= nil;
    local terrainOk:boolean = hasTerrain and terrainRules[terrainType] == true;
    local featureOk:boolean = hasFeature and featureType ~= nil and featureRules[featureType] == true;

    if hasFeature and hasTerrain then
        return terrainOk or featureOk;
    elseif hasFeature then
        return featureOk;
    elseif hasTerrain then
        return terrainOk;
    end
    return false;
end

local function CollectPlantableEntries(pUnit:table)
    local entries:table = {};
    BuildCaches();
    local localPlayerID:number = Game.GetLocalPlayer();
    if localPlayerID < 0
        or not IsFarmImmortal(pUnit)
        or pUnit:GetOwner() ~= localPlayerID
        or pUnit:GetBuildCharges() <= 0
        or pUnit:GetMovesRemaining() <= 0 then
        return entries;
    end

    local plot:table = Map.GetPlot(pUnit:GetX(), pUnit:GetY());
    local player:table = Players[localPlayerID];
    if player == nil or not IsCommonPlotValid(plot, localPlayerID) then
        return entries;
    end

    for _, def in ipairs(m_whitelist) do
        local info:table = def.Info;
        if HasUnlockedResource(info, player) and UICanHaveResource(plot, info.ResourceType) then
            table.insert(entries, {
                ResourceIndex = info.Index,
                ResourceType = info.ResourceType,
                Name = Locale.Lookup(info.Name),
                IconId = def.Icon,
                FilterKey = def.FilterKey
            });
        end
    end

    table.sort(entries, function(a:table, b:table)
        if a.FilterKey ~= b.FilterKey then
            return a.FilterKey < b.FilterKey;
        end
        return Locale.Compare(a.Name, b.Name) == -1;
    end);
    return entries;
end

local function RequestPlant(resourceIndex:number)
    local pSelectedUnit:table = UI.GetHeadSelectedUnit();
    if pSelectedUnit == nil then return; end
    UI.RequestPlayerOperation(pSelectedUnit:GetOwner(), PlayerOperations.EXECUTE_SCRIPT, {
        OnStart = "HaikesiPlantResource",
        UnitID = pSelectedUnit:GetID(),
        X = pSelectedUnit:GetX(),
        Y = pSelectedUnit:GetY(),
        ResourceIndex = resourceIndex
    });
    SimUnitSystem.SetAnimationState(pSelectedUnit, "ACTION_1", "IDLE");
    UI.PlaySound("Build_Improvement_2D");
    Controls.LauncherGrid:SetHide(true);
end

local function ShowChooser(entries:table)
    if entries == nil or #entries == 0 then return; end
    if #entries == 1 then
        RequestPlant(entries[1].ResourceIndex);
        return;
    end
    LuaEvents.Haikesi_PlanterChooser_Open(entries);
end

local function AttachLauncher()
    if m_launcherAttached then return; end
    local actionStack:table = ContextPtr:LookUpControl("/InGame/UnitPanel/StandardActionsStack");
    if actionStack ~= nil then
        Controls.LauncherGrid:ChangeParent(actionStack);
        Controls.LauncherGrid:SetOffsetVal(0, 0);
        m_launcherAttached = true;
    end
end

local function RefreshLauncher()
    AttachLauncher();
    local selectedUnit:table = UI.GetHeadSelectedUnit();
    local localPlayerID:number = Game.GetLocalPlayer();
    local isOurs:boolean = localPlayerID >= 0
        and selectedUnit ~= nil
        and selectedUnit:GetOwner() == localPlayerID
        and IsFarmImmortal(selectedUnit);
    local entries:table = CollectPlantableEntries(selectedUnit);
    Controls.LauncherGrid:SetHide(not isOurs);
    Controls.LauncherButton:SetDisabled(#entries == 0);
    Controls.LauncherButton:SetAlpha(#entries == 0 and 0.6 or 1);
    if isOurs then
        local tip:string = Locale.Lookup("LOC_HAIKESI_PLANTER_ACTION_DESCRIPTION");
        tip = tip .. "[NEWLINE][NEWLINE]" .. Locale.Lookup("LOC_HAIKESI_PLANTER_AVAILABLE") .. " " .. tostring(#entries);
        Controls.LauncherButton:SetToolTipString(tip);
    end
end

local function OnLauncherClicked()
    local entries:table = CollectPlantableEntries(UI.GetHeadSelectedUnit());
    if #entries == 0 then
        RefreshLauncher();
        return;
    end
    UI.PlaySound("Play_UI_Click");
    ShowChooser(entries);
end

local function OnChooserPlantSelected(resourceIndex:number)
    local entries:table = CollectPlantableEntries(UI.GetHeadSelectedUnit());
    for _, entry in ipairs(entries) do
        if entry.ResourceIndex == resourceIndex then
            RequestPlant(resourceIndex);
            return;
        end
    end
    RefreshLauncher();
end

local function OnLocalUnitChanged(playerID:number)
    if playerID == Game.GetLocalPlayer() then
        LuaEvents.Haikesi_PlanterChooser_Invalidate();
        RefreshLauncher();
    end
end

local function OnInit()
    Controls.LauncherIcon:SetIcon(NW_LAUNCHER_ICON);
    Controls.LauncherButton:RegisterCallback(Mouse.eLClick, OnLauncherClicked);
    Controls.LauncherButton:RegisterCallback(Mouse.eMouseEnter, function() UI.PlaySound("Main_Menu_Mouse_Over"); end);
    Controls.LauncherGrid:SetHide(true);
    AttachLauncher();
end

ContextPtr:SetInitHandler(OnInit);
Events.LoadGameViewStateDone.Add(RefreshLauncher);
Events.UnitSelectionChanged.Add(OnLocalUnitChanged);
Events.UnitMoveComplete.Add(OnLocalUnitChanged);
Events.UnitChargesChanged.Add(OnLocalUnitChanged);
Events.ResearchCompleted.Add(OnLocalUnitChanged);
Events.CivicCompleted.Add(OnLocalUnitChanged);
Events.UnitMovementPointsChanged.Add(OnLocalUnitChanged);
Events.UnitMovementPointsCleared.Add(OnLocalUnitChanged);
Events.UnitMovementPointsRestored.Add(OnLocalUnitChanged);
Events.PlayerTurnActivated.Add(OnLocalUnitChanged);
Events.PlayerTurnDeactivated.Add(OnLocalUnitChanged);
LuaEvents.Haikesi_PlanterChooser_PlantSelected.Add(OnChooserPlantSelected);
LuaEvents.Haikesi_PlanterChooser_Canceled.Add(RefreshLauncher);
