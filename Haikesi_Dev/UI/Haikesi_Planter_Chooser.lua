-- ===========================================================================
-- 种地仙人 — 资源选择器（借鉴 BP_ResourcePlanter 弹窗模式，不依赖该模组）
-- ===========================================================================
include("InstanceManager");
include("TabSupport");

local DATA_FIELD_SELECTION:string = "Selection";
local FILTER_ALL:string = "ALL";
local FILTER_BONUS:string = "BONUS";
local FILTER_LUXURY:string = "LUXURY";

local m_resourceEntryIM:table = nil;
local m_tabIM:table = nil;
local m_kTabs:table = nil;
local m_pendingEntries:table = {};
local m_currentFilter:string = FILTER_ALL;
local RefreshList;

local function EntryToFilterKey(entry:table)
    if entry == nil then return nil; end
    return entry.FilterKey;
end

local function TrySetIconFromId(iconControl:table, iconId:string)
    if iconControl == nil or iconId == nil or iconId == "" then
        return false;
    end
    for _, iconSize in ipairs({38, 32, 50, 22, 64, 80, 256}) do
        local textureOffsetX:number, textureOffsetY:number, textureSheet:string = IconManager:FindIconAtlas(iconId, iconSize);
        if textureSheet ~= nil then
            iconControl:SetTexture(textureOffsetX, textureOffsetY, textureSheet);
            return true;
        end
    end
    return false;
end

local function ResolveEntryIcon(iconControl:table, entry:table)
    local candidates:table = { entry and entry.IconId or nil };
    if entry ~= nil and entry.ResourceType ~= nil then
        table.insert(candidates, "ICON_" .. entry.ResourceType);
        table.insert(candidates, entry.ResourceType);
    end
    for _, iconId in ipairs(candidates) do
        if TrySetIconFromId(iconControl, iconId) then
            return iconId;
        end
    end
    return nil;
end

local function Close()
    if not UIManager:IsInPopupQueue(ContextPtr) then
        return;
    end
    UIManager:DequeuePopup(ContextPtr);
end

local function Invalidate()
    Close();
    m_pendingEntries = {};
end

function RefreshList()
    if m_resourceEntryIM == nil then
        return;
    end
    m_resourceEntryIM:ResetInstances();

    local visible:table = {};
    for _, entry in ipairs(m_pendingEntries) do
        if m_currentFilter == FILTER_ALL or EntryToFilterKey(entry) == m_currentFilter then
            table.insert(visible, entry);
        end
    end

    if #visible == 0 then
        Controls.EmptyHint:SetHide(false);
        Controls.ChooserListStack:SetHide(true);
    else
        Controls.EmptyHint:SetHide(true);
        Controls.ChooserListStack:SetHide(false);
        for _, entry in ipairs(visible) do
            local instance:table = m_resourceEntryIM:GetInstance();
            if instance ~= nil then
                local resolvedIconId:string = ResolveEntryIcon(instance.ResourceIcon, entry);
                instance.ResourceIcon:SetHide(resolvedIconId == nil);
                instance.MissingIcon:SetHide(resolvedIconId ~= nil);
                instance.ResourceName:SetText(entry.Name);
                instance.Button:SetToolTipString(entry.Name);
                instance.Button:RegisterCallback(Mouse.eLClick, function()
                    Close();
                    LuaEvents.Haikesi_PlanterChooser_PlantSelected(entry.ResourceIndex);
                end);
                instance.Button:RegisterCallback(Mouse.eMouseEnter, function() UI.PlaySound("Main_Menu_Mouse_Over"); end);
            end
        end
    end
    Controls.ChooserListStack:CalculateSize();
    Controls.ChooserScrollPanel:CalculateSize();
end

