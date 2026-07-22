-- ===========================================================================
-- Haikesi_ExtAI_Bridge.lua
-- 主机权威：FireTuner Stage → ExposedMembers → 本桥接 EXECUTE_SCRIPT 广播 ExtAIApply
-- ===========================================================================

local g_LastBroadcastSeq = 0

local function IsGameHost()
    if Network ~= nil and Network.IsGameHost ~= nil then
        return Network.IsGameHost()
    end
    local function probe(fn)
        if type(fn) ~= "function" then
            return false
        end
        local ok, v = pcall(fn)
        return ok and v == true
    end
    if GameConfiguration ~= nil and (
        probe(GameConfiguration.IsAnyMultiplayer)
        or probe(GameConfiguration.IsNetworkMultiplayer)
        or probe(GameConfiguration.IsLANMultiplayer)
        or probe(GameConfiguration.IsHotseat)
    ) then
        return false
    end
    if Game ~= nil and probe(Game.IsNetworkMultiplayer) then
        return false
    end
    return true
end

local function BroadcastExtAIApply(payload)
    local localPlayer = Game.GetLocalPlayer()
    if localPlayer == nil or localPlayer < 0 then
        print("[Haikesi ExtAI UI] broadcast skip: no local player")
        return false
    end
    local param = {}
    param['OnStart'] = 'HaikesiSelectRelic'
    param['ExtAIApply'] = payload
    UI.RequestPlayerOperation(localPlayer, PlayerOperations.EXECUTE_SCRIPT, param)
    print("[Haikesi ExtAI UI] broadcast ExtAIApply len=" .. tostring(#payload))
    return true
end

local function ProcessStagedExtAI()
    if not IsGameHost() then
        return
    end
    if ExposedMembers == nil then
        return
    end
    local seq = tonumber(ExposedMembers.Haikesi_ExtAIStagedSeq) or 0
    local payload = ExposedMembers.Haikesi_ExtAIStagedPayload
    if seq <= g_LastBroadcastSeq then
        return
    end
    if payload == nil or payload == "" then
        g_LastBroadcastSeq = seq
        return
    end

    -- 先清暂存再广播，避免同帧重复发送
    ExposedMembers.Haikesi_ExtAIStagedPayload = nil
    g_LastBroadcastSeq = seq
    BroadcastExtAIApply(tostring(payload))
end

local function OnLoadScreenClose()
    g_LastBroadcastSeq = tonumber(ExposedMembers and ExposedMembers.Haikesi_ExtAIStagedSeq) or 0
    if ExposedMembers ~= nil then
        ExposedMembers.Haikesi_ExtAIStagedPayload = nil
    end
end

local function Initialize()
    Events.LoadScreenClose.Add(OnLoadScreenClose)
    Events.LocalPlayerTurnBegin.Add(ProcessStagedExtAI)
    if LuaEvents ~= nil then
        LuaEvents.Haikesi_ExtAIStagedUI.Add(ProcessStagedExtAI)
    end
    print("[Haikesi ExtAI UI] host broadcast bridge ready (event-driven)")
end

Initialize()
