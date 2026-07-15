-- ===========================================================================
-- Haikesi_Ability_Panel.lua - 仿生模仿(MIMICRUNE) 能力选择弹窗
-- 外层用图鉴同款 Modal 结构（QueuePopup + SetShowHandler）
-- Instance 复用炎 mod TraitInstance 结构（已验证可用）
-- 由 UI 层 LuaEvents.Haikesi_OpenAbilityPanel() 触发
-- 本地 math.random 从原版文明/领袖 Trait 抽 10 项展示
-- 玩家单选确认后经 EXECUTE_SCRIPT(OnStart='HaikesiSelectAbility') 下发
-- ===========================================================================
include("InstanceManager")

local m_AbilityIM = InstanceManager:new("HaikesiAbilityEntry", "Top", Controls.ChooserTraitItem)
local m_SelectedInst
local m_PendingChoices = nil

print("[Haikesi AbilityPanel] 脚本加载 | ChooserTraitItem=", Controls.ChooserTraitItem)

local function PlayerHasTrait(playerID, traitType)
    if playerID == nil or playerID == PlayerTypes.NONE then return false end
    local pPlayer = Players[playerID]
    if pPlayer == nil then return false end
    return (pPlayer:GetProperty('PROPERTY_' .. traitType) or 0) > 0
end