local function AddFilterTab(nameKey:string, filterKey:string)
    local kTab:table = m_tabIM:GetInstance();
    if kTab == nil then return; end
    kTab.Button[DATA_FIELD_SELECTION] = kTab.Selection;
    local callback:ifunction = function()
        if m_kTabs.prevSelectedControl ~= nil and m_kTabs.prevSelectedControl[DATA_FIELD_SELECTION] ~= nil then
            m_kTabs.prevSelectedControl[DATA_FIELD_SELECTION]:SetHide(true);
        end
        kTab.Selection:SetHide(false);
        m_currentFilter = filterKey;
        RefreshList();
    end
    kTab.Button:GetTextControl():SetText(Locale.Lookup(nameKey));
    kTab.Button:SetSizeToText(40, 20);
    kTab.Button:RegisterCallback(Mouse.eMouseEnter, function() UI.PlaySound("Main_Menu_Mouse_Over"); end);
    m_kTabs.AddTab(kTab.Button, callback);
end

local function Open(entries:table)
    if entries == nil or #entries == 0 then
        return;
    end
    if not UIManager:IsInPopupQueue(ContextPtr) then
        UIManager:QueuePopup(ContextPtr, PopupPriority.Low, { AlwaysVisibleInQueue = true });
    end
    m_pendingEntries = entries;
    m_currentFilter = FILTER_ALL;
    if m_kTabs ~= nil and m_kTabs.tabControls ~= nil and m_kTabs.tabControls[1] ~= nil then
        m_kTabs.SelectTab(m_kTabs.tabControls[1]);
    end
    Controls.ChooserTitle:SetText(Locale.ToUpper(Locale.Lookup("LOC_HAIKESI_PLANTER_CHOOSER_TITLE")));
    Controls.ChooserPrompt:SetText(Locale.Lookup("LOC_HAIKESI_PLANTER_CHOOSER_PROMPT"));
    RefreshList();
    UI.PlaySound("UI_Screen_Open");
end

local function OnCancel()
    Close();
    LuaEvents.Haikesi_PlanterChooser_Canceled();
end

local function OnInputHandler(pInputStruct:table)
    if pInputStruct:GetMessageType() == KeyEvents.KeyUp and pInputStruct:GetKey() == Keys.VK_ESCAPE then
        OnCancel();
        return true;
    end
    return false;
end

local function OnInit()
    m_resourceEntryIM = InstanceManager:new("ResourceEntryInstance", "Button", Controls.ChooserListStack);
    m_tabIM = InstanceManager:new("TabInstance", "Button", Controls.FilterTabContainer);
    m_kTabs = CreateTabs(Controls.FilterTabContainer, 42, 34, UI.GetColorValueFromHexLiteral(0xFF331D05));
    AddFilterTab("LOC_HAIKESI_PLANTER_FILTER_ALL", FILTER_ALL);
    AddFilterTab("LOC_HAIKESI_PLANTER_FILTER_BONUS", FILTER_BONUS);
    AddFilterTab("LOC_HAIKESI_PLANTER_FILTER_LUXURY", FILTER_LUXURY);
    m_kTabs.SameSizedTabs(20);
    m_kTabs.CenterAlignTabs(0);
    if m_kTabs.tabControls ~= nil and m_kTabs.tabControls[1] ~= nil then
        m_kTabs.SelectTab(m_kTabs.tabControls[1]);
    end
    Controls.CancelButton:RegisterCallback(Mouse.eLClick, OnCancel);
    Controls.CancelButton:RegisterCallback(Mouse.eMouseEnter, function() UI.PlaySound("Main_Menu_Mouse_Over"); end);
    Controls.ScreenConsumer:RegisterCallback(Mouse.eRClick, OnCancel);
    LuaEvents.Haikesi_PlanterChooser_Open.Add(Open);
    LuaEvents.Haikesi_PlanterChooser_Invalidate.Add(Invalidate);
end

local function OnShutdown()
    LuaEvents.Haikesi_PlanterChooser_Open.Remove(Open);
    LuaEvents.Haikesi_PlanterChooser_Invalidate.Remove(Invalidate);
    if m_resourceEntryIM ~= nil then m_resourceEntryIM:ResetInstances(); end
    if m_tabIM ~= nil then m_tabIM:ResetInstances(); end
    m_pendingEntries = {};
end

ContextPtr:SetInitHandler(OnInit);
ContextPtr:SetShutdown(OnShutdown);
ContextPtr:SetInputHandler(OnInputHandler, true);
