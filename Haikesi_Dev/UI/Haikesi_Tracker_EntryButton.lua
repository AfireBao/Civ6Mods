-- Haikesi_Tracker_EntryButton
--------------------------------------------------------------
local m_LaunchButtonInstance = {}
local m_HasPendingSelection = false

-- 门控：检查本地玩家是否有未完成的 MIMIC 能力选择
-- （选了 COSPLAY 海克斯但还没选具体能力：PROPERTY_NW_HAIKESI_MIMIC=1 且 PROP_NW_HAIKESI_MIMIC_TRAIT 未设）
local function HasPendingMimicChoice()
    local localPlayerID = Game.GetLocalPlayer()
    if localPlayerID == nil or localPlayerID == PlayerTypes.NONE then return false end
    local pPlayer = Players[localPlayerID]
    if pPlayer == nil then return false end
    local hasMimic = (pPlayer:GetProperty('PROPERTY_NW_HAIKESI_MIMIC') or 0) > 0
    local hasChosenTrait = pPlayer:GetProperty('PROP_NW_HAIKESI_MIMIC_TRAIT') ~= nil
    return hasMimic and (not hasChosenTrait)
end

function Toggle_HaikesiTracker_Popup()
    -- 门控优先级：MIMIC 待选能力 > 海克斯待选 > 追踪/图鉴
    if HasPendingMimicChoice() then
        LuaEvents.Haikesi_OpenAbilityPanel()
        return
    end
    if m_HasPendingSelection then
        m_HasPendingSelection = false
        LuaEvents.Haikesi_TogglePanel()
    else
        LuaEvents.Haikesi_ToggleTracker()
    end
end

-- 命名回调函数（支持热重载 Remove）
local function OnPendingSelection()
    m_HasPendingSelection = true
end

local function OnClearPendingSelection()
    m_HasPendingSelection = false
end

-- 向 LaunchBar 注入入口按钮。返回 true 表示成功。
-- ButtonStack 在本 context 初始化时可能尚未就绪，失败时由调用方延迟到 LoadScreenClose 重试。
local function InjectLaunchButton()
    local buttonStack = ContextPtr:LookUpControl("/InGame/LaunchBar/ButtonStack")
    if buttonStack == nil then
        return false
    end

    ContextPtr:BuildInstanceForControl("HaikesiTracker_Info", m_LaunchButtonInstance, buttonStack)
    m_LaunchButtonInstance.HaikesiTracker_InfoIcon:SetIcon('ICON_HAIKESI_RELIC_ARCANEPUNCHRUNE')
    m_LaunchButtonInstance.HaikesiTracker_InfoButton:RegisterCallback(Mouse.eLClick, Toggle_HaikesiTracker_Popup)
    ContextPtr:BuildInstanceForControl("HaikesiTracker_PinInstance", {}, buttonStack)

    buttonStack:CalculateSize()
    local backing = ContextPtr:LookUpControl("/InGame/LaunchBar/LaunchBacking")
    backing:SetSizeX(buttonStack:GetSizeX() + 116)
    local backingTile = ContextPtr:LookUpControl("/InGame/LaunchBar/LaunchBackingTile")
    backingTile:SetSizeX(buttonStack:GetSizeX() - 20)
    LuaEvents.LaunchBar_Resize(buttonStack:GetSizeX())
    return true
end

local function OnLoadScreenClose()
    if InjectLaunchButton() then
        Events.LoadScreenClose.Remove(OnLoadScreenClose)
    end
end

function Initialize()
    local localPlayerID = Game.GetLocalPlayer()
    if localPlayerID ~= nil and localPlayerID ~= PlayerTypes.NONE and Players[localPlayerID] ~= nil and Players[localPlayerID]:IsHuman() then
        if not InjectLaunchButton() then
            -- LaunchBar 尚未就绪，等待载入完成后再注入
            Events.LoadScreenClose.Add(OnLoadScreenClose)
        end
    end

    -- 智能路由：监听待选标记
    LuaEvents.Haikesi_PendingSelection.Add(OnPendingSelection)
    LuaEvents.Haikesi_ClearPendingSelection.Add(OnClearPendingSelection)
end

function OnInit(isReload)
    if isReload then
        LuaEvents.Haikesi_PendingSelection.Remove(OnPendingSelection)
        LuaEvents.Haikesi_ClearPendingSelection.Remove(OnClearPendingSelection)
        Events.LoadScreenClose.Remove(OnLoadScreenClose)
    end
    Initialize()
end
ContextPtr:SetInitHandler(OnInit)
