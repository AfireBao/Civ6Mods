-- Haikesi_GamePlay_Script
-- Author: 帅翔翔
-- DateCreated: 2025-7-14 16:00:00
--------------------------------------------------------------
-- 海克斯大乱斗 — 服务端 GamePlay 脚本
-- 负责处理海克斯遴选效果：持久化、Modifier 挂载、Lua 效果层
--------------------------------------------------------------

--||======================= Debug ========================||--

-- 人类全图实时视野：仅高级选项「海克斯模式 = 开发者模式」(NW_HAIKESI_MODE == 3) 时开启
local DEV_FULL_MAP_VISION_PROP = 'PROP_NW_HAIKESI_DEV_FULL_MAP_VISION'

-- 内存 Map：RelicType → ModifierId[]（在 Initialize 中构建）
local g_RelicModifierMap = nil
-- RelicType → 资源创建配置（Haikesi_Relic_ResourceSpawns）
local g_RelicResourceSpawnMap = nil

--||======================= Key ========================||--
local RelicsPropertyKey = 'PROP_NW_HAIKESI_RELICS'
local RelicsCountPropertyKey = 'PROP_NW_HAIKESI_RELIC_COUNT'
local RelicsSlotPropertyPrefix = 'PROP_NW_HAIKESI_RELIC_'
local RelicsSummaryPropertyPrefix = 'PROP_NW_HAIKESI_RELIC_SUMMARY_'
local RelicsReasonPropertyPrefix = 'PROP_NW_HAIKESI_RELIC_REASON_'
local EXT_AI_REASON_MAX_LEN = 200
-- 仿生模仿 (MIMICRUNE) 能力选择相关：仅记录玩家最终选定的 Trait（tooltip 用）
local MimicTraitKey = 'PROP_NW_HAIKESI_MIMIC_TRAIT'
local CityFoundedTurnKey = 'PROP_NW_HAIKESI_CITY_FOUNDED_TURN'
local CityFoundedSequenceKey = 'PROP_NW_HAIKESI_CITY_FOUNDED_SEQUENCE'
local CityFoundedSequenceGameKey = 'PROP_NW_HAIKESI_CITY_FOUNDED_SEQUENCE_NEXT'
local AI_RELIC_TYPE_PREFIX = 'NW_AI_'

