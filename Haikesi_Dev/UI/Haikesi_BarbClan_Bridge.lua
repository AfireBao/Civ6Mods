-- ===========================================================================
-- Haikesi_BarbClan_Bridge.lua
-- Gameplay 将南蛮入侵攻城通知入队；本桥接在 UI 侧用 GetTribeNameType 取氏族专名后发送。
-- ===========================================================================

local BARB_ASSAULT_NOTIFY_PROP = 'PROP_NW_HAIKESI_BARB_ASSAULT_NOTIFY'
local g_AssaultNotifyCursor = 0

local function SplitQueue(raw)
    local entries = {}
    if raw == nil or raw == "" then
        return entries
    end
    for entry in string.gmatch(raw, "[^|]+") do
        table.insert(entries, entry)
    end
    return entries
end

local function ResolveTribeNameRow(nameType)
    if nameType == nil then
        return nil
    end
    local row = GameInfo.BarbarianTribeNames[nameType]
    if row ~= nil then
        return row
    end
    if type(nameType) == "number" then
        for r in GameInfo.BarbarianTribeNames() do
            if r.Index == nameType then
                return r
            end
        end
    end
    return nil
end

-- UI 可用：优先营地坐标反查部落索引，再取专名 LOC
local function ResolveClanProperName(iTribe, campX, campY)
    local pBarbManager = Game.GetBarbarianManager()
    if pBarbManager == nil or pBarbManager.GetTribeNameType == nil then
        return Locale.Lookup("LOC_HAIKESI_BARB_INVASION_CLAN_FALLBACK")
    end

    local tribeIndex = iTribe
    if campX ~= nil and campY ~= nil and campX >= 0 and campY >= 0
        and pBarbManager.GetTribeIndexAtLocation ~= nil then
        local okIdx, atLoc = pcall(function()
            return pBarbManager:GetTribeIndexAtLocation(campX, campY)
        end)
        if okIdx and atLoc ~= nil and type(atLoc) == "number" and atLoc >= 0 then
            tribeIndex = atLoc
        end
    end

    if tribeIndex == nil or tribeIndex < 0 then
        return Locale.Lookup("LOC_HAIKESI_BARB_INVASION_CLAN_FALLBACK")
    end

    local ok, nameType = pcall(function()
        return pBarbManager:GetTribeNameType(tribeIndex)
    end)
    if not ok or nameType == nil then
        return Locale.Lookup("LOC_HAIKESI_BARB_INVASION_CLAN_FALLBACK")
    end
    if type(nameType) == "number" and nameType < 0 then
        return Locale.Lookup("LOC_HAIKESI_BARB_INVASION_CLAN_FALLBACK")
    end

    local nameRow = ResolveTribeNameRow(nameType)
    if nameRow ~= nil and nameRow.TribeDisplayName ~= nil then
        return Locale.Lookup(nameRow.TribeDisplayName)
    end
    return Locale.Lookup("LOC_HAIKESI_BARB_INVASION_CLAN_FALLBACK")
end

local function GetPlayerLeaderDisplayName(playerID)
    if playerID == nil or PlayerConfigurations[playerID] == nil then
        return "?"
    end
    return Locale.Lookup(PlayerConfigurations[playerID]:GetLeaderName())
end

local function GetCityDisplayName(playerID, cityID)
    local pPlayer = Players[playerID]
    if pPlayer == nil or cityID == nil then
        return "?"
    end
    local pCity = pPlayer:GetCities():FindID(cityID)
    if pCity == nil then
        return "?"
    end
    return Locale.Lookup(pCity:GetName())
end

local function SendAssaultNotification(triggerPlayerID, iTribe, targetPlayerID, targetCityID, campX, campY)
    if NotificationManager == nil or NotificationManager.SendNotification == nil then
        return
    end
    local notifType = NotificationTypes and NotificationTypes.CLAN_INCITED or nil
    if notifType == nil then
        return
    end

    local leaderName = GetPlayerLeaderDisplayName(triggerPlayerID)
    local clanName = ResolveClanProperName(iTribe, campX, campY)
    local cityName = GetCityDisplayName(targetPlayerID, targetCityID)
    local title = Locale.Lookup("LOC_HAIKESI_BARB_INVASION_ASSAULT_TITLE")
    local body
    if campX ~= nil and campY ~= nil and campX >= 0 and campY >= 0 then
        body = Locale.Lookup(
            "LOC_HAIKESI_BARB_INVASION_ASSAULT_SUMMARY_XY",
            leaderName, clanName, campX, campY, cityName)
    else
        body = Locale.Lookup(
            "LOC_HAIKESI_BARB_INVASION_ASSAULT_SUMMARY",
            leaderName, clanName, cityName)
    end

    pcall(function()
        NotificationManager.SendNotification(targetPlayerID, notifType, title, body)
    end)
    print(string.format(
        "[Haikesi BarbClan UI] BARBARIAN_INVASION notify: %s", tostring(body)))
end

local function ProcessAssaultNotifyQueue()
    local raw = Game:GetProperty(BARB_ASSAULT_NOTIFY_PROP) or ""
    local entries = SplitQueue(raw)
    if #entries <= g_AssaultNotifyCursor then
        return
    end

    local localPlayer = Game.GetLocalPlayer()
    for i = g_AssaultNotifyCursor + 1, #entries do
        local triggerStr, tribeStr, targetStr, cityStr, xStr, yStr = string.match(
            entries[i], "^(%-?%d+);(%-?%d+);(%-?%d+);(%-?%d+);(%-?%d+);(%-?%d+)$")
        local triggerPlayerID = tonumber(triggerStr)
        local iTribe = tonumber(tribeStr)
        local targetPlayerID = tonumber(targetStr)
        local targetCityID = tonumber(cityStr)
        local campX = tonumber(xStr)
        local campY = tonumber(yStr)
        if targetPlayerID ~= nil and localPlayer == targetPlayerID then
            SendAssaultNotification(
                triggerPlayerID, iTribe, targetPlayerID, targetCityID, campX, campY)
        end
    end
    g_AssaultNotifyCursor = #entries
end

local function OnLoadScreenClose()
    -- 读档后跳过历史队列，避免重复弹旧通知
    local entries = SplitQueue(Game:GetProperty(BARB_ASSAULT_NOTIFY_PROP) or "")
    g_AssaultNotifyCursor = #entries
end

local function Initialize()
    Events.LoadScreenClose.Add(OnLoadScreenClose)
    Events.GameCoreEventPublishComplete.Add(ProcessAssaultNotifyQueue)
    print("[Haikesi BarbClan UI] assault notify bridge ready")
end

Initialize()
