-- ===========================================================================
-- Haikesi_Tracker_Panel.lua — 海克斯追踪弹窗（双Tab：已选 + 图鉴）
-- ===========================================================================
include("InstanceManager")
include("TabSupport")
include("Civ6Common")

-- ===========================================================================
-- CONSTANTS
-- ===========================================================================
local TAB_SIZE = 170
local TAB_PADDING = 10

-- ===========================================================================
-- InstanceManagers
-- ===========================================================================
local m_tabButtonIM = InstanceManager:new("TabButtonInstance", "Button", Controls.TabContainer)
local m_tabs = nil
local m_PlayerRowIM = InstanceManager:new("HaikesiPlayerRow", "Content", Controls.PlayerStack)
local m_EncyclopediaIM = InstanceManager:new("HaikesiEncyclopediaEntry", "Content", Controls.EncyclopediaStack)

-- 前向声明：m_HomeTabInstance 在 Initialize 中赋值，但被 OnShow 引用（OnShow 定义在 Initialize 之前）
-- 必须先声明 local，否则 OnShow 闭包会捕获全局 nil
local m_HomeTabInstance = nil

-- ===========================================================================
-- 反向索引
-- ===========================================================================
local IndexToRelic = {}
local RelicTypeToRelic = {}
local HAIKESI_RELICS_PROP_KEY = 'PROP_NW_HAIKESI_RELICS'
local HAIKESI_RELIC_COUNT_KEY = 'PROP_NW_HAIKESI_RELIC_COUNT'
local HAIKESI_RELIC_SLOT_PREFIX = 'PROP_NW_HAIKESI_RELIC_'
local HAIKESI_RELIC_SUMMARY_PREFIX = 'PROP_NW_HAIKESI_RELIC_SUMMARY_'
local HAIKESI_RELIC_REASON_PREFIX = 'PROP_NW_HAIKESI_RELIC_REASON_'
local AI_RELIC_TYPE_PREFIX = 'NW_AI_'

local function BuildIndexMap()
    IndexToRelic = {}
    RelicTypeToRelic = {}
    for row in GameInfo.Haikesi_Relics() do
        IndexToRelic[row.Index] = row
        RelicTypeToRelic[row.RelicType] = row
    end
end

local function GetRelicCardsForPlayer(pPlayer)
    local relicCards = {}
    local count = tonumber(pPlayer:GetProperty(HAIKESI_RELIC_COUNT_KEY) or 0) or 0
    if count > 0 then
        for i = 1, count do
            local relicType = pPlayer:GetProperty(HAIKESI_RELIC_SLOT_PREFIX .. i)
            local relicRow = RelicTypeToRelic[relicType]
            if relicRow ~= nil then
                table.insert(relicCards, relicRow)
            end
        end
    end
    if #relicCards > 0 then
        return relicCards
    end

    local prop = pPlayer:GetProperty(HAIKESI_RELICS_PROP_KEY) or ""
    if prop ~= "" then
        for idxStr in string.gmatch(prop, "[^|]+") do
            local idx = tonumber(idxStr)
            local relicRow = IndexToRelic[idx]
            if relicRow then
                table.insert(relicCards, relicRow)
            end
        end
    end
    return relicCards
end

