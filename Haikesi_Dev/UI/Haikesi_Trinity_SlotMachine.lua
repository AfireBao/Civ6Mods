-- ===========================================================================
-- Haikesi_Trinity_SlotMachine.lua
-- UI-only animation for 三位一体 slot results decided in Gameplay.
-- ===========================================================================

local SYMBOL_ICONS = {
    JUAN = "ICON_HAIKESI_SLOT_JUAN",
    XIANG = "ICON_HAIKESI_SLOT_XIANG",
    LEAF = "ICON_HAIKESI_SLOT_LEAF",
}
local SYMBOL_ORDER = { "JUAN", "XIANG", "LEAF" }
local REWARD_TEXT = {
    NONE = "LOC_HAIKESI_SLOT_MACHINE_RESULT_NONE",
    JUAN2 = "LOC_HAIKESI_SLOT_MACHINE_RESULT_JUAN2",
    JUAN3 = "LOC_HAIKESI_SLOT_MACHINE_RESULT_JUAN3",
    LEAF2 = "LOC_HAIKESI_SLOT_MACHINE_RESULT_LEAF2",
    LEAF3 = "LOC_HAIKESI_SLOT_MACHINE_RESULT_LEAF3",
    XIANG2 = "LOC_HAIKESI_SLOT_MACHINE_RESULT_XIANG2",
    XIANG3 = "LOC_HAIKESI_SLOT_MACHINE_RESULT_XIANG3",
}

local m_FinalSymbols = nil
local m_RewardKey = "NONE"
local m_PendingFloaterPlayerID = nil
local m_PendingFloaterX = nil
local m_PendingFloaterY = nil
local m_PendingFloaterText = nil
local m_IsRolling = false
local m_Elapsed = 0
local m_Tick = 0
local ROLL_DURATION = 1.75
local TICK_TIME = 0.075
local ShowFloater = nil

local function SlotLog(msg)
    print("[Haikesi Trinity UI] " .. tostring(msg))
end

local function ResetSlotState()
    m_FinalSymbols = nil
    m_RewardKey = "NONE"
    m_PendingFloaterPlayerID = nil
    m_PendingFloaterX = nil
    m_PendingFloaterY = nil
    m_PendingFloaterText = nil
    m_IsRolling = false
    m_Elapsed = 0
    m_Tick = 0
    if Controls ~= nil and Controls.ResultText ~= nil then
        Controls.ResultText:SetText("")
    end
    if Controls ~= nil and Controls.CloseButton ~= nil then
        Controls.CloseButton:SetDisabled(false)
    end
end

