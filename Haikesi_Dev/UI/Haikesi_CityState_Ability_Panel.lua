-- ===========================================================================
-- 虚空宗主 (VOIDSUZERAINRUNE)：从 10 项随机城邦宗主能力中选择两项。
-- 候选池按城邦 Trait 聚合，并排除特色改良、已选能力及互斥能力。
-- ===========================================================================
include("InstanceManager")

local m_AbilityIM = InstanceManager:new(
    "HaikesiCityStateAbilityEntry",
    "Top",
    Controls.ChooserTraitItem
)
local VOID_SUZERAIN_CHOICES_PER_RELIC = 2
local m_SelectedTraitTypes = {}
local m_SelectedInstances = {}
local m_RequiredSelectionCount = VOID_SUZERAIN_CHOICES_PER_RELIC
local m_PendingChoices = nil
local m_OpenRequested = false
local m_DeferredConfirmParameters = nil

local EXCLUDED_CITY_STATE_LEADERS = {
    LEADER_MINOR_CIV_DEFAULT = true,
    LEADER_MINOR_CIV_CULTURAL = true,
    LEADER_MINOR_CIV_INDUSTRIAL = true,
    LEADER_MINOR_CIV_MILITARISTIC = true,
    LEADER_MINOR_CIV_RELIGIOUS = true,
    LEADER_MINOR_CIV_SCIENTIFIC = true,
    LEADER_MINOR_CIV_TRADE = true,
    -- Gathering Storm 的城邦选择器不再包含这两个旧版定义。
    LEADER_MINOR_CIV_CARTHAGE = true,
    LEADER_MINOR_CIV_STOCKHOLM = true,
}

