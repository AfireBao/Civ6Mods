-- ===========================================================================
-- Haikesi_ExtAI_AgePick.lua
-- 黄金/英雄时代 AI 双选：轮次标记、候选数量、choice 拆合（wire: REL1+REL2）
-- 独立文件以降低主脚本 local 寄存器压力。
--
-- 注意：Game.GetEras():HasGoldenAge / HasHeroicGoldenAge 为 InGame-only，
-- Gameplay(GameCore) 直接调用会失败→永远 NORMAL。须先经 UI
-- ExposedMembers.Haikesi_RefreshExtAIUICache 写入 Haikesi_UIEraAgeByPlayer /
-- PROP_NW_HAIKESI_UI_ERA_AGE_*，再读戳记。
-- ===========================================================================

local AI_SELECT_ROUND_KEY = 'PROP_NW_HAIKESI_AI_SELECT_ROUND'
local ERA_AGE_PROP_PREFIX = 'PROP_NW_HAIKESI_UI_ERA_AGE_'
local EXT_AI_OPTIONS_SINGLE = 3
local EXT_AI_OPTIONS_DUAL = 6

-- InGame 直播询（UI 或 EM 回调上下文）；GameCore 常全部 pcall 失败 → nil
function Haikesi_ReadLiveEraAgeLabel(playerID)
    if playerID == nil then
        return nil
    end
    local eras = Game.GetEras()
    if eras == nil then
        return nil
    end
    local anyOk = false
    local okH, heroic = pcall(function()
        return eras:HasHeroicGoldenAge(playerID)
    end)
    if okH then
        anyOk = true
        if heroic then
            return "HEROIC"
        end
    end
    okH, heroic = pcall(function()
        return eras:HasHeroicAge(playerID)
    end)
    if okH then
        anyOk = true
        if heroic then
            return "HEROIC"
        end
    end
    local okG, golden = pcall(function()
        return eras:HasGoldenAge(playerID)
    end)
    if okG then
        anyOk = true
        if golden then
            return "GOLDEN"
        end
    end
    local okD, dark = pcall(function()
        return eras:HasDarkAge(playerID)
    end)
    if okD then
        anyOk = true
        if dark then
            return "DARK"
        end
    end
    if anyOk then
        return "NORMAL"
    end
    return nil
end

function Haikesi_PlayerAgeLabel(playerID)
    if playerID == nil then
        return "NORMAL"
    end
    -- 1) UI 戳记（InGame 刷缓存写入）
    if ExposedMembers ~= nil and ExposedMembers.Haikesi_UIEraAgeByPlayer ~= nil then
        local stamped = ExposedMembers.Haikesi_UIEraAgeByPlayer[playerID]
        if stamped == nil then
            stamped = ExposedMembers.Haikesi_UIEraAgeByPlayer[tostring(playerID)]
        end
        if stamped ~= nil and tostring(stamped) ~= "" then
            return tostring(stamped)
        end
    end
    local prop = Game:GetProperty(ERA_AGE_PROP_PREFIX .. tostring(playerID))
    if prop ~= nil and tostring(prop) ~= "" then
        return tostring(prop)
    end
    -- 2) 直播询（仅 InGame 可靠）
    local live = Haikesi_ReadLiveEraAgeLabel(playerID)
    if live ~= nil then
        return live
    end
    return "NORMAL"
end

function Haikesi_PlayerIsGoldenOrHeroicAge(playerID)
    local label = Haikesi_PlayerAgeLabel(playerID)
    return label == "GOLDEN" or label == "HEROIC"
end

function Haikesi_AIPickCountForPlayer(pPlayer)
    if pPlayer == nil then
        return 1
    end
    if Haikesi_PlayerIsGoldenOrHeroicAge(pPlayer:GetID()) then
        return 2
    end
    return 1
end

function Haikesi_AIOptionsCountForPlayer(pPlayer)
    if Haikesi_AIPickCountForPlayer(pPlayer) >= 2 then
        return EXT_AI_OPTIONS_DUAL
    end
    return EXT_AI_OPTIONS_SINGLE
end

-- value: "A" / "A+B" / {"A","B"}
function Haikesi_SplitChoiceRelics(value)
    local list = {}
    if value == nil then
        return list
    end
    if type(value) == "table" then
        for _, item in ipairs(value) do
            if item ~= nil and tostring(item) ~= "" then
                table.insert(list, tostring(item))
            end
        end
        return list
    end
    local s = tostring(value)
    if s == "" then
        return list
    end
    for item in string.gmatch(s, "[^+]+") do
        if item ~= "" then
            table.insert(list, item)
        end
    end
    return list
end

function Haikesi_JoinChoiceRelics(relics)
    if relics == nil or #relics == 0 then
        return nil
    end
    return table.concat(relics, "+")
end

-- 已完成的 AI 选卡轮次（与人类 SELECT 轮次对齐；双选仍只 +1 轮）
-- 旧档无属性时回退到 relic 数量（双选前 1:1）
function Haikesi_GetAISelectRound(pAI)
    if pAI == nil then
        return 0
    end
    local marked = pAI:GetProperty(AI_SELECT_ROUND_KEY)
    if marked ~= nil then
        return tonumber(marked) or 0
    end
    if type(Haikesi_GetPlayerRelicCount) == "function" then
        return Haikesi_GetPlayerRelicCount(pAI)
    end
    return tonumber(pAI:GetProperty('PROP_NW_HAIKESI_RELIC_COUNT') or 0) or 0
end

function Haikesi_SetAISelectRound(pAI, roundNum)
    if pAI == nil or roundNum == nil then
        return
    end
    pAI:SetProperty(AI_SELECT_ROUND_KEY, tonumber(roundNum) or 0)
end

print("[Haikesi AgePick] golden/heroic dual-pick helpers ready")

if ExposedMembers ~= nil then
    ExposedMembers.Haikesi_PlayerIsGoldenOrHeroicAge = Haikesi_PlayerIsGoldenOrHeroicAge
    ExposedMembers.Haikesi_PlayerAgeLabel = Haikesi_PlayerAgeLabel
    ExposedMembers.Haikesi_AIPickCountForPlayer = Haikesi_AIPickCountForPlayer
    ExposedMembers.Haikesi_AIOptionsCountForPlayer = Haikesi_AIOptionsCountForPlayer
    ExposedMembers.Haikesi_SplitChoiceRelics = Haikesi_SplitChoiceRelics
    ExposedMembers.Haikesi_JoinChoiceRelics = Haikesi_JoinChoiceRelics
    ExposedMembers.Haikesi_GetAISelectRound = Haikesi_GetAISelectRound
    ExposedMembers.Haikesi_SetAISelectRound = Haikesi_SetAISelectRound
    ExposedMembers.Haikesi_ReadLiveEraAgeLabel = Haikesi_ReadLiveEraAgeLabel
end