local function SplitCsv(raw)
    local out = {}
    raw = tostring(raw or "")
    for part in string.gmatch(raw, "([^,]+)") do
        table.insert(out, part)
    end
    while #out < 3 do
        table.insert(out, SYMBOL_ORDER[(#out % #SYMBOL_ORDER) + 1])
    end
    return out
end

local function SetSlot(control, symbol)
    local icon = SYMBOL_ICONS[symbol] or SYMBOL_ICONS.JUAN
    control:SetIcon(icon)
end

local function SetAllSlots(symbols)
    SetSlot(Controls.Slot1, symbols[1])
    SetSlot(Controls.Slot2, symbols[2])
    SetSlot(Controls.Slot3, symbols[3])
end

local function UIRandomSymbol(label)
    local idx = math.random(0, 2)
    return SYMBOL_ORDER[1 + (tonumber(idx) or 0)]
end

local function RandomizeSlots()
    SetSlot(Controls.Slot1, UIRandomSymbol())
    SetSlot(Controls.Slot2, UIRandomSymbol())
    SetSlot(Controls.Slot3, UIRandomSymbol())
end

local function FinishRoll()
    if not m_IsRolling then
        return
    end
    m_IsRolling = false
    if m_FinalSymbols ~= nil then
        SetAllSlots(m_FinalSymbols)
    end
    local loc = REWARD_TEXT[m_RewardKey] or REWARD_TEXT.NONE
    Controls.ResultText:SetText(Locale.Lookup(loc))
    Controls.CloseButton:SetDisabled(false)
    if UI ~= nil and UI.PlaySound ~= nil then
        UI.PlaySound("Confirm_Dedication")
    end
    SlotLog("finish reward=" .. tostring(m_RewardKey))
end

local function OnUpdate(deltaTime)
    if not m_IsRolling then
        return
    end
    m_Elapsed = m_Elapsed + (tonumber(deltaTime) or 0)
    m_Tick = m_Tick + (tonumber(deltaTime) or 0)
    if m_Tick >= TICK_TIME then
        m_Tick = 0
        RandomizeSlots()
        if UI ~= nil and UI.PlaySound ~= nil then
            UI.PlaySound("Main_Menu_Mouse_Over")
        end
    end
    if m_Elapsed >= ROLL_DURATION then
        FinishRoll()
    end
end

local function Close()
    if m_IsRolling then
        FinishRoll()
    end
    if UIManager:IsInPopupQueue(ContextPtr) then
        UIManager:DequeuePopup(ContextPtr)
    else
        ContextPtr:SetHide(true)
    end
    if m_PendingFloaterText ~= nil and m_PendingFloaterText ~= "" and ShowFloater ~= nil then
        ShowFloater(m_PendingFloaterPlayerID, m_PendingFloaterX, m_PendingFloaterY, m_PendingFloaterText)
    end
    m_PendingFloaterPlayerID = nil
    m_PendingFloaterX = nil
    m_PendingFloaterY = nil
    m_PendingFloaterText = nil
    SlotLog("closed")
end

local function OpenSlotMachine(playerID, x, y, resultCsv, rewardKey, floaterText)
    local localPlayer = Game.GetLocalPlayer()
    if tonumber(playerID) ~= localPlayer then
        SlotLog("skip open for nonlocal P" .. tostring(playerID))
        return false
    end
    if UIManager:IsInPopupQueue(ContextPtr) then
        UIManager:DequeuePopup(ContextPtr)
        SlotLog("dequeued stale popup before open")
    end
    m_FinalSymbols = SplitCsv(resultCsv)
    m_RewardKey = tostring(rewardKey or "NONE")
    m_PendingFloaterPlayerID = playerID
    m_PendingFloaterX = x
    m_PendingFloaterY = y
    m_PendingFloaterText = tostring(floaterText or "")
    m_IsRolling = true
    m_Elapsed = 0
    m_Tick = 0
    Controls.ResultText:SetText("")
    Controls.CloseButton:SetDisabled(true)
    RandomizeSlots()
    if UI ~= nil and UI.PlaySound ~= nil then
        UI.PlaySound("Confirm_Caravan_Produce")
    end
    ContextPtr:SetHide(false)
    local kParameters = {}
    kParameters.RenderAtCurrentParent = true
    kParameters.InputAtCurrentParent = true
    kParameters.AlwaysVisibleInQueue = true
    UIManager:QueuePopup(ContextPtr, PopupPriority.Low, kParameters)
    SlotLog("open results=" .. tostring(resultCsv) .. " reward=" .. tostring(m_RewardKey))
    return true
end

function ShowFloater(playerID, x, y, text)
    playerID = tonumber(playerID)
    x = tonumber(x)
    y = tonumber(y)
    if playerID == nil or x == nil or y == nil or playerID ~= Game.GetLocalPlayer() then
        return
    end
    if UI ~= nil and UI.AddWorldViewText ~= nil and EventSubTypes ~= nil then
        pcall(function()
            UI.AddWorldViewText(EventSubTypes.PLOT or EventSubTypes.DAMAGE, tostring(text), x, y, playerID)
        end)
    end
end

local function OnInputHandler(pInputStruct)
    if pInputStruct:GetMessageType() == KeyEvents.KeyUp and pInputStruct:GetKey() == Keys.VK_ESCAPE then
        Close()
        return true
    end
    return false
end

local function Initialize()
    if UIManager:IsInPopupQueue(ContextPtr) then
        UIManager:DequeuePopup(ContextPtr)
    end
    ResetSlotState()
    ContextPtr:SetHide(true)
    ContextPtr:SetInputHandler(OnInputHandler, true)
    ContextPtr:SetUpdate(OnUpdate)
    Controls.CloseButton:RegisterCallback(Mouse.eLClick, Close)
    if ExposedMembers ~= nil then
        ExposedMembers.Haikesi_OpenTrinitySlotMachine = OpenSlotMachine
        ExposedMembers.Haikesi_TrinityShowFloater = ShowFloater
    end
    if LuaEvents ~= nil then
        LuaEvents.Haikesi_OpenTrinitySlotMachine.Add(OpenSlotMachine)
        LuaEvents.Haikesi_TrinityShowFloater.Add(ShowFloater)
    end
    SlotLog("slot machine ready")
end

Events.LoadScreenClose.Add(Initialize)
