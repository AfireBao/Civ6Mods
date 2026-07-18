-- ===========================================================================
-- Haikesi_TriTrade_Bridge.lua
-- City:GetTrade / GetOutgoingRoutes 仅 UI Context 可用；Gameplay 调用会 Runtime Error。
-- 本桥接在 UI 侧扫描国际海路、打监测日志，完成时经 EXECUTE_SCRIPT 交 Gameplay 结算。
-- ===========================================================================

local TRIANGULARTRADERUNE = 'TRIANGULARTRADERUNE'
local TRI_TRADE_PROP_KEY = 'PROPERTY_NW_HAIKESI_TRIANGULAR_TRADE'
local TRI_TRADE_MIN_ROUTE_TURNS_STANDARD = 3
local TRI_TRADE_DEBUG = true

local g_TriTradeRouteSnapshot = {}

local function TriTradeLog(fmt, ...)
    if not TRI_TRADE_DEBUG then return end
    print(string.format("[Haikesi TRI] " .. fmt, ...))
end

local function ScaleTurnForGameSpeed(standardTurn)
    if standardTurn == nil then return nil end
    local gameSpeedType = GameConfiguration.GetGameSpeedType()
    local speedInfo = GameInfo.GameSpeeds[gameSpeedType]
    local multiplier = (speedInfo and speedInfo.CostMultiplier or 100)
    return math.floor(standardTurn * multiplier / 100 + 0.5)
end

local function PlayerHasTriangularTradeRelic(pPlayer)
    if pPlayer == nil then return false end
    local prop = pPlayer:GetProperty(TRI_TRADE_PROP_KEY)
    if prop == true or prop == 1 then return true end
    local count = tonumber(pPlayer:GetProperty('PROP_NW_HAIKESI_RELIC_COUNT') or 0) or 0
    for i = 1, count do
        if pPlayer:GetProperty('PROP_NW_HAIKESI_RELIC_' .. i) == TRIANGULARTRADERUNE then
            return true
        end
    end
    return false
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

local function ClassifySeaTradeRoute(route)
    if route == nil then
        return false, "route=nil"
    end

    local tradeManager = Game.GetTradeManager()
    if tradeManager ~= nil and tradeManager.GetTradeRoutePath ~= nil then
        local ok, pathPlots = pcall(function()
            return tradeManager:GetTradeRoutePath(
                route.OriginCityPlayer,
                route.OriginCityID,
                route.DestinationCityPlayer,
                route.DestinationCityID
            )
        end)
        if ok and pathPlots ~= nil then
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

local function CountRouteTable(t)
    local n = 0
    if t == nil then return 0 end
    for _ in pairs(t) do n = n + 1 end
    return n
end

local function CollectOutgoingInternationalSeaRoutes(pPlayer, previousSnapshot, logDetail)
    local routes = {}
    if pPlayer == nil then return routes end
    local iPlayer = pPlayer:GetID()
    local cities = pPlayer:GetCities()
    if cities == nil then return routes end

    local currentTurn = Game.GetCurrentGameTurn()
    previousSnapshot = previousSnapshot or {}
    local intlTotal = 0
    local seaAccepted = 0

    for _, pCity in cities:Members() do
        if pCity ~= nil then
            if pCity.GetTrade == nil then
                TriTradeLog("P%d city GetTrade=nil (unexpected in UI)", iPlayer)
                break
            end
            local pCityTrade = pCity:GetTrade()
            local outgoing = (pCityTrade ~= nil) and pCityTrade:GetOutgoingRoutes() or nil
            if outgoing ~= nil then
                for _, route in ipairs(outgoing) do
                    if route ~= nil
                        and route.OriginCityPlayer == iPlayer
                        and route.DestinationCityPlayer ~= nil
                        and route.OriginCityID ~= nil
                        and route.DestinationCityID ~= nil
                    then
                        local isIntl = route.DestinationCityPlayer ~= iPlayer
                        if isIntl then
                            intlTotal = intlTotal + 1
                            local isSea, seaReason = ClassifySeaTradeRoute(route)
                            local sig = MakeRouteSig(route)
                            if logDetail then
                                TriTradeLog(
                                    "P%d scan intl sig=%s sea=%s reason=%s",
                                    iPlayer, sig, tostring(isSea), tostring(seaReason)
                                )
                            end
                            if isSea then
                                seaAccepted = seaAccepted + 1
                                local prev = previousSnapshot[sig]
                                routes[sig] = {
                                    fromPlayerID = route.OriginCityPlayer,
                                    toPlayerID = route.DestinationCityPlayer,
                                    fromCityID = route.OriginCityID,
                                    toCityID = route.DestinationCityID,
                                    traderUnitID = route.TraderUnitID,
                                    firstSeenTurn = (prev and prev.firstSeenTurn) or currentTurn,
                                    seaReason = seaReason,
                                }
                            end
                        end
                    end
                end
            end
        end
    end

    if logDetail then
        TriTradeLog(
            "P%d collect turn=%d intl=%d seaAccepted=%d tracked=%d",
            iPlayer, currentTurn, intlTotal, seaAccepted, CountRouteTable(routes)
        )
    end
    return routes
