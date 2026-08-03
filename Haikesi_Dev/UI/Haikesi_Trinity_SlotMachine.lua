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

local SLOT_PENDING_SEQUENCE_PROP = "PROP_NW_TRINITY_SLOT_PENDING_SEQUENCE_V2"
local SLOT_SETTLED_SEQUENCE_PROP = "PROP_NW_TRINITY_SLOT_SETTLED_SEQUENCE_V2"
local SLOT_RESULTS_PROP = "PROP_NW_TRINITY_SLOT_RESULTS_V2"
local SLOT_REWARD_KEY_PROP = "PROP_NW_TRINITY_SLOT_REWARD_KEY_V2"
local SLOT_X_PROP = "PROP_NW_TRINITY_SLOT_X_V2"
local SLOT_Y_PROP = "PROP_NW_TRINITY_SLOT_Y_V2"
local SLOT_FLOATER_PROP = "PROP_NW_TRINITY_SLOT_FLOATER_V2"

local m_FinalSymbols = nil
local m_RewardKey = "NONE"
local m_PendingFloaterPlayerID = nil
local m_PendingFloaterX = nil
local m_PendingFloaterY = nil
local m_PendingFloaterText = nil
local m_IsRolling = false
local m_Elapsed = 0
local m_Tick = 0
local m_ActiveSequence = nil
local m_LastOpenedSequence = 0
local m_AwaitingSettlementSequence = nil
local m_AwaitingFloaterPlayerID = nil
local m_AwaitingFloaterX = nil
local m_AwaitingFloaterY = nil
local m_AwaitingFloaterText = nil
local m_SettleRetryElapsed = 0
local ROLL_DURATION = 1.75
local TICK_TIME = 0.075
local SETTLE_RETRY_TIME = 0.75
local ShowFloater = nil
local OpenSlotMachine = nil

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
    m_ActiveSequence = nil
    m_LastOpenedSequence = 0
    m_AwaitingSettlementSequence = nil
    m_AwaitingFloaterPlayerID = nil
    m_AwaitingFloaterX = nil
    m_AwaitingFloaterY = nil
    m_AwaitingFloaterText = nil
    m_SettleRetryElapsed = 0
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

local function RequestSettlement(sequence)
    local localPlayer = Game.GetLocalPlayer()
    if sequence == nil or localPlayer == nil or localPlayer < 0 then
        SlotLog("settle request skipped seq=" .. tostring(sequence) .. " local=" .. tostring(localPlayer))
        return
    end
    UI.RequestPlayerOperation(localPlayer, PlayerOperations.EXECUTE_SCRIPT, {
        OnStart = "HaikesiSelectRelic",
        TrinitySlotSettle = "1",
        TrinitySlotSequence = tostring(sequence),
    })
    m_SettleRetryElapsed = 0
    SlotLog("settle requested seq=" .. tostring(sequence))
end

local function PollSlotState(deltaTime)
    local localPlayer = Game.GetLocalPlayer()
    local pPlayer = localPlayer ~= nil and localPlayer >= 0 and Players[localPlayer] or nil
    if pPlayer == nil then return end

    local settled = tonumber(pPlayer:GetProperty(SLOT_SETTLED_SEQUENCE_PROP) or 0) or 0
    if m_AwaitingSettlementSequence ~= nil then
        if settled >= m_AwaitingSettlementSequence then
            SlotLog("settle acknowledged seq=" .. tostring(m_AwaitingSettlementSequence))
            if m_AwaitingFloaterText ~= nil and m_AwaitingFloaterText ~= "" and ShowFloater ~= nil then
                ShowFloater(m_AwaitingFloaterPlayerID, m_AwaitingFloaterX,
                    m_AwaitingFloaterY, m_AwaitingFloaterText)
            end
            m_AwaitingSettlementSequence = nil
            m_AwaitingFloaterPlayerID = nil
            m_AwaitingFloaterX = nil
            m_AwaitingFloaterY = nil
            m_AwaitingFloaterText = nil
            m_SettleRetryElapsed = 0
        else
            m_SettleRetryElapsed = m_SettleRetryElapsed + (tonumber(deltaTime) or 0)
            if m_SettleRetryElapsed >= SETTLE_RETRY_TIME then
                RequestSettlement(m_AwaitingSettlementSequence)
            end
        end
        return
    end

    if m_ActiveSequence ~= nil then return end
    local pending = tonumber(pPlayer:GetProperty(SLOT_PENDING_SEQUENCE_PROP) or 0) or 0
    if pending <= settled or pending <= m_LastOpenedSequence then return end

    local resultCsv = tostring(pPlayer:GetProperty(SLOT_RESULTS_PROP) or "")
    local rewardKey = tostring(pPlayer:GetProperty(SLOT_REWARD_KEY_PROP) or "NONE")
    local x = tonumber(pPlayer:GetProperty(SLOT_X_PROP) or -1) or -1
    local y = tonumber(pPlayer:GetProperty(SLOT_Y_PROP) or -1) or -1
    local floaterText = tostring(pPlayer:GetProperty(SLOT_FLOATER_PROP) or "")
    OpenSlotMachine(pending, localPlayer, x, y, resultCsv, rewardKey, floaterText)
end

local function OnUpdate(deltaTime)
    PollSlotState(deltaTime)
    if m_IsRolling then
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
    local closingSequence = m_ActiveSequence
    if closingSequence ~= nil then
        m_AwaitingSettlementSequence = closingSequence
        m_AwaitingFloaterPlayerID = m_PendingFloaterPlayerID
        m_AwaitingFloaterX = m_PendingFloaterX
        m_AwaitingFloaterY = m_PendingFloaterY
        m_AwaitingFloaterText = m_PendingFloaterText
    end
    m_ActiveSequence = nil
    m_PendingFloaterPlayerID = nil
    m_PendingFloaterX = nil
    m_PendingFloaterY = nil
    m_PendingFloaterText = nil
    if closingSequence ~= nil then
        RequestSettlement(closingSequence)
    end
    SlotLog("closed seq=" .. tostring(closingSequence) .. "; reward settlement deferred to Gameplay")
end

OpenSlotMachine = function(sequence, playerID, x, y, resultCsv, rewardKey, floaterText)
    local localPlayer = Game.GetLocalPlayer()
    if tonumber(playerID) ~= localPlayer then
        SlotLog("skip open for nonlocal P" .. tostring(playerID))
        return false
    end
    SlotLog("opening seq=" .. tostring(sequence) .. " results=" .. tostring(resultCsv)
        .. " reward=" .. tostring(rewardKey))
    if UIManager:IsInPopupQueue(ContextPtr) then
        UIManager:DequeuePopup(ContextPtr)
        SlotLog("dequeued stale popup before open")
    end
    m_ActiveSequence = tonumber(sequence)
    m_LastOpenedSequence = tonumber(sequence) or m_LastOpenedSequence
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
    SlotLog("open seq=" .. tostring(m_ActiveSequence) .. " results=" .. tostring(resultCsv)
        .. " reward=" .. tostring(m_RewardKey))
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
    SlotLog("slot machine ready (property polling; close-to-settle)")
end

Events.LoadScreenClose.Add(Initialize)