local function BuildAbilityPool()
    local pool = {}
    local seen = {}
    local localPlayerID = Game.GetLocalPlayer()
    print("[Haikesi AbilityPanel] BuildAbilityPool 开始, localPlayerID=" .. tostring(localPlayerID))

    local civCount = 0
    for row in GameInfo.CivilizationTraits() do
        local civ = GameInfo.Civilizations[row.CivilizationType]
        if civ and civ.StartingCivilizationLevelType == 'CIVILIZATION_LEVEL_FULL_CIV' then
            seen[row.TraitType] = true
            civCount = civCount + 1
        end
    end
    print("[Haikesi AbilityPanel] CivilizationTraits 收集=" .. civCount)

    local leaderCount = 0
    for row in GameInfo.LeaderTraits() do
        local leader = GameInfo.Leaders[row.LeaderType]
        if leader and leader.InheritFrom == 'LEADER_DEFAULT' then
            seen[row.TraitType] = true
            leaderCount = leaderCount + 1
        end
    end
    print("[Haikesi AbilityPanel] LeaderTraits 收集=" .. leaderCount)

    local skippedInternal, skippedNoText, skippedGrants, skippedOwned = 0, 0, 0, 0
    for traitType in pairs(seen) do
        local t = GameInfo.Traits[traitType]
        if t == nil then
            skippedNoText = skippedNoText + 1
        elseif (t.InternalOnly or 0) == 1 then
            skippedInternal = skippedInternal + 1
        elseif not (t.Name and t.Description) then
            skippedNoText = skippedNoText + 1
        else
            local grantsThing = false
            for r in GameInfo.Improvements() do if r.TraitType == traitType then grantsThing = true; break end end
            if not grantsThing then for r in GameInfo.Units() do if r.TraitType == traitType then grantsThing = true; break end end end
            if not grantsThing then for r in GameInfo.Buildings() do if r.TraitType == traitType then grantsThing = true; break end end end
            if not grantsThing then for r in GameInfo.Districts() do if r.TraitType == traitType then grantsThing = true; break end end end
            if grantsThing then
                skippedGrants = skippedGrants + 1
            elseif PlayerHasTrait(localPlayerID, traitType) then
                skippedOwned = skippedOwned + 1
            else
                table.insert(pool, traitType)
            end
        end
    end
    print(string.format("[Haikesi AbilityPanel] 能力池完成: pool=%d (跳过 internal=%d noText=%d grants=%d owned=%d)",
        #pool, skippedInternal, skippedNoText, skippedGrants, skippedOwned))
    return pool
end

local function PickRandomChoices(pool, count)
    local copy = {}
    for i, t in ipairs(pool) do copy[i] = t end
    local choices = {}
    for i = 1, math.min(count, #copy) do
        local j = math.random(i, #copy)
        copy[i], copy[j] = copy[j], copy[i]
        table.insert(choices, copy[i])
    end
    print("[Haikesi AbilityPanel] 抽取 choices=" .. #choices .. " 项: " .. table.concat(choices, ", "))
    return choices
end

local function AddAbilityInstance(traitType)
    local t = GameInfo.Traits[traitType]
    if t == nil or not t.Name or not t.Description then
        print("[Haikesi AbilityPanel] 跳过 " .. tostring(traitType) .. " (查无或缺文本)")
        return
    end
    local new = m_AbilityIM:GetInstance()
    if new == nil then
        print("[Haikesi AbilityPanel] GetInstance 返回 nil! traitType=" .. traitType)
        return
    end
    new.Name:SetText(Locale.Lookup(t.Name))
    new.Info:SetText(Locale.Lookup(t.Description))
    -- 标题颜色由 XML 的 ColorSet=ResScienceLabelCS 固定，不再用玩家色覆盖
    new.SelectorBrace:SetColor(UI.GetColorValue(1, 1, 1, 0))
    new.Button:SetVoid1(GameInfo.Traits[traitType].Index)
    new.Button:SetSelected(false)
    new.Button:RegisterCallback(Mouse.eLClick, function()
        SelectCheck(new)
    end)
end

function SelectCheck(new)
    if new ~= m_SelectedInst then
        if m_SelectedInst ~= nil then
            m_SelectedInst.Button:SetSelected(false)
            m_SelectedInst.SelectorBrace:SetColor(UI.GetColorValue(1, 1, 1, 0))
        end
        new.SelectorBrace:SetColor(UI.GetColorValue(1, 1, 1, 1))
        new.Button:SetSelected(true)
        m_SelectedInst = new
        Controls.ConfirmButton:SetDisabled(false)
    else
        new.SelectorBrace:SetColor(UI.GetColorValue(1, 1, 1, 0))
        new.Button:SetSelected(false)
        m_SelectedInst = nil
        Controls.ConfirmButton:SetDisabled(true)
    end
end

-- context 真正显示时回调（QueuePopup 后引擎调用）
function OnShow()
    print("[Haikesi AbilityPanel] OnShow 触发")
    if m_PendingChoices and #m_PendingChoices > 0 then
        m_AbilityIM:DestroyInstances()
        m_SelectedInst = nil
        Controls.ConfirmButton:SetDisabled(true)
        local created = 0
        for i, traitType in ipairs(m_PendingChoices) do
            AddAbilityInstance(traitType)
            created = created + 1
        end
        -- 不清空 m_PendingChoices：保留随机结果，下次打开复用（确认选择后才重置）
        print("[Haikesi AbilityPanel] Refresh 完成, 创建=" .. created)
    end
end

function Refresh()
    -- 兼容直接调用（现已由 OnShow 处理）
    if m_PendingChoices then
        OnShow()
    end
end

function OnConfirm()
    if m_SelectedInst == nil then return end
    local traitIndex = m_SelectedInst.Button:GetVoid1()
    local traitType = nil
    for row in GameInfo.Traits() do
        if row.Index == traitIndex then traitType = row.TraitType; break end
    end
    if traitType == nil then return end
    print("[Haikesi AbilityPanel] ★ 确认选择能力: " .. traitType)
    local param = {}
    param['OnStart'] = 'HaikesiSelectAbility'
    param['TraitType'] = traitType
    UI.RequestPlayerOperation(Game.GetLocalPlayer(), PlayerOperations.EXECUTE_SCRIPT, param)
    UI.PlaySound("Confirm_Dedication")
    -- 确认选择后重置随机结果，下次打开重新随机
    m_PendingChoices = nil
    Close()
end

function Open()
    print("[Haikesi AbilityPanel] Open 被调用")
    if Game.GetLocalPlayer() == -1 then return end
    -- 已有随机结果则复用，不重新随机（确认选择后 OnConfirm 会置 nil）
    if not m_PendingChoices or #m_PendingChoices == 0 then
        local pool = BuildAbilityPool()
        if #pool == 0 then
            print("[Haikesi AbilityPanel] 能力池为空，跳过")
            return
        end
        m_PendingChoices = PickRandomChoices(pool, 10)
    else
        print("[Haikesi AbilityPanel] 复用已有随机结果，不重新随机")
    end
    if not UIManager:IsInPopupQueue(ContextPtr) then
        local kParameters = {}
        kParameters.RenderAtCurrentParent = true
        kParameters.InputAtCurrentParent = true
        kParameters.AlwaysVisibleInQueue = true
        UIManager:QueuePopup(ContextPtr, PopupPriority.Low, kParameters)
    end
    UI.PlaySound("CityStates_Panel_Open")
    print("[Haikesi AbilityPanel] QueuePopup 已执行")
end

function Close()
    if UIManager:IsInPopupQueue(ContextPtr) then
        UIManager:DequeuePopup(ContextPtr)
        UI.PlaySound("CityStates_Panel_Close")
    end
end

function OnToggle_AbilityPanel()
    if UIManager:IsInPopupQueue(ContextPtr) then
        Close()
    else
        Open()
    end
end

function OnInputHandler(pInputStruct)
    local uiMsg = pInputStruct:GetMessageType()
    if uiMsg == KeyEvents.KeyUp and pInputStruct:GetKey() == Keys.VK_ESCAPE then
        Close()
        return true
    end
    return false
end

function OnInit(isReload)
    if isReload then
        Open()
    end
end

function Haikesi_AbilityPanel_Initialize()
    print("[Haikesi AbilityPanel] Initialize 执行")
    ContextPtr:SetHide(true)
    ContextPtr:SetInitHandler(OnInit)
    ContextPtr:SetInputHandler(OnInputHandler, true)
    ContextPtr:SetShowHandler(OnShow)

    Controls.ConfirmButton:RegisterCallback(Mouse.eLClick, OnConfirm)
    -- 绑定 ModalScreenWide Style 内置的关闭按钮（图鉴同款）
    if Controls.ModalScreenClose then
        Controls.ModalScreenClose:RegisterCallback(Mouse.eLClick, Close)
        Controls.ModalScreenClose:SetHide(false)
    else
        print("[Haikesi AbilityPanel] 警告: Controls.ModalScreenClose 不存在")
    end
    LuaEvents.Haikesi_OpenAbilityPanel.Add(OnToggle_AbilityPanel)
    print("[Haikesi AbilityPanel] 已注册 LuaEvents.Haikesi_OpenAbilityPanel + SetShowHandler")
end

Events.LoadScreenClose.Add(Haikesi_AbilityPanel_Initialize)