end

-- 待提交队列：TurnEnd 时先攒着，到 LocalPlayerTurnBegin 再走 HaikesiSelectRelic 通道
-- （ExposedMembers 在 UI 线程无 IsMinor/ChangePopulation；自定义 OnStart 不进 GP）
local g_PendingTriTradeQueue = nil

local function EncodeTriTradeQueue(completedList)
    local parts = {}
    for _, item in ipairs(completedList) do
        table.insert(parts, string.format(
            "%d,%d,%d,%d",
            tonumber(item.OwnerPlayer) or 0,
            tonumber(item.FromCityID) or 0,
            tonumber(item.ToPlayerID) or 0,
            tonumber(item.ToCityID) or 0
        ))
    end
    return table.concat(parts, ";")
end

local function SubmitTriTradeQueueToGameplay(queueStr)
    if queueStr == nil or queueStr == "" then
        return
    end
    local localPlayer = Game.GetLocalPlayer()
    if localPlayer == nil or localPlayer < 0 then
        TriTradeLog("submit skip: no local player")
        return
    end
    -- 复用已验证可用的 HaikesiSelectRelic EXECUTE_SCRIPT（纯字符串参数）
    local param = {}
    param['OnStart'] = 'HaikesiSelectRelic'
    param['TriTradeQueue'] = queueStr
    UI.RequestPlayerOperation(localPlayer, PlayerOperations.EXECUTE_SCRIPT, param)
    TriTradeLog("submit via HaikesiSelectRelic TriTradeQueue=%s", queueStr)
end

