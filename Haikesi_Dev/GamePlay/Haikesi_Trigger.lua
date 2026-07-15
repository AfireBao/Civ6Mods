-- ===========================================================================
-- Haikesi_Trigger.lua — 海克斯大乱斗 选择次数追踪
-- 注意：触发逻辑在 UI Panel 中（避免 PROP 同步延迟）
-- ===========================================================================

--||======================= 选择后递增计数 ========================||--
function OnRelicSelected(playerID, param)
    -- 三角贸易结算借用 HaikesiSelectRelic 通道，不计入选择次数
    if param ~= nil and param.TriTradeQueue ~= nil and tostring(param.TriTradeQueue) ~= "" then
        return
    end
    -- 外部大模型 AI 海克斯落地（ExtAIApply）同通道广播，绝不能递增人类选卡次数；
    -- 否则 SELECT_COUNT 虚高 → 下次 Sync 会确定性补齐+LLM 各发一轮，AI 同回合得两张。
    if param ~= nil and param.ExtAIApply ~= nil and tostring(param.ExtAIApply) ~= "" then
        return
    end
    local pPlayer = Players[playerID]
    if pPlayer == nil then
        print("[Haikesi Trigger] 错误: OnRelicSelected — 无效玩家ID: " .. tostring(playerID))
        return
    end
    local count = pPlayer:GetProperty('PROP_NW_HAIKESI_SELECT_COUNT') or 0
    pPlayer:SetProperty('PROP_NW_HAIKESI_SELECT_COUNT', count + 1)
    -- PVE模式：记录本次选择时的时代，供下次触发判断是否进入新时代
    local currentEra = pPlayer:GetEra()
    pPlayer:SetProperty('PROP_NW_HAIKESI_PVE_ERA', currentEra)
    print("[Haikesi Trigger] 玩家" .. playerID .. " 确认选择，次数=" .. (count + 1) .. "，时代=" .. currentEra)
end

--||======================= INIT ========================||--
function Initialize()
    GameEvents.HaikesiSelectRelic.Add(OnRelicSelected)
    print("[Haikesi Trigger] 选择次数追踪初始化完成")
end

Events.LoadScreenClose.Add(Initialize)