local function IsAIPoolRelicType(relicType)
    return relicType ~= nil and string.sub(relicType, 1, #AI_RELIC_TYPE_PREFIX) == AI_RELIC_TYPE_PREFIX
end
local HAIKESI_DEBUG_PREREQS = false
local g_PrereqDebugPrinted = {}

local function DebugPrereqOnce(key, message)
    if not HAIKESI_DEBUG_PREREQS or g_PrereqDebugPrinted[key] then return end
    g_PrereqDebugPrinted[key] = true
    print(message)
end

local function GetPlayerConfigTypes(playerID)
    local pConfig = PlayerConfigurations[playerID]
    if not pConfig then return nil, nil end
    return pConfig:GetCivilizationTypeName(), pConfig:GetLeaderTypeName()
end

-- 将标准速度回合数缩放为当前游戏速度下的等效回合数
-- 基于 GameSpeeds.CostMultiplier（标准=100, 快速≈67, 史诗=150, 马拉松=300）
local function ScaleTurnForGameSpeed(standardTurn)
    if standardTurn == nil then return nil end
    local gameSpeedType = GameConfiguration.GetGameSpeedType()
    local speedInfo = GameInfo.GameSpeeds[gameSpeedType]
    local multiplier = (speedInfo and speedInfo.CostMultiplier or 100)
    return math.floor(standardTurn * multiplier / 100 + 0.5)
end

-- 标准速度基准人口数 → 按 CostMultiplier 缩放（与商路完成周期同向缩放）
local function ScalePopForGameSpeed(standardPop)
    if standardPop == nil then return 1 end
    local gameSpeedType = GameConfiguration.GetGameSpeedType()
    local speedInfo = GameInfo.GameSpeeds[gameSpeedType]
    local multiplier = (speedInfo and speedInfo.CostMultiplier or 100)
    return math.max(1, math.floor(standardPop * multiplier / 100 + 0.5))
end

local function IsRelicSelectionOnly(relicType)
    local relicDef = GameInfo.Haikesi_Relics[relicType]
    return relicDef ~= nil and relicDef.SelectionOnly == 1
end

local function GetRelicTypeFromIndex(index)
    for row in GameInfo.Haikesi_Relics() do
        if row.Index == index then
            return row.RelicType
        end
    end
    return nil
end

local function GetSelectedRelicTypeListForPlayer(pPlayer)
    local relicTypes = {}
    local count = tonumber(pPlayer:GetProperty(RelicsCountPropertyKey) or 0) or 0
    if count > 0 then
        for i = 1, count do
            local relicType = pPlayer:GetProperty(RelicsSlotPropertyPrefix .. i)
            if relicType ~= nil and (GameInfo.Haikesi_Relics[relicType] ~= nil or IsAIPoolRelicType(relicType)) then
                table.insert(relicTypes, relicType)
            end
        end
    end
    if #relicTypes > 0 then
        return relicTypes
    end

    local prop = pPlayer:GetProperty(RelicsPropertyKey) or ""
    if prop ~= "" then
        for idxStr in string.gmatch(prop, "[^|]+") do
            local idx = tonumber(idxStr)
            if idx ~= nil then
                local relicType = GetRelicTypeFromIndex(idx)
                if relicType ~= nil then
                    table.insert(relicTypes, relicType)
                end
            end
        end
    end
    return relicTypes
end

local function GetSelectedRelicTypesForPlayer(pPlayer)
    local selected = {}
    for _, relicType in ipairs(GetSelectedRelicTypeListForPlayer(pPlayer)) do
        selected[relicType] = true
    end
    return selected
end

local function IsTechnologyPrerequisiteMet(pPlayer, techType, allowInProgress)
    local tech = GameInfo.Technologies[techType]
    if tech == nil then return false end

    local pTechs = pPlayer:GetTechs()
    if pTechs == nil then return false end
    if pTechs:HasTech(tech.Index) then return true end

    return allowInProgress == 1
        and (pTechs:GetResearchingTech() == tech.Index or pTechs:IsResearchingTech(tech.Index))
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

local function AreRelicPrerequisitesMet(pPlayer, relicType, selectedTypes)
    local tableAvailable = GameInfo.Haikesi_Relic_Prerequisites ~= nil
    local matchedRows = 0

    if tableAvailable then
        for req in GameInfo.Haikesi_Relic_Prerequisites() do
            if req.RelicType == relicType then
                matchedRows = matchedRows + 1
                if req.PrerequisiteKind == 'RELIC' then
                    if not selectedTypes[req.PrerequisiteType] then
                        return false
                    end
                elseif req.PrerequisiteKind == 'TECHNOLOGY' then
                    if not IsTechnologyPrerequisiteMet(pPlayer, req.PrerequisiteType, req.AllowInProgress) then
                        return false
                    end
                elseif req.PrerequisiteKind == 'TRAIT' then
                    local playerID = pPlayer:GetID()
                    local hasTrait = PlayerHasTrait(playerID, req.PrerequisiteType)
                    local civType, leaderType = GetPlayerConfigTypes(playerID)
                    DebugPrereqOnce('trait:' .. relicType .. ':' .. req.PrerequisiteType,
                        '[Haikesi GamePlay DEBUG] Trait prereq check relic=' .. tostring(relicType)
                        .. ' required=' .. tostring(req.PrerequisiteType)
                        .. ' player=' .. tostring(playerID)
                        .. ' civ=' .. tostring(civType)
                        .. ' leader=' .. tostring(leaderType)
                        .. ' result=' .. tostring(hasTrait))
                    if not hasTrait then
                        return false
                    end
                elseif req.PrerequisiteKind == 'EXCLUDE_TRAIT' then
                    local playerID = pPlayer:GetID()
                    local hasTrait = PlayerHasTrait(playerID, req.PrerequisiteType)
                    DebugPrereqOnce('exclude_trait:' .. relicType .. ':' .. req.PrerequisiteType,
                        '[Haikesi GamePlay DEBUG] ExcludeTrait check relic=' .. tostring(relicType)
                        .. ' trait=' .. tostring(req.PrerequisiteType)
                        .. ' player=' .. tostring(playerID)
                        .. ' hasTrait=' .. tostring(hasTrait))
                    if hasTrait then
                        return false  -- 拥有该 Trait → 排除出刷新池
                    end
                elseif req.PrerequisiteKind == 'CAPABILITY' then
                    if not IsCapabilityPrerequisiteMet(req.PrerequisiteType) then
                        return false
                    end
                else
                    return false
                end
            end
        end
    end

    DebugPrereqOnce('rows:' .. relicType,
        '[Haikesi GamePlay DEBUG] Prereq rows for relic=' .. tostring(relicType)
        .. ' tableAvailable=' .. tostring(tableAvailable)
        .. ' matchedRows=' .. tostring(matchedRows))
    return true
end
local function CanGrantRelicFromBonus(pPlayer, relicType, selectedTypes)
    local relicDef = GameInfo.Haikesi_Relics[relicType]
    if relicDef == nil or relicDef.IsActive ~= 1 then return false end
    if relicDef.SelectionOnly == 1 then return false end
    if selectedTypes[relicType] and relicDef.IsRepeatable ~= 1 then return false end
    if pPlayer:GetProperty('PROP_NW_HAIKESI_LOCKED_' .. relicType) == 1 then return false end

    -- 回合限制检查（以标准速度为准）
    if relicDef.MinTurn ~= nil or relicDef.MaxTurn ~= nil then
        local currentTurn = Game.GetCurrentGameTurn()
        local scaledMin = ScaleTurnForGameSpeed(relicDef.MinTurn)
        local scaledMax = ScaleTurnForGameSpeed(relicDef.MaxTurn)
        if scaledMin ~= nil and currentTurn < scaledMin then return false end
        if scaledMax ~= nil and currentTurn > scaledMax then return false end
    end

    return AreRelicPrerequisitesMet(pPlayer, relicType, selectedTypes)
end

local function Haikesi_TruncateUtf8ByBytes(text, maxBytes)
    if text == nil or maxBytes == nil or maxBytes <= 0 then
        return text
    end
    if #text <= maxBytes then
        return text
    end
    local truncated = string.sub(text, 1, maxBytes)
    while #truncated > 0 do
        local lastByte = string.byte(truncated, #truncated)
        if lastByte < 128 or lastByte >= 192 then
            break
        end
        truncated = string.sub(truncated, 1, #truncated - 1)
    end
    return truncated
end

-- 修复 FireTuner 经 \\xNN 注入、被 Lua5.1 收成字面 "xe5x88..." 的 reason
local function Haikesi_DecodeMangledHexReason(text)
    if text == nil or text == "" then
        return nil
    end
    -- \xe5\x88\x86 或 xe5x88x86（反斜杠被 Lua5.1 吃掉后）
    local hexBody = text:match("^((?:\\x[0-9a-fA-F][0-9a-fA-F])+)$")
    if hexBody == nil then
        hexBody = text:match("^((?:x[0-9a-fA-F][0-9a-fA-F])+)$")
        if hexBody == nil then
            return nil
        end
        -- 统一成 xHH 序列
    else
        hexBody = hexBody:gsub("\\x", "x")
    end
    local bytes = {}
    for h in hexBody:gmatch("x([0-9a-fA-F][0-9a-fA-F])") do
        table.insert(bytes, string.char(tonumber(h, 16)))
    end
    if #bytes == 0 then
        return nil
    end
    return table.concat(bytes)
end

local function Haikesi_SanitizeDecisionReason(reason)
    if reason == nil then
        return nil
    end
    reason = tostring(reason)
    local decoded = Haikesi_DecodeMangledHexReason(reason:match("^%s*(.-)%s*$") or reason)
    if decoded ~= nil then
        reason = decoded
    end
    -- 只剥 ASCII 控制符(0-31)。Firaxis Lua 的 %c 会匹配 0x80-0x9F，
    -- 正好打中 UTF-8 续字节，把「币/单/发」等字打成空格乱码。
    reason = reason:gsub("[%z\1-\31]", " "):gsub(" +", " "):match("^%s*(.-)%s*$")
    if reason == nil or reason == "" then
        return nil
    end
    if #reason > EXT_AI_REASON_MAX_LEN then
        reason = Haikesi_TruncateUtf8ByBytes(reason, EXT_AI_REASON_MAX_LEN)
    end
    return reason
end

-- ExtAIApply 线格式：requestId#aiId=RELIC*utf8hex|...（reason 用十六进制，避免 EXECUTE_SCRIPT 弄坏 UTF-8）
local function Haikesi_Utf8ToHex(s)
    if s == nil or s == "" then
        return ""
    end
    local t = {}
    for i = 1, #s do
        table.insert(t, string.format("%02x", string.byte(s, i)))
    end
    return table.concat(t)
end

-- 决策理由编码对照：与 PowerShell 侧 text.encode('utf-8').hex() 比较
local function Haikesi_DebugLogReason(phase, aiKey, reason)
    local text = ""
    if reason ~= nil then
        text = tostring(reason)
    end
    local hex = Haikesi_Utf8ToHex(text)
    print(string.format(
        "[Haikesi ReasonDBG] %s ai=%s bytes=%d text=%s",
        tostring(phase), tostring(aiKey), #text, text))
    print(string.format(
        "[Haikesi ReasonDBG] %s ai=%s hex=%s",
        tostring(phase), tostring(aiKey), hex))
end

local function Haikesi_HexToUtf8(h)
    if h == nil or h == "" then
        return ""
    end
    h = tostring(h)
    if (#h % 2) ~= 0 then
        return nil
    end
    if not h:match("^[0-9a-fA-F]+$") then
        return nil
    end
    local t = {}
    for i = 1, #h, 2 do
        local b = tonumber(string.sub(h, i, i + 1), 16)
        if b == nil then
            return nil
        end
        table.insert(t, string.char(b))
    end
    return table.concat(t)
end

local function Haikesi_ReasonForWire(reason)
    local s = Haikesi_SanitizeDecisionReason(reason)
    if s == nil then
        return ""
    end
    s = s:gsub("[#|=*]", "")
    return Haikesi_Utf8ToHex(s)
end

local function Haikesi_EncodeExtAIApply(requestID, choicesTable, reasonsTable)
    local parts = {}
    local ids = {}
    for aiIDStr, _ in pairs(choicesTable) do
        table.insert(ids, tonumber(aiIDStr) or aiIDStr)
    end
    table.sort(ids, function(a, b)
        return tonumber(a) < tonumber(b)
    end)
    for _, aiID in ipairs(ids) do
        local aiIDStr = tostring(aiID)
        local relic = choicesTable[aiIDStr]
        if relic ~= nil then
            local reasonHex = ""
            if reasonsTable ~= nil then
                reasonHex = Haikesi_ReasonForWire(reasonsTable[aiIDStr])
            end
            table.insert(parts, string.format("%s=%s*%s", aiIDStr, relic, reasonHex))
        end
    end
    return tostring(requestID) .. "#" .. table.concat(parts, "|")
end

local function Haikesi_DecodeExtAIApply(raw)
    if raw == nil or raw == "" then
        return nil, nil, nil
    end
    local requestID, rest = string.match(tostring(raw), "^([^#]+)#(.*)$")
    if requestID == nil or requestID == "" then
        return nil, nil, nil
    end
    local choices = {}
    local reasons = {}
    if rest ~= nil and rest ~= "" then
        for entry in string.gmatch(rest, "[^|]+") do
            local aiIDStr, relic, reasonField = string.match(entry, "^(%d+)=([^=*]+)%*(.*)$")
            if aiIDStr ~= nil and relic ~= nil then
                choices[aiIDStr] = relic
                if reasonField ~= nil and reasonField ~= "" then
                    -- 新格式：utf8 hex；旧格式：可能是原文或 mangled xe5...
                    print(string.format(
                        "[Haikesi ReasonDBG] wireField ai=%s raw=%s",
                        aiIDStr, tostring(reasonField)))
                    local decoded = Haikesi_HexToUtf8(reasonField)
                    local via = "hex"
                    if decoded == nil then
                        decoded = Haikesi_DecodeMangledHexReason(reasonField)
                        via = (decoded ~= nil) and "mangled" or "drop"
                        -- 截断后的裸 hex 不再当正文展示（否则追踪面板出现 e69bb4…）
                        if decoded == nil then
                            decoded = nil
                            if reasonField:match("^[0-9a-fA-F]+$") and #reasonField >= 16 then
                                print(string.format(
                                    "[Haikesi ReasonDBG] drop truncated hex ai=%s len=%d",
                                    aiIDStr, #reasonField))
                            else
                                decoded = reasonField
                                via = "passthrough"
                            end
                        end
                    end
                    if decoded ~= nil and decoded ~= "" then
                        reasons[aiIDStr] = decoded
                        Haikesi_DebugLogReason("decode:" .. via, aiIDStr, decoded)
                    end
                end
            end
        end
    end
    if next(choices) == nil then
        return nil, nil, nil
    end
    if next(reasons) == nil then
        reasons = nil
    end
    return requestID, choices, reasons
end

local function Haikesi_StageExtAIPayload(payload)
    if ExposedMembers == nil or payload == nil or payload == "" then
        return false
    end
    ExposedMembers.Haikesi_ExtAIStagedPayload = payload
    ExposedMembers.Haikesi_ExtAIStagedSeq =
        (tonumber(ExposedMembers.Haikesi_ExtAIStagedSeq) or 0) + 1
    pcall(function()
        if LuaEvents ~= nil and LuaEvents.Haikesi_ExtAIStagedUI ~= nil then
            LuaEvents.Haikesi_ExtAIStagedUI()
        end
    end)
    return true
end

--||======================= Core: apply one relic to one player ========================||--
function ApplyRelicToPlayer(iPlayer, relicType, isSelection, decisionReason)
    local pPlayer = Players[iPlayer]
    if pPlayer == nil then
        print("[Haikesi GamePlay] invalid player id: " .. tostring(iPlayer))
        return false
    end

    local relicDef = GameInfo.Haikesi_Relics[relicType]
    if relicDef == nil then
        print("[Haikesi GamePlay] unknown relic type: " .. tostring(relicType))
        return false
    end
    if (not isSelection) and IsRelicSelectionOnly(relicType) then
        print("[Haikesi GamePlay] skipped selection-only bonus relic: " .. tostring(relicType))
        return false
    end

    local relicIndex = relicDef.Index
    local relicTypes = GetSelectedRelicTypeListForPlayer(pPlayer)
    table.insert(relicTypes, relicType)

    local relicIndexes = {}
    for _, selectedRelicType in ipairs(relicTypes) do
        local selectedRelicDef = GameInfo.Haikesi_Relics[selectedRelicType]
        if selectedRelicDef ~= nil then
            table.insert(relicIndexes, tostring(selectedRelicDef.Index))
        end
    end
    pPlayer:SetProperty(RelicsPropertyKey, table.concat(relicIndexes, "|"))
    pPlayer:SetProperty(RelicsCountPropertyKey, #relicTypes)
    pPlayer:SetProperty(RelicsSlotPropertyPrefix .. #relicTypes, relicType)
    if isSelection and IsAIPoolRelicType(relicType) then
        local slotIndex = #relicTypes
        Haikesi_DebugLogReason(
            "store:in player=" .. tostring(iPlayer) .. " slot=" .. tostring(slotIndex),
            relicType, decisionReason)
        local sanitizedReason = Haikesi_SanitizeDecisionReason(decisionReason)
        if sanitizedReason ~= nil then
            pPlayer:SetProperty(RelicsReasonPropertyPrefix .. slotIndex, sanitizedReason)
            pPlayer:SetProperty(RelicsSummaryPropertyPrefix .. slotIndex, nil)
            local stored = pPlayer:GetProperty(RelicsReasonPropertyPrefix .. slotIndex)
            Haikesi_DebugLogReason(
                "store:out player=" .. tostring(iPlayer) .. " slot=" .. tostring(slotIndex),
                relicType, stored)
        else
            -- 未开大模型时不写效果描述到摘要；追踪面板显示名称
            pPlayer:SetProperty(RelicsReasonPropertyPrefix .. slotIndex, nil)
            pPlayer:SetProperty(RelicsSummaryPropertyPrefix .. slotIndex, nil)
            print(string.format(
                "[Haikesi ReasonDBG] store:skipped player=%s relic=%s (no reason)",
                tostring(iPlayer), tostring(relicType)))
        end
    end

    local modifierIds = g_RelicModifierMap[relicType]
    if modifierIds then
        for _, modId in ipairs(modifierIds) do
            pPlayer:AttachModifierByID(modId)
            print("[Haikesi GamePlay] attached Modifier: " .. modId .. " -> Player" .. iPlayer)
        end
    end

    Haikesi_ApplyLuaEffect(iPlayer, relicType)

    print("[Haikesi GamePlay] Player" .. iPlayer .. " gained relic " .. relicType .. " (Index=" .. relicIndex .. ")")
    return true
end

--||======================= Main Event Handler ========================||--
-- AI 专属海克斯池（仅 NW_HAIKESI_AI_RELIC 开关开启时，AI 随玩家同步触发选其一）
-- 服务端仅做校验：relicType 必须属于 AI 池且 AI 未选过；随机选择由房主 UI 端决定（经 EXECUTE_SCRIPT 下发）
local AI_RELIC_TYPES = {
    'NW_AI_STATS_1', 'NW_AI_STATS_2', 'NW_AI_STATS_3', 'NW_AI_STATS_4', 'NW_AI_STATS_5', 'NW_AI_STATS_6',
    'NW_AI_ECHO_SETTLER', 'NW_AI_ECHO_BUILDER', 'NW_AI_ECHO_MELEE', 'NW_AI_ECHO_RANGED',
    'NW_AI_ECHO_LIGHT_CAVALRY', 'NW_AI_ECHO_HEAVY_CAVALRY', 'NW_AI_ECHO_ANTI_CAVALRY', 'NW_AI_ECHO_SIEGE',
    -- 混乱干扰
    'NW_AI_BARBARIAN_INVASION',
    'NW_AI_LIGHTNING_STORM',
    'NW_AI_RIVER_FLOOD',
    -- 资源创建
    'NW_AI_BRAVE_WOOD', 'NW_AI_MAMA_BORN', 'NW_AI_MILK_DRAGON', 'NW_AI_SILK_LAND', 'NW_AI_DRINK_TEA',
    -- 和平互利
    'NW_AI_CELESTIAL_EMPIRE', 'NW_AI_FERTILE_CRESCENT', 'NW_AI_PAX_ROMANA',
}
local AI_RELIC_TYPE_SET = {}
for _, t in ipairs(AI_RELIC_TYPES) do AI_RELIC_TYPE_SET[t] = true end

local BARBARIAN_INVASION_RELIC = 'NW_AI_BARBARIAN_INVASION'
local LIGHTNING_STORM_RELIC = 'NW_AI_LIGHTNING_STORM'
local RIVER_FLOOD_RELIC = 'NW_AI_RIVER_FLOOD'
-- 南蛮入侵 / 闪电风暴 / 仇水连汛：每轮至多 1 个 AI 抽中混乱干扰类之一
local function IsChaosInterferenceRelic(relicType)
    return relicType == BARBARIAN_INVASION_RELIC
        or relicType == LIGHTNING_STORM_RELIC
        or relicType == RIVER_FLOOD_RELIC
end
-- 南蛮入侵实现已拆至 GamePlay/Haikesi_Barbarian_GamePlay.lua
-- 闪电风暴实现已拆至 GamePlay/Haikesi_LightningStorm_GamePlay.lua
-- 仇水连汛实现已拆至 GamePlay/Haikesi_RiverFlood_GamePlay.lua

local function Haikesi_GetAliveAIPlayers()
    local aiPlayers = {}
    for _, pAI in ipairs(PlayerManager.GetAliveMajors()) do
        if not pAI:IsHuman() and not pAI:IsBarbarian() then
            table.insert(aiPlayers, pAI)
        end
    end
    return aiPlayers
end

-- 必须在 Haikesi_ApplyAIChoicesForRound 等全局函数之前定义：
-- 全局 function 编译时若尚未声明该 local，会把名字解析成全局（运行时为 nil）。
local function Haikesi_GetPlayerRelicCount(pPlayer)
    if pPlayer == nil then return 0 end
    return tonumber(pPlayer:GetProperty(RelicsCountPropertyKey) or 0) or 0
end

local function GetAIAvailableRelics(pAI, excludeChaosThisRound)
    local selected = GetSelectedRelicTypesForPlayer(pAI)
    local available = {}
    for _, t in ipairs(AI_RELIC_TYPES) do
        local relicDef = GameInfo.Haikesi_Relics[t]
        local alreadySelected = selected[t]
        local canPick = not alreadySelected or (relicDef ~= nil and relicDef.IsRepeatable == 1)
        if canPick then
            if not (excludeChaosThisRound and IsChaosInterferenceRelic(t)) then
                table.insert(available, t)
            end
        end
    end
    return available
end

local function AIHasOnlyChaosLeft(pAI)
    local available = GetAIAvailableRelics(pAI, false)
    if #available == 0 then
        return false
    end
    for _, t in ipairs(available) do
        if not IsChaosInterferenceRelic(t) then
            return false
        end
    end
    return true
end

-- AgePick 在独立 Gameplay Lua 状态；经 ExposedMembers 绑定到本脚本全局
-- （否则 Haikesi_SplitChoiceRelics 等为 nil → 单机自动选卡 Runtime Error）
do
    local EM = ExposedMembers
    if EM ~= nil
        and type(Haikesi_SplitChoiceRelics) ~= "function"
        and type(EM.Haikesi_SplitChoiceRelics) == "function" then
        Haikesi_PlayerIsGoldenOrHeroicAge = EM.Haikesi_PlayerIsGoldenOrHeroicAge
        Haikesi_PlayerAgeLabel = EM.Haikesi_PlayerAgeLabel
        Haikesi_AIPickCountForPlayer = EM.Haikesi_AIPickCountForPlayer
        Haikesi_AIOptionsCountForPlayer = EM.Haikesi_AIOptionsCountForPlayer
        Haikesi_SplitChoiceRelics = EM.Haikesi_SplitChoiceRelics
        Haikesi_JoinChoiceRelics = EM.Haikesi_JoinChoiceRelics
        Haikesi_GetAISelectRound = EM.Haikesi_GetAISelectRound
        Haikesi_SetAISelectRound = EM.Haikesi_SetAISelectRound
        print("[Haikesi GamePlay] AgePick helpers bound from ExposedMembers")
    end
end

-- 兜底：AgePick 未加载时仍保证自动选卡可用（global，不占 local 寄存器）
-- 优先读 UI 时代戳记（HasGoldenAge 在 GameCore 不可用）
if type(Haikesi_SplitChoiceRelics) ~= "function" then
    function Haikesi_PlayerAgeLabel(playerID)
        if playerID == nil then return "NORMAL" end
        if ExposedMembers ~= nil and ExposedMembers.Haikesi_UIEraAgeByPlayer ~= nil then
            local stamped = ExposedMembers.Haikesi_UIEraAgeByPlayer[playerID]
                or ExposedMembers.Haikesi_UIEraAgeByPlayer[tostring(playerID)]
            if stamped ~= nil and tostring(stamped) ~= "" then
                return tostring(stamped)
            end
        end
        local prop = Game:GetProperty('PROP_NW_HAIKESI_UI_ERA_AGE_' .. tostring(playerID))
        if prop ~= nil and tostring(prop) ~= "" then return tostring(prop) end
        local eras = Game.GetEras()
        if eras == nil then return "NORMAL" end
        local okH, heroic = pcall(function() return eras:HasHeroicGoldenAge(playerID) end)
        if okH and heroic then return "HEROIC" end
        okH, heroic = pcall(function() return eras:HasHeroicAge(playerID) end)
        if okH and heroic then return "HEROIC" end
        local okG, golden = pcall(function() return eras:HasGoldenAge(playerID) end)
        if okG and golden then return "GOLDEN" end
        local okD, dark = pcall(function() return eras:HasDarkAge(playerID) end)
        if okD and dark then return "DARK" end
        return "NORMAL"
    end
    function Haikesi_PlayerIsGoldenOrHeroicAge(playerID)
        local label = Haikesi_PlayerAgeLabel(playerID)
        return label == "GOLDEN" or label == "HEROIC"
    end
    function Haikesi_AIPickCountForPlayer(pPlayer)
        if pPlayer ~= nil and Haikesi_PlayerIsGoldenOrHeroicAge(pPlayer:GetID()) then
            return 2
        end
        return 1
    end
    function Haikesi_AIOptionsCountForPlayer(pPlayer)
        if Haikesi_AIPickCountForPlayer(pPlayer) >= 2 then return 6 end
        return 3
    end
    function Haikesi_SplitChoiceRelics(value)
        local list = {}
        if value == nil then return list end
        if type(value) == "table" then
            for _, item in ipairs(value) do
                if item ~= nil and tostring(item) ~= "" then
                    table.insert(list, tostring(item))
                end
            end
            return list
        end
        local s = tostring(value)
        if s == "" then return list end
        for item in string.gmatch(s, "[^+]+") do
            if item ~= "" then table.insert(list, item) end
        end
        return list
    end
    function Haikesi_JoinChoiceRelics(relics)
        if relics == nil or #relics == 0 then return nil end
        return table.concat(relics, "+")
    end
    function Haikesi_GetAISelectRound(pAI)
        if pAI == nil then return 0 end
        local marked = pAI:GetProperty('PROP_NW_HAIKESI_AI_SELECT_ROUND')
        if marked ~= nil then return tonumber(marked) or 0 end
        return Haikesi_GetPlayerRelicCount(pAI)
    end
    function Haikesi_SetAISelectRound(pAI, roundNum)
        if pAI == nil or roundNum == nil then return end
        pAI:SetProperty('PROP_NW_HAIKESI_AI_SELECT_ROUND', tonumber(roundNum) or 0)
    end
    print("[Haikesi GamePlay] AgePick helpers installed as local fallbacks")
end

-- UI→Gameplay：刷 InGame 时代/军力缓存（双选依赖时代戳记，须在发牌前调用）
function Haikesi_WarmExtAIUICaches()
    pcall(function()
        local warmFn = ExposedMembers and ExposedMembers.Haikesi_RefreshExtAIUICache
        if type(warmFn) == "function" then
            warmFn()
        elseif LuaEvents ~= nil and LuaEvents.Haikesi_ExtAIWarmCache ~= nil then
            LuaEvents.Haikesi_ExtAIWarmCache()
        end
    end)
end

function Haikesi_BuildDeterministicAIChoices(requesterPlayerID, countBefore)
    Haikesi_WarmExtAIUICaches()
    local choices = {}
    local chaosAssigned = false
    local aiPlayers = Haikesi_GetAliveAIPlayers()

    local function PickNForAI(pAI, pickCount, startChaos)
        local picked = {}
        local localChaos = startChaos
        local aiID = pAI:GetID()
        for pickIdx = 1, pickCount do
            local available = GetAIAvailableRelics(pAI, localChaos)
            -- 排除本轮已抽
            if #picked > 0 then
                local filtered = {}
                local used = {}
                for _, r in ipairs(picked) do
                    used[r] = true
                end
                for _, r in ipairs(available) do
                    if not used[r] then
                        table.insert(filtered, r)
                    end
                end
                available = filtered
            end
            if #available == 0 then
                break
            end
            local salt = (countBefore or 0) * 1000 + aiID + (requesterPlayerID or 0) + pickIdx * 7919
            local relic = available[(math.abs(salt) % #available) + 1]
            table.insert(picked, relic)
            if IsChaosInterferenceRelic(relic) then
                localChaos = true
            end
        end
        return picked, localChaos
    end

    local chaosOnlyAIs = {}
    for _, pAI in ipairs(aiPlayers) do
        if AIHasOnlyChaosLeft(pAI) then
            table.insert(chaosOnlyAIs, pAI)
        end
    end
    if #chaosOnlyAIs > 0 then
        local pickIdx = (math.abs(countBefore * 997 + requesterPlayerID) % #chaosOnlyAIs) + 1
        local pPick = chaosOnlyAIs[pickIdx]
        local n = Haikesi_AIPickCountForPlayer(pPick)
        local picked, nowChaos = PickNForAI(pPick, n, false)
        if #picked > 0 then
            choices[tostring(pPick:GetID())] = Haikesi_JoinChoiceRelics(picked)
            chaosAssigned = nowChaos
        end
    end

    for _, pAI in ipairs(aiPlayers) do
        local aiIDStr = tostring(pAI:GetID())
        if choices[aiIDStr] == nil then
            local n = Haikesi_AIPickCountForPlayer(pAI)
            local picked, nowChaos = PickNForAI(pAI, n, chaosAssigned)
            if #picked == 0 then
                print("[Haikesi GamePlay] AI Player" .. aiIDStr .. " no available AI relic this round")
            else
                choices[aiIDStr] = Haikesi_JoinChoiceRelics(picked)
                chaosAssigned = nowChaos
                if n >= 2 then
                    print("[Haikesi GamePlay] AI Player" .. aiIDStr
                        .. " dual-pick (" .. tostring(Haikesi_PlayerAgeLabel(pAI:GetID()))
                        .. "): " .. tostring(choices[aiIDStr]))
                end
            end
        end
    end
    return choices
end

-- 每轮至多 1 个 AI 拿混乱干扰类；重复强制改抽（落地前最后一道闸）
-- choices 值可为 "A" 或 "A+B"
local function Haikesi_EnforceChaosMutexInChoices(choices, requesterPlayerID, countBefore)
    if choices == nil then return choices end
    local chaosHolders = {}
    for aiIDStr, packed in pairs(choices) do
        local relics = Haikesi_SplitChoiceRelics(packed)
        for _, relic in ipairs(relics) do
            if IsChaosInterferenceRelic(relic) then
                table.insert(chaosHolders, { aiIDStr = aiIDStr, relic = relic })
                break
            end
        end
    end
    if #chaosHolders <= 1 then
        return choices
    end
    table.sort(chaosHolders, function(a, b)
        return tostring(a.aiIDStr) < tostring(b.aiIDStr)
    end)
    local keepIdx = (math.abs((countBefore or 0) * 997 + (requesterPlayerID or 0)) % #chaosHolders) + 1
    local keep = chaosHolders[keepIdx].aiIDStr
    print("[Haikesi GamePlay] CHAOS mutex: " .. tostring(#chaosHolders)
        .. " AIs had chaos interference; keep AI" .. tostring(keep))
    for _, holder in ipairs(chaosHolders) do
        local aiIDStr = holder.aiIDStr
        if aiIDStr ~= keep then
            local aiID = tonumber(aiIDStr)
            local pAI = aiID ~= nil and Players[aiID] or nil
            local oldList = Haikesi_SplitChoiceRelics(choices[aiIDStr])
            local newList = {}
            local localChaos = true -- 已有 keep 占用混乱
            for _, relic in ipairs(oldList) do
                if IsChaosInterferenceRelic(relic) then
                    local replacement = nil
                    if pAI ~= nil then
                        local available = GetAIAvailableRelics(pAI, true)
                        local used = {}
                        for _, r in ipairs(newList) do used[r] = true end
                        for _, r in ipairs(oldList) do used[r] = true end
                        local filtered = {}
                        for _, r in ipairs(available) do
                            if not used[r] and not IsChaosInterferenceRelic(r) then
                                table.insert(filtered, r)
                            end
                        end
                        if #filtered > 0 then
                            local salt = (countBefore or 0) * 1000 + aiID + (requesterPlayerID or 0)
                            replacement = filtered[(math.abs(salt) % #filtered) + 1]
                        end
                    end
                    if replacement ~= nil then
                        table.insert(newList, replacement)
                    end
                else
                    table.insert(newList, relic)
                end
            end
            choices[aiIDStr] = Haikesi_JoinChoiceRelics(newList)
            print("[Haikesi GamePlay] CHAOS mutex: AI" .. tostring(aiIDStr)
                .. " reassigned -> " .. tostring(choices[aiIDStr]))
        end
    end
    return choices
end

function Haikesi_ApplyAIChoicesForRound(requesterPlayerID, aiChoicesTable, countBefore, aiReasonsTable)
    local choices = aiChoicesTable
    if choices == nil then
        choices = Haikesi_BuildDeterministicAIChoices(requesterPlayerID, countBefore)
        print("[Haikesi GamePlay] Host generated deterministic AIChoices for Player"
            .. tostring(requesterPlayerID) .. " selectCount=" .. tostring(countBefore))
    end
    if choices == nil or next(choices) == nil then
        return 0
    end
    choices = Haikesi_EnforceChaosMutexInChoices(choices, requesterPlayerID, countBefore)

    local applied = 0
    local chaosApplied = false
    local roundNum = (countBefore or 0) + 1
    -- 稳定顺序，避免 pairs 打乱互斥二次校验
    local aiIDList = {}
    for aiIDStr, _ in pairs(choices) do
        table.insert(aiIDList, aiIDStr)
    end
    table.sort(aiIDList)

    for _, aiIDStr in ipairs(aiIDList) do
        local packed = choices[aiIDStr]
        local aiID = tonumber(aiIDStr)
        local relicList = Haikesi_SplitChoiceRelics(packed)
        if aiID == nil then
            print("[Haikesi GamePlay] AIChoices invalid aiID: " .. tostring(aiIDStr))
        elseif #relicList == 0 then
            print("[Haikesi GamePlay] AIChoices empty pack for AI " .. tostring(aiIDStr))
        else
            local pAI = Players[aiID]
            if pAI ~= nil and not pAI:IsHuman() and not pAI:IsBarbarian() then
                if Haikesi_GetAISelectRound(pAI) >= roundNum then
                    print("[Haikesi GamePlay] AI Player" .. aiID
                        .. " already at round " .. tostring(roundNum) .. ", skip")
                else
                    local appliedThisAI = 0
                    for pickIdx, aiRelic in ipairs(relicList) do
                        if not AI_RELIC_TYPE_SET[aiRelic] then
                            print("[Haikesi GamePlay] AIChoices rejected (not in AI pool): "
                                .. tostring(aiRelic))
                        else
                            if IsChaosInterferenceRelic(aiRelic) and chaosApplied then
                                local available = GetAIAvailableRelics(pAI, true)
                                if #available > 0 then
                                    local salt = (countBefore or 0) * 1000 + aiID
                                        + (requesterPlayerID or 0) + pickIdx * 7919
                                    aiRelic = available[(math.abs(salt) % #available) + 1]
                                    print("[Haikesi GamePlay] CHAOS mutex at apply: AI" .. aiID
                                        .. " -> " .. tostring(aiRelic))
                                else
                                    print("[Haikesi GamePlay] CHAOS mutex at apply: AI" .. aiID
                                        .. " skip pick (no alt)")
                                    aiRelic = nil
                                end
                            end
                            if aiRelic ~= nil then
                                local selectedTypes = GetSelectedRelicTypesForPlayer(pAI)
                                local relicDef = GameInfo.Haikesi_Relics[aiRelic]
                                local canApply = not selectedTypes[aiRelic]
                                    or (relicDef ~= nil and relicDef.IsRepeatable == 1)
                                if canApply then
                                    local reason = aiReasonsTable and aiReasonsTable[aiIDStr] or nil
                                    local okApplyOne, applyResult = pcall(
                                        ApplyRelicToPlayer, aiID, aiRelic, true, reason)
                                    if not okApplyOne then
                                        print("[Haikesi GamePlay] AI Player" .. aiID
                                            .. " ApplyRelic error for " .. tostring(aiRelic)
                                            .. ": " .. tostring(applyResult))
                                    elseif applyResult then
                                        applied = applied + 1
                                        appliedThisAI = appliedThisAI + 1
                                        if IsChaosInterferenceRelic(aiRelic) then
                                            chaosApplied = true
                                        end
                                        print("[Haikesi GamePlay] AI Player" .. aiID
                                            .. " gained AI relic " .. aiRelic)
                                    else
                                        print("[Haikesi GamePlay] AI Player" .. aiID
                                            .. " failed to apply AI relic " .. tostring(aiRelic))
                                    end
                                else
                                    print("[Haikesi GamePlay] AI Player" .. aiID
                                        .. " already has " .. aiRelic .. ", skip")
                                end
                            end
                        end
                    end
                    if appliedThisAI > 0 then
                        Haikesi_SetAISelectRound(pAI, roundNum)
                    end
                end
            end
        end
    end
    -- UI 下发的 AIChoices 若全部失效，回退确定性选择，避免本轮 AI 空窗
    if applied == 0 and aiChoicesTable ~= nil then
        print("[Haikesi GamePlay] UI AIChoices applied 0, fallback deterministic selectCount="
            .. tostring(countBefore))
        return Haikesi_ApplyAIChoicesForRound(requesterPlayerID, nil, countBefore, aiReasonsTable)
    end
    return applied
end

-- 外部大模型 AI 海克斯：异步挂起请求（FireTuner / civ6-mcp 轮询提交）
local EXT_AI_PENDING_KEY = 'PROP_NW_HAIKESI_EXT_AI_PENDING'
local EXT_AI_REQUEST_ID_KEY = 'PROP_NW_HAIKESI_EXT_AI_REQUEST_ID'
local EXT_AI_REQUESTER_KEY = 'PROP_NW_HAIKESI_EXT_AI_REQUESTER'
local EXT_AI_COUNT_BEFORE_KEY = 'PROP_NW_HAIKESI_EXT_AI_COUNT_BEFORE'
local EXT_AI_HUMAN_RELIC_KEY = 'PROP_NW_HAIKESI_EXT_AI_HUMAN_RELIC'
local EXT_AI_CREATED_TURN_KEY = 'PROP_NW_HAIKESI_EXT_AI_CREATED_TURN'
local EXT_AI_OPTION_IDS_KEY = 'PROP_NW_HAIKESI_EXT_AI_OPTION_IDS'
local EXT_AI_OPTIONS_PREFIX = 'PROP_NW_HAIKESI_EXT_AI_OPTIONS_'
-- 普通 3 选 1；黄金/英雄 6 选 2（见 Haikesi_ExtAI_AgePick.lua）
local EXT_AI_TIMEOUT_TURNS = 1

-- Civ6 布尔配置常为 0/1；Lua 中 0 为真，故不能写 (GetValue() or false)
local function Haikesi_IsConfigEnabled(configId)
    local v = GameConfiguration.GetValue(configId)
    return v == true or v == 1 or v == "1"
end

local function Haikesi_IsExternalAIEnabled()
    return Haikesi_IsConfigEnabled('NW_HAIKESI_EXTERNAL_AI')
end

-- 以人类「选择轮次」为准给 AI 补齐（Trigger 递增前 target = SELECT_COUNT+1）
-- 按轮次整批发牌（每轮一次 Build/UI），保证南蛮入侵互斥不被「逐 AI 重掷」打穿
local function Haikesi_SyncAIRelicCountToHuman(requesterPlayerID, targetCount, uiChoicesTable, aiReasonsTable)
    if targetCount == nil or targetCount < 1 then
        return 0
    end
    local totalApplied = 0
    local aiPlayers = Haikesi_GetAliveAIPlayers()

    for needCount = 1, targetCount do
        local countBefore = needCount - 1
        local useUI = (needCount == targetCount and uiChoicesTable ~= nil)
        local choices = useUI and uiChoicesTable
            or Haikesi_BuildDeterministicAIChoices(requesterPlayerID, countBefore)
        if choices == nil or next(choices) == nil then
            print("[Haikesi GamePlay] sync round " .. tostring(needCount) .. " empty choices")
        else
            choices = Haikesi_EnforceChaosMutexInChoices(choices, requesterPlayerID, countBefore)

            local chaosApplied = false
            local sortedIDs = {}
            for _, pAI in ipairs(aiPlayers) do
                table.insert(sortedIDs, pAI:GetID())
            end
            table.sort(sortedIDs)

            for _, aiID in ipairs(sortedIDs) do
                local pAI = Players[aiID]
                if pAI ~= nil and Haikesi_GetAISelectRound(pAI) < needCount then
                    local aiIDStr = tostring(aiID)
                    local packed = choices[aiIDStr]
                    local reason = (useUI and aiReasonsTable ~= nil) and aiReasonsTable[aiIDStr] or nil
                    local relicList = Haikesi_SplitChoiceRelics(packed)

                    local function PickAltForAI(excludeChaos, excludeSet)
                        local available = GetAIAvailableRelics(pAI, excludeChaos)
                        if excludeSet ~= nil then
                            local filtered = {}
                            for _, r in ipairs(available) do
                                if not excludeSet[r] then
                                    table.insert(filtered, r)
                                end
                            end
                            available = filtered
                        end
                        if #available == 0 then return nil end
                        local salt = countBefore * 1000 + aiID + requesterPlayerID
                        return available[(math.abs(salt) % #available) + 1]
                    end

                    if #relicList == 0 then
                        local one = PickAltForAI(chaosApplied, nil)
                        if one ~= nil then
                            relicList = { one }
                        end
                        reason = nil
                    end

                    local appliedAny = false
                    local usedThisRound = {}
                    for pickIdx, relic in ipairs(relicList) do
                        if relic == nil or not AI_RELIC_TYPE_SET[relic] then
                            relic = PickAltForAI(chaosApplied, usedThisRound)
                            reason = nil
                        end

                        if IsChaosInterferenceRelic(relic) and chaosApplied then
                            relic = PickAltForAI(true, usedThisRound)
                            reason = nil
                            print("[Haikesi GamePlay] CHAOS mutex sync: AI" .. aiID
                                .. " -> " .. tostring(relic))
                        end

                        if relic == nil then
                            print("[Haikesi GamePlay] AI Player" .. aiIDStr
                                .. " cannot catch up round " .. tostring(needCount)
                                .. " pick " .. tostring(pickIdx))
                        else
                            local selectedTypes = GetSelectedRelicTypesForPlayer(pAI)
                            local relicDef = GameInfo.Haikesi_Relics[relic]
                            local canApply = not selectedTypes[relic]
                                or (relicDef ~= nil and relicDef.IsRepeatable == 1)
                            if not canApply or usedThisRound[relic] then
                                relic = PickAltForAI(chaosApplied, usedThisRound)
                                reason = nil
                                if relic == nil then
                                    print("[Haikesi GamePlay] AI Player" .. aiIDStr
                                        .. " catch-up blocked round " .. tostring(needCount))
                                end
                            end

                            if relic ~= nil then
                                local okCatch, catchResult = pcall(
                                    ApplyRelicToPlayer, aiID, relic, true, reason)
                                if not okCatch then
                                    print("[Haikesi GamePlay] AI Player" .. aiID
                                        .. " catch-up ApplyRelic error: " .. tostring(catchResult))
                                elseif catchResult then
                                    totalApplied = totalApplied + 1
                                    appliedAny = true
                                    usedThisRound[relic] = true
                                    if IsChaosInterferenceRelic(relic) then
                                        chaosApplied = true
                                    end
                                    print("[Haikesi GamePlay] AI Player" .. aiID
                                        .. " catch-up gained " .. relic
                                        .. " (round " .. tostring(needCount)
                                        .. "/" .. tostring(targetCount) .. ")")
                                else
                                    print("[Haikesi GamePlay] AI Player" .. aiID
                                        .. " catch-up apply failed: " .. tostring(relic))
                                end
                            end
                        end
                    end
                    if appliedAny then
                        Haikesi_SetAISelectRound(pAI, needCount)
                    end
                end
            end
        end
    end
    return totalApplied
end

local function Haikesi_ClearExternalAIOptions()
    local idsStr = Game:GetProperty(EXT_AI_OPTION_IDS_KEY) or ""
    if idsStr ~= "" then
        for aiIDStr in string.gmatch(idsStr, "[^,]+") do
            Game:SetProperty(EXT_AI_OPTIONS_PREFIX .. aiIDStr, nil)
        end
    end
    Game:SetProperty(EXT_AI_OPTION_IDS_KEY, nil)
end

local function Haikesi_ClearExternalAIRequest()
    Haikesi_ClearExternalAIOptions()
    Game:SetProperty(EXT_AI_PENDING_KEY, 0)
    Game:SetProperty(EXT_AI_REQUEST_ID_KEY, nil)
    Game:SetProperty(EXT_AI_REQUESTER_KEY, nil)
    Game:SetProperty(EXT_AI_COUNT_BEFORE_KEY, nil)
    Game:SetProperty(EXT_AI_HUMAN_RELIC_KEY, nil)
    Game:SetProperty(EXT_AI_CREATED_TURN_KEY, nil)
    pcall(function()
        if LuaEvents ~= nil and LuaEvents.Haikesi_ExtAIClearedUI ~= nil then
            LuaEvents.Haikesi_ExtAIClearedUI()
        end
    end)
end

local function Haikesi_ParseCommaList(value)
    local list = {}
    if value == nil or value == "" then
        return list
    end
    for item in string.gmatch(value, "[^,]+") do
        if item ~= "" then
            table.insert(list, item)
        end
    end
    return list
end

local function Haikesi_GetStoredExternalAIOptions(aiID)
    return Haikesi_ParseCommaList(Game:GetProperty(EXT_AI_OPTIONS_PREFIX .. tostring(aiID)))
end

-- 从候选池不放回随机抽取至多 count 个（确定性 salt，轮询时选项稳定）
local function Haikesi_PickRandomRelicsFromPool(pool, count, salt)
    if pool == nil or #pool == 0 then
        return {}
    end
    local working = {}
    for _, relicType in ipairs(pool) do
        table.insert(working, relicType)
    end
    local pickCount = math.min(count, #working)
    local picked = {}
    for i = 1, pickCount do
        local idx = (math.abs(salt + i * 131 + #working * 17) % #working) + 1
        table.insert(picked, working[idx])
        table.remove(working, idx)
    end
    return picked
end

local function Haikesi_StoreExternalAIOptionsForAllAIs(requesterPlayerID, countBefore, createdTurn)
    -- 混乱干扰互斥：整批候选至多 1 张混乱类（跨 AI + 同一 AI 的 6 选里也只留 1 张）。
    -- 大模型提示词不再写互斥规则，靠候选列表自然约束；提交侧仍二次校验。
    local chaosInOptionsBatch = false
    local aiOptionIDs = {}
    for _, pAI in ipairs(Haikesi_GetAliveAIPlayers()) do
        local aiID = pAI:GetID()
        local available = GetAIAvailableRelics(pAI, chaosInOptionsBatch)
        local optCount = Haikesi_AIOptionsCountForPlayer(pAI)
        local salt = countBefore * 1000 + aiID * 17 + requesterPlayerID + createdTurn * 997
        local options = Haikesi_PickRandomRelicsFromPool(available, optCount, salt)

        -- 同一 AI 选项里若抽到多张混乱，只保留第一张，其余用非混乱补满
        local filtered = {}
        local chaosKeptHere = false
        for _, opt in ipairs(options) do
            if IsChaosInterferenceRelic(opt) then
                if not chaosInOptionsBatch and not chaosKeptHere then
                    table.insert(filtered, opt)
                    chaosKeptHere = true
                    chaosInOptionsBatch = true
                end
            else
                table.insert(filtered, opt)
            end
        end
        if #filtered < optCount then
            local have = {}
            for _, t in ipairs(filtered) do
                have[t] = true
            end
            local refill = GetAIAvailableRelics(pAI, true) -- 强制无混乱
            for _, t in ipairs(refill) do
                if #filtered >= optCount then
                    break
                end
                if not have[t] then
                    table.insert(filtered, t)
                    have[t] = true
                end
            end
        end
        options = filtered

        Game:SetProperty(EXT_AI_OPTIONS_PREFIX .. aiID, table.concat(options, ","))
        table.insert(aiOptionIDs, tostring(aiID))
        print("[Haikesi GamePlay] External AI options Player" .. aiID
            .. " picks=" .. tostring(Haikesi_AIPickCountForPlayer(pAI))
            .. " age=" .. tostring(Haikesi_PlayerAgeLabel(aiID))
            .. ": " .. table.concat(options, ", "))
    end
    Game:SetProperty(EXT_AI_OPTION_IDS_KEY, table.concat(aiOptionIDs, ","))
end

local function Haikesi_EnsureExternalAIOptionsStored()
    if (Game:GetProperty(EXT_AI_PENDING_KEY) or 0) ~= 1 then
        return
    end
    local idsStr = Game:GetProperty(EXT_AI_OPTION_IDS_KEY) or ""
    local needRegen = (idsStr == "")
    if not needRegen then
        for aiIDStr in string.gmatch(idsStr, "[^,]+") do
            if #Haikesi_GetStoredExternalAIOptions(aiIDStr) == 0 then
                needRegen = true
                break
            end
        end
    end
    if not needRegen then
        return
    end
    local requester = tonumber(Game:GetProperty(EXT_AI_REQUESTER_KEY)) or 0
    local countBefore = tonumber(Game:GetProperty(EXT_AI_COUNT_BEFORE_KEY)) or 0
    local createdTurn = tonumber(Game:GetProperty(EXT_AI_CREATED_TURN_KEY))
        or Game.GetCurrentGameTurn()
    print("[Haikesi GamePlay] External AI options missing, regenerating...")
    Haikesi_WarmExtAIUICaches()
    Haikesi_StoreExternalAIOptionsForAllAIs(requester, countBefore, createdTurn)
end

-- 对局标识（随机种子+地图+人类位）；watch 据此归档 decision 并在新开档时重置
local function Haikesi_PrintGameSessionKV(requesterPlayerID)
    local requester = requesterPlayerID or 0
    local seed = GameConfiguration.GetValue("GAME_SYNC_RANDOM_SEED") or 0
    local mapScript = GameConfiguration.GetValue("MAP_SCRIPT") or "Unknown"
    local mapSize = GameConfiguration.GetValue("MAP_SIZE") or "Unknown"
    local reqCiv = "Unknown"
    pcall(function()
        local reqCfg = PlayerConfigurations[requester]
        if reqCfg then
            reqCiv = Locale.Lookup(reqCfg:GetCivilizationShortDescription()):gsub("|", "/")
        end
    end)
    print("GAME_SESSION=" .. tostring(seed) .. "|" .. tostring(mapScript) .. "|"
        .. tostring(mapSize) .. "|" .. tostring(requester) .. "|" .. reqCiv)
end

local function Haikesi_PrintGameSpeedKV()
    pcall(function()
        local gsIdx = Game.GetGameSpeedType()
        local gsRow = GameInfo.GameSpeeds[gsIdx]
        if gsRow then
            local gsName = Locale.Lookup(gsRow.Name)
            local gsMult = gsRow.CostMultiplier or 100
            print("GAME_SPEED=" .. gsName .. "|" .. tostring(gsMult))
        end
    end)
end

-- 结构化 dump：联机无 FireTuner 时由外置 watch 尾 Lua.log 解析（与 GetExternalAIRequest 同字段）
local function Haikesi_DumpExternalAIRequestToLog(reason)
    if (Game:GetProperty(EXT_AI_PENDING_KEY) or 0) ~= 1 then
        return
    end
    Haikesi_EnsureExternalAIOptionsStored()

    local requestID = Game:GetProperty(EXT_AI_REQUEST_ID_KEY) or ""
    local requester = Game:GetProperty(EXT_AI_REQUESTER_KEY) or 0
    local countBefore = Game:GetProperty(EXT_AI_COUNT_BEFORE_KEY) or 0
    local humanRelic = Game:GetProperty(EXT_AI_HUMAN_RELIC_KEY) or ""
    local turn = Game.GetCurrentGameTurn()
    local invasionMutex = 0
    for _, t in ipairs(AI_RELIC_TYPES) do
        if t == BARBARIAN_INVASION_RELIC then
            invasionMutex = 1
            break
        end
    end
    local function probeMp(fn)
        if type(fn) ~= "function" then
            return nil
        end
        local ok, v = pcall(fn)
        if not ok then
            return nil
        end
        return v == true
    end
    -- FireTuner 在 AnyMultiplayer（热座/局域网/互联网含 PVE 房）均禁用 → MP=1 走横幅/LOG
    local gcAny = GameConfiguration ~= nil and probeMp(GameConfiguration.IsAnyMultiplayer)
    local gcNet = GameConfiguration ~= nil and probeMp(GameConfiguration.IsNetworkMultiplayer)
    local gcLan = GameConfiguration ~= nil and probeMp(GameConfiguration.IsLANMultiplayer)
    local gcHot = GameConfiguration ~= nil and probeMp(GameConfiguration.IsHotseat)
    local gameNet = Game ~= nil and probeMp(Game.IsNetworkMultiplayer)
    local netNet = Network ~= nil and probeMp(Network.IsNetworkMultiplayer)
    local mp = 0
    if gcAny or gcNet or gcLan or gcHot or gameNet or netNet then
        mp = 1
    end
    print(string.format(
        "[Haikesi GamePlay] ExtAI session flags: GC.Any=%s GC.Net=%s GC.LAN=%s GC.Hotseat=%s Game.Net=%s Network.Net=%s mpFlag=%s",
        tostring(gcAny), tostring(gcNet), tostring(gcLan), tostring(gcHot),
        tostring(gameNet), tostring(netNet), tostring(mp)))

    print("===HAIKESI_EXT_AI_REQ_BEGIN===")
    print("DUMP_REASON=" .. tostring(reason or "create"))
    print("CHANNEL=LOG")
    print("MP=" .. tostring(mp))
    print("REQUEST_ID=" .. tostring(requestID))
    print("TURN=" .. tostring(turn))
    print("REQUESTER=" .. tostring(requester))
    print("HUMAN_RELIC=" .. tostring(humanRelic))
    print("COUNT_BEFORE=" .. tostring(countBefore))
    print("INVASION_MUTEX=" .. tostring(invasionMutex))
    Haikesi_PrintGameSessionKV(requester)
    Haikesi_PrintGameSpeedKV()

    local viewerIDs = {}
    for _, pAI in ipairs(Haikesi_GetAliveAIPlayers()) do
        local aiID = pAI:GetID()
        table.insert(viewerIDs, aiID)
        local _, leaderType = GetPlayerConfigTypes(aiID)
        local civLabel = leaderType or ("Player" .. tostring(aiID))
        local pConfig = PlayerConfigurations[aiID]
        local playerName = (pConfig and pConfig:GetPlayerName()) or ""
        local options = Haikesi_GetStoredExternalAIOptions(aiID)
        local selectedList = GetSelectedRelicTypeListForPlayer(pAI)
        print("AI|" .. tostring(aiID) .. "|" .. tostring(civLabel) .. "|"
            .. table.concat(options, ",") .. "|selected:" .. table.concat(selectedList, ",")
            .. "|name:" .. tostring(playerName)
            .. "|picks:" .. tostring(Haikesi_AIPickCountForPlayer(pAI))
            .. "|age:" .. tostring(Haikesi_PlayerAgeLabel(aiID)))
    end
    -- 与单机 FireTuner gather 同线格式：overview + WC + 各 AI 迷雾/外交视图
    -- Context 脚本在独立 Gameplay 环境，经 ExposedMembers 调用
    local dumpFn = Haikesi_DumpExtAIContext
    if type(dumpFn) ~= "function" and ExposedMembers ~= nil then
        dumpFn = ExposedMembers.Haikesi_DumpExtAIContext
    end
    if type(dumpFn) == "function" then
        local requester = Game:GetProperty(EXT_AI_REQUESTER_KEY) or 0
        dumpFn(requester, viewerIDs)
    else
        print("[Haikesi GamePlay] WARN: Haikesi_DumpExtAIContext missing (reload ExtAI Context script)")
    end
    print("===HAIKESI_EXT_AI_REQ_END===")
end

local function Haikesi_CreateExternalAIRequest(requesterPlayerID, humanRelic, countBefore)
    local turn = Game.GetCurrentGameTurn()
    -- 同回合重选/读档重测：追加全局序号，避免 request_id 碰撞导致 watch/归档互相覆盖
    local seq = tonumber(Game:GetProperty('PROP_NW_HAIKESI_EXT_AI_SEQ') or 0) or 0
    seq = seq + 1
    Game:SetProperty('PROP_NW_HAIKESI_EXT_AI_SEQ', seq)
    local requestID = tostring(turn) .. '_' .. tostring(countBefore)
        .. '_' .. tostring(requesterPlayerID) .. '_' .. tostring(seq)
    Haikesi_ClearExternalAIOptions()
    Game:SetProperty(EXT_AI_PENDING_KEY, 1)
    Game:SetProperty(EXT_AI_REQUEST_ID_KEY, requestID)
    Game:SetProperty(EXT_AI_REQUESTER_KEY, requesterPlayerID)
    Game:SetProperty(EXT_AI_COUNT_BEFORE_KEY, countBefore)
    Game:SetProperty(EXT_AI_HUMAN_RELIC_KEY, humanRelic)
    Game:SetProperty(EXT_AI_CREATED_TURN_KEY, turn)

    -- 须在发牌前刷 UI 时代戳记：HasGoldenAge 仅 InGame，否则黄金时代也会 3 选 1
    Haikesi_WarmExtAIUICaches()
    Haikesi_StoreExternalAIOptionsForAllAIs(requesterPlayerID, countBefore, turn)

    print("[Haikesi GamePlay] External AI request created: " .. requestID
        .. " requester=" .. tostring(requesterPlayerID)
        .. " humanRelic=" .. tostring(humanRelic)
        .. " countBefore=" .. tostring(countBefore))
    -- 再刷一次军力/外交缓存后 dump（时代已在发牌前刷过）
    Haikesi_WarmExtAIUICaches()
    -- 单机/联机均 dump：联机 watch 无 Tuner 时依赖此块；单机可忽略
    Haikesi_DumpExternalAIRequestToLog("create")
    pcall(function()
        if LuaEvents ~= nil and LuaEvents.Haikesi_ExtAIPendingUI ~= nil then
            LuaEvents.Haikesi_ExtAIPendingUI()
        end
    end)
end

local function Haikesi_ValidateExternalAIChoices(choicesTable)
    if choicesTable == nil or next(choicesTable) == nil then
        return false, "empty choices"
    end

    -- UI Trim 曾截断 wire 只剩 1 个 AI：拒绝并保留 pending，避免半应用
    local optionIds = Haikesi_ParseCommaList(Game:GetProperty(EXT_AI_OPTION_IDS_KEY) or "")
    if #optionIds > 0 then
        local choiceCount = 0
        for _ in pairs(choicesTable) do
            choiceCount = choiceCount + 1
        end
        if choiceCount < #optionIds then
            return false, "incomplete choices: got " .. tostring(choiceCount)
                .. " expected " .. tostring(#optionIds)
        end
    end

    local chaosCount = 0
    for _, packed in pairs(choicesTable) do
        for _, aiRelic in ipairs(Haikesi_SplitChoiceRelics(packed)) do
            if IsChaosInterferenceRelic(aiRelic) then
                chaosCount = chaosCount + 1
            end
        end
    end
    if chaosCount > 1 then
        return false, "multiple chaos interference assignments"
    end

    local chaosAssignedInBatch = chaosCount == 1
    for aiIDStr, packed in pairs(choicesTable) do
        local aiID = tonumber(aiIDStr)
        if aiID == nil then
            return false, "invalid aiID: " .. tostring(aiIDStr)
        end
        local pAI = Players[aiID]
        if pAI == nil or pAI:IsHuman() or pAI:IsBarbarian() then
            return false, "invalid AI player: " .. tostring(aiIDStr)
        end
        local relicList = Haikesi_SplitChoiceRelics(packed)
        local expectedPicks = Haikesi_AIPickCountForPlayer(pAI)
        if #relicList < 1 then
            return false, "empty picks for AI " .. aiIDStr
        end
        if #relicList > expectedPicks then
            return false, "too many picks for AI " .. aiIDStr
                .. " got " .. tostring(#relicList) .. " expected <=" .. tostring(expectedPicks)
        end
        local seen = {}
        for _, aiRelic in ipairs(relicList) do
            if seen[aiRelic] then
                return false, "duplicate pick for AI " .. aiIDStr .. ": " .. tostring(aiRelic)
            end
            seen[aiRelic] = true
            if not AI_RELIC_TYPE_SET[aiRelic] then
                return false, "not in AI pool: " .. tostring(aiRelic)
            end
        end
        -- 候选充足时必须选满（金/英 6 选 2）
        local options = Haikesi_GetStoredExternalAIOptions(aiID)
        if #options == 0 then
            local excludeChaos = chaosAssignedInBatch
            options = GetAIAvailableRelics(pAI, excludeChaos)
        end
        if #relicList < expectedPicks and #options >= expectedPicks then
            return false, "under-picked for AI " .. aiIDStr
                .. " got " .. tostring(#relicList) .. " expected " .. tostring(expectedPicks)
        end
        for _, aiRelic in ipairs(relicList) do
            local found = false
            for _, t in ipairs(options) do
                if t == aiRelic then
                    found = true
                    break
                end
            end
            if not found then
                return false, "invalid choice for AI " .. aiIDStr
                    .. " (not in options): " .. tostring(aiRelic)
            end
        end
    end
    return true, nil
end

local function Haikesi_ValidateExternalAIReasons(choicesTable, reasonsTable)
    if reasonsTable == nil or next(reasonsTable) == nil then
        return true, nil
    end
    for aiIDStr, reason in pairs(reasonsTable) do
        if choicesTable[aiIDStr] == nil then
            return false, "reason without choice for AI " .. tostring(aiIDStr)
        end
        if type(reason) ~= "string" or Haikesi_SanitizeDecisionReason(reason) == nil then
            return false, "invalid reason for AI " .. tostring(aiIDStr)
        end
    end
    return true, nil
end

function Haikesi_GetExternalAIRequest()
    if (Game:GetProperty(EXT_AI_PENDING_KEY) or 0) ~= 1 then
        print("NONE")
        return
    end

    Haikesi_EnsureExternalAIOptionsStored()

    local requestID = Game:GetProperty(EXT_AI_REQUEST_ID_KEY) or ""
    local requester = Game:GetProperty(EXT_AI_REQUESTER_KEY) or 0
    local countBefore = Game:GetProperty(EXT_AI_COUNT_BEFORE_KEY) or 0
    local humanRelic = Game:GetProperty(EXT_AI_HUMAN_RELIC_KEY) or ""
    local turn = Game.GetCurrentGameTurn()
    local invasionMutex = 0
    for _, t in ipairs(AI_RELIC_TYPES) do
        if t == BARBARIAN_INVASION_RELIC then
            invasionMutex = 1
            break
        end
    end

    -- FireTuner 轮询格式（无 BEGIN/END 标记）
    print("REQUEST_ID=" .. tostring(requestID))
    print("TURN=" .. tostring(turn))
    print("REQUESTER=" .. tostring(requester))
    print("HUMAN_RELIC=" .. tostring(humanRelic))
    print("COUNT_BEFORE=" .. tostring(countBefore))
    print("INVASION_MUTEX=" .. tostring(invasionMutex))
    Haikesi_PrintGameSessionKV(requester)
    Haikesi_PrintGameSpeedKV()

    for _, pAI in ipairs(Haikesi_GetAliveAIPlayers()) do
        local aiID = pAI:GetID()
        local _, leaderType = GetPlayerConfigTypes(aiID)
        local civLabel = leaderType or ("Player" .. tostring(aiID))
        local pConfig = PlayerConfigurations[aiID]
        local playerName = (pConfig and pConfig:GetPlayerName()) or ""
        local options = Haikesi_GetStoredExternalAIOptions(aiID)
        local selectedList = GetSelectedRelicTypeListForPlayer(pAI)
        print("AI|" .. tostring(aiID) .. "|" .. tostring(civLabel) .. "|"
            .. table.concat(options, ",") .. "|selected:" .. table.concat(selectedList, ",")
            .. "|name:" .. tostring(playerName)
            .. "|picks:" .. tostring(Haikesi_AIPickCountForPlayer(pAI))
            .. "|age:" .. tostring(Haikesi_PlayerAgeLabel(aiID)))
    end
end

-- FireTuner/MCP：仅校验并暂存到主机 ExposedMembers，不改局内收益（由 UI EXECUTE_SCRIPT 广播落地）
function Haikesi_SubmitExternalAIChoices(requestID, choicesTable, reasonsTable)
    if (Game:GetProperty(EXT_AI_PENDING_KEY) or 0) ~= 1 then
        print("ERR:no pending request")
        return false
    end
    local pendingID = Game:GetProperty(EXT_AI_REQUEST_ID_KEY)
    if pendingID ~= requestID then
        print("ERR:request_id mismatch expected=" .. tostring(pendingID) .. " got=" .. tostring(requestID))
        return false
    end

    local ok, err = Haikesi_ValidateExternalAIChoices(choicesTable)
    if not ok then
        print("ERR:" .. tostring(err))
        return false
    end

    ok, err = Haikesi_ValidateExternalAIReasons(choicesTable, reasonsTable)
    if not ok then
        print("ERR:" .. tostring(err))
        return false
    end

    local sanitizedReasons = nil
    if reasonsTable ~= nil and next(reasonsTable) ~= nil then
        sanitizedReasons = {}
        for aiIDStr, reason in pairs(reasonsTable) do
            Haikesi_DebugLogReason("submit:raw", aiIDStr, reason)
            local cleaned = Haikesi_SanitizeDecisionReason(reason)
            sanitizedReasons[aiIDStr] = cleaned
            Haikesi_DebugLogReason("submit:sanitized", aiIDStr, cleaned)
            if cleaned ~= nil then
                print(string.format(
                    "[Haikesi ReasonDBG] submit:wireHex ai=%s hex=%s",
                    aiIDStr, Haikesi_Utf8ToHex(cleaned:gsub("[#|=*]", ""))))
            end
        end
    end

    local requester = tonumber(Game:GetProperty(EXT_AI_REQUESTER_KEY))
    local countBefore = tonumber(Game:GetProperty(EXT_AI_COUNT_BEFORE_KEY))
    local pRequester = requester ~= nil and Players[requester] or nil
    if pRequester == nil or countBefore == nil then
        print("ERR:invalid pending metadata")
        return false
    end

    local payload = Haikesi_EncodeExtAIApply(requestID, choicesTable, sanitizedReasons)
    print(string.format(
        "[Haikesi ReasonDBG] submit:payloadLen=%d payload=%s",
        #tostring(payload), tostring(payload)))
    if not Haikesi_StageExtAIPayload(payload) then
        print("ERR:stage failed (ExposedMembers unavailable)")
        return false
    end
    print("OK:staged request_id=" .. tostring(requestID)
        .. " seq=" .. tostring(ExposedMembers.Haikesi_ExtAIStagedSeq))
    return true
end

-- EXECUTE_SCRIPT / ExposedMembers 落地：各端同参 Apply（pending 已清则幂等忽略）
function Haikesi_ApplyExternalAIFromNetwork(raw)
    local requestID, choicesTable, reasonsTable = Haikesi_DecodeExtAIApply(raw)
    if requestID == nil or choicesTable == nil then
        print("[Haikesi GamePlay] ExtAIApply decode failed")
        return false
    end
    if (Game:GetProperty(EXT_AI_PENDING_KEY) or 0) ~= 1 then
        print("[Haikesi GamePlay] ExtAIApply ignored: no pending")
        return false
    end
    local pendingID = Game:GetProperty(EXT_AI_REQUEST_ID_KEY)
    if pendingID ~= requestID then
        print("[Haikesi GamePlay] ExtAIApply ignored: request_id mismatch expected="
            .. tostring(pendingID) .. " got=" .. tostring(requestID))
        return false
    end

    local ok, err = Haikesi_ValidateExternalAIChoices(choicesTable)
    if not ok then
        print("[Haikesi GamePlay] ExtAIApply rejected: " .. tostring(err))
        return false
    end
    ok, err = Haikesi_ValidateExternalAIReasons(choicesTable, reasonsTable)
    if not ok then
        print("[Haikesi GamePlay] ExtAIApply rejected: " .. tostring(err))
        return false
    end

    local sanitizedReasons = nil
    if reasonsTable ~= nil and next(reasonsTable) ~= nil then
        sanitizedReasons = {}
        for aiIDStr, reason in pairs(reasonsTable) do
            Haikesi_DebugLogReason("applyNet:raw", aiIDStr, reason)
            local cleaned = Haikesi_SanitizeDecisionReason(reason)
            sanitizedReasons[aiIDStr] = cleaned
            Haikesi_DebugLogReason("applyNet:sanitized", aiIDStr, cleaned)
        end
    end

    local requester = tonumber(Game:GetProperty(EXT_AI_REQUESTER_KEY))
    local countBefore = tonumber(Game:GetProperty(EXT_AI_COUNT_BEFORE_KEY))
    local pRequester = requester ~= nil and Players[requester] or nil
    if pRequester == nil or countBefore == nil then
        print("[Haikesi GamePlay] ExtAIApply invalid pending metadata")
        Haikesi_ClearExternalAIRequest()
        return false
    end

    local targetRound = countBefore + 1
    -- 只发本轮 LLM 选择，禁止 Sync(1..target) 把缺口用确定性补齐混进同一次落地
    -- （否则日志会出现 round N/N+1 确定性 + round N+1/N+1 大模型，AI 一次得两张）
    local aiSyncedTo = tonumber(pRequester:GetProperty('PROP_NW_HAIKESI_AI_CHOICES_FOR_COUNT') or -1) or -1
    if aiSyncedTo < countBefore then
        print("[Haikesi GamePlay] ExtAIApply pre-align AI to countBefore="
            .. tostring(countBefore) .. " (was syncedTo=" .. tostring(aiSyncedTo) .. ")")
        Haikesi_SyncAIRelicCountToHuman(requester, countBefore, nil, nil)
        pRequester:SetProperty('PROP_NW_HAIKESI_AI_CHOICES_FOR_COUNT', countBefore)
    end
    if aiSyncedTo >= targetRound then
        -- 读档重放常见：AI 已有本轮牌。仍尝试 Apply（内部会对已达轮次的 AI skip），
        -- 并清 pending，避免横幅卡死、wire「粘了却不消费」。
        print("[Haikesi GamePlay] ExtAIApply note: AI syncedTo="
            .. tostring(aiSyncedTo) .. " >= target=" .. tostring(targetRound)
            .. " — still try apply then clear pending")
    end
    local okApply, appliedOrErr = pcall(
        Haikesi_ApplyAIChoicesForRound,
        requester, choicesTable, countBefore, sanitizedReasons
    )
    if not okApply then
        print("[Haikesi GamePlay] ExtAIApply ApplyAIChoices error: " .. tostring(appliedOrErr))
        -- 不清除 pending，留给超时/下次选卡补齐；避免半写入后丢请求
        return false
    end
    local appliedN = tonumber(appliedOrErr) or 0
    if aiSyncedTo < targetRound or appliedN > 0 then
        pRequester:SetProperty('PROP_NW_HAIKESI_AI_CHOICES_FOR_COUNT', targetRound)
    end
    Haikesi_ClearExternalAIRequest()
    print("[Haikesi GamePlay] ExtAIApply applied request_id=" .. tostring(requestID)
        .. " applied=" .. tostring(appliedOrErr) .. " round=" .. tostring(targetRound)
        .. " wasSyncedTo=" .. tostring(aiSyncedTo))
    -- 主机侧可见通知：免切出看 PowerShell（注入瞬间需保持游戏前台）
    pcall(function()
        if NotificationManager == nil or NotificationManager.SendNotification == nil then
            return
        end
        if NotificationTypes == nil then
            return
        end
        -- 固定 DEFAULT（感叹号），避免 USER_DEFINED_1..9 轮换成时代分/村庄等图标
        local nt = NotificationTypes.DEFAULT or NotificationTypes.USER_DEFINED_1
        local title = Locale.Lookup("LOC_HAIKESI_EXT_AI_APPLY_NOTIFY_TITLE")
        if title == nil or title == "" or string.sub(title, 1, 4) == "LOC_" then
            title = "外部AI海克斯"
        end
        local body = Locale.Lookup(
            "LOC_HAIKESI_EXT_AI_APPLY_NOTIFY_BODY",
            tostring(appliedOrErr), tostring(requestID))
        if body == nil or body == "" or string.sub(body, 1, 4) == "LOC_" then
            body = "已同步 " .. tostring(appliedOrErr) .. " 位领袖 (" .. tostring(requestID) .. ")"
        end
        NotificationManager.SendNotification(requester, nt, title, body)
    end)
    return true
end

function Haikesi_CancelExternalAIRequest(requestID)
    if (Game:GetProperty(EXT_AI_PENDING_KEY) or 0) ~= 1 then
        print("ERR:no pending request")
        return false
    end
    local pendingID = Game:GetProperty(EXT_AI_REQUEST_ID_KEY)
    if requestID ~= nil and pendingID ~= requestID then
        print("ERR:request_id mismatch")
        return false
    end
    Haikesi_ClearExternalAIRequest()
    print("OK:cancelled")
    return true
end

local function Haikesi_TryFallbackExternalAIRequest()
    if not Haikesi_IsExternalAIEnabled() then return end
    if (Game:GetProperty(EXT_AI_PENDING_KEY) or 0) ~= 1 then return end

    local createdTurn = tonumber(Game:GetProperty(EXT_AI_CREATED_TURN_KEY) or 0) or 0
    local currentTurn = Game.GetCurrentGameTurn()
    if currentTurn <= createdTurn + EXT_AI_TIMEOUT_TURNS then return end

    local requester = tonumber(Game:GetProperty(EXT_AI_REQUESTER_KEY))
    local countBefore = tonumber(Game:GetProperty(EXT_AI_COUNT_BEFORE_KEY))
    local pRequester = requester ~= nil and Players[requester] or nil
    if pRequester == nil or countBefore == nil then
        Haikesi_ClearExternalAIRequest()
        return
    end

    print("[Haikesi GamePlay] External AI timeout, fallback deterministic request_id="
        .. tostring(Game:GetProperty(EXT_AI_REQUEST_ID_KEY)))
    local targetRound = countBefore + 1
    local aiSyncedTo = tonumber(pRequester:GetProperty('PROP_NW_HAIKESI_AI_CHOICES_FOR_COUNT') or -1) or -1
    if aiSyncedTo >= targetRound then
        Haikesi_ClearExternalAIRequest()
        return
    end
    if aiSyncedTo < countBefore then
        local okSync, syncErr = pcall(Haikesi_SyncAIRelicCountToHuman, requester, countBefore, nil, nil)
        if not okSync then
            print("[Haikesi GamePlay] External AI timeout pre-align error: " .. tostring(syncErr))
            return
        end
        pRequester:SetProperty('PROP_NW_HAIKESI_AI_CHOICES_FOR_COUNT', countBefore)
    end
    local choices = Haikesi_BuildDeterministicAIChoices(requester, countBefore)
    local fallbackReasons = {}
    for aiIDStr, _ in pairs(choices) do
        fallbackReasons[aiIDStr] = "外部决策超时，依规则自动选定"
    end
    local okApply, applyErr = pcall(
        Haikesi_ApplyAIChoicesForRound, requester, choices, countBefore, fallbackReasons
    )
    if not okApply then
        print("[Haikesi GamePlay] External AI timeout apply error: " .. tostring(applyErr))
        return
    end
    pRequester:SetProperty('PROP_NW_HAIKESI_AI_CHOICES_FOR_COUNT', targetRound)
    Haikesi_ClearExternalAIRequest()
end

local function OnExternalAICheck(_, bIsFirstTime)
    if not bIsFirstTime then return end
    Haikesi_TryFallbackExternalAIRequest()
end

function HaikesiSelectRelic(iPlayer, param)
    -- 三角贸易完成结算（不选海克斯；借用本事件：自定义 OnStart / ExposedMembers 不可靠）
    if param ~= nil and param.TriTradeQueue ~= nil and tostring(param.TriTradeQueue) ~= "" then
        print("[Haikesi TRI] HaikesiSelectRelic TriTradeQueue path caller=P" .. tostring(iPlayer))
        if Haikesi_ProcessTriTradeQueue ~= nil then
            Haikesi_ProcessTriTradeQueue(tostring(param.TriTradeQueue))
        else
            print("[Haikesi TRI] Haikesi_ProcessTriTradeQueue missing")
        end
        return
    end

    -- 外部大模型 AI 海克斯：主机 UI 广播 ExtAIApply，各端同参落地
    if param ~= nil and param.ExtAIApply ~= nil and tostring(param.ExtAIApply) ~= "" then
        print("[Haikesi GamePlay] HaikesiSelectRelic ExtAIApply path caller=P" .. tostring(iPlayer))
        Haikesi_ApplyExternalAIFromNetwork(tostring(param.ExtAIApply))
        return
    end

    if param == nil or param.RelicType == nil then
        print("[Haikesi GamePlay] invalid HaikesiSelectRelic param")
        return
    end
    local pPlayer = Players[iPlayer]
    if pPlayer == nil then
        print("[Haikesi GamePlay] invalid player id: " .. tostring(iPlayer))
        return
    end
    local relicType = param.RelicType

    if not ApplyRelicToPlayer(iPlayer, relicType, true) then
        return
    end

    if param.ExtraRelicTypes ~= nil then
        for _, extraType in ipairs(param.ExtraRelicTypes) do
            local selectedTypes = GetSelectedRelicTypesForPlayer(pPlayer)
            if CanGrantRelicFromBonus(pPlayer, extraType, selectedTypes)
                and ApplyRelicToPlayer(iPlayer, extraType, false) then
                print("[Haikesi GamePlay] Player" .. iPlayer .. " bonus relic " .. extraType)
            else
                print("[Haikesi GamePlay] rejected invalid bonus relic " .. tostring(extraType) .. " for Player" .. iPlayer)
            end
        end
    end

    -- PVE + AI relics：仅主机选卡带 TriggerAIRelicRound 时推进一轮（各端同参落地）
    -- 外部 AI：各端同建 pending；落地仅经 ExtAIApply 广播
    local aiRelicConfig = Haikesi_IsConfigEnabled('NW_HAIKESI_AI_RELIC')
    local externalAIEnabled = Haikesi_IsExternalAIEnabled()
    local countBefore = tonumber(pPlayer:GetProperty('PROP_NW_HAIKESI_SELECT_COUNT') or 0) or 0
    local targetRound = countBefore + 1
    local aiSyncedTo = tonumber(pPlayer:GetProperty('PROP_NW_HAIKESI_AI_CHOICES_FOR_COUNT') or -1) or -1
    local hostTriggeredAIRound = (param.TriggerAIRelicRound == 1
        or param.TriggerAIRelicRound == true
        or param.TriggerAIRelicRound == "1")
    if pPlayer:IsHuman() and aiRelicConfig and hostTriggeredAIRound then
        if aiSyncedTo == targetRound then
            -- 读档后常见：上轮 ExtAI/超时已把 AI 推到本轮，人类再选不会新建 pending
            print("[Haikesi GamePlay] AI already synced to select round " .. tostring(targetRound)
                .. " (Player" .. iPlayer .. "), skip ExtAI — "
                .. "load an earlier save or AI already received this round")
        elseif externalAIEnabled then
            -- 上一轮挂起未提交时先确定性补齐，再挂起本轮（防覆盖丢轮）
            if (Game:GetProperty(EXT_AI_PENDING_KEY) or 0) == 1 then
                local prevCount = tonumber(Game:GetProperty(EXT_AI_COUNT_BEFORE_KEY) or -1)
                local prevRequester = tonumber(Game:GetProperty(EXT_AI_REQUESTER_KEY))
                if prevRequester ~= nil and prevCount ~= nil and prevCount ~= countBefore then
                    print("[Haikesi GamePlay] External AI pending overwritten; flush prev countBefore="
                        .. tostring(prevCount))
                    Haikesi_SyncAIRelicCountToHuman(prevRequester, prevCount + 1, nil, nil)
                    local pPrev = Players[prevRequester]
                    if pPrev ~= nil then
                        pPrev:SetProperty('PROP_NW_HAIKESI_AI_CHOICES_FOR_COUNT', prevCount + 1)
                    end
                    Haikesi_ClearExternalAIRequest()
                end
            end
            local pendingCount = tonumber(Game:GetProperty(EXT_AI_COUNT_BEFORE_KEY) or -1)
            if (Game:GetProperty(EXT_AI_PENDING_KEY) or 0) == 1 and pendingCount == countBefore then
                -- 读档/重选：pending 仍在则重 dump，让 watch 再吃一块（同 request_id）
                print("[Haikesi GamePlay] External AI request already pending for select count "
                    .. tostring(countBefore) .. " (Player" .. iPlayer .. ") — redump for watch")
                Haikesi_DumpExternalAIRequestToLog("redump")
                pcall(function()
                    if LuaEvents ~= nil and LuaEvents.Haikesi_ExtAIPendingUI ~= nil then
                        LuaEvents.Haikesi_ExtAIPendingUI()
                    end
                end)
            else
                -- 挂起前先把 AI 对齐到 countBefore，避免 LLM 落地时再混进确定性补齐
                if aiSyncedTo < countBefore then
                    print("[Haikesi GamePlay] External AI pre-align before request: syncedTo="
                        .. tostring(aiSyncedTo) .. " -> " .. tostring(countBefore))
                    Haikesi_SyncAIRelicCountToHuman(iPlayer, countBefore, nil, nil)
                    pPlayer:SetProperty('PROP_NW_HAIKESI_AI_CHOICES_FOR_COUNT', countBefore)
                    aiSyncedTo = countBefore
                end
                Haikesi_CreateExternalAIRequest(iPlayer, relicType, countBefore)
            end
        else
            -- 有 AIChoices 用广播结果；无则各端跑同一套确定性补齐
            local applied = Haikesi_SyncAIRelicCountToHuman(
                iPlayer, targetRound, param.AIChoices, nil
            )
            pPlayer:SetProperty('PROP_NW_HAIKESI_AI_CHOICES_FOR_COUNT', targetRound)
            print("[Haikesi GamePlay] AI sync to selectRound=" .. tostring(targetRound)
                .. " applied=" .. tostring(applied) .. " (Player" .. iPlayer .. ")")
        end
    elseif pPlayer:IsHuman() and aiRelicConfig and not hostTriggeredAIRound then
        print("[Haikesi GamePlay] skip AI relic round (non-host human select) Player"
            .. tostring(iPlayer))
    end
end

--||======================= MIMIC ability confirm ========================||--
function HaikesiSelectAbility(iPlayer, param)
    if param == nil or param.TraitType == nil then
        print("[Haikesi GamePlay] invalid HaikesiSelectAbility param")
        return
    end
    local pPlayer = Players[iPlayer]
    if pPlayer == nil then return end
    local traitType = param.TraitType

    -- 遍历 TraitModifiers，Attach 该 Trait 的所有 Modifier
    local attached = 0
    for row in GameInfo.TraitModifiers() do
        if row.TraitType == traitType then
            pPlayer:AttachModifierByID(row.ModifierId)
            attached = attached + 1
        end
    end
    print("[Haikesi GamePlay] MIMIC 玩家" .. iPlayer .. " 获得能力 " .. traitType .. " (attached " .. attached .. " modifiers)")

    -- 记录选中的 Trait（已选海克斯 tooltip 追加用）
    pPlayer:SetProperty(MimicTraitKey, traitType)

    -- UI 关闭由本地能力窗自行处理（Gameplay 不通知 UI）
end
--||======================= Lua Effect ========================||--
-- 南蛮入侵 / 三角贸易 / 种地仙人 已拆至独立 GamePlay 脚本（寄存器上限）
-- 混合层：部分海克斯效果必须 Lua 实现（无原生 Modifier 对应）
-- 占位检测仅对残存占位项生效（目前已无残留）
local PLACEHOLDER_MODIFIER_ID = 'MODIFIER_NW_HAIKESI_PLACEHOLDER_UNIT'


local function GetNewestCityForPlayer(pPlayer)
    if pPlayer == nil then
        return nil
    end
    local pCities = pPlayer:GetCities()
    if pCities == nil then
        return nil
    end
    local newestCity = nil
    local newestTurn = -1
    local newestSequence = -1
    local newestCityID = -1
    for _, pCity in pCities:Members() do
        if pCity ~= nil then
            local foundedTurn = tonumber(pCity:GetProperty(CityFoundedTurnKey))
            local foundedSequence = tonumber(pCity:GetProperty(CityFoundedSequenceKey))
            local cityID = pCity:GetID()
            local hasTrackedTurn = foundedTurn ~= nil
            local newestHasTrackedTurn = newestTurn >= 0

            if (hasTrackedTurn and not newestHasTrackedTurn)
                or (hasTrackedTurn and newestHasTrackedTurn
                    and (foundedTurn > newestTurn
                        or (foundedTurn == newestTurn
                            and ((foundedSequence or -1) > newestSequence
                                or ((foundedSequence or -1) == newestSequence
                                    and cityID > newestCityID)))))
                or (not hasTrackedTurn and not newestHasTrackedTurn and cityID > newestCityID) then
                newestTurn = foundedTurn or -1
                newestSequence = foundedSequence or -1
                newestCityID = cityID
                newestCity = pCity
            end
        end
    end
    return newestCity
end

local function OnHaikesiCityBuilt(playerID, cityID, cityX, cityY)
    local pCity = CityManager.GetCity(playerID, cityID)
    if pCity == nil and cityX ~= nil and cityY ~= nil then
        pCity = CityManager.GetCityAt(cityX, cityY)
    end
    if pCity == nil then
        print(string.format(
            "[Haikesi GamePlay] CityBuilt tracking failed player=%s city=%s",
            tostring(playerID), tostring(cityID)))
        return
    end

    local sequence = tonumber(Game:GetProperty(CityFoundedSequenceGameKey) or 0) + 1
    Game:SetProperty(CityFoundedSequenceGameKey, sequence)
    pCity:SetProperty(CityFoundedTurnKey, Game.GetCurrentGameTurn())
    pCity:SetProperty(CityFoundedSequenceKey, sequence)
    print(string.format(
        "[Haikesi GamePlay] CityBuilt tracked player=%d city=%d turn=%d sequence=%d",
        playerID, cityID, Game.GetCurrentGameTurn(), sequence))
end

local function PickRandomIndex(maxCount, reason)
    if maxCount <= 0 then
        return 0
    end
    if TerrainBuilder ~= nil and TerrainBuilder.GetRandomNumber ~= nil then
        return TerrainBuilder.GetRandomNumber(maxCount, reason)
    end
    return Game.GetRandNum(maxCount, reason) or 0
end

--||======================= 资源创建类型（Haikesi_Relic_ResourceSpawns） ========================||--
-- 数据驱动：同类型海克斯只需在 SQL 表加行，无需改 Lua 分支
local g_ResourceValidImprovements = nil -- resourceIndex → { [impIndex]=true }

local function Haikesi_GetResourceIndex(resourceType)
    local row = GameInfo.Resources[resourceType]
    return row and row.Index or -1
end

local function Haikesi_BuildResourceValidImprovementCache()
    g_ResourceValidImprovements = {}
    for row in GameInfo.Improvement_ValidResources() do
        local resRow = GameInfo.Resources[row.ResourceType]
        local impRow = GameInfo.Improvements[row.ImprovementType]
        if resRow ~= nil and impRow ~= nil then
            local resIndex = resRow.Index
            if g_ResourceValidImprovements[resIndex] == nil then
                g_ResourceValidImprovements[resIndex] = {}
            end
            g_ResourceValidImprovements[resIndex][impRow.Index] = true
        end
    end
end

local function Haikesi_IsRestorableImprovementForResource(impIndex, resourceIndex)
    if impIndex == nil or impIndex < 0 or resourceIndex == nil or resourceIndex < 0 then
        return false
    end
    if g_ResourceValidImprovements == nil then
        Haikesi_BuildResourceValidImprovementCache()
    end
    local valid = g_ResourceValidImprovements[resourceIndex]
    return valid ~= nil and valid[impIndex] == true
end

-- CanHaveResource 在已有改良时可能误判；探测时临时移除再还原
local function Haikesi_CanPlotHaveResource(pPlot, resourceIndex)
    if pPlot == nil or resourceIndex < 0 then
        return false
    end
    if pPlot:GetDistrictType() ~= -1 then
        return false
    end
    if pPlot:GetResourceType() ~= -1 then
        return false
    end

    local oldImp = pPlot:GetImprovementType()
    if oldImp ~= -1 and ImprovementBuilder ~= nil then
        ImprovementBuilder.SetImprovementType(pPlot, -1, -1)
    end

    local canHave = ResourceBuilder.CanHaveResource(pPlot, resourceIndex)

    if oldImp ~= -1 and ImprovementBuilder ~= nil then
        ImprovementBuilder.SetImprovementType(pPlot, oldImp, -1)
    end
    return canHave == true
end

-- 避坑：先移除改良 → SetResourceType → 仅当原改良对该资源合法时再放回
local function Haikesi_PlaceResourceOnPlot(pPlot, resourceIndex, resourceCount)
    if pPlot == nil or resourceIndex < 0 then
        return false
    end
    local count = resourceCount or 1
    local oldImp = pPlot:GetImprovementType()
    if oldImp ~= -1 and ImprovementBuilder ~= nil then
        ImprovementBuilder.SetImprovementType(pPlot, -1, -1)
    end

    ResourceBuilder.SetResourceType(pPlot, resourceIndex, count)

    if pPlot:GetResourceType() ~= resourceIndex then
        if oldImp ~= -1 and ImprovementBuilder ~= nil then
            ImprovementBuilder.SetImprovementType(pPlot, oldImp, -1)
        end
        return false
    end

    if oldImp ~= -1
        and Haikesi_IsRestorableImprovementForResource(oldImp, resourceIndex)
        and ImprovementBuilder ~= nil then
        ImprovementBuilder.SetImprovementType(pPlot, oldImp, -1)
    end
    return true
end

local function Haikesi_GetResourceSpawnCity(pPlayer, cityTarget)
    if pPlayer == nil then
        return nil
    end
    if cityTarget == 'CAPITAL' then
        local pCities = pPlayer:GetCities()
        return pCities and pCities:GetCapitalCity() or nil
    end
    -- 默认 NEWEST
    return GetNewestCityForPlayer(pPlayer)
end

local function Haikesi_GatherResourceSpawnCandidates(pCity, playerID, resourceIndex, cfg)
    local owned = {}
    local unowned = {}
    local foreign = {}
    if pCity == nil or cfg == nil then
        return owned, unowned, foreign
    end

    local minDist = tonumber(cfg.MinDistance) or 1
    local radius = tonumber(cfg.Radius) or 3
    local centerX, centerY = pCity:GetX(), pCity:GetY()
    for dx = -radius, radius do
        for dy = -radius, radius do
            local pPlot = Map.GetPlotXY(centerX, centerY, dx, dy)
            if pPlot ~= nil then
                local dist = Map.GetPlotDistance(centerX, centerY, pPlot:GetX(), pPlot:GetY())
                if dist ~= nil and dist >= minDist and dist <= radius
                    and Haikesi_CanPlotHaveResource(pPlot, resourceIndex) then
                    local owner = pPlot:GetOwner()
                    if owner == playerID then
                        table.insert(owned, pPlot)
                    elseif owner == -1 then
                        table.insert(unowned, pPlot)
                    else
                        table.insert(foreign, pPlot)
                    end
                end
            end
        end
    end
    return owned, unowned, foreign
end

local function Haikesi_PickPlotsFromPool(pool, count, reasonPrefix)
    local picked = {}
    if pool == nil or #pool == 0 or count <= 0 then
        return picked
    end
    local working = {}
    for i = 1, #pool do
        working[i] = pool[i]
    end
    local need = math.min(count, #working)
    for i = 1, need do
        local idx = PickRandomIndex(#working, reasonPrefix .. i) + 1
        if idx < 1 then idx = 1 end
        if idx > #working then idx = #working end
        table.insert(picked, working[idx])
        table.remove(working, idx)
    end
    return picked
end

local function Haikesi_SelectResourceSpawnPlots(owned, unowned, foreign, cfg, reasonSalt)
    local need = tonumber(cfg.Amount) or 1
    local preferOwned = (tonumber(cfg.PreferOwned) or 1) == 1
    local allowUnowned = (tonumber(cfg.AllowUnowned) or 1) == 1
    local allowForeign = (tonumber(cfg.AllowForeign) or 0) == 1
    local selected = {}
    local salt = reasonSalt or "HaikesiResSpawn"

    local function takeFrom(pool, tag)
        if #selected >= need then return end
        local more = Haikesi_PickPlotsFromPool(pool, need - #selected, salt .. tag)
        for _, pPlot in ipairs(more) do
            table.insert(selected, pPlot)
        end
    end

    if preferOwned then
        takeFrom(owned, "Owned")
        if allowUnowned then takeFrom(unowned, "Unowned") end
        if allowForeign then takeFrom(foreign, "Foreign") end
    else
        -- 不优先己方：合并后统一抽（仍尊重 Allow*）
        local merged = {}
        for _, p in ipairs(owned) do table.insert(merged, p) end
        if allowUnowned then
            for _, p in ipairs(unowned) do table.insert(merged, p) end
        end
        if allowForeign then
            for _, p in ipairs(foreign) do table.insert(merged, p) end
        end
        takeFrom(merged, "Merged")
    end
    return selected
end

function Haikesi_ApplyResourceSpawnRelic(iPlayer, relicType)
    local cfg = g_RelicResourceSpawnMap and g_RelicResourceSpawnMap[relicType]
    if cfg == nil then
        print("[Haikesi GamePlay] ResourceSpawn skip — no config for " .. tostring(relicType))
        return false
    end

    local pPlayer = Players[iPlayer]
    if pPlayer == nil then
        print("[Haikesi GamePlay] ResourceSpawn skip — invalid player")
        return false
    end

    local resourceIndex = Haikesi_GetResourceIndex(cfg.ResourceType)
    if resourceIndex < 0 then
        print(string.format(
            "[Haikesi GamePlay] ResourceSpawn skip — missing resource %s (%s)",
            tostring(cfg.ResourceType), tostring(relicType)))
        return false
    end

    local pCity = Haikesi_GetResourceSpawnCity(pPlayer, cfg.CityTarget)
    if pCity == nil then
        print(string.format(
            "[Haikesi GamePlay] ResourceSpawn skip — no city player=%d relic=%s target=%s",
            iPlayer, tostring(relicType), tostring(cfg.CityTarget)))
        return false
    end

    local owned, unowned, foreign = Haikesi_GatherResourceSpawnCandidates(
        pCity, iPlayer, resourceIndex, cfg)
    local selected = Haikesi_SelectResourceSpawnPlots(
        owned, unowned, foreign, cfg, "HaikesiResSpawn_" .. tostring(relicType) .. "_")

    local resourceCount = tonumber(cfg.ResourceCount) or 1
    local placed = 0
    for _, pPlot in ipairs(selected) do
        if Haikesi_PlaceResourceOnPlot(pPlot, resourceIndex, resourceCount) then
            placed = placed + 1
            print(string.format(
                "[Haikesi GamePlay] ResourceSpawn %s -> %s at (%d,%d) player=%d city=%d",
                tostring(relicType), tostring(cfg.ResourceType),
                pPlot:GetX(), pPlot:GetY(), iPlayer, pCity:GetID()))
        end
    end

    print(string.format(
        "[Haikesi GamePlay] ResourceSpawn done relic=%s player=%d city=(%d,%d) placed=%d/%d owned=%d unowned=%d foreign=%d",
        tostring(relicType), iPlayer, pCity:GetX(), pCity:GetY(),
        placed, tonumber(cfg.Amount) or 1, #owned, #unowned, #foreign))
    return placed > 0
end



-- 判断某海克斯是否仍为占位（即其 Modifier 列表里只有占位 Modifier）
local function IsRelicPlaceholder(relicType)
    local modifierIds = g_RelicModifierMap[relicType]
    if not modifierIds or #modifierIds == 0 then
        return true  -- 无任何 Modifier 映射，按占位处理
    end
    for _, modId in ipairs(modifierIds) do
        if modId ~= PLACEHOLDER_MODIFIER_ID then
            return false  -- 存在非占位 Modifier，视为已迁移
        end
    end
    return true
end

-- DICEMANIAC 持久化 Key：记录该玩家是否拥有额外刷新
local DICEMANIAC_PROP_KEY = 'PROP_NW_HAIKESI_DICEMANIAC'

-- DOUBLEEXISTENCERUNE 持久化 Key：记录该玩家是否被禁止刷新海克斯
local NO_REROLL_PROP_KEY = 'PROP_NW_HAIKESI_NO_REROLL'

function Haikesi_ApplyLuaEffect(iPlayer, relicType)
    local pPlayer = Players[iPlayer]
    if pPlayer == nil then
        print("[Haikesi GamePlay] 错误: Haikesi_ApplyLuaEffect — 无效玩家ID: " .. tostring(iPlayer))
        return
    end

    -- ==============================
    -- CIRCLEOFDEATH 死亡之环
    -- 删除首都7环内全部非己方单位；删除首都9环外全部己方单位
    -- ==============================
    if relicType == 'CIRCLEOFDEATHRUNE' then
        local pCapital = pPlayer:GetCities():GetCapitalCity()
        if pCapital == nil then
            print("[Haikesi GamePlay] CIRCLEOFDEATH 跳过 — 无首都")
            return
        end
        local capX, capY = pCapital:GetX(), pCapital:GetY()
        local unitsToKill = {}

        -- 非己方单位（含蛮族、城邦、其他文明）：首都 7 环以内
        for iOtherID = 0, 63 do
            if iOtherID ~= iPlayer then
                local pOther = Players[iOtherID]
                if pOther ~= nil then
                    local units = pOther:GetUnits()
                    if units ~= nil then
                        for _, unit in units:Members() do
                            if unit and Map.GetPlotDistance(capX, capY, unit:GetX(), unit:GetY()) <= 7 then
                                table.insert(unitsToKill, unit)
                            end
                        end
                    end
                end
            end
        end

        -- 己方单位：首都 9 环以外
        local myUnits = pPlayer:GetUnits()
        if myUnits ~= nil then
            for _, unit in myUnits:Members() do
                if unit and Map.GetPlotDistance(capX, capY, unit:GetX(), unit:GetY()) > 9 then
                    table.insert(unitsToKill, unit)
                end
            end
        end

        local killCount = 0
        for _, unit in ipairs(unitsToKill) do
            UnitManager.Kill(unit, true)
            killCount = killCount + 1
        end
        print("[Haikesi GamePlay] CIRCLEOFDEATH 删除 " .. killCount .. " 个单位")
        return
    end

    -- ==============================
    -- NW_AI_BARBARIAN_INVASION 南蛮入侵
    -- 除触发 AI 外，各其他玩家最新城市 5 环尝试生成 3 个遵循原版间距的营地；
    -- 每缺 1 个，在最近的现有营地处补充 3 个蛮族单位；
    -- 若全图无营地，则在该文明所有城市 4 环各生成 3 个蛮族单位
    -- （实现在独立 Gameplay 脚本，经 ExposedMembers 调用）
    -- ==============================
    if relicType == BARBARIAN_INVASION_RELIC then
        local spawnFn = nil
        if ExposedMembers ~= nil then
            spawnFn = ExposedMembers.Haikesi_SpawnBarbarianInvasionCamps
        end
        if type(spawnFn) ~= "function" then
            spawnFn = rawget(_G, "Haikesi_SpawnBarbarianInvasionCamps")
        end
        if type(spawnFn) ~= "function" then
            print("[Haikesi GamePlay] BARBARIAN_INVASION missing spawn fn (ExposedMembers not ready)")
            return
        end
        local okSpawn, errSpawn = pcall(spawnFn, iPlayer)
        if not okSpawn then
            print("[Haikesi GamePlay] BARBARIAN_INVASION spawn error: " .. tostring(errSpawn))
        end
        return
    end

    -- ==============================
    -- NW_AI_LIGHTNING_STORM 闪电风暴
    -- 按存活主要文明数连续 ApplyEvent 官方风暴（独立脚本）
    -- ==============================
    if relicType == LIGHTNING_STORM_RELIC then
        local stormFn = nil
        if ExposedMembers ~= nil then
            stormFn = ExposedMembers.Haikesi_ApplyLightningStormRelic
        end
        if type(stormFn) ~= "function" then
            stormFn = rawget(_G, "Haikesi_ApplyLightningStormRelic")
        end
        if type(stormFn) ~= "function" then
            print("[Haikesi GamePlay] LIGHTNING_STORM missing apply fn (ExposedMembers not ready)")
            return
        end
        local okStorm, errStorm = pcall(stormFn, iPlayer)
        if not okStorm then
            print("[Haikesi GamePlay] LIGHTNING_STORM apply error: " .. tostring(errStorm))
        end
        return
    end

    -- ==============================
    -- NW_AI_RIVER_FLOOD 仇水连汛
    -- 关系最差最多 3 文明城市附近命名河，下回合起连续 5 回合洪水
    -- ==============================
    if relicType == RIVER_FLOOD_RELIC then
        local floodFn = nil
        if ExposedMembers ~= nil then
            floodFn = ExposedMembers.Haikesi_ApplyRiverFloodRelic
        end
        if type(floodFn) ~= "function" then
            floodFn = rawget(_G, "Haikesi_ApplyRiverFloodRelic")
        end
        if type(floodFn) ~= "function" then
            print("[Haikesi GamePlay] RIVER_FLOOD missing apply fn (ExposedMembers not ready)")
            return
        end
        local okFlood, errFlood = pcall(floodFn, iPlayer)
        if not okFlood then
            print("[Haikesi GamePlay] RIVER_FLOOD apply error: " .. tostring(errFlood))
        end
        return
    end

    -- ==============================
    -- CRASHHELICOPTERUNE 铝翼坠毁
    -- 单位由 SQL 宫殿 Grant；此处仅打开坠毁标记期望 / 给已生成机打标
    -- ==============================
    if relicType == 'CRASHHELICOPTERUNE' then
        local applyFn = nil
        if ExposedMembers ~= nil then
            applyFn = ExposedMembers.Haikesi_ApplyCrashHeliRelic
        end
        if type(applyFn) ~= "function" then
            applyFn = rawget(_G, "Haikesi_ApplyCrashHeliRelic")
        end
        if type(applyFn) ~= "function" then
            print("[Haikesi GamePlay] CRASHHELICOPTERUNE missing mark fn")
            return
        end
        local okApply, errApply = pcall(applyFn, iPlayer)
        if not okApply then
            print("[Haikesi GamePlay] CRASHHELICOPTERUNE mark error: " .. tostring(errApply))
        end
        return
    end

    -- ==============================
    -- 资源创建类型（Haikesi_Relic_ResourceSpawns）
    -- 例：NW_AI_BRAVE_WOOD 勇敢的木 → 最新城市 3 环 4 棉花
    -- ==============================
    if g_RelicResourceSpawnMap ~= nil and g_RelicResourceSpawnMap[relicType] ~= nil then
        Haikesi_ApplyResourceSpawnRelic(iPlayer, relicType)
        return
    end

    -- ==============================
    -- DICEMANIAC 掷骰狂人
    -- 后续选择海克斯时，所有海克斯可额外刷新一次（UI 读取 PROP 实现）
    -- ==============================
    if relicType == 'DICEMANIACRUNE' then
        pPlayer:SetProperty(DICEMANIAC_PROP_KEY, 1)
        -- The same-turn bonus relic is selected once in UI and passed through
        -- ExtraRelicTypes. Do not roll again here, or MP peers can persist a
        -- different relic list than the player confirmed.
        print("[Haikesi GamePlay] DICEMANIAC bonus reroll enabled (Player" .. iPlayer .. ")")
        return
    end

    -- ==============================
    -- DOUBLEEXISTENCERUNE 手快全拿
    -- "另外两个海克斯"由 UI 侧通过 ExtraRelicTypes 一并下发，服务端循环 ApplyRelicToPlayer 处理。
    -- 本分支只负责副作用：之后无法再刷新海克斯（UI 读取 NO_REROLL_PROP_KEY 锁定 RerollCard）。
    -- ==============================
    if relicType == 'DOUBLEEXISTENCERUNE' then
        pPlayer:SetProperty(NO_REROLL_PROP_KEY, 1)
        -- 全队锁定：同队所有人类玩家不再能刷出手快全选
        local myTeam = pPlayer:GetTeam()
        for i = 0, 63 do
            local pOther = Players[i]
            if pOther and pOther:IsHuman() and pOther:GetTeam() == myTeam then
                pOther:SetProperty('PROP_NW_HAIKESI_LOCKED_DOUBLEEXISTENCERUNE', 1)
            end
        end
        print("[Haikesi GamePlay] DOUBLEEXISTENCE — 刷新已锁定 (Player" .. iPlayer .. ")")
        return
    end

    -- ==============================
    -- HASTYSCRIBBLERUNE 潦草急就：清空当前所有金币（送大将军由 SQL GRANT 实现）
    -- 无原生"清零金币"Modifier，必须 Lua。GetTreasury():SetGoldBalance(0) 置零。
    -- ==============================
    if relicType == 'HASTYSCRIBBLERUNE' then
        local pTreasury = pPlayer:GetTreasury()
        if pTreasury and pTreasury.SetGoldBalance then
            pTreasury:SetGoldBalance(0)
            print("[Haikesi GamePlay] HASTYSCRIBBLE — 清空玩家" .. iPlayer .. " 金币")
        else
            print("[Haikesi GamePlay] 警告: GetTreasury().SetGoldBalance 不可用（HASTYSCRIBBLE）")
        end
        return
    end

    -- ==============================
    -- MIMICRUNE 仿生模仿：空 Marker 已在 ApplyRelicToPlayer 标记非占位
    -- 抽 10 项 + 弹能力窗 全在 UI 端（math.random），Gameplay 不参与
    -- 玩家在能力窗选定的 Trait 由 HaikesiSelectAbility 挂 Modifier
    -- ==============================
    if relicType == 'MIMICRUNE' then
        print("[Haikesi GamePlay] MIMIC 玩家" .. iPlayer .. " 触发能力选择（UI 端处理）")
        return
    end

    -- ==============================
    -- TRIANGULARTRADERUNE 三角贸易（见 Haikesi_TriTrade_GamePlay.lua）
    -- ==============================
    if relicType == 'TRIANGULARTRADERUNE' then
        local applyTri = nil
        if ExposedMembers ~= nil then
            applyTri = ExposedMembers.Haikesi_ApplyTriangularTradeRelicEffect
        end
        if type(applyTri) ~= "function" then
            applyTri = rawget(_G, "Haikesi_ApplyTriangularTradeRelicEffect")
        end
        if type(applyTri) == "function" then
            local okTri, errTri = pcall(applyTri, iPlayer, pPlayer)
            if not okTri then
                print("[Haikesi GamePlay] TRIANGULARTRADE apply error: " .. tostring(errTri))
            end
        else
            print("[Haikesi GamePlay] TRIANGULARTRADE missing apply fn (ExposedMembers not ready)")
        end
        return
    end

    -- ==============================
    -- 占位补偿：无真实效果的海克斯补 100 金币过渡（目前已无残留占位）
    -- ==============================
    if not IsRelicPlaceholder(relicType) then
        return
    end
    pPlayer:GetTreasury():ChangeGoldBalance(100)
    print("[Haikesi GamePlay] Lua 占位补偿：玩家" .. iPlayer .. " 获得 100 金币 → " .. relicType)
end

local function Haikesi_DevGrantFullMapVisionForHumans()
    if (GameConfiguration.GetValue('NW_HAIKESI_MODE') or 0) ~= 3 then return end
    for _, pPlayer in ipairs(PlayerManager.GetAliveMajors()) do
        if pPlayer:IsHuman() then
            local iPlayer = pPlayer:GetID()
            local pVis = PlayersVisibility[iPlayer]
            if pVis ~= nil and pPlayer:GetProperty(DEV_FULL_MAP_VISION_PROP) ~= 1 then
                -- ChangeVisibilityCount(+1) 为每格添加永久视野来源；
                -- RevealAllPlots/SetRevealed 只会去除未探索黑幕，不会显示实时单位与改良变化。
                for plotIndex = 0, Map.GetPlotCount() - 1 do
                    pVis:ChangeVisibilityCount(plotIndex, 1)
                end
                pPlayer:SetProperty(DEV_FULL_MAP_VISION_PROP, 1)
                print("[Haikesi Dev] Granted live full-map vision to human Player" .. iPlayer)
            end
        end
    end
end

-- 种地仙人种植逻辑已拆至 GamePlay/Haikesi_Planter_GamePlay.lua
-- （主脚本文件级 local 已近 Firaxis Lua 5.1 寄存器上限，再塞会整文件加载失败）

local function OnDevVisionPlayerTurnActivated(_, bIsFirstTime)
    if not bIsFirstTime then return end
    Haikesi_DevGrantFullMapVisionForHumans()
end

--||======================= INIT ========================||--
function Initialize()
    -- 构建 RelicType → ModifierId[] 内存 Map（一次性，替代运行时全表遍历）
    g_RelicModifierMap = {}
    local rowCount = 0
    for row in GameInfo.Haikesi_Relic_Modifiers() do
        if not g_RelicModifierMap[row.RelicType] then
            g_RelicModifierMap[row.RelicType] = {}
        end
        table.insert(g_RelicModifierMap[row.RelicType], row.ModifierId)
        rowCount = rowCount + 1
    end
    print("[Haikesi GamePlay] RelicModifierMap 构建完成，行数 = " .. rowCount)

    -- 资源创建类型配置 Map
    g_RelicResourceSpawnMap = {}
    local spawnCount = 0
    if GameInfo.Haikesi_Relic_ResourceSpawns ~= nil then
        for row in GameInfo.Haikesi_Relic_ResourceSpawns() do
            g_RelicResourceSpawnMap[row.RelicType] = row
            spawnCount = spawnCount + 1
        end
    end
    Haikesi_BuildResourceValidImprovementCache()
    print("[Haikesi GamePlay] RelicResourceSpawnMap 构建完成，行数 = " .. spawnCount)

    local aiPoolDesc = {}
    for _, t in ipairs(AI_RELIC_TYPES) do
        table.insert(aiPoolDesc, t)
    end
    print("[Haikesi Dev] Mod ID 7c4e8a2b — AI relic pool (" .. #AI_RELIC_TYPES .. "): " .. table.concat(aiPoolDesc, ", "))

    GameEvents.HaikesiSelectRelic.Add(HaikesiSelectRelic)
    GameEvents.HaikesiSelectAbility.Add(HaikesiSelectAbility)
    GameEvents.CityBuilt.Add(OnHaikesiCityBuilt)

    if (GameConfiguration.GetValue('NW_HAIKESI_MODE') or 0) == 3 then
        Haikesi_DevGrantFullMapVisionForHumans()
        Events.PlayerTurnActivated.Add(OnDevVisionPlayerTurnActivated)
    end

    Events.PlayerTurnActivated.Add(OnExternalAICheck)
    -- ExtAI inject-file 轮询已拆至 GamePlay/Haikesi_ExtAI_Inject.lua（避免本文件寄存器超限）

    -- 三角贸易 GamePlay 已拆至 Haikesi_TriTrade_GamePlay.lua；商路扫描在 UI TriTrade_Bridge

    -- 外部 AI：主机 FireTuner Stage → UI 广播；初始化暂存槽
    ExposedMembers.Haikesi_ExtAIStagedPayload = nil
    ExposedMembers.Haikesi_ExtAIStagedSeq = 0
    ExposedMembers.Haikesi_ApplyExtAIWire = Haikesi_ApplyExternalAIFromNetwork
    print("[Haikesi GamePlay] ExtAI ExposedMembers stage/apply ready")

    -- 种地仙人种植已拆至 Haikesi_Planter_GamePlay.lua（避免主脚本 local 寄存器溢出）

    print("[Haikesi GamePlay] Script 初始化完成")
end

Events.LoadScreenClose.Add(Initialize)