local function FlushTriTradeCompletions(completedList)
    if completedList == nil or #completedList == 0 then
        return
    end

    TriTradeLog("flush completions count=%d", #completedList)
    for _, item in ipairs(completedList) do
        TriTradeLog(
            "flush item owner=P%d from=%s to=P%d city=%s sig=%s",
            item.OwnerPlayer, tostring(item.FromCityID),
            item.ToPlayerID, tostring(item.ToCityID), tostring(item.Sig)
        )
    end

    local encoded = EncodeTriTradeQueue(completedList)
    if g_PendingTriTradeQueue ~= nil and g_PendingTriTradeQueue ~= "" then
        g_PendingTriTradeQueue = g_PendingTriTradeQueue .. ";" .. encoded
    else
        g_PendingTriTradeQueue = encoded
    end
    TriTradeLog("pending queue=%s (submit on LocalPlayerTurnBegin)", tostring(g_PendingTriTradeQueue))
end

local function OnLocalPlayerTurnBegin()
    if g_PendingTriTradeQueue == nil or g_PendingTriTradeQueue == "" then
        return
    end
    local queue = g_PendingTriTradeQueue
    g_PendingTriTradeQueue = nil
    TriTradeLog("LocalPlayerTurnBegin submit pending queue")
    SubmitTriTradeQueueToGameplay(queue)
end

local function ProcessSnapshotDiff(iPlayer, pPlayer, phase)
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

    local completedList = {}
    for sig, oldRoute in pairs(prevRoutes) do
        if nowRoutes[sig] == nil then
            local lived = currentTurn - (oldRoute.firstSeenTurn or currentTurn)
            if lived >= minLivedTurns then
                TriTradeLog(
                    "%s P%d COMPLETE sig=%s lived=%d >= min=%d → queue",
                    tostring(phase), iPlayer, sig, lived, minLivedTurns
                )
                table.insert(completedList, {
                    OwnerPlayer = iPlayer,
                    FromCityID = oldRoute.fromCityID,
                    ToPlayerID = oldRoute.toPlayerID,
                    ToCityID = oldRoute.toCityID,
                    Sig = sig,
                })
            else
                TriTradeLog(
                    "%s P%d DROP_TOO_SOON sig=%s lived=%d < min=%d (recall/cancel?)",
                    tostring(phase), iPlayer, sig, lived, minLivedTurns
                )
            end
        end
    end

    FlushTriTradeCompletions(completedList)
    g_TriTradeRouteSnapshot[iPlayer] = nowRoutes
end

local function ShouldScanPlayer(pPlayer)
    if pPlayer == nil or not pPlayer:IsAlive() or not pPlayer:IsMajor() then
        return false
    end
    if not PlayerHasTriangularTradeRelic(pPlayer) then
        return false
    end
    -- 主机扫所有持有者；非主机仅扫本地人类（联机）
    if Network.IsGameHost() then
        return true
    end
    return pPlayer:IsHuman() and pPlayer:GetID() == Game.GetLocalPlayer()
end

local function OnTurnPhase(phase)
    for iPlayer = 0, 63 do
        local pPlayer = Players[iPlayer]
        if ShouldScanPlayer(pPlayer) then
            ProcessSnapshotDiff(iPlayer, pPlayer, phase)
        end
    end
end

local function RebuildSnapshotsOnLoad()
    local currentTurn = Game.GetCurrentGameTurn()
    local minLivedTurns = ScaleTurnForGameSpeed(TRI_TRADE_MIN_ROUTE_TURNS_STANDARD) or TRI_TRADE_MIN_ROUTE_TURNS_STANDARD
    local syntheticFirst = math.max(0, currentTurn - minLivedTurns)
    local rebuiltPlayers = 0

    for iPlayer = 0, 63 do
        local pPlayer = Players[iPlayer]
        if ShouldScanPlayer(pPlayer) then
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

-- ===========================================================================
-- 南蛮入侵攻城通知（原 Haikesi_BarbClan_Bridge：独立 Context 未进加载列表，并入本桥接）
-- ===========================================================================
local BARB_ASSAULT_NOTIFY_PROP = 'PROP_NW_HAIKESI_BARB_ASSAULT_NOTIFY'
local g_AssaultNotifyCursor = 0

local function SplitAssaultQueue(raw)
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
    if not ok or nameType == nil
        or (type(nameType) == "number" and nameType < 0) then
        return Locale.Lookup("LOC_HAIKESI_BARB_INVASION_CLAN_FALLBACK")
    end
    local nameRow = ResolveTribeNameRow(nameType)
    if nameRow ~= nil and nameRow.TribeDisplayName ~= nil then
        return Locale.Lookup(nameRow.TribeDisplayName)
    end
    return Locale.Lookup("LOC_HAIKESI_BARB_INVASION_CLAN_FALLBACK")
end

local function SendAssaultNotification(triggerPlayerID, iTribe, targetPlayerID, targetCityID, campX, campY)
    if NotificationManager == nil or NotificationManager.SendNotification == nil then
        return
    end
    local notifType = NotificationTypes and NotificationTypes.CLAN_INCITED or nil
    if notifType == nil then
        return
    end
    local leaderName = "?"
    if triggerPlayerID ~= nil and PlayerConfigurations[triggerPlayerID] ~= nil then
        leaderName = Locale.Lookup(PlayerConfigurations[triggerPlayerID]:GetLeaderName())
    end
    local clanName = ResolveClanProperName(iTribe, campX, campY)
    local cityName = "?"
    local pPlayer = Players[targetPlayerID]
    if pPlayer ~= nil and targetCityID ~= nil then
        local pCity = pPlayer:GetCities():FindID(targetCityID)
        if pCity ~= nil then
            cityName = Locale.Lookup(pCity:GetName())
        end
    end
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
        "[Haikesi UI] BARBARIAN_INVASION notify: %s", tostring(body)))
