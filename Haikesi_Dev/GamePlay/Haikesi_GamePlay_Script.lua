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
    -- 资源创建
    'NW_AI_BRAVE_WOOD', 'NW_AI_MAMA_BORN', 'NW_AI_MILK_DRAGON', 'NW_AI_SILK_LAND', 'NW_AI_DRINK_TEA',
    -- 和平互利
    'NW_AI_CELESTIAL_EMPIRE',
}
local AI_RELIC_TYPE_SET = {}
for _, t in ipairs(AI_RELIC_TYPES) do AI_RELIC_TYPE_SET[t] = true end

local BARBARIAN_INVASION_RELIC = 'NW_AI_BARBARIAN_INVASION'
local BARBARIAN_CAMP_IMPROVEMENT = 'IMPROVEMENT_BARBARIAN_CAMP'
local INVASION_CAMP_DISTANCE = 5
local INVASION_CAMPS_PER_PLAYER = 3
local INVASION_UNITS_PER_MISSING_CAMP = 3
local INVASION_NO_CAMP_UNIT_DISTANCE = 4
local INVASION_FALLBACK_UNIT_RADIUS = 3
-- 补兵成功后：50% 令该氏族对目标城市发动原版攻城行动（煽动近似）
local INVASION_REINFORCE_ASSAULT_CHANCE = 50
local BARBARIAN_CITY_ASSAULT_OPERATION = 'Barbarian City Assault'
local BARBARIAN_CAMP_MINIMUM_DISTANCE_ANOTHER_CAMP = 7
local BARBARIAN_CAMP_MINIMUM_DISTANCE_CITY = 4
local BARBARIAN_FALLBACK_UNIT = 'UNIT_WARRIOR'
local BARBARIAN_HORSE_RESOURCE = 'RESOURCE_HORSES'
local BARBARIAN_HORSE_RANGE = 3
local BARBARIAN_TRIBE_UNIT_RANGE = 3
-- CreateTribeOfType 返回的部落索引/类型缓存
-- 注意：GetTribeIndexAtLocation 仅 UI 可用，Gameplay 必须靠缓存/存档属性/附近单位反查
local g_BarbarianTribeIndexByPlot = {}
local g_BarbarianTribeTypeByPlot = {}
-- plot → TribeDisplayName 的 LOC key（如 LOC_BARBARIAN_CLAN_MELEE_OPEN_1）
local g_BarbarianTribeNameLocByPlot = {}
local BARB_TRIBE_MAP_PROP = 'PROP_NW_HAIKESI_BARB_TRIBE_MAP'
-- Gameplay 排队，UI 桥接取专名后发通知（GetTribeNameType 仅 UI 可靠）
local BARB_ASSAULT_NOTIFY_PROP = 'PROP_NW_HAIKESI_BARB_ASSAULT_NOTIFY'
local BARB_TRIBE_LOOKUP_RADIUS = 8
local HAIKESI_BARB_HORSEMAN_TAG = 'CLASS_HAIKESI_BARB_HORSEMAN'
local HAIKESI_BARB_HORSE_ARCHER_TAG = 'CLASS_HAIKESI_BARB_HORSE_ARCHER'
local HAIKESI_BARB_GALLEY_TAG = 'CLASS_HAIKESI_BARB_GALLEY'
local HAIKESI_BARB_QUADRIREME_TAG = 'CLASS_HAIKESI_BARB_QUADRIREME'
local BARBARIAN_HORSEMAN_UNIT = 'UNIT_BARBARIAN_HORSEMAN'
local BARBARIAN_HORSE_ARCHER_UNIT = 'UNIT_BARBARIAN_HORSE_ARCHER'
local BARBARIAN_GALLEY_UNIT = 'UNIT_GALLEY'
local BARBARIAN_QUADRIREME_UNIT = 'UNIT_QUADRIREME'

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

local function GetAIAvailableRelics(pAI, excludeInvasionThisRound)
    local selected = GetSelectedRelicTypesForPlayer(pAI)
    local available = {}
    for _, t in ipairs(AI_RELIC_TYPES) do
        local relicDef = GameInfo.Haikesi_Relics[t]
        local alreadySelected = selected[t]
        local canPick = not alreadySelected or (relicDef ~= nil and relicDef.IsRepeatable == 1)
        if canPick then
            if not (excludeInvasionThisRound and t == BARBARIAN_INVASION_RELIC) then
                table.insert(available, t)
            end
        end
    end
    return available
end

local function AIHasOnlyInvasionLeft(pAI)
    local available = GetAIAvailableRelics(pAI, false)
    return #available == 1 and available[1] == BARBARIAN_INVASION_RELIC
end