local function StartsWith(value, prefix)
    return value ~= nil and string.sub(value, 1, #prefix) == prefix
end

local function GetRelicAndChoiceCounts(pPlayer)
    if pPlayer == nil then return 0, 0 end
    local relicCount = 0
    local totalRelics = tonumber(pPlayer:GetProperty('PROP_NW_HAIKESI_RELIC_COUNT') or 0) or 0
    for i = 1, totalRelics do
        if pPlayer:GetProperty('PROP_NW_HAIKESI_RELIC_' .. tostring(i)) == 'VOIDSUZERAINRUNE' then
            relicCount = relicCount + 1
        end
    end
    local choiceCount = tonumber(pPlayer:GetProperty('PROP_NW_HAIKESI_VOID_SUZERAIN_CHOICE_COUNT') or 0) or 0
    return relicCount, choiceCount
end

local function HasPendingChoice()
    local playerID = Game.GetLocalPlayer()
    if playerID == nil or playerID == PlayerTypes.NONE then return false end
    local pPlayer = Players[playerID]
    local relicCount, choiceCount = GetRelicAndChoiceCounts(pPlayer)
    return relicCount * VOID_SUZERAIN_CHOICES_PER_RELIC > choiceCount
end

local function BuildSelectedTraitSet(pPlayer)
    local selected = {}
    if pPlayer == nil then return selected end

    local choiceCount = tonumber(pPlayer:GetProperty('PROP_NW_HAIKESI_VOID_SUZERAIN_CHOICE_COUNT') or 0) or 0
    for i = 1, choiceCount do
        local traitType = pPlayer:GetProperty('PROP_NW_HAIKESI_VOID_SUZERAIN_TRAIT_' .. tostring(i))
        if traitType ~= nil then
            selected[tostring(traitType)] = true
        end
    end

    return selected
end

local function BuildTraitModifierMap()
    local result = {}
    for row in GameInfo.TraitModifiers() do
        local list = result[row.TraitType]
        if list == nil then
            list = {}
            result[row.TraitType] = list
        end
        table.insert(list, row.ModifierId)
    end
    return result
end

local function BuildAttachedModifierMap()
    local result = {}
    for row in GameInfo.ModifierArguments() do
        if row.Name == 'ModifierId' and row.Value ~= nil then
            result[row.ModifierId] = tostring(row.Value)
        end
    end
    return result
end

local function TraitHasUniqueImprovement(traitType, traitModifiers, attachedModifiers)
    local modifierIds = traitModifiers[traitType] or {}
    for _, outerId in ipairs(modifierIds) do
        local outerInfo = GameInfo.Modifiers[outerId]
        local actualId = outerId
        if outerInfo ~= nil and outerInfo.ModifierType == 'MODIFIER_ALL_PLAYERS_ATTACH_MODIFIER' then
            actualId = attachedModifiers[outerId]
        end
        local actualInfo = actualId and GameInfo.Modifiers[actualId] or nil
        if actualInfo ~= nil
            and actualInfo.ModifierType == 'MODIFIER_PLAYER_ADJUST_VALID_IMPROVEMENT' then
            return true
        end
    end
    return false
end

local function BuildAbilityPool()
    local pool = {}
    local seen = {}
    local playerID = Game.GetLocalPlayer()
    local pPlayer = playerID ~= nil and playerID ~= PlayerTypes.NONE and Players[playerID] or nil
    local selectedTraits = BuildSelectedTraitSet(pPlayer)
    local hasCourtOfLove = pPlayer ~= nil
        and (tonumber(pPlayer:GetProperty('PROPERTY_NW_HAIKESI_COURT_OF_LOVE') or 0) or 0) >= 1
    local traitModifiers = BuildTraitModifierMap()
    local attachedModifiers = BuildAttachedModifierMap()
    local filteredImprovements = 0
    local filteredSelected = 0
    local filteredCourtOfLove = 0

    for row in GameInfo.LeaderTraits() do
        local leaderType = row.LeaderType
        local leader = GameInfo.Leaders[leaderType]
        local trait = GameInfo.Traits[row.TraitType]
        if StartsWith(leaderType, 'LEADER_MINOR_CIV_')
            and not EXCLUDED_CITY_STATE_LEADERS[leaderType]
            and leader ~= nil
            and StartsWith(leader.InheritFrom, 'LEADER_MINOR_CIV_')
            and trait ~= nil
            and (trait.InternalOnly or 0) == 0
            and trait.Name ~= nil
            and trait.Description ~= nil
            and not seen[row.TraitType] then
            seen[row.TraitType] = true
            if selectedTraits[row.TraitType] then
                filteredSelected = filteredSelected + 1
            elseif hasCourtOfLove and row.TraitType == 'MINOR_CIV_BABYLON_TRAIT' then
                filteredCourtOfLove = filteredCourtOfLove + 1
            elseif TraitHasUniqueImprovement(row.TraitType, traitModifiers, attachedModifiers) then
                filteredImprovements = filteredImprovements + 1
            else
                table.insert(pool, {
                    TraitType = row.TraitType,
                    LeaderType = leaderType,
                    CityName = leader.Name,
                })
            end
        end
    end

    print("[Haikesi VoidSuzerain] ability pool=" .. tostring(#pool)
        .. " filtered improvements=" .. tostring(filteredImprovements)
        .. " selected=" .. tostring(filteredSelected)
        .. " court=" .. tostring(filteredCourtOfLove))
    return pool
end

local function PickRandomChoices(pool, count)
    local copy = {}
    for i, choice in ipairs(pool) do copy[i] = choice end
    local choices = {}
    for i = 1, math.min(count, #copy) do
        local j = math.random(i, #copy)
        copy[i], copy[j] = copy[j], copy[i]
        table.insert(choices, copy[i])
    end
    return choices
end

local function UpdateSelectionState()
    local selectedCount = #m_SelectedTraitTypes
    Controls.SelectionCount:SetText(tostring(selectedCount) .. "/" .. tostring(m_RequiredSelectionCount))
    Controls.ConfirmButton:SetDisabled(selectedCount ~= m_RequiredSelectionCount)
end

local function RemoveSelectedTrait(traitType)
    for i, selectedTrait in ipairs(m_SelectedTraitTypes) do
        if selectedTrait == traitType then
            table.remove(m_SelectedTraitTypes, i)
            break
        end
    end
    m_SelectedInstances[traitType] = nil
end

local function ToggleSelection(instance, traitType)
    if m_SelectedInstances[traitType] == nil then
        if #m_SelectedTraitTypes >= m_RequiredSelectionCount then
            return
        end
        table.insert(m_SelectedTraitTypes, traitType)
        m_SelectedInstances[traitType] = instance
        instance.SelectorBrace:SetColor(UI.GetColorValue(1, 1, 1, 1))
        instance.Button:SetSelected(true)
    else
        RemoveSelectedTrait(traitType)
        instance.SelectorBrace:SetColor(UI.GetColorValue(1, 1, 1, 0))
        instance.Button:SetSelected(false)
    end
    UpdateSelectionState()
end

local function AddAbilityInstance(choice)
    local trait = GameInfo.Traits[choice.TraitType]
    if trait == nil or trait.Description == nil then return end

    local instance = m_AbilityIM:GetInstance()
    if instance == nil then return end

    local cityName = Locale.Lookup(choice.CityName)
    local description = Locale.Lookup(trait.Description)
    instance.Name:SetText(cityName)
    instance.Info:SetText(cityName .. "之力：" .. description)
    instance.SelectorBrace:SetColor(UI.GetColorValue(1, 1, 1, 0))
    instance.Button:SetSelected(false)
    instance.Button:RegisterCallback(Mouse.eLClick, function()
        ToggleSelection(instance, choice.TraitType)
    end)
end

local function OnShow()
    if m_PendingChoices == nil or #m_PendingChoices == 0 then return end
    m_AbilityIM:DestroyInstances()
    m_SelectedTraitTypes = {}
    m_SelectedInstances = {}
    UpdateSelectionState()
    for _, choice in ipairs(m_PendingChoices) do
        AddAbilityInstance(choice)
    end
end

local function Close()
    m_DeferredConfirmParameters = nil
    if UIManager:IsInPopupQueue(ContextPtr) then
        UIManager:DequeuePopup(ContextPtr)
        UI.PlaySound("CityStates_Panel_Close")
    end
end

local function SubmitSelection(parameters)
    UI.RequestPlayerOperation(Game.GetLocalPlayer(), PlayerOperations.EXECUTE_SCRIPT, parameters)
    UI.PlaySound("Confirm_Dedication")
    m_DeferredConfirmParameters = nil
    m_PendingChoices = nil
    Close()
end

local function OnConfirm()
    if #m_SelectedTraitTypes ~= m_RequiredSelectionCount then return end
    local parameters = {}
    parameters.OnStart = 'HaikesiSelectCityStateAbility'
    parameters.TraitType1 = m_SelectedTraitTypes[1]
    parameters.TraitType2 = m_SelectedTraitTypes[2]
    if HasPendingChoice() then
        SubmitSelection(parameters)
    else
        -- 极端情况下玩家可在遗物 EXECUTE_SCRIPT 落地前完成双选；保留选择，
        -- 待 GameCoreEventPublishComplete 后按原顺序提交 Gameplay 确认。
        m_DeferredConfirmParameters = parameters
        Controls.ConfirmButton:SetDisabled(true)
        print("[Haikesi VoidSuzerain] confirm deferred until relic Gameplay publish")
    end
end

local function Open(forcedSelectionCount)
    local playerID = Game.GetLocalPlayer()
    if playerID == nil or playerID == PlayerTypes.NONE then return end
    local pPlayer = Players[playerID]
    if pPlayer == nil then return end

    local relicCount, choiceCount = GetRelicAndChoiceCounts(pPlayer)
    local remainingChoices = relicCount * VOID_SUZERAIN_CHOICES_PER_RELIC - choiceCount
    local requestedChoices = tonumber(forcedSelectionCount) or 0
    if requestedChoices <= 0 then
        requestedChoices = remainingChoices
    end
    if requestedChoices <= 0 then return end
    m_OpenRequested = false

    if m_PendingChoices == nil or #m_PendingChoices == 0 then
        local pool = BuildAbilityPool()
        if #pool == 0 then
            print("[Haikesi VoidSuzerain] no eligible city-state abilities")
            return
        end
        m_RequiredSelectionCount = math.min(
            VOID_SUZERAIN_CHOICES_PER_RELIC,
            requestedChoices,
            #pool
        )
        m_PendingChoices = PickRandomChoices(pool, 10)
    end

    if not UIManager:IsInPopupQueue(ContextPtr) then
        local parameters = {}
        parameters.RenderAtCurrentParent = true
        parameters.InputAtCurrentParent = true
        parameters.AlwaysVisibleInQueue = true
        UIManager:QueuePopup(ContextPtr, PopupPriority.Low, parameters)
        UI.PlaySound("CityStates_Panel_Open")
    end
end

-- 海克斯确认使用异步 EXECUTE_SCRIPT。主面板发来打开事件时，Gameplay 可能尚未
-- 写回遗物计数；先记录请求，待 GameCoreEventPublishComplete 后再打开。
local function RequestOpen(forcedSelectionCount)
    local forcedCount = tonumber(forcedSelectionCount) or 0
    if forcedCount > 0 then
        print("[Haikesi VoidSuzerain] immediate pre-generated open, choices="
            .. tostring(forcedCount))
        Open(forcedCount)
        return
    end
    if HasPendingChoice() then
        Open()
    else
        m_OpenRequested = true
        print("[Haikesi VoidSuzerain] open requested; waiting for Gameplay publish")
    end
end

local function OnGameCoreEventPublishComplete()
    if m_DeferredConfirmParameters ~= nil and HasPendingChoice() then
        print("[Haikesi VoidSuzerain] relic publish complete; submitting deferred confirm")
        SubmitSelection(m_DeferredConfirmParameters)
        return
    end
    if not m_OpenRequested then return end
    if HasPendingChoice() then
        m_OpenRequested = false
        print("[Haikesi VoidSuzerain] Gameplay publish complete; opening panel")
        Open()
    end
end

local function OnInputHandler(input)
    if input:GetMessageType() == KeyEvents.KeyUp and input:GetKey() == Keys.VK_ESCAPE then
        Close()
        return true
    end
    return false
end

local function OnInit(isReload)
    if isReload and HasPendingChoice() then
        RequestOpen()
    end
end

local function Initialize()
    ContextPtr:SetHide(true)
    ContextPtr:SetInitHandler(OnInit)
    ContextPtr:SetInputHandler(OnInputHandler, true)
    ContextPtr:SetShowHandler(OnShow)
    Controls.ConfirmButton:RegisterCallback(Mouse.eLClick, OnConfirm)
    if Controls.ModalScreenClose ~= nil then
        Controls.ModalScreenClose:RegisterCallback(Mouse.eLClick, Close)
        Controls.ModalScreenClose:SetHide(false)
    end
    LuaEvents.Haikesi_OpenCityStateAbilityPanel.Add(RequestOpen)
    Events.GameCoreEventPublishComplete.Add(OnGameCoreEventPublishComplete)
    print("[Haikesi VoidSuzerain] city-state ability panel initialized")
end

Events.LoadScreenClose.Add(Initialize)