end

local function ProcessAssaultNotifyQueue()
    if Game == nil or Game.GetProperty == nil then
        return
    end
    local ok, err = pcall(function()
        local raw = Game:GetProperty(BARB_ASSAULT_NOTIFY_PROP) or ""
        local entries = SplitAssaultQueue(raw)
        if #entries <= (g_AssaultNotifyCursor or 0) then
            return
        end
        local localPlayer = Game.GetLocalPlayer()
        for i = (g_AssaultNotifyCursor or 0) + 1, #entries do
            local triggerStr, tribeStr, targetStr, cityStr, xStr, yStr = string.match(
                entries[i], "^(%-?%d+);(%-?%d+);(%-?%d+);(%-?%d+);(%-?%d+);(%-?%d+)$")
            local targetPlayerID = tonumber(targetStr)
            if targetPlayerID ~= nil and localPlayer == targetPlayerID then
                SendAssaultNotification(
                    tonumber(triggerStr), tonumber(tribeStr), targetPlayerID,
                    tonumber(cityStr), tonumber(xStr), tonumber(yStr))
            end
        end
        g_AssaultNotifyCursor = #entries
    end)
    if not ok then
        print("[Haikesi UI] ProcessAssaultNotifyQueue error: " .. tostring(err))
    end
end

-- ===========================================================================
-- 外部 AI Stage→广播（原 Haikesi_ExtAI_Bridge，并入本桥接保证加载）
-- ===========================================================================
local g_LastExtAIBroadcastSeq = 0

local function IsGameHost()
    if Network ~= nil and Network.IsGameHost ~= nil then
        return Network.IsGameHost()
    end
    if Game ~= nil and Game.IsNetworkMultiplayer ~= nil then
        return not Game.IsNetworkMultiplayer()
    end
    return true
end