-- 追踪卡片 icon 下方文案：AI 海克斯优先显示大模型决策理由（[领袖名]觉得[reason]，故选择[海克斯名称]）
local function IsAIRelicType(relicType)
    return relicType ~= nil and string.sub(relicType, 1, #AI_RELIC_TYPE_PREFIX) == AI_RELIC_TYPE_PREFIX
end

local function GetLeaderDisplayName(pPlayer)
    if pPlayer == nil then
        return ""
    end
    local pConfig = PlayerConfigurations[pPlayer:GetID()]
    if pConfig == nil then
        return ""
    end
    return Locale.Lookup(pConfig:GetLeaderName()) or Locale.Lookup(pConfig:GetPlayerName()) or ""
end

-- 修复旧存档里 Lua5.1 把 \\xNN 收成字面 "xe5x88..." 的决策理由
local function DecodeMangledHexReason(text)
    if text == nil or text == "" then
        return text
    end
    local hexBody = text:match("^((?:\\x[0-9a-fA-F][0-9a-fA-F])+)$")
    if hexBody ~= nil then
        hexBody = hexBody:gsub("\\x", "x")
    else
        hexBody = text:match("^((?:x[0-9a-fA-F][0-9a-fA-F])+)$")
    end
    if hexBody == nil then
        return text
    end
    local bytes = {}
    for h in hexBody:gmatch("x([0-9a-fA-F][0-9a-fA-F])") do
        table.insert(bytes, string.char(tonumber(h, 16)))
    end
    if #bytes == 0 then
        return text
    end
    return table.concat(bytes)
end

local function GetRelicCardDisplayText(pPlayer, slotIndex, relicRow)
    -- AI 海克斯：有大模型决策理由时显示理由；否则只显示名称（不用效果描述）
    if IsAIRelicType(relicRow.RelicType) then
        if pPlayer ~= nil and slotIndex ~= nil then
            local reason = pPlayer:GetProperty(HAIKESI_RELIC_REASON_PREFIX .. slotIndex)
            if reason ~= nil and reason ~= "" then
                reason = DecodeMangledHexReason(tostring(reason))
                -- 截断残留的裸 hex 不当理由显示
                if reason:match("^[0-9a-fA-F]+$") and #reason >= 16 then
                    reason = ""
                end
                if reason ~= nil and reason ~= "" then
                    return reason
                end
            end
        end
        return Locale.Lookup(relicRow.Name) or ""
    end

    if pPlayer ~= nil and slotIndex ~= nil then
        local stored = pPlayer:GetProperty(HAIKESI_RELIC_SUMMARY_PREFIX .. slotIndex)
        if stored ~= nil and stored ~= "" then
            if string.sub(stored, 1, 4) == 'LOC_' then
                return Locale.Lookup(stored) or stored
            end
            return stored
        end
    end

    return Locale.Lookup(relicRow.Name) or ""
end

-- ===========================================================================
-- 图鉴数据（一次性加载，静态）
-- 开发者模式（NW_HAIKESI_MODE == 3）下列出全部海克斯（含未实装），便于设计期对照
-- ===========================================================================
local g_EncyclopediaLoaded = false
local g_RelicPrerequisiteKindMap = nil

local function GetRelicPrerequisiteKind(relicType)
    if g_RelicPrerequisiteKindMap == nil then
        g_RelicPrerequisiteKindMap = {}
        if GameInfo.Haikesi_Relic_Prerequisites ~= nil then
            for req in GameInfo.Haikesi_Relic_Prerequisites() do
                local kind = tostring(req.PrerequisiteKind or "")
                local currentKind = g_RelicPrerequisiteKindMap[req.RelicType]
                if currentKind == nil or kind < currentKind then
                    g_RelicPrerequisiteKindMap[req.RelicType] = kind
                end
            end
        end
    end

    return g_RelicPrerequisiteKindMap[relicType] or ""
end

local function InitEncyclopediaData()
    if g_EncyclopediaLoaded then return end
    g_EncyclopediaLoaded = true

    -- mode==3 → DEV：放行 IsActive==0 的占位海克斯（参见 Haikesi_Config_FE.sql DomainValues）
    local mode = GameConfiguration.GetValue('NW_HAIKESI_MODE') or 0
    local isDevMode = (mode == 3)
    local encyclopediaRows = {}

    for row in GameInfo.Haikesi_Relics() do
        -- 默认仅列已实装且填了描述的；DEV 模式全部列出
        local isActive = (row.IsActive == 1)
        local desc = Locale.Lookup(row.Description) or ""
        local hasDesc = (desc ~= "" and desc ~= "效果待填充")

        local showEntry
        if isDevMode then
            showEntry = true                          -- DEV：一律显示
        else
            showEntry = isActive and hasDesc          -- 正式：原有筛选
        end

        if showEntry then
            table.insert(encyclopediaRows, {
                Row = row,
                PrerequisiteKind = GetRelicPrerequisiteKind(row.RelicType),
                Index = row.Index or 0
            })
        end
    end

    table.sort(encyclopediaRows, function(a, b)
        if a.PrerequisiteKind ~= b.PrerequisiteKind then
            return a.PrerequisiteKind < b.PrerequisiteKind
        end
        return a.Index < b.Index
    end)

    m_EncyclopediaIM:ResetInstances()
    for _, entry in ipairs(encyclopediaRows) do
        local row = entry.Row
        local instance = m_EncyclopediaIM:GetInstance()
        instance.RelicIcon:SetIcon(row.Icon)

        -- 仅「效果待填充」/无描述的占位项加标签；已写效果的（含 IsActive=0 的 AI 卡）不标
        local name = Locale.ToUpper(Locale.Lookup(row.Name))
        local desc = Locale.Lookup(row.Description) or ""
        local hasDesc = (desc ~= "" and desc ~= "效果待填充")
        if isDevMode and not hasDesc then
            name = "[待实装] " .. name
        end
        instance.RelicName:SetText(name)

        -- 描述：DEV 模式下未填的用 RelicType 兜底，避免 UI 行高坍塌
        if hasDesc then
            instance.RelicDesc:SetText(desc)
        else
            instance.RelicDesc:SetText("（暂无描述 · " .. tostring(row.RelicType) .. "）")
        end
        instance.RelicFlavor:SetText(Locale.Lookup(row.Flavor) or "")
    end
    Controls.EncyclopediaStack:CalculateSize()
    Controls.EncyclopediaScroller:CalculateSize()
end

-- ===========================================================================
-- Refresh — 已选海克斯追踪
-- ===========================================================================
function Refresh()
    m_PlayerRowIM:ResetInstances()
    BuildIndexMap()

    local alivePlayers = PlayerManager.GetAliveMajors()
    for _, pPlayer in ipairs(alivePlayers) do
        local relicCards = GetRelicCardsForPlayer(pPlayer)
        if #relicCards > 0 then
            local playerID = pPlayer:GetID()
            local rowInstance = m_PlayerRowIM:GetInstance()

            local pConfig = PlayerConfigurations[playerID]
            rowInstance.PlayerName:SetText(Locale.Lookup(pConfig:GetPlayerName()))

            local leaderType = pConfig:GetLeaderTypeName()
            rowInstance.CivIcon:SetIcon("ICON_" .. leaderType)

            local relicGrid = rowInstance.RelicGrid
            relicGrid:DestroyAllChildren()

            local rowIM = InstanceManager:new("HaikesiRelicRow", "Content", relicGrid)
            local cardIM = nil
            for i, relicRow in ipairs(relicCards) do
                if (i - 1) % 6 == 0 then
                    local rowInst = rowIM:GetInstance()
                    cardIM = InstanceManager:new("HaikesiRelicCard", "Content", rowInst.Content)
                end
                local card = cardIM:GetInstance()
                card.CardIcon:SetIcon(relicRow.Icon)
                local tooltip = Locale.Lookup(relicRow.Description) or ""
                -- MIMICRUNE 卡片：海克斯描述 + 换行 + 能力标题 + 换行 + 能力描述
                if relicRow.RelicType == 'MIMICRUNE' then
                    local trait = pPlayer:GetProperty('PROP_NW_HAIKESI_MIMIC_TRAIT')
                    local tInfo = trait and GameInfo.Traits[trait] or nil
                    if tInfo and tInfo.Name and tInfo.Description then
                        tooltip = tooltip
                            .. "[NEWLINE][NEWLINE]"
                            .. "[COLOR:ResScienceLabelCS]" .. Locale.Lookup(tInfo.Name) .. "[ENDCOLOR]"
                            .. "[NEWLINE]"
                            .. Locale.Lookup(tInfo.Description)
                    end
                end
                card.CardIcon:SetToolTipString(tooltip)
                card.CardName:SetText(GetRelicCardDisplayText(pPlayer, i, relicRow))
            end

            relicGrid:CalculateSize()
            -- rowInstance.Content 是 Grid 控件（XML: Instance HaikesiPlayerRow），
            -- Grid 无 CalculateSize 方法，直接调用会抛 "function expected instead of nil"
            -- 从而中断整个 alivePlayers 循环，只留下首个已渲染玩家可见（详见踩坑经验）。
            -- 用 ReprocessAnchoring 替代：让 Grid 依据 auto 尺寸 + 内层 Stack 重排。
            rowInstance.Content:ReprocessAnchoring()
        end
    end

    Controls.PlayerStack:CalculateSize()
    Controls.PlayerScroller:CalculateSize()
end

-- ===========================================================================
-- Area 切换
-- ===========================================================================
local function ResetAreas()
    Controls.TrackerArea:SetHide(true)
    Controls.EncyclopediaArea:SetHide(true)
end

local function ViewTracker()
    ResetAreas()
    Controls.TrackerArea:SetHide(false)
    Refresh()
    Controls.PlayerStack:CalculateSize()
    Controls.PlayerScroller:CalculateSize()
end

local function ViewEncyclopedia()
    ResetAreas()
    Controls.EncyclopediaArea:SetHide(false)
    InitEncyclopediaData()
    Controls.EncyclopediaStack:CalculateSize()
    Controls.EncyclopediaScroller:CalculateSize()
end

-- ===========================================================================
-- Tab 按钮辅助（实例化按钮无法被 TabSupport 的 SetSelectedTabVisually 选中，
-- 因为其 SelectButton 是 InstanceManager 实例的子控件，不在顶层 Controls 表中。
-- 故需自建高亮：显式显隐各实例的 SelectButton 叠加层）
-- 先 local 声明，再赋函数体，确保上方的 OnTrackerTabClick/OnEncyclopediaTabClick 闭包
-- 捕获到本 local（而非全局 nil）
-- ===========================================================================
local SetTabButtonsSelected
local function OnTrackerTabClick(uiSelectedButton)
    SetTabButtonsSelected(uiSelectedButton)
    ViewTracker()
end

local function OnEncyclopediaTabClick(uiSelectedButton)
    SetTabButtonsSelected(uiSelectedButton)
    ViewEncyclopedia()
end

SetTabButtonsSelected = function(buttonControl)
    for i = 1, m_tabButtonIM.m_iCount, 1 do
        local buttonInstance = m_tabButtonIM:GetAllocatedInstance(i)
        if buttonInstance then
            if buttonInstance.Button == buttonControl then
                buttonInstance.Button:SetSelected(true)
                buttonInstance.SelectButton:SetHide(false)
            else
                buttonInstance.Button:SetSelected(false)
                buttonInstance.SelectButton:SetHide(true)
            end
        end
    end
end

-- ===========================================================================
-- 面板控制
-- ===========================================================================
local function Open()
    if not UIManager:IsInPopupQueue(ContextPtr) then
        local kParameters = {}
        kParameters.RenderAtCurrentParent = true
        kParameters.InputAtCurrentParent = true
        kParameters.AlwaysVisibleInQueue = true
        UIManager:QueuePopup(ContextPtr, PopupPriority.Low, kParameters)
        UI.PlaySound("UI_Screen_Open")
    end
    -- tab 高亮与内容由 OnShow 统一设置
    print("[Haikesi Tracker] 面板已打开")
end

-- context 真正显示时回调（首次打开 + 关闭再开都会触发）
-- 自建高亮 + 内容刷新，避开 TabSupport 对实例化按钮的无效选中
local function OnShow()
    SetTabButtonsSelected(m_HomeTabInstance.Button)
    ViewTracker()
    print("[Haikesi Tracker] OnShow — tab 与内容已就绪")
end

local function Close()
    if UIManager:DequeuePopup(ContextPtr) then
        UI.PlaySound("UI_Screen_Close")
        print("[Haikesi Tracker] 面板已关闭")
    end
end

local function OnToggle()
    if not UIManager:IsInPopupQueue(ContextPtr) then
        Open()
    else
        Close()
    end
end

-- ===========================================================================
-- 输入
-- ===========================================================================
local function OnInputHandler(pInputStruct)
    if pInputStruct:GetMessageType() == KeyEvents.KeyUp then
        if pInputStruct:GetKey() == Keys.VK_ESCAPE then
            Close()
            return true
        end
    end
    return false
end

-- ===========================================================================
-- 添加 Tab 按钮
-- ===========================================================================
local function AddTabInstance(buttonText, callbackFunc)
    local kInstance = m_tabButtonIM:GetInstance()
    kInstance.Button:SetText(Locale.Lookup(buttonText))
    kInstance.Button:RegisterCallback(Mouse.eMouseEnter, function()
        UI.PlaySound("Main_Menu_Mouse_Over")
    end)
    m_tabs.AddTab(kInstance.Button, callbackFunc)
    return kInstance
end

-- ===========================================================================
-- 初始化
-- ===========================================================================
local function Initialize()
    ContextPtr:SetHide(true)
    ContextPtr:SetInputHandler(OnInputHandler, true)
    ContextPtr:SetShowHandler(OnShow)

    Controls.ModalScreenClose:RegisterCallback(Mouse.eLClick, Close)
    Controls.ModalBG:SetHide(true)
    Controls.ModalScreenTitle:SetText(Locale.Lookup("LOC_HAIKESI_TRACKER_TITLE"))

    -- Tab 系统初始化
    m_tabs = CreateTabs(Controls.TabContainer, 42, 34, UI.GetColorValueFromHexLiteral(0xFF331D05))
    m_HomeTabInstance = AddTabInstance("LOC_HAIKESI_TRACKER_TAB_SELECTED", OnTrackerTabClick)
    AddTabInstance("LOC_HAIKESI_TRACKER_TAB_ENCYCLOPEDIA", OnEncyclopediaTabClick)

    -- 扩展 TabContainer 宽度以容纳两个按钮（170*2 + 10 = 350）
    Controls.TabContainer:SetSizeX(350)

    m_tabs.CenterAlignTabs(-10)

    -- tab 高亮与内容由 OnShow 在 context 显示时统一设置，此处不再预先 SelectTab

    LuaEvents.Haikesi_ToggleTracker.Add(OnToggle)
    print("[Haikesi Tracker] 面板初始化完成")
end

function OnInit(isReload)
    if isReload then
        LuaEvents.Haikesi_ToggleTracker.Remove(OnToggle)
    end
    Initialize()
end
ContextPtr:SetInitHandler(OnInit)