function Haikesi_BuildDeterministicAIChoices(requesterPlayerID, countBefore)
    local choices = {}
    local invasionAssigned = false
    local aiPlayers = Haikesi_GetAliveAIPlayers()

    local invasionOnlyAIs = {}
    for _, pAI in ipairs(aiPlayers) do
        if AIHasOnlyInvasionLeft(pAI) then
            table.insert(invasionOnlyAIs, pAI)
        end
    end
    if #invasionOnlyAIs > 0 then
        local pickIdx = (math.abs(countBefore * 997 + requesterPlayerID) % #invasionOnlyAIs) + 1
        local pPick = invasionOnlyAIs[pickIdx]
        choices[tostring(pPick:GetID())] = BARBARIAN_INVASION_RELIC
        invasionAssigned = true
    end

    for _, pAI in ipairs(aiPlayers) do
        local aiIDStr = tostring(pAI:GetID())
        if choices[aiIDStr] == nil then
            local available = GetAIAvailableRelics(pAI, invasionAssigned)
            if #available == 0 then
                print("[Haikesi GamePlay] AI Player" .. aiIDStr .. " no available AI relic this round")
            else
                local salt = countBefore * 1000 + pAI:GetID() + requesterPlayerID
                local idx = (math.abs(salt) % #available) + 1
                local relic = available[idx]
                choices[aiIDStr] = relic
                if relic == BARBARIAN_INVASION_RELIC then
                    invasionAssigned = true
                end
            end
        end
    end
    return choices
end

-- 每轮至多 1 个 AI 拿南蛮入侵；重复强制改抽（落地前最后一道闸）
local function Haikesi_EnforceInvasionMutexInChoices(choices, requesterPlayerID, countBefore)
    if choices == nil then return choices end
    local invaders = {}
    for aiIDStr, relic in pairs(choices) do
        if relic == BARBARIAN_INVASION_RELIC then
            table.insert(invaders, aiIDStr)
        end
    end
    if #invaders <= 1 then
        return choices
    end
    table.sort(invaders)
    local keepIdx = (math.abs((countBefore or 0) * 997 + (requesterPlayerID or 0)) % #invaders) + 1
    local keep = invaders[keepIdx]
    print("[Haikesi GamePlay] INVASION mutex: " .. tostring(#invaders)
        .. " AIs had invasion; keep AI" .. tostring(keep))
    for _, aiIDStr in ipairs(invaders) do
        if aiIDStr ~= keep then
            local aiID = tonumber(aiIDStr)
            local pAI = aiID ~= nil and Players[aiID] or nil
            local replacement = nil
            if pAI ~= nil then
                local available = GetAIAvailableRelics(pAI, true)
                if #available > 0 then
                    local salt = (countBefore or 0) * 1000 + aiID + (requesterPlayerID or 0)
                    replacement = available[(math.abs(salt) % #available) + 1]
                end
            end
            choices[aiIDStr] = replacement
            print("[Haikesi GamePlay] INVASION mutex: AI" .. tostring(aiIDStr)
                .. " reassigned -> " .. tostring(replacement))
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
    choices = Haikesi_EnforceInvasionMutexInChoices(choices, requesterPlayerID, countBefore)

    local applied = 0
    local invasionApplied = false
    -- 稳定顺序，避免 pairs 打乱互斥二次校验
    local aiIDList = {}
    for aiIDStr, _ in pairs(choices) do
        table.insert(aiIDList, aiIDStr)
    end
    table.sort(aiIDList)

    for _, aiIDStr in ipairs(aiIDList) do
        local aiRelic = choices[aiIDStr]
        local aiID = tonumber(aiIDStr)
        if aiID == nil then
            print("[Haikesi GamePlay] AIChoices invalid aiID: " .. tostring(aiIDStr))
        elseif aiRelic == nil or not AI_RELIC_TYPE_SET[aiRelic] then
            print("[Haikesi GamePlay] AIChoices rejected (not in AI pool): " .. tostring(aiRelic))
        else
            local pAI = Players[aiID]
            if pAI ~= nil and not pAI:IsHuman() and not pAI:IsBarbarian() then
                if aiRelic == BARBARIAN_INVASION_RELIC and invasionApplied then
                    local available = GetAIAvailableRelics(pAI, true)
                    if #available > 0 then
                        local salt = (countBefore or 0) * 1000 + aiID + (requesterPlayerID or 0)
                        aiRelic = available[(math.abs(salt) % #available) + 1]
                        print("[Haikesi GamePlay] INVASION mutex at apply: AI" .. aiID
                            .. " -> " .. tostring(aiRelic))
                    else
                        print("[Haikesi GamePlay] INVASION mutex at apply: AI" .. aiID .. " skip (no alt)")
                        aiRelic = nil
                    end
                end
                if aiRelic ~= nil then
                    local needCount = (countBefore or 0) + 1
                    if Haikesi_GetPlayerRelicCount(pAI) >= needCount then
                        print("[Haikesi GamePlay] AI Player" .. aiID
                            .. " already at round " .. tostring(needCount) .. ", skip")
                    else
                        local selectedTypes = GetSelectedRelicTypesForPlayer(pAI)
                        local relicDef = GameInfo.Haikesi_Relics[aiRelic]
                        local canApply = not selectedTypes[aiRelic]
                            or (relicDef ~= nil and relicDef.IsRepeatable == 1)
                        if canApply then
                            local reason = aiReasonsTable and aiReasonsTable[aiIDStr] or nil
                            if ApplyRelicToPlayer(aiID, aiRelic, true, reason) then
                                applied = applied + 1
                                if aiRelic == BARBARIAN_INVASION_RELIC then
                                    invasionApplied = true
                                end
                                print("[Haikesi GamePlay] AI Player" .. aiID .. " gained AI relic " .. aiRelic)
                            else
                                print("[Haikesi GamePlay] AI Player" .. aiID .. " failed to apply AI relic " .. tostring(aiRelic))
                            end
                        else
                            print("[Haikesi GamePlay] AI Player" .. aiID .. " already has " .. aiRelic .. ", skip")
                        end
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
local EXT_AI_OPTIONS_PER_PLAYER = 3
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
            choices = Haikesi_EnforceInvasionMutexInChoices(choices, requesterPlayerID, countBefore)

            local invasionApplied = false
            local sortedIDs = {}
            for _, pAI in ipairs(aiPlayers) do
                table.insert(sortedIDs, pAI:GetID())
            end
            table.sort(sortedIDs)

            for _, aiID in ipairs(sortedIDs) do
                local pAI = Players[aiID]
                if pAI ~= nil and Haikesi_GetPlayerRelicCount(pAI) < needCount then
                    local aiIDStr = tostring(aiID)
                    local relic = choices[aiIDStr]
                    local reason = (useUI and aiReasonsTable ~= nil) and aiReasonsTable[aiIDStr] or nil

                    -- 缺卡/非法/本轮南蛮已占用：只在本 AI 候选池内重抽，勿再整桌 Build（会重置互斥）
                    local function PickAltForAI(excludeInvasion)
                        local available = GetAIAvailableRelics(pAI, excludeInvasion)
                        if #available == 0 then return nil end
                        local salt = countBefore * 1000 + aiID + requesterPlayerID
                        return available[(math.abs(salt) % #available) + 1]
                    end

                    if relic == nil or not AI_RELIC_TYPE_SET[relic] then
                        relic = PickAltForAI(invasionApplied)
                        reason = nil
                    end

                    if relic == BARBARIAN_INVASION_RELIC and invasionApplied then
                        relic = PickAltForAI(true)
                        reason = nil
                        print("[Haikesi GamePlay] INVASION mutex sync: AI" .. aiID
                            .. " -> " .. tostring(relic))
                    end

                    if relic == nil then
                        print("[Haikesi GamePlay] AI Player" .. aiIDStr
                            .. " cannot catch up round " .. tostring(needCount))
                    else
                        local selectedTypes = GetSelectedRelicTypesForPlayer(pAI)
                        local relicDef = GameInfo.Haikesi_Relics[relic]
                        local canApply = not selectedTypes[relic]
                            or (relicDef ~= nil and relicDef.IsRepeatable == 1)
                        if not canApply then
                            relic = PickAltForAI(invasionApplied)
                            reason = nil
                            if relic == nil then
                                print("[Haikesi GamePlay] AI Player" .. aiIDStr
                                    .. " catch-up blocked round " .. tostring(needCount))
                            end
                        end

                        if relic ~= nil then
                            if ApplyRelicToPlayer(aiID, relic, true, reason) then
                                totalApplied = totalApplied + 1
                                if relic == BARBARIAN_INVASION_RELIC then
                                    invasionApplied = true
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
    local invasionInOptionsBatch = false
    local aiOptionIDs = {}
    for _, pAI in ipairs(Haikesi_GetAliveAIPlayers()) do
        local aiID = pAI:GetID()
        local available = GetAIAvailableRelics(pAI, invasionInOptionsBatch)
        local salt = countBefore * 1000 + aiID * 17 + requesterPlayerID + createdTurn * 997
        local options = Haikesi_PickRandomRelicsFromPool(available, EXT_AI_OPTIONS_PER_PLAYER, salt)
        Game:SetProperty(EXT_AI_OPTIONS_PREFIX .. aiID, table.concat(options, ","))
        table.insert(aiOptionIDs, tostring(aiID))
        for _, opt in ipairs(options) do
            if opt == BARBARIAN_INVASION_RELIC then
                invasionInOptionsBatch = true
                break
            end
        end
        print("[Haikesi GamePlay] External AI options Player" .. aiID .. ": "
            .. table.concat(options, ", "))
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
    Haikesi_StoreExternalAIOptionsForAllAIs(requester, countBefore, createdTurn)
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
    local mp = 0
    if Game ~= nil and Game.IsNetworkMultiplayer ~= nil and Game.IsNetworkMultiplayer() then
        mp = 1
    end

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
            .. "|name:" .. tostring(playerName))
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
    local requestID = tostring(turn) .. '_' .. tostring(countBefore) .. '_' .. tostring(requesterPlayerID)
    Haikesi_ClearExternalAIOptions()
    Game:SetProperty(EXT_AI_PENDING_KEY, 1)
    Game:SetProperty(EXT_AI_REQUEST_ID_KEY, requestID)
    Game:SetProperty(EXT_AI_REQUESTER_KEY, requesterPlayerID)
    Game:SetProperty(EXT_AI_COUNT_BEFORE_KEY, countBefore)
    Game:SetProperty(EXT_AI_HUMAN_RELIC_KEY, humanRelic)
    Game:SetProperty(EXT_AI_CREATED_TURN_KEY, turn)

    Haikesi_StoreExternalAIOptionsForAllAIs(requesterPlayerID, countBefore, turn)

    print("[Haikesi GamePlay] External AI request created: " .. requestID
        .. " requester=" .. tostring(requesterPlayerID)
        .. " humanRelic=" .. tostring(humanRelic)
        .. " countBefore=" .. tostring(countBefore))
    -- 单机/联机均 dump：联机 watch 无 Tuner 时依赖此块；单机可忽略
    Haikesi_DumpExternalAIRequestToLog("create")
end

local function Haikesi_ValidateExternalAIChoices(choicesTable)
    if choicesTable == nil or next(choicesTable) == nil then
        return false, "empty choices"
    end

    local invasionCount = 0
    for _, aiRelic in pairs(choicesTable) do
        if aiRelic == BARBARIAN_INVASION_RELIC then
            invasionCount = invasionCount + 1
        end
    end
    if invasionCount > 1 then
        return false, "multiple invasion assignments"
    end

    local invasionAssignedInBatch = invasionCount == 1
    for aiIDStr, aiRelic in pairs(choicesTable) do
        local aiID = tonumber(aiIDStr)
        if aiID == nil then
            return false, "invalid aiID: " .. tostring(aiIDStr)
        end
        if not AI_RELIC_TYPE_SET[aiRelic] then
            return false, "not in AI pool: " .. tostring(aiRelic)
        end
        local pAI = Players[aiID]
        if pAI == nil or pAI:IsHuman() or pAI:IsBarbarian() then
            return false, "invalid AI player: " .. tostring(aiIDStr)
        end
        local options = Haikesi_GetStoredExternalAIOptions(aiID)
        if #options == 0 then
            local excludeInvasion = invasionAssignedInBatch and aiRelic ~= BARBARIAN_INVASION_RELIC
            options = GetAIAvailableRelics(pAI, excludeInvasion)
        end
        local found = false
        for _, t in ipairs(options) do
            if t == aiRelic then
                found = true
                break
            end
        end
        if not found then
            return false, "invalid choice for AI " .. aiIDStr .. " (not in options): " .. tostring(aiRelic)
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
            .. "|name:" .. tostring(playerName))
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

-- EXECUTE_SCRIPT 广播落地：各端同参 Apply（pending 已清则幂等忽略）
local function Haikesi_ApplyExternalAIFromNetwork(raw)
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
        print("[Haikesi GamePlay] ExtAIApply skip: AI already at round " .. tostring(targetRound))
        Haikesi_ClearExternalAIRequest()
        return false
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
    pRequester:SetProperty('PROP_NW_HAIKESI_AI_CHOICES_FOR_COUNT', targetRound)
    Haikesi_ClearExternalAIRequest()
    print("[Haikesi GamePlay] ExtAIApply applied request_id=" .. tostring(requestID)
        .. " applied=" .. tostring(appliedOrErr) .. " round=" .. tostring(targetRound))
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
            print("[Haikesi GamePlay] AI already synced to select round " .. tostring(targetRound)
                .. " (Player" .. iPlayer .. "), skip")
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
                print("[Haikesi GamePlay] External AI request already pending for select count "
                    .. tostring(countBefore) .. " (Player" .. iPlayer .. ")")
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
-- 混合层：部分海克斯效果必须 Lua 实现（无原生 Modifier 对应）
-- 占位检测仅对残存占位项生效（目前已无残留）
local PLACEHOLDER_MODIFIER_ID = 'MODIFIER_NW_HAIKESI_PLACEHOLDER_UNIT'

local function GetBarbarianCampImprovementIndex()
    local row = GameInfo.Improvements[BARBARIAN_CAMP_IMPROVEMENT]
    if row == nil then
        return nil
    end
    return row.Index
end

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

local function IsFarEnoughFromBarbarianCamps(pPlot, iBarbCampIndex)
    for plotIndex = 0, Map.GetPlotCount() - 1 do
        local pExistingPlot = Map.GetPlotByIndex(plotIndex)
        if pExistingPlot ~= nil
            and pExistingPlot:GetImprovementType() == iBarbCampIndex
            and Map.GetPlotDistance(
                pPlot:GetX(), pPlot:GetY(),
                pExistingPlot:GetX(), pExistingPlot:GetY())
                < BARBARIAN_CAMP_MINIMUM_DISTANCE_ANOTHER_CAMP then
            return false
        end
    end
    return true
end

local function IsFarEnoughFromCities(pPlot)
    for playerID = 0, 63 do
        local pPlayer = Players[playerID]
        if pPlayer ~= nil then
            local pCities = pPlayer:GetCities()
            if pCities ~= nil then
                for _, pCity in pCities:Members() do
                    if pCity ~= nil
                        and Map.GetPlotDistance(
                            pPlot:GetX(), pPlot:GetY(),
                            pCity:GetX(), pCity:GetY())
                            < BARBARIAN_CAMP_MINIMUM_DISTANCE_CITY then
                        return false
                    end
                end
            end
        end
    end
    return true
end

local function CanPlaceBarbarianCampWithVanillaSpacing(pPlot, iBarbCampIndex)
    return ImprovementBuilder.CanHaveImprovement(pPlot, iBarbCampIndex, -1)
        and IsFarEnoughFromBarbarianCamps(pPlot, iBarbCampIndex)
        and IsFarEnoughFromCities(pPlot)
end

local function GatherBarbarianCampPlotsAtDistance(centerX, centerY, distance, iBarbCampIndex, usedPlotIDs)
    local candidates = {}
    local candidatePlotIDs = {}
    for dx = -distance, distance do
        for dy = -distance, distance do
            local pPlot = Map.GetPlotXY(centerX, centerY, dx, dy)
            if pPlot ~= nil then
                local dist = Map.GetPlotDistance(centerX, centerY, pPlot:GetX(), pPlot:GetY())
                local plotID = pPlot:GetIndex()
                if dist == distance
                    and not usedPlotIDs[plotID]
                    and not candidatePlotIDs[plotID]
                    and pPlot:GetImprovementType() ~= iBarbCampIndex
                    and CanPlaceBarbarianCampWithVanillaSpacing(pPlot, iBarbCampIndex) then
                    candidatePlotIDs[plotID] = true
                    table.insert(candidates, pPlot)
                end
            end
        end
    end
    return candidates
end

local function GetBarbarianPlayer()
    if PlayerManager.GetAliveBarbarians ~= nil then
        for _, pBarb in ipairs(PlayerManager.GetAliveBarbarians()) do
            if pBarb ~= nil and pBarb:IsAlive() then
                return pBarb
            end
        end
    end
    for iPlayer = 0, 63 do
        local pPlayer = Players[iPlayer]
        if pPlayer ~= nil and pPlayer:IsBarbarian() and pPlayer:IsAlive() then
            return pPlayer
        end
    end
    return nil
end

local function IsBarbarianClansModeEnabled()
    local v = GameConfiguration.GetValue("GAMEMODE_BARBARIAN_CLANS")
    return v == true or v == 1 or v == "1"
end

local function CountBarbarianUnitsNear(centerX, centerY, radius)
    local pBarb = GetBarbarianPlayer()
    if pBarb == nil then return 0 end
    local n = 0
    local pUnits = pBarb:GetUnits()
    if pUnits == nil then return 0 end
    for _, pUnit in pUnits:Members() do
        if pUnit ~= nil then
            local dist = Map.GetPlotDistance(centerX, centerY, pUnit:GetX(), pUnit:GetY())
            if dist ~= nil and dist <= radius then
                n = n + 1
            end
        end
    end
    return n
end

local function PlotTouchesWaterOrCoast(pPlot)
    if pPlot == nil then return false end
    local ok, coastal = pcall(function()
        return pPlot:IsCoastalLand()
    end)
    if ok and coastal then return true end
    for dir = 0, 5 do
        local adj = Map.GetAdjacentPlot(pPlot:GetX(), pPlot:GetY(), dir)
        if adj ~= nil and adj:IsWater() then
            return true
        end
    end
    return false
end

local function PlotHasNearbyResource(pPlot, resourceType, range)
    local resourceRow = GameInfo.Resources[resourceType]
    if pPlot == nil or resourceRow == nil then return false end
    local resourceIndex = resourceRow.Index
    local x, y = pPlot:GetX(), pPlot:GetY()
    for dx = -range, range do
        for dy = -range, range do
            local pCheck = Map.GetPlotXY(x, y, dx, dy)
            if pCheck ~= nil
                and Map.GetPlotDistance(x, y, pCheck:GetX(), pCheck:GetY()) <= range
                and pCheck:GetResourceType() == resourceIndex then
                return true
            end
        end
    end
    return false
end

local function PlotHasNearbyFeatureClass(pPlot, featureType, range)
    local featureRow = GameInfo.Features[featureType]
    if pPlot == nil or featureRow == nil then return false end
    local featureIndex = featureRow.Index
    local x, y = pPlot:GetX(), pPlot:GetY()
    for dx = -range, range do
        for dy = -range, range do
            local pCheck = Map.GetPlotXY(x, y, dx, dy)
            if pCheck ~= nil
                and Map.GetPlotDistance(x, y, pCheck:GetX(), pCheck:GetY()) <= range
                and pCheck:GetFeatureType() == featureIndex then
                return true
            end
        end
    end
    return false
end

-- 按地块环境选择蛮族氏族类型（氏族模式用 CLAN_*，否则原版 TRIBE_*）
local function ResolveBarbarianTribeTypeForPlot(pPlot)
    local clans = IsBarbarianClansModeEnabled()
    if PlotTouchesWaterOrCoast(pPlot) then
        if clans and GameInfo.BarbarianTribes["TRIBE_CLAN_NAVAL"] ~= nil then
            return "TRIBE_CLAN_NAVAL"
        end
        if GameInfo.BarbarianTribes["TRIBE_NAVAL"] ~= nil then
            return "TRIBE_NAVAL"
        end
    end
    if PlotHasNearbyResource(pPlot, BARBARIAN_HORSE_RESOURCE, BARBARIAN_HORSE_RANGE) then
        if clans then
            if PlotHasNearbyFeatureClass(pPlot, "FEATURE_JUNGLE", 1)
                and GameInfo.BarbarianTribes["TRIBE_CLAN_CAVALRY_JUNGLE"] ~= nil then
                return "TRIBE_CLAN_CAVALRY_JUNGLE"
            end
            if GameInfo.BarbarianTribes["TRIBE_CLAN_CAVALRY_OPEN"] ~= nil then
                return "TRIBE_CLAN_CAVALRY_OPEN"
            end
        end
        if GameInfo.BarbarianTribes["TRIBE_CAVALRY"] ~= nil then
            return "TRIBE_CAVALRY"
        end
    end
    if clans then
        if PlotHasNearbyFeatureClass(pPlot, "FEATURE_FOREST", 0)
            and GameInfo.BarbarianTribes["TRIBE_CLAN_MELEE_FOREST"] ~= nil then
            return "TRIBE_CLAN_MELEE_FOREST"
        end
        local okHills, isHills = pcall(function() return pPlot:IsHills() end)
        if okHills and isHills and GameInfo.BarbarianTribes["TRIBE_CLAN_MELEE_HILLS"] ~= nil then
            return "TRIBE_CLAN_MELEE_HILLS"
        end
        if GameInfo.BarbarianTribes["TRIBE_CLAN_MELEE_OPEN"] ~= nil then
            return "TRIBE_CLAN_MELEE_OPEN"
        end
    end
    if GameInfo.BarbarianTribes["TRIBE_MELEE"] ~= nil then
        return "TRIBE_MELEE"
    end
    return nil
end

local function ResolveTribeNameRow(nameType)
    if nameType == nil then return nil end
    local row = GameInfo.BarbarianTribeNames[nameType]
    if row ~= nil then return row end
    if type(nameType) == "number" then
        for r in GameInfo.BarbarianTribeNames() do
            if r.Index == nameType then
                return r
            end
        end
    end
    return nil
end

-- 取氏族专名 LOC（Quiet Fox 等）；Gameplay 下 GetTribeNameType 偶发失败
local function CaptureTribeNameLoc(iTribe)
    if iTribe == nil or iTribe < 0 then return nil end
    local pBarbManager = Game.GetBarbarianManager()
    if pBarbManager == nil or pBarbManager.GetTribeNameType == nil then
        return nil
    end
    local ok, nameType = pcall(function()
        return pBarbManager:GetTribeNameType(iTribe)
    end)
    if not ok or nameType == nil then
        return nil
    end
    if type(nameType) == "number" and nameType < 0 then
        return nil
    end
    local nameRow = ResolveTribeNameRow(nameType)
    if nameRow ~= nil and nameRow.TribeDisplayName ~= nil then
        return nameRow.TribeDisplayName
    end
    return nil
end

local function PersistBarbarianTribeMap()
    local parts = {}
    for plotIndex, iTribe in pairs(g_BarbarianTribeIndexByPlot) do
        if iTribe ~= nil and iTribe >= 0 then
            local tType = g_BarbarianTribeTypeByPlot[plotIndex] or ""
            local nameLoc = g_BarbarianTribeNameLocByPlot[plotIndex] or ""
            table.insert(parts, string.format(
                "%d:%d:%s:%s", plotIndex, iTribe, tType, nameLoc))
        end
    end
    table.sort(parts)
    Game:SetProperty(BARB_TRIBE_MAP_PROP, table.concat(parts, "|"))
end

-- 丢掉已无蛮寨地块上的过期映射
local function PruneBarbarianTribeMap()
    local iBarbCampIndex = GetBarbarianCampImprovementIndex()
    if iBarbCampIndex == nil then return end
    local dead = {}
    for plotIndex, _ in pairs(g_BarbarianTribeIndexByPlot) do
        local pPlot = Map.GetPlotByIndex(plotIndex)
        if pPlot == nil or pPlot:GetImprovementType() ~= iBarbCampIndex then
            table.insert(dead, plotIndex)
        end
    end
    for _, plotIndex in ipairs(dead) do
        g_BarbarianTribeIndexByPlot[plotIndex] = nil
        g_BarbarianTribeTypeByPlot[plotIndex] = nil
        g_BarbarianTribeNameLocByPlot[plotIndex] = nil
    end
end

-- 从存档合并映射；属性为空时绝不清空内存（同会话上一波建营的索引还在）
local function LoadBarbarianTribeMap()
    local raw = Game:GetProperty(BARB_TRIBE_MAP_PROP) or ""
    local iBarbCampIndex = GetBarbarianCampImprovementIndex()
    if raw ~= "" and iBarbCampIndex ~= nil then
        for entry in string.gmatch(raw, "[^|]+") do
            local plotStr, tribeStr, tType, nameLoc = string.match(
                entry, "^(%d+):(%-?%d+):([^:]*):(.*)$")
            if plotStr == nil then
                plotStr, tribeStr, tType = string.match(entry, "^(%d+):(%-?%d+):(.*)$")
                nameLoc = ""
            end
            local plotIndex = tonumber(plotStr)
            local iTribe = tonumber(tribeStr)
            if plotIndex ~= nil and iTribe ~= nil and iTribe >= 0 then
                local pPlot = Map.GetPlotByIndex(plotIndex)
                if pPlot ~= nil and pPlot:GetImprovementType() == iBarbCampIndex then
                    g_BarbarianTribeIndexByPlot[plotIndex] = iTribe
                    if tType ~= nil and tType ~= "" then
                        g_BarbarianTribeTypeByPlot[plotIndex] = tType
                    end
                    if nameLoc ~= nil and nameLoc ~= "" then
                        g_BarbarianTribeNameLocByPlot[plotIndex] = nameLoc
                    end
                end
            end
        end
    end
    PruneBarbarianTribeMap()
end

local function CacheBarbarianTribeIndex(plotIndex, iTribe, tribeType, doPersist)
    if plotIndex ~= nil and iTribe ~= nil and iTribe >= 0 then
        g_BarbarianTribeIndexByPlot[plotIndex] = iTribe
        if g_BarbarianTribeNameLocByPlot[plotIndex] == nil then
            local nameLoc = CaptureTribeNameLoc(iTribe)
            if nameLoc ~= nil then
                g_BarbarianTribeNameLocByPlot[plotIndex] = nameLoc
            end
        end
    end
    if plotIndex ~= nil and tribeType ~= nil then
        g_BarbarianTribeTypeByPlot[plotIndex] = tribeType
    end
    if doPersist ~= false then
        PersistBarbarianTribeMap()
    end
end

local function ResolveTribeTypeRowAtCamp(pCamp, iTribe)
    if pCamp ~= nil then
        local cachedType = g_BarbarianTribeTypeByPlot[pCamp:GetIndex()]
        if cachedType ~= nil and GameInfo.BarbarianTribes[cachedType] ~= nil then
            return GameInfo.BarbarianTribes[cachedType], cachedType
        end
    end
    if iTribe == nil or iTribe < 0 then
        return nil, nil
    end
    local pBarbManager = Game.GetBarbarianManager()
    if pBarbManager == nil then
        return nil, nil
    end
    if pBarbManager.GetTribeType ~= nil then
        local ok, eTribeType = pcall(function()
            return pBarbManager:GetTribeType(iTribe)
        end)
        if ok and eTribeType ~= nil and GameInfo.BarbarianTribes[eTribeType] ~= nil then
            return GameInfo.BarbarianTribes[eTribeType], eTribeType
        end
    end
    if pBarbManager.GetTribeNameType ~= nil then
        local ok, nameType = pcall(function()
            return pBarbManager:GetTribeNameType(iTribe)
        end)
        if ok and nameType ~= nil then
            local nameRow = GameInfo.BarbarianTribeNames[nameType]
            local tribeType = nameRow and nameRow.TribeType or nil
            if tribeType ~= nil and GameInfo.BarbarianTribes[tribeType] ~= nil then
                return GameInfo.BarbarianTribes[tribeType], tribeType
            end
        end
    end
    return nil, nil
end

-- 世界是否已有人解锁某科技（用于判断能否走原版时代进阶兵种）
local function IsAnyMajorHasTech(techType)
    local techRow = GameInfo.Technologies[techType]
    if techRow == nil then return false end
    for _, pMajor in ipairs(PlayerManager.GetAliveMajors()) do
        if pMajor ~= nil then
            local pTechs = pMajor:GetTechs()
            if pTechs ~= nil and pTechs:HasTech(techRow.Index) then
                return true
            end
        end
    end
    return false
end

local function PushSpawnJob(jobs, primaryTag, earlyTag, earlyUnitType, count)
    if count <= 0 then return end
    table.insert(jobs, {
        tag = primaryTag,
        fallbackTag = earlyTag,
        unitType = earlyUnitType,
        count = count,
    })
end

-- 优先原版氏族 MeleeTag/RangedTag（随科技进阶）；远古未解锁时用早期独占 Tag 兜底
local function BuildTribeUnitSpawnJobs(pCamp, iTribe, count)
    local jobs = {}
    if count <= 0 then return jobs end
    local tribeRow = ResolveTribeTypeRowAtCamp(pCamp, iTribe)
    if tribeRow == nil and pCamp ~= nil then
        local guessedType = ResolveBarbarianTribeTypeForPlot(pCamp)
        tribeRow = guessedType and GameInfo.BarbarianTribes[guessedType] or nil
        if guessedType ~= nil then
            CacheBarbarianTribeIndex(pCamp:GetIndex(), iTribe, guessedType)
        end
    end
    local meleeTag = (tribeRow and tribeRow.MeleeTag) or "CLASS_MELEE"
    local rangedTag = tribeRow and tribeRow.RangedTag or nil
    local percentRanged = 0
    if tribeRow ~= nil and tribeRow.PercentRangedUnits ~= nil then
        percentRanged = tonumber(tribeRow.PercentRangedUnits) or 0
    end

    local rangedCount = 0
    if percentRanged > 0 and rangedTag ~= nil then
        rangedCount = math.floor(count * percentRanged / 100)
    end
    local meleeCount = count - rangedCount

    if meleeTag == "CLASS_LIGHT_CAVALRY" then
        -- 有骑术后走原版 CLASS_*（骑手→骑兵→直升机…）；否则强制早期蛮族骑手/弓骑手
        local useVanilla = IsAnyMajorHasTech("TECH_HORSEBACK_RIDING")
        if useVanilla then
            PushSpawnJob(jobs, meleeTag, HAIKESI_BARB_HORSEMAN_TAG,
                BARBARIAN_HORSEMAN_UNIT, meleeCount)
            PushSpawnJob(jobs, rangedTag or "CLASS_MOBILE_RANGED",
                HAIKESI_BARB_HORSE_ARCHER_TAG, BARBARIAN_HORSE_ARCHER_UNIT, rangedCount)
        else
            PushSpawnJob(jobs, HAIKESI_BARB_HORSEMAN_TAG, meleeTag,
                BARBARIAN_HORSEMAN_UNIT, meleeCount)
            PushSpawnJob(jobs, HAIKESI_BARB_HORSE_ARCHER_TAG,
                rangedTag or "CLASS_RANGED_CAVALRY", BARBARIAN_HORSE_ARCHER_UNIT, rangedCount)
        end
        return jobs
    end

    if meleeTag == "CLASS_NAVAL_MELEE" then
        local useVanillaMelee = IsAnyMajorHasTech("TECH_SAILING")
        local useVanillaRanged = IsAnyMajorHasTech("TECH_SHIPBUILDING")
        if useVanillaMelee then
            PushSpawnJob(jobs, meleeTag, HAIKESI_BARB_GALLEY_TAG,
                BARBARIAN_GALLEY_UNIT, meleeCount)
        else
            PushSpawnJob(jobs, HAIKESI_BARB_GALLEY_TAG, meleeTag,
                BARBARIAN_GALLEY_UNIT, meleeCount)
        end
        if rangedCount > 0 then
            if useVanillaRanged then
                PushSpawnJob(jobs, rangedTag or "CLASS_NAVAL_RANGED",
                    HAIKESI_BARB_QUADRIREME_TAG, BARBARIAN_QUADRIREME_UNIT, rangedCount)
            else
                PushSpawnJob(jobs, HAIKESI_BARB_QUADRIREME_TAG,
                    rangedTag or "CLASS_NAVAL_RANGED", BARBARIAN_QUADRIREME_UNIT, rangedCount)
            end
        end
        return jobs
    end

    -- 近战等：完全交给原版 Tag
    PushSpawnJob(jobs, meleeTag, nil, nil, meleeCount)
    if rangedCount > 0 and rangedTag ~= nil then
        PushSpawnJob(jobs, rangedTag, nil, nil, rangedCount)
    end
    return jobs
end

-- 从营地附近已有蛮族单位反查部落索引（Gameplay 可用；GetTribeIndexAtLocation 仅 UI）
local function FindTribeIndexFromNearbyUnits(pCamp, radius)
    if pCamp == nil then return nil end
    local pBarb = GetBarbarianPlayer()
    if pBarb == nil then return nil end
    local pUnits = pBarb:GetUnits()
    if pUnits == nil then return nil end
    local campX, campY = pCamp:GetX(), pCamp:GetY()
    local bestTribe, bestDist = nil, math.huge
    for _, pUnit in pUnits:Members() do
        if pUnit ~= nil and pUnit.GetBarbarianTribeIndex ~= nil then
            local ok, iTribe = pcall(function()
                return pUnit:GetBarbarianTribeIndex()
            end)
            if ok and iTribe ~= nil and iTribe >= 0 then
                local dist = Map.GetPlotDistance(campX, campY, pUnit:GetX(), pUnit:GetY())
                if dist ~= nil and dist <= radius and dist < bestDist then
                    bestTribe = iTribe
                    bestDist = dist
                    if bestDist == 0 then
                        break
                    end
                end
            end
        end
    end
    return bestTribe
end

-- 解析营地部落索引：存档映射 > 内存缓存 > 附近氏族单位；绝不清营重建
local function ResolveTribeIndexAtCamp(pCamp)
    if pCamp == nil then return nil end
    local plotIndex = pCamp:GetIndex()
    local cached = g_BarbarianTribeIndexByPlot[plotIndex]
    if cached ~= nil and cached >= 0 then
        return cached
    end

    -- UI-only API，Gameplay 下通常失败；保留尝试以兼容
    local pBarbManager = Game.GetBarbarianManager()
    if pBarbManager ~= nil and pBarbManager.GetTribeIndexAtLocation ~= nil then
        local ok, iTribe = pcall(function()
            return pBarbManager:GetTribeIndexAtLocation(pCamp:GetX(), pCamp:GetY())
        end)
        if ok and iTribe ~= nil and iTribe >= 0 then
            CacheBarbarianTribeIndex(plotIndex, iTribe, nil, true)
            return iTribe
        end
    end

    local fromUnit = FindTribeIndexFromNearbyUnits(pCamp, BARB_TRIBE_LOOKUP_RADIUS)
    if fromUnit ~= nil then
        CacheBarbarianTribeIndex(plotIndex, fromUnit, nil, true)
        return fromUnit
    end
    return nil
end

-- 用附近已入族蛮兵给尚未缓存的营地补索引（应对读档/热更后内存空）
local function RebuildTribeIndexFromNearbyUnits(iBarbCampIndex)
    if iBarbCampIndex == nil then return 0 end
    local filled = 0
    for plotIndex = 0, Map.GetPlotCount() - 1 do
        local pPlot = Map.GetPlotByIndex(plotIndex)
        if pPlot ~= nil
            and pPlot:GetImprovementType() == iBarbCampIndex
            and g_BarbarianTribeIndexByPlot[plotIndex] == nil then
            local fromUnit = FindTribeIndexFromNearbyUnits(pPlot, BARB_TRIBE_LOOKUP_RADIUS)
            if fromUnit ~= nil then
                CacheBarbarianTribeIndex(plotIndex, fromUnit, nil, false)
                filled = filled + 1
            end
        end
    end
    if filled > 0 then
        PersistBarbarianTribeMap()
    end
    return filled
end

-- 氏族模式下孤儿营：在原格 CreateTribeOfType 绑定索引（不先清营，避免拆寨）
local function EnsureTribeIndexAtCamp(pCamp)
    local iTribe = ResolveTribeIndexAtCamp(pCamp)
    if iTribe ~= nil then
        return iTribe
    end
    if pCamp == nil or not IsBarbarianClansModeEnabled() then
        return nil
    end
    local pBarbManager = Game.GetBarbarianManager()
    if pBarbManager == nil or pBarbManager.CreateTribeOfType == nil then
        return nil
    end
    local tribeType = g_BarbarianTribeTypeByPlot[pCamp:GetIndex()]
        or ResolveBarbarianTribeTypeForPlot(pCamp)
    local tribeRow = tribeType and GameInfo.BarbarianTribes[tribeType] or nil
    if tribeRow == nil then
        return nil
    end
    local ok, newTribe = pcall(function()
        return pBarbManager:CreateTribeOfType(tribeRow.Index, pCamp:GetIndex())
    end)
    if ok and newTribe ~= nil and type(newTribe) == "number" and newTribe >= 0 then
        CacheBarbarianTribeIndex(pCamp:GetIndex(), newTribe, tribeType, true)
        print(string.format(
            "[Haikesi GamePlay] BARBARIAN_INVASION ensureTribe=%s tribeIdx=%s at (%d,%d)",
            tostring(tribeType), tostring(newTribe), pCamp:GetX(), pCamp:GetY()))
        return newTribe
    end
    return nil
end

local function PlaceBarbarianCampAtPlot(pPlot, iBarbCampIndex)
    if pPlot == nil or iBarbCampIndex == nil then
        return false, nil
    end
    local pBarbManager = Game.GetBarbarianManager()
    if pBarbManager ~= nil and pBarbManager.CreateTribeOfType ~= nil then
        local tribeType = ResolveBarbarianTribeTypeForPlot(pPlot)
        local tribeRow = tribeType and GameInfo.BarbarianTribes[tribeType] or nil
        if tribeRow ~= nil then
            ImprovementBuilder.SetImprovementType(pPlot, -1, -1)
            local ok, iTribe = pcall(function()
                return pBarbManager:CreateTribeOfType(tribeRow.Index, pPlot:GetIndex())
            end)
            if ok and pPlot:GetImprovementType() == iBarbCampIndex then
                CacheBarbarianTribeIndex(pPlot:GetIndex(), iTribe, tribeType, true)
                print(string.format(
                    "[Haikesi GamePlay] BARBARIAN_INVASION camp+tribe=%s tribeIdx=%s at (%d,%d) clans=%s",
                    tostring(tribeType), tostring(iTribe),
                    pPlot:GetX(), pPlot:GetY(), tostring(IsBarbarianClansModeEnabled())))
                return true, iTribe
            end
        end
    end
    ImprovementBuilder.SetImprovementType(pPlot, iBarbCampIndex, -1)
    if pPlot:GetImprovementType() == iBarbCampIndex then
        return true, nil
    end
    return false, nil
end

local function GatherBarbarianCampsSorted(centerX, centerY, iBarbCampIndex)
    local camps = {}
    for plotIndex = 0, Map.GetPlotCount() - 1 do
        local pPlot = Map.GetPlotByIndex(plotIndex)
        if pPlot ~= nil and pPlot:GetImprovementType() == iBarbCampIndex then
            table.insert(camps, {
                plot = pPlot,
                dist = Map.GetPlotDistance(centerX, centerY, pPlot:GetX(), pPlot:GetY()),
                index = plotIndex,
            })
        end
    end
    table.sort(camps, function(a, b)
        if a.dist == b.dist then
            return a.index < b.index
        end
        return a.dist < b.dist
    end)
    local plots = {}
    for _, entry in ipairs(camps) do
        table.insert(plots, entry.plot)
    end
    return plots, camps
end

local function GatherBarbarianUnitPlots(centerX, centerY, radius, requireWater)
    local candidates = {}
    local candidatePlotIDs = {}
    for dx = -radius, radius do
        for dy = -radius, radius do
            local pPlot = Map.GetPlotXY(centerX, centerY, dx, dy)
            if pPlot ~= nil then
                local dist = Map.GetPlotDistance(centerX, centerY, pPlot:GetX(), pPlot:GetY())
                local plotID = pPlot:GetIndex()
                local terrainOk
                if requireWater then
                    terrainOk = pPlot:IsWater() and not pPlot:IsLake()
                else
                    terrainOk = (not pPlot:IsWater()) and (not pPlot:IsImpassable())
                end
                if dist <= radius
                    and not candidatePlotIDs[plotID]
                    and terrainOk
                    and CityManager.GetCityAt(pPlot:GetX(), pPlot:GetY()) == nil then
                    candidatePlotIDs[plotID] = true
                    table.insert(candidates, pPlot)
                end
            end
        end
    end
    table.sort(candidates, function(a, b)
        local distanceA = Map.GetPlotDistance(centerX, centerY, a:GetX(), a:GetY())
        local distanceB = Map.GetPlotDistance(centerX, centerY, b:GetX(), b:GetY())
        if distanceA == distanceB then
            return a:GetIndex() < b:GetIndex()
        end
        return distanceA < distanceB
    end)
    return candidates
end

local function IsNavalDomainUnit(unitType)
    local unitRow = unitType and GameInfo.Units[unitType] or nil
    return unitRow ~= nil and unitRow.Domain == "DOMAIN_SEA"
end

local function SpawnBarbarianUnitsAtCampFallback(pCamp, count, unitType)
    local pBarb = GetBarbarianPlayer()
    local unitRow = GameInfo.Units[unitType or BARBARIAN_FALLBACK_UNIT]
        or GameInfo.Units[BARBARIAN_FALLBACK_UNIT]
    if pBarb == nil or unitRow == nil or pCamp == nil or count <= 0 then
        return 0
    end
    local needWater = IsNavalDomainUnit(unitRow.UnitType or unitType)
    local candidates = GatherBarbarianUnitPlots(
        pCamp:GetX(), pCamp:GetY(),
        needWater and BARBARIAN_TRIBE_UNIT_RANGE or INVASION_FALLBACK_UNIT_RADIUS,
        needWater)
    local spawned = 0
    for _, pPlot in ipairs(candidates) do
        if spawned >= count then break end
        local pUnit = pBarb:GetUnits():Create(unitRow.Index, pPlot:GetX(), pPlot:GetY())
        if pUnit ~= nil then
            spawned = spawned + 1
        end
    end
    return spawned
end

local function CreateTribeUnitsWithTag(pBarbManager, iTribe, tag, count, plotIndex)
    if pBarbManager == nil or iTribe == nil or tag == nil or count <= 0 then
        return false
    end
    local ok = pcall(function()
        pBarbManager:CreateTribeUnits(
            iTribe, tag, count, plotIndex, BARBARIAN_TRIBE_UNIT_RANGE)
    end)
    return ok
end

-- CreateTribeUnits：优先原版氏族 Tag（时代进阶），不足再用早期 Tag / 指定单位兜底
local function SpawnBarbarianUnitsAtCamp(pCamp, count)
    if pCamp == nil or count <= 0 then
        return 0
    end
    local pBarbManager = Game.GetBarbarianManager()
    local iTribe = ResolveTribeIndexAtCamp(pCamp)
    local jobs = BuildTribeUnitSpawnJobs(pCamp, iTribe, count)
    local totalSpawned = 0

    if pBarbManager ~= nil
        and iTribe ~= nil and iTribe >= 0
        and pBarbManager.CreateTribeUnits ~= nil
        and #jobs > 0 then
        for _, job in ipairs(jobs) do
            local before = CountBarbarianUnitsNear(
                pCamp:GetX(), pCamp:GetY(), BARBARIAN_TRIBE_UNIT_RANGE + 1)
            local tagUsed = job.tag
            local ok = CreateTribeUnitsWithTag(
                pBarbManager, iTribe, job.tag, job.count, pCamp:GetIndex())
            local after = CountBarbarianUnitsNear(
                pCamp:GetX(), pCamp:GetY(), BARBARIAN_TRIBE_UNIT_RANGE + 1)
            local spawned = ok and math.max(0, after - before) or 0

            if spawned < job.count and job.fallbackTag ~= nil then
                before = CountBarbarianUnitsNear(
                    pCamp:GetX(), pCamp:GetY(), BARBARIAN_TRIBE_UNIT_RANGE + 1)
                tagUsed = job.fallbackTag
                ok = CreateTribeUnitsWithTag(
                    pBarbManager, iTribe, job.fallbackTag, job.count - spawned,
                    pCamp:GetIndex())
                after = CountBarbarianUnitsNear(
                    pCamp:GetX(), pCamp:GetY(), BARBARIAN_TRIBE_UNIT_RANGE + 1)
                local extra = ok and math.max(0, after - before) or 0
                spawned = spawned + extra
            end
            -- 氏族模式只用 CreateTribeUnits（Units:Create 无法挂氏族）
            if spawned < job.count
                and job.unitType ~= nil
                and not IsBarbarianClansModeEnabled() then
                local extra = SpawnBarbarianUnitsAtCampFallback(
                    pCamp, job.count - spawned, job.unitType)
                spawned = spawned + extra
                tagUsed = job.unitType
            end

            totalSpawned = totalSpawned + spawned
            print(string.format(
                "[Haikesi GamePlay] BARBARIAN_INVASION tribeUnits camp(%d,%d) "
                    .. "tribe=%s tag=%s req=%d got=%d",
                pCamp:GetX(), pCamp:GetY(), tostring(iTribe), tostring(tagUsed),
                job.count, spawned))
        end
        return totalSpawned
    end

    print(string.format(
        "[Haikesi GamePlay] BARBARIAN_INVASION skip camp(%d,%d): no tribe index (avoid clanless Create)",
        pCamp:GetX(), pCamp:GetY()))

    -- 非氏族模式才允许 Units:Create 回退
    if not IsBarbarianClansModeEnabled() then
        for _, job in ipairs(jobs) do
            if job.unitType ~= nil then
                totalSpawned = totalSpawned + SpawnBarbarianUnitsAtCampFallback(
                    pCamp, job.count, job.unitType)
            else
                totalSpawned = totalSpawned + SpawnBarbarianUnitsAtCampFallback(
                    pCamp, job.count, BARBARIAN_FALLBACK_UNIT)
            end
        end
        if totalSpawned == 0 then
            totalSpawned = SpawnBarbarianUnitsAtCampFallback(
                pCamp, count, BARBARIAN_FALLBACK_UNIT)
        end
    end
    return totalSpawned
end

-- 复用原版煽动通知图标：仅人类被打时入队，由 UI 桥接取专名后发送
local function NotifyBarbarianInvasionAssault(
    triggerPlayerID, iTribe, targetPlayerID, targetCityID, pCamp)
    local pTarget = Players[targetPlayerID]
    if pTarget == nil or not pTarget:IsHuman() then
        return
    end
    if triggerPlayerID == nil or iTribe == nil or targetCityID == nil then
        return
    end

    local campX = -1
    local campY = -1
    if pCamp ~= nil then
        campX = pCamp:GetX() or -1
        campY = pCamp:GetY() or -1
    end
    local entry = string.format(
        "%d;%d;%d;%d;%d;%d",
        triggerPlayerID, iTribe, targetPlayerID, targetCityID, campX, campY)
    local queue = Game:GetProperty(BARB_ASSAULT_NOTIFY_PROP) or ""
    if queue == "" then
        queue = entry
    else
        queue = queue .. "|" .. entry
    end
    Game:SetProperty(BARB_ASSAULT_NOTIFY_PROP, queue)
    print(string.format(
        "[Haikesi GamePlay] BARBARIAN_INVASION notifyQueued tribe=%s -> human=%s city=%s camp(%d,%d)",
        tostring(iTribe), tostring(targetPlayerID), tostring(targetCityID),
        campX, campY))
end

-- 令氏族对指定城市发动攻城（Gameplay 可用；不扣城邦点、不花金币）
local function TryOrderTribeAssaultCity(
    iTribe, targetPlayerID, targetCityID, pCamp, triggerPlayerID)
    if iTribe == nil or iTribe < 0
        or targetPlayerID == nil or targetCityID == nil then
        return false
    end
    local pBarbManager = Game.GetBarbarianManager()
    if pBarbManager == nil or pBarbManager.StartOperationWithCityTarget == nil then
        return false
    end
    local ok, result = pcall(function()
        return pBarbManager:StartOperationWithCityTarget(
            iTribe, BARBARIAN_CITY_ASSAULT_OPERATION, targetPlayerID, targetCityID)
    end)
    local campX = (pCamp ~= nil) and pCamp:GetX() or -1
    local campY = (pCamp ~= nil) and pCamp:GetY() or -1
    print(string.format(
        "[Haikesi GamePlay] BARBARIAN_INVASION assault tribe=%s -> player=%s city=%s "
            .. "camp(%d,%d) ok=%s result=%s",
        tostring(iTribe), tostring(targetPlayerID), tostring(targetCityID),
        campX, campY, tostring(ok), tostring(result)))
    local success = ok == true and (result == true or result == nil)
    if success then
        NotifyBarbarianInvasionAssault(
            triggerPlayerID, iTribe, targetPlayerID, targetCityID, pCamp)
    end
    return success
end

-- 仅向能解析/绑定出部落索引的营地均分补兵（保证入族）
-- 补兵成功后按概率令该氏族进攻被入侵玩家的目标城市
local function SpawnBarbarianUnitsDistributed(
    campPlots, totalCount, targetPlayerID, targetCityID, triggerPlayerID)
    if campPlots == nil or #campPlots == 0 or totalCount <= 0 then
        return 0
    end
    local eligible = {}
    for _, pCamp in ipairs(campPlots) do
        local iTribe = EnsureTribeIndexAtCamp(pCamp)
        if iTribe ~= nil and iTribe >= 0 then
            table.insert(eligible, { plot = pCamp, tribe = iTribe })
        end
    end
    if #eligible == 0 then
        print("[Haikesi GamePlay] BARBARIAN_INVASION distributed: no camps with tribe index")
        return 0
    end
    if #eligible < #campPlots then
        print(string.format(
            "[Haikesi GamePlay] BARBARIAN_INVASION distributed: tribeCamps=%d/%d",
            #eligible, #campPlots))
    end
    local campCount = #eligible
    local base = math.floor(totalCount / campCount)
    local rem = totalCount % campCount
    local spawned = 0
    for i, entry in ipairs(eligible) do
        local n = base + ((i <= rem) and 1 or 0)
        if n > 0 then
            local got = SpawnBarbarianUnitsAtCamp(entry.plot, n)
            spawned = spawned + got
            if got > 0
                and targetPlayerID ~= nil
                and targetCityID ~= nil
                and PickRandomIndex(100, "Haikesi BarbInvasion reinforce assault")
                    < INVASION_REINFORCE_ASSAULT_CHANCE then
                TryOrderTribeAssaultCity(
                    entry.tribe, targetPlayerID, targetCityID, entry.plot,
                    triggerPlayerID)
            end
        end
    end
    return spawned
end

local function SpawnBarbarianUnitsAtCityDistance(centerX, centerY, distance, count)
    local pBarb = GetBarbarianPlayer()
    local unitRow = GameInfo.Units[BARBARIAN_FALLBACK_UNIT]
    if pBarb == nil or unitRow == nil or count <= 0 then
        return 0
    end

    local candidates = {}
    local candidatePlotIDs = {}
    for dx = -distance, distance do
        for dy = -distance, distance do
            local pPlot = Map.GetPlotXY(centerX, centerY, dx, dy)
            if pPlot ~= nil then
                local plotID = pPlot:GetIndex()
                if not candidatePlotIDs[plotID]
                    and Map.GetPlotDistance(centerX, centerY, pPlot:GetX(), pPlot:GetY()) == distance
                    and not pPlot:IsWater()
                    and not pPlot:IsImpassable()
                    and CityManager.GetCityAt(pPlot:GetX(), pPlot:GetY()) == nil then
                    candidatePlotIDs[plotID] = true
                    table.insert(candidates, pPlot)
                end
            end
        end
    end

    local spawned = 0
    while spawned < count and #candidates > 0 do
        local pickIdx = PickRandomIndex(#candidates, "Haikesi BarbInvasion city fallback unit") + 1
        local pPlot = candidates[pickIdx]
        table.remove(candidates, pickIdx)
        local pUnit = pBarb:GetUnits():Create(unitRow.Index, pPlot:GetX(), pPlot:GetY())
        if pUnit ~= nil then
            spawned = spawned + 1
        end
    end
    return spawned
end

local function SpawnBarbarianCampsAtDistance(
    centerX, centerY, iBarbCampIndex, usedPlotIDs, requestedCount)
    local spawnedCamps = {}
    local totalCandidates = 0

    while #spawnedCamps < requestedCount do
        -- 每成功放置一个营地后重新收集候选，确保新营地也参与 7 格间距检查。
        local candidates = GatherBarbarianCampPlotsAtDistance(
            centerX, centerY, INVASION_CAMP_DISTANCE, iBarbCampIndex, usedPlotIDs)
        totalCandidates = totalCandidates + #candidates
        if #candidates == 0 then
            break
        end

        local placedCamp = nil
        while #candidates > 0 and placedCamp == nil do
            local pickIdx = PickRandomIndex(#candidates, "Haikesi BarbInvasion camp") + 1
            local pPlot = candidates[pickIdx]
            table.remove(candidates, pickIdx)
            local plotID = pPlot:GetIndex()
            usedPlotIDs[plotID] = true

            if CanPlaceBarbarianCampWithVanillaSpacing(pPlot, iBarbCampIndex) then
                local placed = PlaceBarbarianCampAtPlot(pPlot, iBarbCampIndex)
                if placed then
                    placedCamp = pPlot
                    table.insert(spawnedCamps, pPlot)
                end
            end
        end
        if placedCamp == nil then
            break
        end
    end
    return spawnedCamps, totalCandidates
end

local function SpawnBarbarianUnitsForAllCities(pPlayer, distance, countPerCity)
    local totalSpawned = 0
    local pCities = pPlayer:GetCities()
    if pCities == nil then return 0 end

    for _, pCity in pCities:Members() do
        if pCity ~= nil then
            local spawned = SpawnBarbarianUnitsAtCityDistance(
                pCity:GetX(), pCity:GetY(), distance, countPerCity)
            totalSpawned = totalSpawned + spawned
            print(string.format(
                "[Haikesi GamePlay] BARBARIAN_INVASION no camps: player=%d city=%d "
                    .. "city(%d,%d) ring=%d units=%d",
                pPlayer:GetID(), pCity:GetID(), pCity:GetX(), pCity:GetY(), distance, spawned))
        end
    end
    return totalSpawned
end

local function Haikesi_SpawnBarbarianInvasionCamps(triggeringAIPlayerID)
    local iBarbCampIndex = GetBarbarianCampImprovementIndex()
    if iBarbCampIndex == nil then
        print("[Haikesi GamePlay] BARBARIAN_INVASION missing improvement index")
        return
    end

    local usedPlotIDs = {}
    local totalCampsSpawned = 0
    local totalUnitsSpawned = 0
    local clansEnabled = IsBarbarianClansModeEnabled()
    -- 从存档合并 plot→tribe；勿整表清空（Gameplay 无 GetTribeIndexAtLocation）
    LoadBarbarianTribeMap()
    local rebuilt = 0
    if clansEnabled then
        rebuilt = RebuildTribeIndexFromNearbyUnits(iBarbCampIndex)
    end
    print(string.format(
        "[Haikesi GamePlay] BARBARIAN_INVASION start clansMode=%s cachedTribes=%d rebuilt=%d",
        tostring(clansEnabled),
        (function()
            local n = 0
            for _ in pairs(g_BarbarianTribeIndexByPlot) do n = n + 1 end
            return n
        end)(),
        rebuilt))

    for _, pPlayer in ipairs(PlayerManager.GetAliveMajors()) do
        if pPlayer ~= nil and not pPlayer:IsBarbarian() and pPlayer:GetID() ~= triggeringAIPlayerID then
            local pCity = GetNewestCityForPlayer(pPlayer)
            if pCity ~= nil then
                local centerX, centerY = pCity:GetX(), pCity:GetY()
                local spawnedCamps, candidateCount = SpawnBarbarianCampsAtDistance(
                    centerX, centerY, iBarbCampIndex, usedPlotIDs,
                    INVASION_CAMPS_PER_PLAYER)
                local spawnedCampCount = #spawnedCamps
                local missingCampCount = INVASION_CAMPS_PER_PLAYER - spawnedCampCount
                local spawnedUnits = 0

                totalCampsSpawned = totalCampsSpawned + spawnedCampCount

                -- 补兵仅在建营失败/不足时：按缺营数均分到已有蛮寨；无营则在城市环上生成
                if missingCampCount > 0 then
                    local requestedUnits = missingCampCount * INVASION_UNITS_PER_MISSING_CAMP
                    local campPlots, campMeta = GatherBarbarianCampsSorted(
                        centerX, centerY, iBarbCampIndex)
                    if #campPlots > 0 then
                        spawnedUnits = SpawnBarbarianUnitsDistributed(
                            campPlots, requestedUnits, pPlayer:GetID(), pCity:GetID(),
                            triggeringAIPlayerID)
                        local nearest = campMeta[1]
                        print(string.format(
                            "[Haikesi GamePlay] BARBARIAN_INVASION targetPlayer=%d city(%d,%d) "
                                .. "missingCamps=%d eligibleCamps=%d nearest(%d,%d) dist=%d "
                                .. "units=%d/%d (distributed)",
                            pPlayer:GetID(), centerX, centerY, missingCampCount, #campPlots,
                            nearest.plot:GetX(), nearest.plot:GetY(), nearest.dist,
                            spawnedUnits, requestedUnits))
                    else
                        spawnedUnits = SpawnBarbarianUnitsForAllCities(
                            pPlayer, INVASION_NO_CAMP_UNIT_DISTANCE,
                            INVASION_UNITS_PER_MISSING_CAMP)
                    end
                    totalUnitsSpawned = totalUnitsSpawned + spawnedUnits
                end

                if spawnedCampCount > 0 then
                    print(string.format(
                        "[Haikesi GamePlay] BARBARIAN_INVASION targetPlayer=%d city(%d,%d) "
                            .. "camps=%d/%d ring=%d candidateChecks=%d",
                        pPlayer:GetID(), centerX, centerY, spawnedCampCount,
                        INVASION_CAMPS_PER_PLAYER, INVASION_CAMP_DISTANCE, candidateCount))
                end
            end
        end
    end

    print(string.format(
        "[Haikesi GamePlay] BARBARIAN_INVASION total camps=%d units=%d",
        totalCampsSpawned, totalUnitsSpawned))
end

--||======================= 三角贸易 (TRIANGULARTRADERUNE) ========================||--
-- Civ6 商路 API：city:GetTrade():GetOutgoingRoutes()（切勿用 Civ5 的 pPlayer:GetTradeRoutes）
local TRIANGULARTRADERUNE = 'TRIANGULARTRADERUNE'
local TRI_TRADE_PROP_KEY = 'PROPERTY_NW_HAIKESI_TRIANGULAR_TRADE'
local TRI_TRADE_MIN_REMAINING_POP = 4
local TRI_TRADE_BASE_POP = 1
-- 仅防「当回合派出又召回」刷人口；短商路自然完成常 <18 回合，门槛不能按全程时长卡
local TRI_TRADE_MIN_ROUTE_TURNS_STANDARD = 3
-- 同盟/宗主商路产出 Modifier（旧存档选过海克斯时需补挂，防重复 Attach）
local TRI_TRADE_YIELD_MODS_PROP = 'PROP_NW_HAIKESI_TRI_TRADE_YIELD_MODS_V1'
local TRI_TRADE_YIELD_MOD_IDS = {
    'MODIFIER_NW_TRIANGULAR_TRADE_ALLY_ORIGIN_PROD',
    'MODIFIER_NW_TRIANGULAR_TRADE_ALLY_DEST_GOLD',
    'MODIFIER_NW_TRIANGULAR_TRADE_SUZ_ORIGIN_PROD',
    'MODIFIER_NW_TRIANGULAR_TRADE_SUZ_DEST_GOLD',
}
local g_TriTradeRouteSnapshot = {}
-- [DEV] 三角贸易监测日志；正式发布可改 false
local TRI_TRADE_DEBUG = true

local function TriTradeLog(fmt, ...)
    if not TRI_TRADE_DEBUG then return end
    print(string.format("[Haikesi TRI] " .. fmt, ...))
end

local function PlayerHasTriangularTradeRelic(pPlayer)
    if pPlayer == nil then return false end
    local prop = pPlayer:GetProperty(TRI_TRADE_PROP_KEY)
    if prop == true or prop == 1 then return true end
    for _, relicType in ipairs(GetSelectedRelicTypeListForPlayer(pPlayer)) do
        if relicType == TRIANGULARTRADERUNE then return true end
    end
    return false
end

-- 旧存档：选海克斯时尚未有同盟/宗主产出 Modifier，读档后补挂一次
local function Haikesi_SyncTriTradeYieldModifiersForPlayer(pPlayer)
    if pPlayer == nil or not PlayerHasTriangularTradeRelic(pPlayer) then
        return false
    end
    if pPlayer:GetProperty(TRI_TRADE_YIELD_MODS_PROP) == 1 then
        return false
    end
    local iPlayer = pPlayer:GetID()
    for _, modId in ipairs(TRI_TRADE_YIELD_MOD_IDS) do
        pPlayer:AttachModifierByID(modId)
        TriTradeLog("sync yield mod %s -> P%d", modId, iPlayer)
    end
    pPlayer:SetProperty(TRI_TRADE_YIELD_MODS_PROP, 1)
    TriTradeLog("sync yield mods done P%d", iPlayer)
    return true
end

local function Haikesi_SyncTriTradeYieldModifiersAll()
    local n = 0
    for iPlayer = 0, 63 do
        local pPlayer = Players[iPlayer]
        if pPlayer ~= nil and pPlayer:IsAlive() and pPlayer:IsMajor() then
            if Haikesi_SyncTriTradeYieldModifiersForPlayer(pPlayer) then
                n = n + 1
            end
        end
    end
    if n > 0 then
        print("[Haikesi TRI] synced ally/suzerain yield mods for " .. tostring(n) .. " player(s)")
    end
end

local function CityTouchesWater(pCity)
    if pCity == nil then return false end
    local okCoastal, isCoastal = pcall(function()
        return pCity:IsCoastal() or pCity:IsCoastalLand()
    end)
    if okCoastal and isCoastal then return true end

    local x, y = pCity:GetX(), pCity:GetY()
    if x == nil or y == nil then return false end
    for dx = -1, 1 do
        for dy = -1, 1 do
            if not (dx == 0 and dy == 0) then
                local pPlot = Map.GetPlot(x + dx, y + dy)
                if pPlot ~= nil and pPlot:IsWater() then
                    return true
                end
            end
        end
    end
    return false
end

local function MakeRouteSig(route)
    return tostring(route.OriginCityID)
        .. '->' .. tostring(route.DestinationCityID)
        .. '@' .. tostring(route.DestinationCityPlayer)
        .. '#' .. tostring(route.TraderUnitID or 0)
end

-- 返回 isSea, reason（供日志）
local function ClassifySeaTradeRoute(route)
    if route == nil then
        return false, "route=nil"
    end

    local tradeManager = Game.GetTradeManager()
    if tradeManager == nil then
        -- 继续回退
    elseif tradeManager.GetTradeRoutePath == nil then
        -- Gameplay 常见：无路径 API
    else
        local ok, pathPlots = pcall(function()
            return tradeManager:GetTradeRoutePath(
                route.OriginCityPlayer,
                route.OriginCityID,
                route.DestinationCityPlayer,
                route.DestinationCityID
            )
        end)
        if not ok then
            -- pcall 失败，走回退
        elseif pathPlots ~= nil then
            local sawWater = false
            local n = 0
            for _, plotIndex in ipairs(pathPlots) do
                n = n + 1
                local pPlot = Map.GetPlotByIndex(plotIndex)
                if pPlot ~= nil and pPlot:IsWater() then
                    sawWater = true
                    break
                end
            end
            if sawWater then
                return true, "path_has_water"
            end
            if n > 0 then
                return false, "path_land_only(plots=" .. tostring(n) .. ")"
            end
        end
    end

    if route.TraderUnitID ~= nil then
        local pOwner = Players[route.OriginCityPlayer]
        if pOwner ~= nil then
            local pUnit = pOwner:GetUnits():FindID(route.TraderUnitID)
            if pUnit ~= nil and pUnit.GetDomainType ~= nil and DomainTypes ~= nil then
                local okDomain, domain = pcall(function()
                    return pUnit:GetDomainType()
                end)
                if okDomain and domain == DomainTypes.DOMAIN_SEA then
                    return true, "trader_domain_sea"
                end
                if okDomain then
                    -- 非海域商人，仍可用临海回退
                end
            end
        end
    end

    local pOrigin = CityManager.GetCity(route.OriginCityPlayer, route.OriginCityID)
    local pDest = CityManager.GetCity(route.DestinationCityPlayer, route.DestinationCityID)
    local originWater = CityTouchesWater(pOrigin)
    local destWater = CityTouchesWater(pDest)
    if originWater or destWater then
        return true, string.format(
            "coastal_fallback(origin=%s,dest=%s)",
            tostring(originWater), tostring(destWater)
        )
    end
    return false, "not_sea(path/domain/coastal all fail)"
end

-- City:GetTrade 仅 UI 可用（见 Sukritact City.md）。Gameplay 禁止扫描商路，
-- 监测与完成检测在 UI/Haikesi_TriTrade_Bridge.lua，经 HaikesiTriTradeComplete 回传。
local function CollectOutgoingInternationalSeaRoutes(_pPlayer, _previousSnapshot, _logDetail)
    TriTradeLog("Gameplay Collect skipped — use UI Haikesi_TriTrade_Bridge")
    return {}
end

local function GetPlayerScienceTotal(pPlayer)
    if pPlayer == nil then return 0 end
    local pTechs = pPlayer:GetTechs()
    if pTechs == nil then return 0 end
    local total = 0
    for row in GameInfo.Technologies() do
        if pTechs:HasTech(row.Index) then
            total = total + (row.Cost or 0)
        end
    end
    return total
end

local function IsAmericaPlayer(iPlayer)
    local civTypeName = select(1, GetPlayerConfigTypes(iPlayer))
    return civTypeName == 'CIVILIZATION_AMERICA'
end

-- 翻倍条件任满其一即 ×2；多条件同时成立不叠加（绝不再乘）
-- 返回 doubled, reason（IsMinor 等 API 用 pcall，避免跨上下文 nil）
local function EvaluateTriangularTradeDouble(iOwnerPlayer, iTargetPlayer)
    local pTarget = Players[iTargetPlayer]
    if pTarget == nil then
        return false, "target_nil"
    end
    local okMinor, isMinor = pcall(function()
        return pTarget:IsMinor()
    end)
    if okMinor and isMinor then
        return true, "dest_is_city_state"
    end
    if not okMinor then
        local okMajor, isMajor = pcall(function()
            return pTarget:IsMajor()
        end)
        if okMajor and isMajor == false then
            return true, "dest_not_major"
        end
    end
    if IsAmericaPlayer(iOwnerPlayer) then
        return true, "owner_is_america"
    end
    local ownerSci = GetPlayerScienceTotal(Players[iOwnerPlayer])
    local targetSci = GetPlayerScienceTotal(pTarget)
    if ownerSci <= 0 then
        return false, string.format("no_double(ownerSci=%d,targetSci=%d)", ownerSci, targetSci)
    end
    if targetSci < (ownerSci * 0.5) then
        return true, string.format(
            "target_sci_below_50pct(ownerSci=%d,targetSci=%d)",
            ownerSci, targetSci
        )
    end
    return false, string.format(
        "no_double(ownerSci=%d,targetSci=%d,need<%.0f)",
        ownerSci, targetSci, ownerSci * 0.5
    )
end

local function Haikesi_GetCityDisplayName(pCity)
    if pCity == nil then return "?" end
    local raw = pCity:GetName()
    if Locale ~= nil and Locale.Lookup ~= nil then
        return Locale.Lookup(raw)
    end
    return tostring(raw)
end

-- 同批多条若都用 USER_DEFINED_1 会互相覆盖，只显示最后一条
local g_TriTradeNotifyBatch = nil -- { playerID=, lines={} }
local g_TriTradeNotifySlot = 0

local function Haikesi_BuildTriTradeNotifyBody(destCityName, lostPop, originCityName, gainedPop, diseaseHit)
    local body = Locale.Lookup(
        "LOC_HAIKESI_TRI_TRADE_NOTIFY_BODY",
        destCityName, lostPop, originCityName, gainedPop
    )
    if diseaseHit then
        body = body .. Locale.Lookup("LOC_HAIKESI_TRI_TRADE_NOTIFY_DISEASE")
    end
    return body
end

local function Haikesi_PickUserDefinedNotifType()
    if NotificationTypes == nil then return nil end
    g_TriTradeNotifySlot = (g_TriTradeNotifySlot % 9) + 1
    local key = "USER_DEFINED_" .. tostring(g_TriTradeNotifySlot)
    return NotificationTypes[key] or NotificationTypes.USER_DEFINED_1
end

local function Haikesi_SendTriTradeNotification(iOwnerPlayer, body, titleSuffix)
    if iOwnerPlayer == nil or body == nil or body == "" then return false end
    local title = Locale.Lookup("LOC_HAIKESI_TRI_TRADE_NOTIFY_TITLE")
    if titleSuffix ~= nil and titleSuffix ~= "" then
        title = title .. titleSuffix
    end
    local notified = false
    if NotificationManager ~= nil and NotificationManager.SendNotification ~= nil then
        local notifType = Haikesi_PickUserDefinedNotifType()
        if notifType ~= nil then
            local ok = pcall(function()
                NotificationManager.SendNotification(iOwnerPlayer, notifType, title, body)
            end)
            notified = ok
        end
    end
    TriTradeLog("notify send P%d ok=%s msg=%s", iOwnerPlayer, tostring(notified), tostring(body))
    return notified
end

-- Gameplay 可用：NotificationManager.SendNotification；批处理时先缓存再合并发送
local function Haikesi_NotifyTriangularTrade(iOwnerPlayer, destCityName, lostPop, originCityName, gainedPop, diseaseHit)
    local body = Haikesi_BuildTriTradeNotifyBody(
        destCityName, lostPop, originCityName, gainedPop, diseaseHit
    )
    if g_TriTradeNotifyBatch ~= nil then
        g_TriTradeNotifyBatch.playerID = iOwnerPlayer
        table.insert(g_TriTradeNotifyBatch.lines, body)
        TriTradeLog(
            "notify buffered #%d disease=%s msg=%s",
            #g_TriTradeNotifyBatch.lines, tostring(diseaseHit), tostring(body)
        )
        return
    end
    Haikesi_SendTriTradeNotification(iOwnerPlayer, body, nil)
end

local function Haikesi_FlushTriTradeNotifyBatch()
    local batch = g_TriTradeNotifyBatch
    g_TriTradeNotifyBatch = nil
    if batch == nil or batch.lines == nil or #batch.lines == 0 then
        return
    end
    local playerID = batch.playerID
    if playerID == nil then return end

    -- 合并为一条，避免同类型覆盖；正文用换行列出每条商路
    local body = table.concat(batch.lines, "[NEWLINE]")
    local suffix = ""
    if #batch.lines > 1 then
        suffix = " (" .. tostring(#batch.lines) .. ")"
    end
    Haikesi_SendTriTradeNotification(playerID, body, suffix)
    TriTradeLog("notify batch flushed lines=%d", #batch.lines)
end

local function Haikesi_ExecuteTriangularTrade(iOwnerPlayer, routeData)
    if routeData == nil then
        TriTradeLog("execute abort: routeData=nil")
        return
    end
    local pOwner = Players[iOwnerPlayer]
    if pOwner == nil or not PlayerHasTriangularTradeRelic(pOwner) then
        TriTradeLog("execute abort: owner P%d missing relic", iOwnerPlayer)
        return
    end

    local iTargetPlayer = routeData.toPlayerID
    local pTargetPlayer = Players[iTargetPlayer]
    if pTargetPlayer == nil then
        TriTradeLog("execute abort: target player nil id=%s", tostring(iTargetPlayer))
        return
    end

    local pOriginCity = CityManager.GetCity(iOwnerPlayer, routeData.fromCityID)
    local pTargetCity = CityManager.GetCity(iTargetPlayer, routeData.toCityID)
    if pOriginCity == nil or pTargetCity == nil then
        TriTradeLog(
            "execute abort: city missing origin=%s dest=%s (P%d city %s -> P%d city %s)",
            tostring(pOriginCity ~= nil), tostring(pTargetCity ~= nil),
            iOwnerPlayer, tostring(routeData.fromCityID),
            iTargetPlayer, tostring(routeData.toCityID)
        )
        return
    end

    local originPopBefore = pOriginCity:GetPopulation()
    local targetPopBefore = pTargetCity:GetPopulation()
    TriTradeLog(
        "execute check P%d city%d(pop=%d) <- P%d city%d(pop=%d) minRemain=%d",
        iOwnerPlayer, routeData.fromCityID, originPopBefore,
        iTargetPlayer, routeData.toCityID, targetPopBefore,
        TRI_TRADE_MIN_REMAINING_POP
    )

    if targetPopBefore < TRI_TRADE_MIN_REMAINING_POP then
        TriTradeLog(
            "execute REJECT dest_pop=%d < minRemain=%d",
            targetPopBefore, TRI_TRADE_MIN_REMAINING_POP
        )
        return
    end

    local baseAmount = ScalePopForGameSpeed(TRI_TRADE_BASE_POP)
    local doubled, doubleReason = EvaluateTriangularTradeDouble(iOwnerPlayer, iTargetPlayer)
    local amount = baseAmount
    if doubled then
        amount = amount * 2
    end

    local maxTransfer = targetPopBefore - TRI_TRADE_MIN_REMAINING_POP
    local amountBeforeCap = amount
    if maxTransfer < 1 then
        TriTradeLog("execute REJECT maxTransfer=%d (dest would drop below minRemain)", maxTransfer)
        return
    end
    amount = math.min(amount, maxTransfer)

    TriTradeLog(
        "execute amount base=%d doubled=%s(%s) capped=%d->%d (maxTransfer=%d)",
        baseAmount, tostring(doubled), tostring(doubleReason),
        amountBeforeCap, amount, maxTransfer
    )

    -- Civ6：ChangePopulation 仅接受增量，无第二参数（勿用 Civ5 的 ChangePopulation(n, true)）
    local okLoss = pcall(function()
        pTargetCity:ChangePopulation(-amount)
    end)
    if not okLoss then
        TriTradeLog("execute FAIL ChangePopulation(-%d) on dest", amount)
        return
    end
    local okGain = pcall(function()
        pOriginCity:ChangePopulation(amount)
    end)
    if not okGain then
        pcall(function()
            pTargetCity:ChangePopulation(amount)
        end)
        TriTradeLog("execute FAIL ChangePopulation(+%d) on origin; dest reverted", amount)
        return
    end

    local originPopAfterTrade = pOriginCity:GetPopulation()
    local targetPopAfter = pTargetCity:GetPopulation()
    TriTradeLog(
        "execute OK transfer=%d | origin P%d city%d %d->%d | dest P%d city%d %d->%d",
        amount,
        iOwnerPlayer, routeData.fromCityID, originPopBefore, originPopAfterTrade,
        iTargetPlayer, routeData.toCityID, targetPopBefore, targetPopAfter
    )

    -- 33%：疾病路途，出发城再失去 1 人口（Gameplay 同步 RNG，与其他海克斯一致）
    local diseaseRoll = PickRandomIndex(3, "Haikesi_TriTrade_Disease")
    local diseaseHit = (diseaseRoll == 0)
    local originGained = amount
    TriTradeLog("disease roll=%d hit=%s (0=yes, 1/3)", diseaseRoll, tostring(diseaseHit))
    if diseaseHit then
        if originPopAfterTrade > 1 then
            local okDisease = pcall(function()
                pOriginCity:ChangePopulation(-1)
            end)
            if okDisease then
                originGained = amount - 1
                TriTradeLog(
                    "disease OK origin P%d city%d %d->%d netGain=%d",
                    iOwnerPlayer, routeData.fromCityID,
                    originPopAfterTrade, pOriginCity:GetPopulation(), originGained
                )
            else
                diseaseHit = false
                TriTradeLog("disease FAIL ChangePopulation(-1); treat as no disease for notify")
            end
        else
            diseaseHit = false
            TriTradeLog("disease skip: origin pop would drop below 1")
        end
    end

    local destName = Haikesi_GetCityDisplayName(pTargetCity)
    local originName = Haikesi_GetCityDisplayName(pOriginCity)
    -- gainedPop 用净获得（已扣疾病）；疾病句仍单独提示原因
    Haikesi_NotifyTriangularTrade(
        iOwnerPlayer, destName, amount, originName, originGained, diseaseHit
    )
end

-- UI→GP 三角贸易队列：纯数字串，走已验证的 HaikesiSelectRelic EXECUTE_SCRIPT
-- 格式: owner,fromCity,toPlayer,toCity;owner,...
-- 逐条 pcall，单条失败不阻断同批后续（如瓦莱塔）
function Haikesi_ProcessTriTradeQueue(queueStr)
    if queueStr == nil or queueStr == "" then
        return 0
    end
    TriTradeLog("ProcessTriTradeQueue raw=%s", tostring(queueStr))
    local entries = {}
    for entry in string.gmatch(queueStr, "[^;]+") do
        table.insert(entries, entry)
    end
    TriTradeLog("ProcessTriTradeQueue queued=%d (settle one-by-one)", #entries)

    -- 同批通知先缓存，结算完合并弹一条（避免 USER_DEFINED_1 互相覆盖）
    g_TriTradeNotifyBatch = { playerID = nil, lines = {} }

    local n = 0
    for i, entry in ipairs(entries) do
        local ownerS, fromS, toPS, toCS = string.match(entry, "^(%d+),(%d+),(%d+),(%d+)$")
        if ownerS == nil then
            TriTradeLog("ProcessTriTradeQueue [%d/%d] bad entry=%s", i, #entries, tostring(entry))
        else
            TriTradeLog(
                "ProcessTriTradeQueue [%d/%d] settle P%s city%s <- P%s city%s",
                i, #entries, ownerS, fromS, toPS, toCS
            )
            local ok, err = pcall(function()
                Haikesi_TriTradeCompleteOne(
                    tonumber(ownerS), tonumber(fromS), tonumber(toPS), tonumber(toCS),
                    "SelectRelic.TriTradeQueue#" .. tostring(i)
                )
            end)
            if ok then
                n = n + 1
                TriTradeLog("ProcessTriTradeQueue [%d/%d] OK", i, #entries)
            else
                TriTradeLog(
                    "ProcessTriTradeQueue [%d/%d] FAIL err=%s (continue queue)",
                    i, #entries, tostring(err)
                )
            end
        end
    end

    Haikesi_FlushTriTradeNotifyBatch()
    TriTradeLog("ProcessTriTradeQueue done ok=%d / total=%d", n, #entries)
    return n
end

-- UI 桥接入口：支持单条或 Routes[] 批量（TurnEnd 同帧多条 EXECUTE_SCRIPT 会被吞）
function Haikesi_TriTradeCompleteOne(ownerPlayer, fromCityID, toPlayerID, toCityID, callerTag)
    ownerPlayer = tonumber(ownerPlayer)
    fromCityID = tonumber(fromCityID)
    toPlayerID = tonumber(toPlayerID)
    toCityID = tonumber(toCityID)
    if ownerPlayer == nil or fromCityID == nil or toPlayerID == nil or toCityID == nil then
        TriTradeLog(
            "completeOne abort bad ids owner=%s from=%s toP=%s toC=%s via=%s",
            tostring(ownerPlayer), tostring(fromCityID), tostring(toPlayerID), tostring(toCityID),
            tostring(callerTag)
        )
        return false
    end
    TriTradeLog(
        "completeOne owner=P%d fromCity=%d to=P%d city=%d via=%s",
        ownerPlayer, fromCityID, toPlayerID, toCityID, tostring(callerTag)
    )
    Haikesi_ExecuteTriangularTrade(ownerPlayer, {
        fromPlayerID = ownerPlayer,
        toPlayerID = toPlayerID,
        fromCityID = fromCityID,
        toCityID = toCityID,
    })
    return true
end

function HaikesiTriTradeComplete(iPlayer, param)
    TriTradeLog("HaikesiTriTradeComplete ENTER caller=P%s param=%s", tostring(iPlayer), tostring(param ~= nil))
    if param == nil then
        TriTradeLog("HaikesiTriTradeComplete abort: param=nil")
        return
    end

    if param.Routes ~= nil then
        local n = 0
        for _, route in ipairs(param.Routes) do
            if route ~= nil then
                Haikesi_TriTradeCompleteOne(
                    route.OwnerPlayer or param.OwnerPlayer or iPlayer,
                    route.FromCityID,
                    route.ToPlayerID,
                    route.ToCityID,
                    "EXECUTE_SCRIPT.Routes"
                )
                n = n + 1
            end
        end
        TriTradeLog("HaikesiTriTradeComplete batch done count=%d", n)
        return
    end

    Haikesi_TriTradeCompleteOne(
        param.OwnerPlayer or iPlayer,
        param.FromCityID,
        param.ToPlayerID,
        param.ToCityID,
        "EXECUTE_SCRIPT.single"
    )
end

-- UI 直调（避免 TurnEnd 时 EXECUTE_SCRIPT 丢事件）；Gameplay 定义，供 ExposedMembers
function Haikesi_TriTradeCompleteFromUI(routesOrOwner, fromCityID, toPlayerID, toCityID)
    if type(routesOrOwner) == "table" then
        local n = 0
        for _, route in ipairs(routesOrOwner) do
            if route ~= nil then
                Haikesi_TriTradeCompleteOne(
                    route.OwnerPlayer,
                    route.FromCityID,
                    route.ToPlayerID,
                    route.ToCityID,
                    "ExposedMembers"
                )
                n = n + 1
            end
        end
        TriTradeLog("FromUI batch done count=%d", n)
        return n
    end
    Haikesi_TriTradeCompleteOne(routesOrOwner, fromCityID, toPlayerID, toCityID, "ExposedMembers")
    return 1
end

local function CountRouteTable(t)
    local n = 0
    if t == nil then return 0 end
    for _ in pairs(t) do n = n + 1 end
    return n
end

-- 对比快照：消失且存活够久 → 视为完成并结算。TurnBegin/TurnEnd 都必须跑，
-- 否则回合中完成时 TurnEnd 会直接覆盖快照，下一回合再也检测不到。
local function Haikesi_TriTrade_ProcessSnapshotDiff(iPlayer, pPlayer, phase)
    local minLivedTurns = ScaleTurnForGameSpeed(TRI_TRADE_MIN_ROUTE_TURNS_STANDARD) or TRI_TRADE_MIN_ROUTE_TURNS_STANDARD
    local currentTurn = Game.GetCurrentGameTurn()
    local prevRoutes = g_TriTradeRouteSnapshot[iPlayer] or {}
    local nowRoutes = CollectOutgoingInternationalSeaRoutes(pPlayer, prevRoutes, true)

    TriTradeLog(
        "%s turn=%d P%d snapshot prev=%d now=%d minLived=%d",
        tostring(phase), currentTurn, iPlayer,
        CountRouteTable(prevRoutes), CountRouteTable(nowRoutes), minLivedTurns
    )

    for sig, route in pairs(nowRoutes) do
        local lived = currentTurn - (route.firstSeenTurn or currentTurn)
        TriTradeLog(
            "%s P%d ACTIVE sig=%s lived=%d firstSeen=%d sea=%s",
            tostring(phase), iPlayer, sig, lived,
            tonumber(route.firstSeenTurn) or -1,
            tostring(route.seaReason or "?")
        )
    end

    for sig, oldRoute in pairs(prevRoutes) do
        if nowRoutes[sig] == nil then
            local lived = currentTurn - (oldRoute.firstSeenTurn or currentTurn)
            if lived >= minLivedTurns then
                TriTradeLog(
                    "%s P%d COMPLETE sig=%s lived=%d >= min=%d → try transfer",
                    tostring(phase), iPlayer, sig, lived, minLivedTurns
                )
                Haikesi_ExecuteTriangularTrade(iPlayer, oldRoute)
            else
                TriTradeLog(
                    "%s P%d DROP_TOO_SOON sig=%s lived=%d < min=%d (recall/cancel?)",
                    tostring(phase), iPlayer, sig, lived, minLivedTurns
                )
            end
        end
    end

    g_TriTradeRouteSnapshot[iPlayer] = nowRoutes
end

local function Haikesi_TriTrade_OnTurnEnd()
    for iPlayer = 0, 63 do
        local pPlayer = Players[iPlayer]
        if pPlayer ~= nil and pPlayer:IsAlive() and pPlayer:IsMajor() and PlayerHasTriangularTradeRelic(pPlayer) then
            Haikesi_TriTrade_ProcessSnapshotDiff(iPlayer, pPlayer, "TurnEnd")
        end
    end
end

local function Haikesi_TriTrade_OnTurnBegin()
    for iPlayer = 0, 63 do
        local pPlayer = Players[iPlayer]
        if pPlayer ~= nil and pPlayer:IsAlive() and pPlayer:IsMajor() and PlayerHasTriangularTradeRelic(pPlayer) then
            Haikesi_TriTrade_ProcessSnapshotDiff(iPlayer, pPlayer, "TurnBegin")
        end
    end
end

-- 读档后内存快照为空：为已拥有三角贸易的玩家重建；firstSeen 回拨 minLived，避免读档后还要再等一整段
local function Haikesi_TriTrade_RebuildSnapshotsOnLoad()
    local currentTurn = Game.GetCurrentGameTurn()
    local minLivedTurns = ScaleTurnForGameSpeed(TRI_TRADE_MIN_ROUTE_TURNS_STANDARD) or TRI_TRADE_MIN_ROUTE_TURNS_STANDARD
    local syntheticFirst = math.max(0, currentTurn - minLivedTurns)
    local rebuiltPlayers = 0

    for iPlayer = 0, 63 do
        local pPlayer = Players[iPlayer]
        if pPlayer ~= nil and pPlayer:IsAlive() and pPlayer:IsMajor() and PlayerHasTriangularTradeRelic(pPlayer) then
            local routes = CollectOutgoingInternationalSeaRoutes(pPlayer, {}, true)
            for sig, route in pairs(routes) do
                route.firstSeenTurn = syntheticFirst
                TriTradeLog(
                    "load rebuild P%d sig=%s firstSeen=%d (synthetic, turn=%d)",
                    iPlayer, sig, syntheticFirst, currentTurn
                )
            end
            g_TriTradeRouteSnapshot[iPlayer] = routes
            rebuiltPlayers = rebuiltPlayers + 1
            TriTradeLog(
                "load rebuild P%d tracked=%d prop=%s",
                iPlayer, CountRouteTable(routes),
                tostring(pPlayer:GetProperty(TRI_TRADE_PROP_KEY))
            )
        end
    end
    TriTradeLog("load rebuild done playersWithRelic=%d turn=%d", rebuiltPlayers, currentTurn)
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
    -- ==============================
    if relicType == BARBARIAN_INVASION_RELIC then
        Haikesi_SpawnBarbarianInvasionCamps(iPlayer)
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
    -- TRIANGULARTRADERUNE 三角贸易：Marker+同盟/宗主产出已挂；人口转移见 UI 桥接
    -- ==============================
    if relicType == TRIANGULARTRADERUNE then
        pPlayer:SetProperty(TRI_TRADE_YIELD_MODS_PROP, 1)
        TriTradeLog(
            "relic enabled P%d turn=%d — route scan/logs via UI TriTrade_Bridge",
            iPlayer, Game.GetCurrentGameTurn()
        )
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

    -- 三角贸易商路扫描在 UI/Haikesi_TriTrade_Bridge（GetTrade 仅 UI）
    GameEvents.HaikesiTriTradeComplete.Add(HaikesiTriTradeComplete)
    ExposedMembers.HaikesiTriTradeCompleteFromUI = Haikesi_TriTradeCompleteFromUI
    print("[Haikesi GamePlay] TriTrade ExposedMembers bridge ready")

    -- 外部 AI：主机 FireTuner Stage → UI 广播；初始化暂存槽
    ExposedMembers.Haikesi_ExtAIStagedPayload = nil
    ExposedMembers.Haikesi_ExtAIStagedSeq = 0
    print("[Haikesi GamePlay] ExtAI ExposedMembers stage slot ready")

    -- 旧存档补挂同盟/宗主商路产出（仅 Attach 过一次的不会重复）
    Haikesi_SyncTriTradeYieldModifiersAll()

    -- 种地仙人种植已拆至 Haikesi_Planter_GamePlay.lua（避免主脚本 local 寄存器溢出）

    print("[Haikesi GamePlay] Script 初始化完成")
end

Events.LoadScreenClose.Add(Initialize)