local function ProcessStagedExtAI()
    if not IsGameHost() or ExposedMembers == nil then
        return
    end
    local seq = tonumber(ExposedMembers.Haikesi_ExtAIStagedSeq) or 0
    local payload = ExposedMembers.Haikesi_ExtAIStagedPayload
    if seq <= g_LastExtAIBroadcastSeq then
        return
    end
    if payload == nil or payload == "" then
        g_LastExtAIBroadcastSeq = seq
        return
    end
    ExposedMembers.Haikesi_ExtAIStagedPayload = nil
    g_LastExtAIBroadcastSeq = seq
    local localPlayer = Game.GetLocalPlayer()
    if localPlayer == nil or localPlayer < 0 then
        print("[Haikesi ExtAI UI] broadcast skip: no local player")
        return
    end
    local param = {}
    param['OnStart'] = 'HaikesiSelectRelic'
    param['ExtAIApply'] = tostring(payload)
    UI.RequestPlayerOperation(localPlayer, PlayerOperations.EXECUTE_SCRIPT, param)
    print("[Haikesi ExtAI UI] broadcast ExtAIApply len=" .. tostring(#tostring(payload)))
end

-- ===========================================================================
-- 联机 ExtAI：事件驱动（选卡 pending / EditBox 粘贴 / 回合缓存）
-- 不再挂 GameCoreEventPublishComplete 每帧轮询
-- ===========================================================================
local EXT_AI_PENDING_PROP = "PROP_NW_HAIKESI_EXT_AI_PENDING"
local EXT_AI_UI_MIL_PROP_PREFIX = "PROP_NW_HAIKESI_UI_MIL_"
local EXT_AI_UI_DIP_PROP_PREFIX = "PROP_NW_HAIKESI_UI_DIP_"
local g_ExtAILastAutoApply = ""
local g_ExtAIPendingNotified = false

local function ShortDiploStateFromIndex(idx)
    if idx == nil then
        return nil
    end
    local row = GameInfo.DiplomaticStates[idx]
    if row ~= nil and row.StateType ~= nil then
        return tostring(row.StateType):gsub("^DIPLO_STATE_", "")
    end
    local states = {"ALLIED", "DECLARED_FRIEND", "FRIENDLY", "NEUTRAL", "UNFRIENDLY", "DENOUNCED", "WAR"}
    return states[(tonumber(idx) or -1) + 1]
end

-- GetMilitaryStrength / GetDiplomaticStateIndex / GetGrievancesAgainst 仅 UI；
-- 仅在回合初 / 选卡前 / pending 时刷新，写入 Game 属性供 Gameplay CTX dump
local function RefreshExtAIMilitaryCache()
    local okAll, errAll = pcall(function()
        if Game == nil then
            return
        end
        local cache = {}
        local majors = nil
        pcall(function()
            majors = PlayerManager.GetAliveMajors()
        end)
        if majors == nil then
            return
        end
        local ids = {}
        for _, pPlayer in ipairs(majors) do
            if pPlayer ~= nil then
                local pid = pPlayer:GetID()
                table.insert(ids, pid)
                local mil = 0
                pcall(function()
                    local st = pPlayer.GetStats and pPlayer:GetStats() or nil
                    if st ~= nil and st.GetMilitaryStrength ~= nil then
                        mil = tonumber(st:GetMilitaryStrength()) or 0
                    end
                end)
                cache[pid] = mil
                pcall(function()
                    if Game.SetProperty ~= nil then
                        Game:SetProperty(EXT_AI_UI_MIL_PROP_PREFIX .. tostring(pid), mil)
                    end
                end)
            end
        end
        if ExposedMembers ~= nil then
            ExposedMembers.Haikesi_UIMilitaryByPlayer = cache
        end
        for _, fromId in ipairs(ids) do
            local pFrom = Players[fromId]
            if pFrom ~= nil then
                local pDiplo = nil
                local pAI = nil
                pcall(function() pDiplo = pFrom:GetDiplomacy() end)
                pcall(function() pAI = pFrom:GetDiplomaticAI() end)
                for _, towardId in ipairs(ids) do
                    if towardId ~= fromId then
                        local stateName = "NEUTRAL"
                        local relScore = 0
                        local griev = 0
                        pcall(function()
                            if pAI ~= nil and pAI.GetDiplomaticStateIndex ~= nil then
                                stateName = ShortDiploStateFromIndex(pAI:GetDiplomaticStateIndex(towardId))
                                    or stateName
                            end
                        end)
                        pcall(function()
                            if pAI ~= nil and pAI.GetDiplomaticScore ~= nil then
                                relScore = tonumber(pAI:GetDiplomaticScore(towardId)) or 0
                            end
                        end)
                        pcall(function()
                            if pDiplo ~= nil and pDiplo.GetGrievancesAgainst ~= nil then
                                griev = tonumber(pDiplo:GetGrievancesAgainst(towardId)) or 0
                            end
                        end)
                        pcall(function()
                            if Game.SetProperty ~= nil then
                                Game:SetProperty(
                                    EXT_AI_UI_DIP_PROP_PREFIX .. tostring(fromId) .. "_" .. tostring(towardId),
                                    tostring(stateName) .. ";" .. tostring(relScore) .. ";" .. tostring(griev))
                            end
                        end)
                    end
                end
            end
        end
    end)
    if not okAll then
        print("[Haikesi ExtAI MP] RefreshExtAIUICache error: " .. tostring(errAll))
    end
end

local function TrimExtAIPayload(text)
    if text == nil then
        return ""
    end
    text = tostring(text):gsub("^%s+", ""):gsub("%s+$", ""):gsub("[\r\n]", "")
    return text
end

local function LooksLikeExtAIApply(text)
    if text == nil or text == "" then
        return false
    end
    return string.find(text, "^[^#]+#%d+=[%w_]+", 1) ~= nil
end

local function CanBroadcastExtAI()
    if Game ~= nil and Game.IsNetworkMultiplayer ~= nil and not Game.IsNetworkMultiplayer() then
        return true
    end
    return IsGameHost()
end

local function IsExtAIPending()
    return (Game:GetProperty(EXT_AI_PENDING_PROP) or 0) == 1
end

local function ExtAINotifType()
    -- USER_DEFINED_1 在联机右侧通知栏可见；DEFAULT 常无显示
    if NotificationTypes == nil then
        return nil
    end
    return NotificationTypes.USER_DEFINED_1 or NotificationTypes.DEFAULT
end

local function FocusExtAIEditBox()
    if Controls == nil or Controls.ExtAIPayloadEdit == nil then
        return false
    end
    if Controls.ExtAIPayloadEdit.TakeFocus ~= nil then
        Controls.ExtAIPayloadEdit:TakeFocus()
        return true
    end
    if Controls.ExtAIPayloadEdit.SetFocus ~= nil then
        Controls.ExtAIPayloadEdit:SetFocus()
        return true
    end
    return false
end

local function BroadcastExtAIApplyFromMP(payload)
    if not CanBroadcastExtAI() then
        print("[Haikesi ExtAI MP] skip apply: not host / no authority")
        return false
    end
    local localPlayer = Game.GetLocalPlayer()
    if localPlayer == nil or localPlayer < 0 then
        print("[Haikesi ExtAI MP] skip apply: no local player")
        return false
    end
    local param = {}
    param['OnStart'] = 'HaikesiSelectRelic'
    param['ExtAIApply'] = payload
    UI.RequestPlayerOperation(localPlayer, PlayerOperations.EXECUTE_SCRIPT, param)
    print("[Haikesi ExtAI MP] EXECUTE_SCRIPT ExtAIApply len=" .. tostring(#payload))
    return true
end

local function ApplyExtAIPayload(raw, source)
    raw = TrimExtAIPayload(raw)
    if raw == "" then
        return false
    end
    if not LooksLikeExtAIApply(raw) then
        print("[Haikesi ExtAI MP] payload shape rejected (" .. tostring(source) .. ")")
        return false
    end
    if raw == g_ExtAILastAutoApply then
        return false
    end
    if BroadcastExtAIApplyFromMP(raw) then
        g_ExtAILastAutoApply = raw
        if Controls ~= nil and Controls.ExtAIPayloadEdit ~= nil then
            Controls.ExtAIPayloadEdit:SetText("")
        end
        -- 粘贴已发出：先藏横幅（Gameplay 清 pending 后还会再发 Cleared）
        g_ExtAIPendingNotified = false
        SetExtAIBannerVisible(false)
        return true
    end
    return false
end

local function ApplyExtAIFromEditBox(source)
    if Controls == nil or Controls.ExtAIPayloadEdit == nil then
        print("[Haikesi ExtAI MP] EditBox missing")
        return
    end
    local raw = TrimExtAIPayload(Controls.ExtAIPayloadEdit:GetText())
    if LooksLikeExtAIApply(raw) then
        ApplyExtAIPayload(raw, source)
    end
end

local function AttachExtAIBannerToHud()
    if Controls == nil or Controls.ExtAIBanner == nil then
        print("[Haikesi ExtAI MP] WARN: ExtAIBanner missing, cannot attach to HUD")
        return false
    end
    local hud = ContextPtr:LookUpControl("/InGame/HUD")
    if hud == nil then
        hud = ContextPtr:LookUpControl("/InGame/WorldInput")
    end
    if hud == nil then
        print("[Haikesi ExtAI MP] WARN: /InGame/HUD not found")
        return false
    end
    Controls.ExtAIBanner:ChangeParent(hud)
    -- 提到最前，避免被其它 HUD 挡住
    if Controls.ExtAIBanner.SetHide ~= nil then
        Controls.ExtAIBanner:SetHide(true)
    end
    print("[Haikesi ExtAI MP] ExtAIBanner ChangeParent → HUD/WorldInput")
    return true
end

-- pending 横幅：挂到 HUD 后显示在屏幕上方中央
local function SetExtAIBannerVisible(visible, statusLocOrText)
    if Controls == nil then
        return
    end
    if Controls.ExtAIBanner ~= nil and Controls.ExtAIBanner.SetHide ~= nil then
        pcall(function()
            Controls.ExtAIBanner:SetHide(not visible)
        end)
    end
    if visible and Controls.ExtAIStatusLabel ~= nil and statusLocOrText ~= nil then
        local text = Locale.Lookup(statusLocOrText)
        if text == nil or text == "" or string.sub(tostring(text), 1, 4) == "LOC_" then
            text = "外部AI决策中… 完成后在下方框 Ctrl+V"
        end
        if Controls.ExtAIStatusLabel.SetText ~= nil then
            pcall(function()
                Controls.ExtAIStatusLabel:SetText(text)
            end)
        end
    end
end

local function ShowExtAIToast(title, body)
    pcall(function()
        if NotificationManager == nil then
            return
        end
        local localPlayer = Game.GetLocalPlayer()
        if localPlayer == nil or localPlayer < 0 then
            return
        end
        local nt = ExtAINotifType()
        if nt == nil then
            return
        end
        NotificationManager.SendNotification(localPlayer, nt, title, body)
    end)
    if UI ~= nil and UI.PlaySound ~= nil then
        pcall(function()
            UI.PlaySound("Confirm_Caravan_Produce")
        end)
    end
end

-- 选卡确认 / Gameplay 建 pending / 读档恢复：显示横幅（粘贴靠 EditBox 回调）
local function OnExtAIPendingUI(source)
    local ok, err = pcall(function()
        RefreshExtAIMilitaryCache()
        if not CanBroadcastExtAI() then
            SetExtAIBannerVisible(false)
            return
        end
        if Controls == nil or Controls.ExtAIPayloadEdit == nil then
            print("[Haikesi ExtAI MP] pending UI skip: EditBox missing (" .. tostring(source) .. ")")
            return
        end
        AttachExtAIBannerToHud()
        SetExtAIBannerVisible(true, "LOC_HAIKESI_EXT_AI_BANNER_PENDING")
        if not g_ExtAIPendingNotified then
            g_ExtAIPendingNotified = true
            local title = Locale.Lookup("LOC_HAIKESI_EXT_AI_PENDING_NOTIFY_TITLE")
            if title == nil or title == "" or string.sub(tostring(title), 1, 4) == "LOC_" then
                title = "外部AI海克斯"
            end
            local body = Locale.Lookup("LOC_HAIKESI_EXT_AI_PENDING_NOTIFY_BODY")
            if body == nil or body == "" or string.sub(tostring(body), 1, 4) == "LOC_" then
                body = "AI 决策中。完成后在下方输入框 Ctrl+V 粘贴 wire。"
            end
            ShowExtAIToast(title, body)
            print("[Haikesi ExtAI MP] pending banner (" .. tostring(source or "event") .. ")")
        end
        FocusExtAIEditBox()
        ApplyExtAIFromEditBox("pending")
    end)
    if not ok then
        print("[Haikesi ExtAI MP] OnExtAIPendingUI error: " .. tostring(err))
    end
end

local function OnExtAIClearedUI(source)
    g_ExtAIPendingNotified = false
    SetExtAIBannerVisible(false)
    print("[Haikesi ExtAI MP] pending cleared (" .. tostring(source or "event") .. ")")
end

local function OnExtAIWarmCacheUI()
    RefreshExtAIMilitaryCache()
end

local function OnExtAIPayloadChanged()
    if not IsExtAIPending() and not g_ExtAIPendingNotified then
        return
    end
    ApplyExtAIFromEditBox("changed")
end

local function OnExtAIInputHandler(pInputStruct)
    local uiMsg = pInputStruct:GetMessageType()
    if uiMsg ~= KeyEvents.KeyUp and uiMsg ~= KeyEvents.KeyDown then
        return false
    end
    if not pInputStruct:IsControlDown()
        or not pInputStruct:IsAltDown()
        or not pInputStruct:IsShiftDown() then
        return false
    end
    local key = pInputStruct:GetKey()
    if key == Keys.R then
        if uiMsg == KeyEvents.KeyDown then
            print("[Haikesi ExtAI MP] hotkey R → focus EditBox for Ctrl+V")
            if IsExtAIPending() or g_ExtAIPendingNotified then
                SetExtAIBannerVisible(true, "LOC_HAIKESI_EXT_AI_BANNER_PENDING")
            end
            FocusExtAIEditBox()
            return true
        end
        return true
    end
    return false
end

local function Initialize()
    Events.TurnBegin.Add(function()
        OnTurnPhase("TurnBegin")
        RefreshExtAIMilitaryCache()
        ProcessStagedExtAI()
        if g_ExtAIPendingNotified and not IsExtAIPending() then
            OnExtAIClearedUI("TurnBegin")
        elseif IsExtAIPending() and not g_ExtAIPendingNotified then
            OnExtAIPendingUI("TurnBegin")
        end
    end)
    Events.TurnEnd.Add(function()
        OnTurnPhase("TurnEnd")
    end)
    Events.LocalPlayerTurnBegin.Add(function()
        OnLocalPlayerTurnBegin()
        RefreshExtAIMilitaryCache()
        ProcessStagedExtAI()
        if g_ExtAIPendingNotified and not IsExtAIPending() then
            OnExtAIClearedUI("LocalPlayerTurnBegin")
        elseif IsExtAIPending() and not g_ExtAIPendingNotified then
            OnExtAIPendingUI("LocalPlayerTurnBegin")
        end
    end)
    -- 攻城通知：队列为空时极早返回（与 ExtAI 解耦，不再每帧跑 ExtAI）
    Events.GameCoreEventPublishComplete.Add(ProcessAssaultNotifyQueue)

    if LuaEvents ~= nil then
        LuaEvents.Haikesi_ExtAIWarmCache.Add(OnExtAIWarmCacheUI)
        LuaEvents.Haikesi_ExtAIPendingUI.Add(function()
            OnExtAIPendingUI("LuaEvent")
        end)
        LuaEvents.Haikesi_ExtAIClearedUI.Add(function()
            OnExtAIClearedUI("LuaEvent")
        end)
        LuaEvents.Haikesi_ExtAIStagedUI.Add(ProcessStagedExtAI)
    end

    RebuildSnapshotsOnLoad()
    g_AssaultNotifyCursor = #SplitAssaultQueue(
        Game:GetProperty(BARB_ASSAULT_NOTIFY_PROP) or "")
    g_LastExtAIBroadcastSeq = tonumber(
        ExposedMembers and ExposedMembers.Haikesi_ExtAIStagedSeq) or 0
    if ExposedMembers ~= nil then
        ExposedMembers.Haikesi_ExtAIStagedPayload = nil
    end

    ContextPtr:SetInputHandler(OnExtAIInputHandler, true)
    AttachExtAIBannerToHud()
    RefreshExtAIMilitaryCache()
    if Controls.ExtAIBanner ~= nil then
        if Controls.ExtAIBanner.SetHide ~= nil then
            Controls.ExtAIBanner:SetHide(true)
        end
    else
        print("[Haikesi ExtAI MP] WARN: ExtAIBanner missing (XML not loaded?)")
    end
    if Controls.ExtAIPayloadEdit ~= nil then
        if Controls.ExtAIPayloadEdit.RegisterStringChangedCallback ~= nil then
            Controls.ExtAIPayloadEdit:RegisterStringChangedCallback(OnExtAIPayloadChanged)
        end
        if Controls.ExtAIPayloadEdit.RegisterCommitCallback ~= nil then
            Controls.ExtAIPayloadEdit:RegisterCommitCallback(function()
                ApplyExtAIFromEditBox("commit")
            end)
        end
    else
        print("[Haikesi ExtAI MP] WARN: ExtAIPayloadEdit control missing")
    end

    if IsExtAIPending() then
        OnExtAIPendingUI("load")
    end

    TriTradeLog("UI bridge initialized (TriTrade+BarbNotify+ExtAI event-driven)")
    print("[Haikesi UI] TriTrade/BarbNotify/ExtAI bridge ready (event-driven Ctrl+V)")
end

Events.LoadScreenClose.Add(Initialize)
