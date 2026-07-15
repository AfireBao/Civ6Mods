-- ===========================================================================
-- Haikesi_Panel.lua — 海克斯大乱斗 三卡选择面板
-- ===========================================================================
include("InstanceManager")

-- ===========================================================================
-- 棱彩池 — 从 GameInfo.Haikesi_Relics() 直接读取 Name/Description/Icon
-- SQL 表含完整字段: RelicType, Name, Description, Flavor, Icon, Rarity
-- ===========================================================================

-- 运行时缓存
local m_AugmentPool = nil

local function BuildAugmentPool()
    if m_AugmentPool then return m_AugmentPool end

    m_AugmentPool = {}
    for row in GameInfo.Haikesi_Relics() do
        if row.IsActive == 1 then
            local desc = Locale.Lookup(row.Description) or ""
            table.insert(m_AugmentPool, {
                Type   = row.RelicType,
                Name   = Locale.Lookup(row.Name),
                Desc   = desc,
                Flavor = Locale.Lookup(row.Flavor),
                Icon   = row.Icon,
                IsRepeatable = row.IsRepeatable,
                Weight = row.Weight or 100,
                MinTurn = row.MinTurn,
                MaxTurn = row.MaxTurn,
            })
        end
    end
    print("[Haikesi] 棱彩池构建完成 — " .. #m_AugmentPool .. " 个海克斯")
    return m_AugmentPool
end

-- ===========================================================================
-- Index → RelicType 映射（用于从 PROP 解析已选海克斯）
-- ===========================================================================
local g_IndexToRelicType = nil
local HAIKESI_RELICS_PROP_KEY = 'PROP_NW_HAIKESI_RELICS'
local HAIKESI_RELIC_COUNT_KEY = 'PROP_NW_HAIKESI_RELIC_COUNT'
local HAIKESI_RELIC_SLOT_PREFIX = 'PROP_NW_HAIKESI_RELIC_'

-- Civ6 布尔配置常为 0/1；Lua 中 0 为真，不能写 (GetValue() or false)
local function Haikesi_IsConfigEnabled(configId)
    local v = GameConfiguration.GetValue(configId)
    return v == true or v == 1 or v == "1"
end

-- AI 专用海克斯池（NW_HAIKESI_AI_RELIC 开启；主机 Network.IsGameHost 可为 AI 选海克斯）
-- IsActive=0 故不在玩家棱彩池；此列表独立维护，与服务端 AI_RELIC_TYPES 一致
local AI_RELIC_TYPES = {
    'NW_AI_STATS_1', 'NW_AI_STATS_2', 'NW_AI_STATS_3', 'NW_AI_STATS_4', 'NW_AI_STATS_5', 'NW_AI_STATS_6',
    'NW_AI_ECHO_SETTLER', 'NW_AI_ECHO_BUILDER', 'NW_AI_ECHO_MELEE', 'NW_AI_ECHO_RANGED',
    'NW_AI_ECHO_LIGHT_CAVALRY', 'NW_AI_ECHO_HEAVY_CAVALRY', 'NW_AI_ECHO_ANTI_CAVALRY', 'NW_AI_ECHO_SIEGE',
    -- 混乱干扰
    'NW_AI_BARBARIAN_INVASION',
    -- 资源创建
    'NW_AI_BRAVE_WOOD', 'NW_AI_MAMA_BORN', 'NW_AI_MILK_DRAGON', 'NW_AI_SILK_LAND', 'NW_AI_DRINK_TEA',
    -- 和平互利
    'NW_AI_CELESTIAL_EMPIRE',
}
local BARBARIAN_INVASION_RELIC = 'NW_AI_BARBARIAN_INVASION'

-- 为指定 AI 构建未选过的候选池（excludeInvasionThisRound：本轮南蛮入侵已被占用）
local function GetAIAvailableRelicsForUI(pAI, excludeInvasionThisRound)
    local selected = {}
    local count = tonumber(pAI:GetProperty(HAIKESI_RELIC_COUNT_KEY) or 0) or 0
    if count > 0 then
        for i = 1, count do
            local relicType = pAI:GetProperty(HAIKESI_RELIC_SLOT_PREFIX .. i)
            if relicType ~= nil then
                if GameInfo.Haikesi_Relics[relicType] ~= nil or string.sub(relicType, 1, 6) == 'NW_AI_' then
                    selected[relicType] = true
                end
            end
        end
    end
    local candidates = {}
    for _, relicType in ipairs(AI_RELIC_TYPES) do
        local relicDef = GameInfo.Haikesi_Relics[relicType]
        local alreadySelected = selected[relicType]
        local canPick = not alreadySelected or (relicDef ~= nil and relicDef.IsRepeatable == 1)
        if canPick then
            if not (excludeInvasionThisRound and relicType == BARBARIAN_INVASION_RELIC) then
                table.insert(candidates, relicType)
            end
        end
    end
    return candidates
end

local function AIHasOnlyInvasionLeftForUI(pAI)
    local available = GetAIAvailableRelicsForUI(pAI, false)
    return #available == 1 and available[1] == BARBARIAN_INVASION_RELIC
end

local function BuildAIChoicesBatch()
    local aiChoices = {}
    local invasionAssigned = false
    local aiPlayers = {}
    for _, pAI in ipairs(PlayerManager.GetAliveMajors()) do
        if not pAI:IsHuman() and not pAI:IsBarbarian() then
            table.insert(aiPlayers, pAI)
        end
    end

    local invasionOnlyAIs = {}
    for _, pAI in ipairs(aiPlayers) do
        if AIHasOnlyInvasionLeftForUI(pAI) then
            table.insert(invasionOnlyAIs, pAI)
        end
    end
    if #invasionOnlyAIs > 0 then
        local pPick = invasionOnlyAIs[math.random(#invasionOnlyAIs)]
        aiChoices[tostring(pPick:GetID())] = BARBARIAN_INVASION_RELIC
        invasionAssigned = true
    end

    for _, pAI in ipairs(aiPlayers) do
        local aiIDStr = tostring(pAI:GetID())
        if aiChoices[aiIDStr] == nil then
            local candidates = GetAIAvailableRelicsForUI(pAI, invasionAssigned)
            if #candidates > 0 then
                local aiRelic = candidates[math.random(#candidates)]
                aiChoices[aiIDStr] = aiRelic
                if aiRelic == BARBARIAN_INVASION_RELIC then
                    invasionAssigned = true
                end
            else
                print("[Haikesi] AI Player" .. aiIDStr .. " no available AI relic this round")
            end
        end
    end
    return aiChoices
end

local function BuildIndexToRelicType()
    if g_IndexToRelicType then return g_IndexToRelicType end
    g_IndexToRelicType = {}
    for row in GameInfo.Haikesi_Relics() do
        g_IndexToRelicType[row.Index] = row.RelicType
    end
    return g_IndexToRelicType
end

local function AddSelectedRelicType(selected, relicType)
    if relicType ~= nil and GameInfo.Haikesi_Relics[relicType] ~= nil then
        selected[relicType] = true
        return true
    end
    return false
end

-- 获取本地玩家已选海克斯的 RelicType 集合。
-- 新存档优先读逐槽位 RelicType；旧存档回退读 Index 串。
local function GetSelectedRelicTypes()
    local selected = {}
    local localPlayerID = Game.GetLocalPlayer()
    local pLocal = Players[localPlayerID]
    if pLocal then
        local hasSlotData = false
        local count = tonumber(pLocal:GetProperty(HAIKESI_RELIC_COUNT_KEY) or 0) or 0
        if count > 0 then
            for i = 1, count do
                hasSlotData = AddSelectedRelicType(selected, pLocal:GetProperty(HAIKESI_RELIC_SLOT_PREFIX .. i)) or hasSlotData
            end
        end
        if hasSlotData then
            return selected
        end

        local prop = pLocal:GetProperty(HAIKESI_RELICS_PROP_KEY) or ""
        if prop ~= "" then
            local indexMap = BuildIndexToRelicType()
            for idxStr in string.gmatch(prop, "[^|]+") do
                local idx = tonumber(idxStr)
                local relicType = indexMap[idx]
                if relicType then
                    selected[relicType] = true
                end
            end
        end
    end
    return selected
end

local g_RelicPrerequisiteMap = nil
local HAIKESI_DEBUG_PREREQS = false
local g_PrereqDebugPrinted = {}

local function DebugPrereqOnce(key, message)
    if not HAIKESI_DEBUG_PREREQS or g_PrereqDebugPrinted[key] then return end
    g_PrereqDebugPrinted[key] = true
    print(message)
end

local function AddRelicPrerequisite(map, relicType, kind, prereqType, allowInProgress)
    if not map[relicType] then
        map[relicType] = {}
    end
    table.insert(map[relicType], {
        Kind = kind,
        Type = prereqType,
        AllowInProgress = allowInProgress == true,
    })
end

local function BuildRelicPrerequisiteMap()
    if g_RelicPrerequisiteMap then return g_RelicPrerequisiteMap end

    g_RelicPrerequisiteMap = {}
    local tableAvailable = GameInfo.Haikesi_Relic_Prerequisites ~= nil
    local rowCount = 0

    if tableAvailable then
        for row in GameInfo.Haikesi_Relic_Prerequisites() do
            rowCount = rowCount + 1
            AddRelicPrerequisite(
                g_RelicPrerequisiteMap,
                row.RelicType,
                row.PrerequisiteKind,
                row.PrerequisiteType,
                row.AllowInProgress == 1
            )
            if rowCount <= 20 then
                print('[Haikesi DEBUG] Prereq row #' .. rowCount
                    .. ' relic=' .. tostring(row.RelicType)
                    .. ' kind=' .. tostring(row.PrerequisiteKind)
                    .. ' type=' .. tostring(row.PrerequisiteType)
                    .. ' allow=' .. tostring(row.AllowInProgress))
            end
        end
    end

    print('[Haikesi DEBUG] Prereq map built: tableAvailable=' .. tostring(tableAvailable) .. ', rows=' .. rowCount)
    return g_RelicPrerequisiteMap
end

local function GetPlayerConfigTypes(playerID)
    local pConfig = PlayerConfigurations[playerID]
    if not pConfig then return nil, nil end
    return pConfig:GetCivilizationTypeName(), pConfig:GetLeaderTypeName()
end
local function IsTechnologyPrerequisiteMet(pPlayer, techType, allowInProgress)
    local tech = GameInfo.Technologies[techType]
    if not tech then return false end

    local pTechs = pPlayer and pPlayer:GetTechs()
    if not pTechs then return false end
    if pTechs:HasTech(tech.Index) then return true end

    return allowInProgress
        and (pTechs:GetResearchingTech() == tech.Index or pTechs:IsResearchingTech(tech.Index))
end

-- 检测当局是否启用指定 GameCapability（如 CAPABILITY_SECRETSOCIETIES）
local function IsCapabilityPrerequisiteMet(capType)
    if capType == nil then return false end
    if type(GameCapabilities) == 'table' and type(GameCapabilities.HasCapability) == 'function' then
        return GameCapabilities.HasCapability(capType) == true
    end
    if type(HasCapability) == 'function' then
        return HasCapability(capType) == true
    end
    if GameInfo.GameCapabilities ~= nil then
        for row in GameInfo.GameCapabilities() do
            if row.GameCapability == capType then
                return true
            end
        end
    end
    return false
end

-- 检查玩家是否拥有指定 Trait：通过 ModCore 绑定的 PROPERTY_<TraitType> 判断（O(1)）
-- ModCore 给每个文明/领袖 Trait set PROPERTY_<TraitType>=1；替代遍历 CivilizationTraits/LeaderTraits 的 O(n) 旧逻辑
local function PlayerHasTrait(playerID, traitType)
    if playerID == nil or playerID == PlayerTypes.NONE then return false end
    if traitType == nil then return false end
    local pPlayer = Players[playerID]
    if pPlayer == nil then return false end
    return (pPlayer:GetProperty('PROPERTY_' .. traitType) or 0) > 0
end

-- 将标准速度回合数缩放为当前游戏速度下的等效回合数
-- 基于 GameSpeeds.CostMultiplier（标准=100, 快速≈67, 史诗=150, 马拉松=300）
-- 必须定义在 IsRelicRefreshEligible 之前（后者引用此函数，避免 local 前向引用 nil）
local function ScaleTurnForGameSpeed(standardTurn)
    if standardTurn == nil then return nil end
    local gameSpeedType = GameConfiguration.GetGameSpeedType()
    local speedInfo = GameInfo.GameSpeeds[gameSpeedType]
    local multiplier = (speedInfo and speedInfo.CostMultiplier or 100)
    return math.floor(standardTurn * multiplier / 100 + 0.5)
end

local function IsRelicRefreshEligible(aug, selectedTypes)
    -- 全队锁定检查（手快全选等）：同队有人选过后，其他人不再刷出
    local pLocal = Players[Game.GetLocalPlayer()]
    if pLocal and pLocal:GetProperty('PROP_NW_HAIKESI_LOCKED_' .. aug.Type) == 1 then
        return false
    end

    -- 回合限制检查（以标准速度为准，经游戏速度缩放）
    if aug.MinTurn ~= nil or aug.MaxTurn ~= nil then
        local currentTurn = Game.GetCurrentGameTurn()
        local scaledMin = ScaleTurnForGameSpeed(aug.MinTurn)
        local scaledMax = ScaleTurnForGameSpeed(aug.MaxTurn)
        if scaledMin ~= nil and currentTurn < scaledMin then
            return false
        end
        if scaledMax ~= nil and currentTurn > scaledMax then
            return false
        end
    end

    local prereqs = BuildRelicPrerequisiteMap()[aug.Type]
    if not prereqs then return true end

    local localPlayerID = Game.GetLocalPlayer()
    local pLocal = Players[localPlayerID]
    for _, req in ipairs(prereqs) do
        if req.Kind == 'RELIC' then
            if not selectedTypes[req.Type] then
                return false
            end
        elseif req.Kind == 'TECHNOLOGY' then
            if not IsTechnologyPrerequisiteMet(pLocal, req.Type, req.AllowInProgress) then
                return false
            end
        elseif req.Kind == 'TRAIT' then
            local hasTrait = PlayerHasTrait(localPlayerID, req.Type)
            local civType, leaderType = GetPlayerConfigTypes(localPlayerID)
            DebugPrereqOnce('trait:' .. aug.Type .. ':' .. req.Type,
                '[Haikesi DEBUG] Trait prereq check relic=' .. tostring(aug.Type)
                .. ' required=' .. tostring(req.Type)
                .. ' player=' .. tostring(localPlayerID)
                .. ' civ=' .. tostring(civType)
                .. ' leader=' .. tostring(leaderType)
                .. ' result=' .. tostring(hasTrait))
            if not hasTrait then
                return false
            end
        elseif req.Kind == 'EXCLUDE_TRAIT' then
            local hasTrait = PlayerHasTrait(localPlayerID, req.Type)
            if hasTrait then
                return false  -- 拥有该 Trait → 排除出刷新池
            end
        elseif req.Kind == 'CAPABILITY' then
            if not IsCapabilityPrerequisiteMet(req.Type) then
                return false
            end
        else
            return false
        end
    end
    return true
end
-- ===========================================================================
-- 卡片控件 ID 映射表 (Xml → 三卡索引)
-- ===========================================================================
local CARD = {
    { BG = "Card1_BG", Frame = "Card1_Frame", Button = "Card1",
      Icon = "Card1_Icon", Title = "Card1_Title", Desc = "Card1_Desc",
      Flavor = "Card1_Flavor", Refresh = "Card1_Refresh" },
    { BG = "Card2_BG", Frame = "Card2_Frame", Button = "Card2",
      Icon = "Card2_Icon", Title = "Card2_Title", Desc = "Card2_Desc",
      Flavor = "Card2_Flavor", Refresh = "Card2_Refresh" },
    { BG = "Card3_BG", Frame = "Card3_Frame", Button = "Card3",
      Icon = "Card3_Icon", Title = "Card3_Title", Desc = "Card3_Desc",
      Flavor = "Card3_Flavor", Refresh = "Card3_Refresh" },
}

-- Flavor 锚点 C,B，贴卡片底部（XML 中 Offset="0,20"），无需自适应下推

-- ===========================================================================
-- 状态
-- ===========================================================================
local m_SelectedIndex  = -1       -- 当前选中卡片 (1/2/3)，-1 = 无
local m_CurrentAugments = {}      -- { [1]=augData, [2]=augData, [3]=augData }
local m_RerollCount = {0, 0, 0}  -- 每张卡已重Roll次数
local m_SkippedTypes = {}       -- 本轮内已略过（被刷新掉）的海克斯 Type → true
local m_PendingResume = false   -- ESC 跳过后标记：重进时恢复本轮牌面与刷新配额（防洗牌 exploit）


-- ===========================================================================
-- 工具函数
-- ===========================================================================
-- UI Context 专用随机: 只用 math.random. 不要走 Game.GetRandNum!
-- 理由: Game.GetRandNum 是全局同步 RNG, 所有客机共享同一序列.
-- UI 面板只在打开时才 Shuffle, 打开面板的客机会消耗几十次 GetRandNum,
-- 没打开面板的客机不消耗 → 全局 RNG 序列错位 → 后续战斗/蛮族/灾害等所有依赖
-- 全局 RNG 的判定跨端结果不同 → OOS desync.
-- UI 随机的结果最终通过 EXECUTE_SCRIPT 由主机下发即可,不需要各端一致.
-- (reason 参数保留以便未来切换回 GetRandNum, 目前仅用于调试打印/无操作)
local function GetPanelRand(max, reason)
    if max == nil or max <= 0 then
        return 0
    end
    return math.random(max) - 1
end

local function Shuffle(tbl)
    for i = #tbl, 2, -1 do
        local j = GetPanelRand(i, "Haikesi panel shuffle") + 1
        tbl[i], tbl[j] = tbl[j], tbl[i]
    end
    return tbl
end

-- 加权随机：从候选列表中按 Weight 字段加权抽取一个元素，返回索引
-- 候选列表非空，Weight 默认为 100
local function WeightedPickIndex(candidates)
    local totalWeight = 0
    for _, aug in ipairs(candidates) do
        totalWeight = totalWeight + (aug.Weight or 100)
    end
    if totalWeight <= 0 then
        return GetPanelRand(#candidates, "Haikesi weighted fallback") + 1
    end
    local roll = math.random(totalWeight)
    local accum = 0
    for i, aug in ipairs(candidates) do
        accum = accum + (aug.Weight or 100)
        if roll <= accum then
            return i
        end
    end
    return #candidates
end

-- 从棱彩池中无重复随机抽取 count 个（排除不可重复的已选海克斯）
local function RollAugments(count)
    local pool = BuildAugmentPool()
    local selectedTypes = GetSelectedRelicTypes()

    -- 筛选：排除不可重复的已选海克斯
    local candidates = {}
    for _, aug in ipairs(pool) do
        if not IsRelicRefreshEligible(aug, selectedTypes) then
            -- 前置条件未满足，跳过
        elseif selectedTypes[aug.Type] and aug.IsRepeatable ~= 1 then
            -- 已选择且 IsRepeatable ≠ 1，跳过
        else
            table.insert(candidates, aug)
        end
    end

    -- 加权不放回抽取 count 个
    local result = {}
    for _ = 1, math.min(count, #candidates) do
        local idx = WeightedPickIndex(candidates)
        table.insert(result, candidates[idx])
        table.remove(candidates, idx)
    end
    return result
end

-- DICEMANIAC 赠送海克斯的单点随机：仅在发起方 UI 端算一次，结果通过
-- ExtraRelicTypes 经 EXECUTE_SCRIPT 下发，避免各客机各自 Game.GetRandNum 导致 desync。
-- 候选规则与服务端原 CanGrantRelicFromBonus 等价：IsActive、非 SelectionOnly、前置满足、
-- 非"已拥有且不可重复"，并排除掷骰狂人自身。
local function PickBonusRelicType(excludeType)
    local selectedTypes = GetSelectedRelicTypes()
    local candidates = {}
    for row in GameInfo.Haikesi_Relics() do
        if row.IsActive == 1
            and row.SelectionOnly ~= 1
            and row.RelicType ~= excludeType then
            local aug = { Type = row.RelicType, MinTurn = row.MinTurn, MaxTurn = row.MaxTurn }
            if IsRelicRefreshEligible(aug, selectedTypes)
                and not (selectedTypes[row.RelicType] and row.IsRepeatable ~= 1) then
                table.insert(candidates, row.RelicType)
            end
        end
    end
    if #candidates == 0 then return nil end
    local index = GetPanelRand(#candidates, "Haikesi Dice Maniac bonus relic") + 1
    return candidates[index]
end

-- ===========================================================================
-- 卡片填充
-- ===========================================================================
local function PopulateCard(index, augmentData)
    local c = CARD[index]
    if not c then return end

    if augmentData then
        Controls[c.Icon]:SetIcon(augmentData.Icon)
        Controls[c.Title]:SetText(Locale.ToUpper(augmentData.Name))
        Controls[c.Desc]:SetText(augmentData.Desc)
        Controls[c.Flavor]:SetText(augmentData.Flavor)
        Controls[c.BG]:SetHide(false)
        Controls[c.Frame]:SetHide(false)
        Controls[c.Button]:SetHide(false)
        Controls[c.Flavor]:SetHide(false)
        Controls[c.Refresh]:SetHide(false)


    else
        -- 空卡占位（数据不足3个时）
        Controls[c.BG]:SetHide(true)
        Controls[c.Frame]:SetHide(true)
        Controls[c.Button]:SetHide(true)
        Controls[c.Flavor]:SetHide(true)
        Controls[c.Refresh]:SetHide(true)
    end
end

-- ===========================================================================
-- 选中高亮 — 背景变亮金 + 边框上金色（参考按钮 Selected 态）
-- ===========================================================================
local function SetHighlight(index, active)
    local c = CARD[index]
    if not c then return end
    if active then
        -- 背景：明亮暗金
        Controls[c.BG]:SetColor(0.20, 0.14, 0.04, 1.0)
        -- 边框：金色辉光
        Controls[c.Frame]:SetColor(1.0, 0.84, 0.0, 1.0)
    else
        -- 背景：原色 #10151E
        Controls[c.BG]:SetColor(0.063, 0.082, 0.118, 1.0)
        -- 边框：正常
        Controls[c.Frame]:SetColor(1.0, 1.0, 1.0, 1.0)
    end
end

-- ===========================================================================
-- 面板关闭
-- 注意：Close 不清空 m_CurrentAugments / m_RerollCount / m_SkippedTypes —— 这些
-- 是"本轮"状态，ESC 跳过后重进需恢复。仅在 OnConfirm 真正选中后才清空。
-- ===========================================================================
local function Close()
    m_SelectedIndex = -1
    UI.PlaySound("Tech_Tray_Slide_Closed")
    -- ★ 着力点模式: 先 Panel_Closed → 再 SetHide → 最后发通知
    LuaEvents.HaikesiPanel_Closed()
    ContextPtr:SetHide(true)
    m_SuppressReopen = true  -- 抑制异步重开
    print("[Haikesi] 面板已关闭")
end

-- ESC / 跳过选择 → 关闭并标记待选（重进时恢复本轮牌面与刷新配额，防止洗牌 exploit）
local function ClosePending()
    Close()
    m_PendingResume = true
    -- ESC 跳过本就允许立即通过工具栏重进，清除 Close 置的抑制标记
    m_SuppressReopen = false
    LuaEvents.Haikesi_PendingSelection()
    print("[Haikesi] ESC关闭 — 通过工具栏按钮可重新打开（保留本轮牌面）")
end

-- ===========================================================================
-- 确认按钮
-- ===========================================================================
local function UpdateConfirmButton()
    local hasSelection = (m_SelectedIndex > 0)
    print("[Haikesi] UpdateConfirm: selected=" .. m_SelectedIndex .. " hasSelection=" .. tostring(hasSelection))
    Controls.ConfirmBtn:SetDisabled(not hasSelection)
end

local function OnConfirm()
    if m_SelectedIndex <= 0 then return end

    local aug = m_CurrentAugments[m_SelectedIndex]
    print(string.format("[Haikesi] ★ 确认选择: Card%d → %s (%s)", m_SelectedIndex, aug.Type, aug.Name))

    local param = {}
    param['OnStart'] = 'HaikesiSelectRelic'
    param['RelicType'] = aug.Type

    -- DOUBLEEXISTENCERUNE 手快全拿：把另外两张卡的海克斯一并下发
    if aug.Type == 'DOUBLEEXISTENCERUNE' then
        local extras = {}
        for i, other in ipairs(m_CurrentAugments) do
            if i ~= m_SelectedIndex and other then
                table.insert(extras, other.Type)
            end
        end
        if #extras > 0 then
            param['ExtraRelicTypes'] = extras
            print("[Haikesi] 手快全拿 — 附加海克斯: " .. table.concat(extras, ", "))
        end
    end

    -- DICEMANIACRUNE 掷骰狂人：赠送海克斯在 UI 端单点随机后下发，
    -- 服务端不再自行随机（消除各客机结果不一致的 desync）。
    if aug.Type == 'DICEMANIACRUNE' then
        local bonusType = PickBonusRelicType(aug.Type)
        if bonusType then
            param['ExtraRelicTypes'] = { bonusType }
            print("[Haikesi] 掷骰狂人 — 赠送海克斯: " .. bonusType)
        else
            print("[Haikesi] 掷骰狂人 — 无可用赠送海克斯")
        end
    end

    -- PVE + AI 海克斯：仅主机确认才触发一轮 AI 发牌（客机选卡不推进 AI 轮次）
    -- 外部大模型：主机打 TriggerAIRelicRound，FireTuner Stage 后由 UI 桥接广播 ExtAIApply
    -- 非外部：主机打包 AIChoices；客机不带 Trigger，Gameplay 不发 AI 牌
    local externalAIEnabled = Haikesi_IsConfigEnabled('NW_HAIKESI_EXTERNAL_AI')
    if Network.IsGameHost() and Haikesi_IsConfigEnabled('NW_HAIKESI_AI_RELIC') then
        param['TriggerAIRelicRound'] = 1
        if not externalAIEnabled then
            local aiChoices = BuildAIChoicesBatch()
            if next(aiChoices) ~= nil then
                param['AIChoices'] = aiChoices
                print("[Haikesi] 主机下发 AI 海克斯选择")
            end
        else
            print("[Haikesi] 主机触发外部 AI 海克斯轮次（待 FireTuner Stage）")
        end
    end

    UI.RequestPlayerOperation(Game.GetLocalPlayer(), PlayerOperations.EXECUTE_SCRIPT, param)

    LuaEvents.Haikesi_ClearPendingSelection()
    UI.PlaySound("Confirm_Dedication")
    Close()

    -- MIMICRUNE 仿生模仿：选完海克斯后本地弹能力选择窗
    -- 能力窗自包含池构建+math.random抽10项（UI Context，不走 GetRandNum）
    -- Gameplay 仅在能力窗确认时 HaikesiSelectAbility 挂 Trait Modifier
    local isMimic = (aug.Type == 'MIMICRUNE')
    local localPlayerID = Game.GetLocalPlayer()

    -- 真正选中：清空本轮牌面与配额，确保下轮触发从全新状态开始
    m_CurrentAugments = {}
    m_RerollCount = {0, 0, 0}
    m_SkippedTypes = {}
    m_PendingResume = false

    -- 海克斯面板关闭后再弹能力窗（避免同帧双弹窗冲突）
    if isMimic then
        LuaEvents.Haikesi_OpenAbilityPanel()
    end
end

-- ===========================================================================
-- 选中逻辑
-- ===========================================================================
local function OnCardClicked(index)
    print("[Haikesi] Card" .. index .. " 被点击")

    if m_SelectedIndex == index then
        -- 取消选中
        SetHighlight(index, false)
        m_SelectedIndex = -1
    else
        if m_SelectedIndex > 0 then
            SetHighlight(m_SelectedIndex, false)
        end
        SetHighlight(index, true)
        m_SelectedIndex = index
    end

    UpdateConfirmButton()
end

-- 当前本地玩家的单卡最大刷新次数（DICEMANIAC +1；DOUBLEEXISTENCERUNE 全锁为 0）
-- 定义于 RerollCard / Open 之前，确保两者引用的 local 已绑定（避免前向引用 nil）
local function GetMaxRerolls()
    -- 开发者模式（NW_HAIKESI_MODE == 3）：无限刷新，便于设计期反复抽取与测试
    -- 返回足够大的整数充当"无上限"，无需触及 m_RerollCount / DOUBLEEXISTENCERUNE 锁定逻辑
    if (GameConfiguration.GetValue('NW_HAIKESI_MODE') or 0) == 3 then
        return 9999
    end
    local localPlayerID = Game.GetLocalPlayer()
    local pLocal = Players[localPlayerID]
    if pLocal then
        if (pLocal:GetProperty('PROP_NW_HAIKESI_NO_REROLL') or 0) > 0 then
            return 0
        end
        if (pLocal:GetProperty('PROP_NW_HAIKESI_DICEMANIAC') or 0) > 0 then
            return 2
        end
    end
    return 1
end

-- ===========================================================================
-- 单卡重Roll
-- ===========================================================================
local function RerollCard(index)
    if index == m_SelectedIndex then
        print("[Haikesi] 无法重Roll — Card" .. index .. " 已被选中，请先取消选择")
        return
    end

    -- DOUBLEEXISTENCERUNE 副作用：持有该海克斯后无法再刷新
    -- 开发者模式（NW_HAIKESI_MODE == 3）下绕过 NO_REROLL 锁，保证无限刷新
    local localPlayerID = Game.GetLocalPlayer()
    local pLocal = Players[localPlayerID]
    local devMode = (GameConfiguration.GetValue('NW_HAIKESI_MODE') or 0) == 3
    if not devMode and pLocal and (pLocal:GetProperty('PROP_NW_HAIKESI_NO_REROLL') or 0) > 0 then
        print("[Haikesi] 无法重Roll — 手快全拿已锁定刷新")
        return
    end

    local maxRerolls = GetMaxRerolls()

    if m_RerollCount[index] >= maxRerolls then
        print("[Haikesi] Card" .. index .. " 已达刷新上限 (" .. maxRerolls .. "次)")
        return
    end
    m_RerollCount[index] = m_RerollCount[index] + 1

    -- 将当前卡的海克斯标记为"已略过"
    local oldAug = m_CurrentAugments[index]
    if oldAug then
        m_SkippedTypes[oldAug.Type] = true
    end

    -- 收集排除集合：其他卡当前显示 + 本轮已略过
    local excludedTypes = {}
    for i, aug in ipairs(m_CurrentAugments) do
        if i ~= index and aug then
            excludedTypes[aug.Type] = true
        end
    end
    for t, _ in pairs(m_SkippedTypes) do
        excludedTypes[t] = true
    end

    -- Task 3: 不可重复的已选海克斯也需排除
    local selectedTypes = GetSelectedRelicTypes()

    local pool = BuildAugmentPool()
    local candidates = {}
    for _, aug in ipairs(pool) do
        if not excludedTypes[aug.Type] and IsRelicRefreshEligible(aug, selectedTypes) then
            if not (selectedTypes[aug.Type] and aug.IsRepeatable ~= 1) then
                table.insert(candidates, aug)
            end
        end
    end

    if #candidates == 0 then
        print("[Haikesi] Card" .. index .. " 重Roll失败 — 池中无可用新卡")
        return
    end

    local pickIdx = WeightedPickIndex(candidates)
    m_CurrentAugments[index] = candidates[pickIdx]
    PopulateCard(index, candidates[pickIdx])
    SetHighlight(index, false)

    -- 刷新后：仅当用完配额才隐藏刷新按钮
    if m_RerollCount[index] >= maxRerolls then
        Controls[CARD[index].Refresh]:SetHide(true)
    end

    print(string.format("[Haikesi] Card%d 重Roll → %s", index, candidates[pickIdx].Name))
end

-- ===========================================================================
-- 面板开关
-- ===========================================================================
local m_IsOpening = false  -- 重入防护

local function UpdateExternalAIHint()
    local showHint = Haikesi_IsConfigEnabled('NW_HAIKESI_AI_RELIC')
        and Haikesi_IsConfigEnabled('NW_HAIKESI_EXTERNAL_AI')
    if Controls.ExternalAIHint ~= nil then
        if showHint then
            Controls.ExternalAIHint:SetText(Locale.Lookup('LOC_HAIKESI_PANEL_EXTERNAL_AI_HINT'))
            Controls.ExternalAIHint:SetHide(false)
        else
            Controls.ExternalAIHint:SetHide(true)
        end
    end
end

local function Open()
    if m_IsOpening then
        print("[Haikesi] ★ Open 重入阻止")
        return
    end
    if not ContextPtr:IsHidden() then
        print("[Haikesi] Open 跳过 — 面板未隐藏")
        return
    end
    m_IsOpening = true

    local localPlayerID = Game.GetLocalPlayer()
    if PlayerConfigurations[localPlayerID]:GetLeaderTypeName() == "LEADER_SPECTATOR" then return end
    if localPlayerID == PlayerTypes.NONE then return end

    ContextPtr:SetHide(false)
    LuaEvents.Haikesi_ClearPendingSelection()
    UI.PlaySound("Tech_Tray_Slide_Open")

    local isResume = m_PendingResume

    if isResume then
        -- 待选重进：恢复本轮牌面与刷新配额，禁止重新抽牌（防洗牌 exploit）
        m_SelectedIndex = -1
        print("[Haikesi] ── 待选重进（保留本轮牌面）──")
    else
        -- 新一轮：抽 3 个海克斯并重置配额
        m_CurrentAugments = RollAugments(3)
        m_RerollCount = {0, 0, 0}
        m_SkippedTypes = {}
        m_SelectedIndex = -1
    end

    local maxRerolls = GetMaxRerolls()
    for i = 1, 3 do
        local aug = m_CurrentAugments[i]
        PopulateCard(i, aug)
        SetHighlight(i, false)
        -- 按实际配额同步刷新按钮可见性：
        --   新一轮：未用尽则显示；
        --   待选重进：仅当尚未用尽当前配额时显示（用尽的卡按钮保持隐藏）
        if aug and m_RerollCount[i] < maxRerolls then
            Controls[CARD[i].Refresh]:SetHide(false)
        else
            Controls[CARD[i].Refresh]:SetHide(true)
        end
    end

    UpdateConfirmButton()  -- 根据 m_SelectedIndex 自动显隐
    UpdateExternalAIHint()

    LuaEvents.HaikesiPanel_Opened()

    m_IsOpening = false
    if isResume then
        m_PendingResume = false
    end
    print("[Haikesi] ── 面板已打开 ──")
    for i, aug in ipairs(m_CurrentAugments) do
        if aug then
            print(string.format("  Card%d: %s | %s", i, aug.Name, aug.Desc))
        else
            print(string.format("  Card%d: (空)", i))
        end
    end
end

local m_SuppressReopen = false

local function OnTogglePanel()
    print("[Haikesi] ★ OnTogglePanel — isHidden=" .. tostring(ContextPtr:IsHidden()))
    if m_SuppressReopen then
        print("[Haikesi] ★ 重开被抑制")
        m_SuppressReopen = false
        return
    end
    if ContextPtr:IsHidden() then
        Open()
    else
        Close()
    end
end

-- ===========================================================================
-- 输入处理 (ESC 关闭)
-- ===========================================================================
local function OnInputHandler(pInputStruct)
    if pInputStruct:GetMessageType() == KeyEvents.KeyUp then
        if pInputStruct:GetKey() == Keys.VK_ESCAPE then
            ClosePending()
        end
    end
    return true
end



-- ===========================================================================
-- 触发时机常量（无需前端参数配置）
-- ===========================================================================
local HAIKESI_CLASSIC_TURNS  = {3, 25, 45}
local HAIKESI_HAIKESI_FIRST  = 10
local HAIKESI_HAIKESI_INTERVAL = 10
local HAIKESI_MP_FIRST       = 5
local HAIKESI_MP_INTERVAL    = 5
local HAIKESI_PVE_ERA_KEY    = 'PROP_NW_HAIKESI_PVE_ERA'

-- ===========================================================================
-- 触发时机计算（人类与 AI 共用）
-- ===========================================================================
local function ShouldOpenForPlayer(pPlayer, mode, turn)
    local selectCount = pPlayer:GetProperty('PROP_NW_HAIKESI_SELECT_COUNT') or 0
    if mode == 0 then
        -- 经典三板斧
        return selectCount < #HAIKESI_CLASSIC_TURNS and turn >= HAIKESI_CLASSIC_TURNS[selectCount + 1]
    elseif mode == 1 then
        -- 海克斯大乱斗
        return turn >= HAIKESI_HAIKESI_FIRST + selectCount * HAIKESI_HAIKESI_INTERVAL
    elseif mode == 3 then
        -- 开发者模式：每回合
        return true
    elseif mode == 4 then
        -- 海克斯大乱斗（联机）：每5回合
        return turn >= HAIKESI_MP_FIRST + selectCount * HAIKESI_MP_INTERVAL
    end
    -- mode == 2: PVE经典，每个时代选择一次
    local currentEra = pPlayer:GetEra()
    local lastEra = pPlayer:GetProperty(HAIKESI_PVE_ERA_KEY)
    if lastEra == nil then return true end
    return currentEra > lastEra
end

-- ===========================================================================
-- 回合触发：内置触发计算（不依赖 GP PROP 同步）
-- 仅对本地人类玩家：打开选择面板。AI 不参与海克斯。
-- 注意：不重置 m_PendingResume —— 跨回合也保留本轮牌面与刷新配额，
-- 玩家"刷牌-ESC-下回合"无法洗刷新配额，必须真正确认选择才算一轮结束。
-- ===========================================================================
function OnPlayerTurnActivated(playerID, isFirst)
    if not isFirst then return end
    local localPlayerID = Game.GetLocalPlayer()
    if localPlayerID == nil or playerID ~= localPlayerID then return end

    local pPlayer = Players[playerID]
    if pPlayer == nil or not pPlayer:IsHuman() then return end

    local mode = GameConfiguration.GetValue('NW_HAIKESI_MODE') or 0
    local turn = Game.GetCurrentGameTurn()

    if not ShouldOpenForPlayer(pPlayer, mode, turn) then return end

    if ContextPtr:IsHidden() then
        -- ★ 跨回合触发：主动清除上一轮 Close 留下的 SuppressReopen，
        -- 防止 OnConfirm→Close 设的标志位"沉淀"到下个触发回合（例如经典模式 25/55 回合不弹）。
        -- SuppressReopen 仅用于同帧异步重开抑制，不应跨回合生效。
        m_SuppressReopen = false
        print("[Haikesi] ★ 回合触发 → OnTogglePanel (模式=" .. mode .. ", 回合=" .. turn .. ")")
        OnTogglePanel()
    else
        print("[Haikesi] 回合触发跳过 — 面板已打开")
    end
end

-- ===========================================================================
-- 初始化
-- ===========================================================================
local function Initialize()
    ContextPtr:SetHide(true)

    ContextPtr:SetInputHandler(OnInputHandler, true)

    -- 三卡点击 → 选中
    for i = 1, 3 do
        local index = i
        local c = CARD[i]
        Controls[c.Button]:RegisterCallback(Mouse.eLClick, function()
            OnCardClicked(index)
        end)
        Controls[c.Refresh]:RegisterCallback(Mouse.eLClick, function()
            RerollCard(index)
        end)
    end

    -- 确认 / 关闭
    Controls.ConfirmBtn:RegisterCallback(Mouse.eLClick, OnConfirm)
    Controls.HideBtn:RegisterCallback(Mouse.eLClick, ClosePending)
    Controls.CloseBtn:RegisterCallback(Mouse.eLClick, ClosePending)

    -- 对外暴露面板开关
    LuaEvents.Haikesi_TogglePanel.Add(OnTogglePanel)

    -- DEBUG: 开局触发
    Events.PlayerTurnActivated.Add(OnPlayerTurnActivated)

    -- 预构建棱彩池并打印统计
    local pool = BuildAugmentPool()
    print("[Haikesi] 面板初始化完成 — 棱彩池: " .. #pool .. " 个")
end

function OnInit(isReload)
    if isReload then
        LuaEvents.Haikesi_TogglePanel.Remove(OnTogglePanel)
        Events.PlayerTurnActivated.Remove(OnPlayerTurnActivated)
    end
    Initialize()
end
ContextPtr:SetInitHandler(OnInit)
