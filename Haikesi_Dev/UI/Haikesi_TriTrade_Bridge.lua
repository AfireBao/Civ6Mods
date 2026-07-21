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

local function IsNetworkMultiplayerGame()
    return Game ~= nil
        and Game.IsNetworkMultiplayer ~= nil
        and Game.IsNetworkMultiplayer()
end

local function ProcessStagedExtAI()
    if not IsGameHost() or ExposedMembers == nil then
        return
    end
    -- 读档/回主菜单帧上 Game 可能为 nil：绝不能先清 payload / 抬高 seq，否则 LLM stage 永久丢失
    if Game == nil then
        return
    end
    local seq = tonumber(ExposedMembers.Haikesi_ExtAIStagedSeq) or 0
    local payload = ExposedMembers.Haikesi_ExtAIStagedPayload
    if seq <= g_LastExtAIBroadcastSeq then
        return
    end
    if payload == nil or payload == "" then
        print("[Haikesi ExtAI UI] staged seq=" .. tostring(seq)
            .. " payload empty — keep waiting (do not consume seq)")
        return
    end
    local localPlayer = Game.GetLocalPlayer()
    if localPlayer == nil or localPlayer < 0 then
        localPlayer = tonumber(Game:GetProperty("PROP_NW_HAIKESI_EXT_AI_REQUESTER") or -1)
    end
    if localPlayer == nil or localPlayer < 0 then
        print("[Haikesi ExtAI UI] broadcast defer: no local player (will retry seq="
            .. tostring(seq) .. ")")
        return
    end
    -- 仅在确认能广播后再消费，避免 Game nil / 无席位时吞掉 stage
    ExposedMembers.Haikesi_ExtAIStagedPayload = nil
    g_LastExtAIBroadcastSeq = seq
    local param = {}
    param['OnStart'] = 'HaikesiSelectRelic'
    param['ExtAIApply'] = tostring(payload)
    local okReq, errReq = pcall(function()
        UI.RequestPlayerOperation(localPlayer, PlayerOperations.EXECUTE_SCRIPT, param)
    end)
    if not okReq then
        -- 广播失败：塞回 payload，允许下帧重试同一 seq
        ExposedMembers.Haikesi_ExtAIStagedPayload = payload
        g_LastExtAIBroadcastSeq = seq - 1
        print("[Haikesi ExtAI UI] broadcast FAILED seq=" .. tostring(seq)
            .. " err=" .. tostring(errReq) .. " — restored payload for retry")
        return
    end
    print("[Haikesi ExtAI UI] broadcast ExtAIApply len=" .. tostring(#tostring(payload))
        .. " via P" .. tostring(localPlayer) .. " seq=" .. tostring(seq))
    -- 单机再直调一次 Gameplay，防止 EXECUTE_SCRIPT 丢失
    if not IsNetworkMultiplayerGame() then
        pcall(function()
            local fn = ExposedMembers and ExposedMembers.Haikesi_ApplyExtAIWire
            if type(fn) == "function" then
                fn(tostring(payload))
            end
        end)
    end
end

-- ===========================================================================
-- 联机 ExtAI：事件驱动（选卡 pending / EditBox 粘贴 / 回合缓存）
-- 不再挂 GameCoreEventPublishComplete 每帧轮询
-- ===========================================================================
local EXT_AI_PENDING_PROP = "PROP_NW_HAIKESI_EXT_AI_PENDING"
local EXT_AI_REQUESTER_PROP = "PROP_NW_HAIKESI_EXT_AI_REQUESTER"
local EXT_AI_UI_MIL_PROP_PREFIX = "PROP_NW_HAIKESI_UI_MIL_"
local EXT_AI_UI_DIP_PROP_PREFIX = "PROP_NW_HAIKESI_UI_DIP_"
local g_ExtAILastAutoApply = ""
local g_ExtAIPendingNotified = false
-- 本端已成功 apply，但 Game pending 属性偶发晚清：先藏横幅且禁止重弹
local g_ExtAIUiConsumed = false
-- EXECUTE_SCRIPT 后 Game prop 偶发晚一拍；短重试拉横幅（与 LLM/exchange 无关）
local g_ExtAIBannerRetryFrames = 0
local EXT_AI_BANNER_RETRY_MAX = 90

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

-- 军力/旅游/内游/外交VP/支持度 / 关系不满 / 金英暗时代：仅 UI(InGame) 可靠；
-- 军力与外交条一致用 GetMilitaryStrengthWithoutTreasury（含国库版会偏高）
-- 仅在回合初 / 选卡前 / pending 时刷新，写入 ExposedMembers + Game 属性
-- 时代戳记供 Gameplay 双选（HasGoldenAge 在 GameCore 不可用）
local function RefreshExtAIMilitaryCache()
    local okAll, errAll = pcall(function()
        if Game == nil then
            return
        end
        local cache = {}
        local vstatCache = {}
        local eraAgeCache = {}
        local majors = nil
        pcall(function()
            majors = PlayerManager.GetAliveMajors()
        end)
        if majors == nil then
            return
        end
        local ids = {}
        local eras = nil
        pcall(function()
            eras = Game.GetEras()
        end)
        for _, pPlayer in ipairs(majors) do
            if pPlayer ~= nil then
                local pid = pPlayer:GetID()
                table.insert(ids, pid)
                -- 金/英/暗：Gameplay 读此戳记决定 6 选 2
                local age = "NORMAL"
                if eras ~= nil then
                    local okAge, ageLabel = pcall(function()
                        if eras.HasHeroicGoldenAge ~= nil and eras:HasHeroicGoldenAge(pid) then
                            return "HEROIC"
                        end
                        if eras.HasHeroicAge ~= nil and eras:HasHeroicAge(pid) then
                            return "HEROIC"
                        end
                        if eras.HasGoldenAge ~= nil and eras:HasGoldenAge(pid) then
                            return "GOLDEN"
                        end
                        if eras.HasDarkAge ~= nil and eras:HasDarkAge(pid) then
                            return "DARK"
                        end
                        return "NORMAL"
                    end)
                    if okAge and ageLabel ~= nil and ageLabel ~= "" then
                        age = tostring(ageLabel)
                    end
                end
                eraAgeCache[pid] = age
                pcall(function()
                    if Game.SetProperty ~= nil then
                        Game:SetProperty("PROP_NW_HAIKESI_UI_ERA_AGE_" .. tostring(pid), age)
                    end
                end)
                -- mil/techs/civics：失败时不写缓存（避免假 0 盖住 Gameplay 回退）
                local mil = nil
                local techs, civics = nil, nil
                -- 与 WorldRankings 文化页一致：旅业绩=GetTourism，国内游客=Staycationers，国际游客=GetTouristsTo
                local diploVP, tourism, stay, favor, visiting = 0, 0, 0, 0, 0
                pcall(function()
                    local st = pPlayer.GetStats and pPlayer:GetStats() or nil
                    if st ~= nil then
                        -- 与 DiplomacyRibbon / WorldRankings 征服榜同一 API
                        if st.GetMilitaryStrengthWithoutTreasury ~= nil then
                            mil = tonumber(st:GetMilitaryStrengthWithoutTreasury())
                        elseif st.GetMilitaryStrength ~= nil then
                            mil = tonumber(st:GetMilitaryStrength())
                        end
                        if st.GetDiplomaticVictoryPoints ~= nil then
                            diploVP = tonumber(st:GetDiplomaticVictoryPoints()) or 0
                        end
                        if st.GetTourism ~= nil then
                            tourism = math.floor(tonumber(st:GetTourism()) or 0)
                        end
                    end
                end)
                pcall(function()
                    local cul = pPlayer.GetCulture and pPlayer:GetCulture() or nil
                    if cul ~= nil then
                        if cul.GetStaycationers ~= nil then
                            stay = tonumber(cul:GetStaycationers()) or 0
                        end
                        if cul.GetTouristsTo ~= nil then
                            visiting = tonumber(cul:GetTouristsTo()) or 0
                        end
                        if cul.GetNumCivicsCompleted ~= nil then
                            civics = tonumber(cul:GetNumCivicsCompleted())
                        elseif cul.HasCivic ~= nil then
                            local n = 0
                            for row in GameInfo.Civics() do
                                if cul:HasCivic(row.Index) then
                                    n = n + 1
                                end
                            end
                            civics = n
                        end
                    end
                end)
                pcall(function()
                    local te = pPlayer.GetTechs and pPlayer:GetTechs() or nil
                    if te ~= nil then
                        if te.GetNumTechsResearched ~= nil then
                            techs = tonumber(te:GetNumTechsResearched())
                        elseif te.HasTech ~= nil then
                            local n = 0
                            for row in GameInfo.Technologies() do
                                if te:HasTech(row.Index) then
                                    n = n + 1
                                end
                            end
                            techs = n
                        end
                    end
                end)
                pcall(function()
                    if pPlayer.GetFavor ~= nil then
                        favor = tonumber(pPlayer:GetFavor()) or 0
                    end
                end)
                if mil ~= nil then
                    cache[pid] = mil
                end
                -- diploVP;tourism;stay;favor;visiting;techs;civics（空段=未知）
                vstatCache[pid] = tostring(diploVP) .. ";" .. tostring(tourism)
                    .. ";" .. tostring(stay) .. ";" .. tostring(favor)
                    .. ";" .. tostring(visiting)
                    .. ";" .. (techs ~= nil and tostring(techs) or "")
                    .. ";" .. (civics ~= nil and tostring(civics) or "")
                pcall(function()
                    if Game.SetProperty ~= nil then
                        if mil ~= nil then
                            Game:SetProperty(EXT_AI_UI_MIL_PROP_PREFIX .. tostring(pid), mil)
                        end
                        Game:SetProperty(
                            "PROP_NW_HAIKESI_UI_VSTAT_" .. tostring(pid),
                            vstatCache[pid])
                    end
                end)
            end
        end
        local dipCache = {}
        if ExposedMembers ~= nil then
            ExposedMembers.Haikesi_UIMilitaryByPlayer = cache
            ExposedMembers.Haikesi_UIVstatByPlayer = vstatCache
            ExposedMembers.Haikesi_UIEraAgeByPlayer = eraAgeCache
        end
        local ageParts = {}
        for _, pid in ipairs(ids) do
            table.insert(ageParts, "P" .. tostring(pid) .. "=" .. tostring(eraAgeCache[pid] or "?"))
        end
        if #ageParts > 0 then
            print("[Haikesi ExtAI UI] era ages: " .. table.concat(ageParts, " "))
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
                        -- Score API 偶发恒 0：用修饰语合计回填
                        if relScore == 0 and pAI ~= nil and pAI.GetDiplomaticModifiers ~= nil then
                            pcall(function()
                                local mods = pAI:GetDiplomaticModifiers(towardId)
                                if mods ~= nil then
                                    local sum = 0
                                    for _, mod in ipairs(mods) do
                                        sum = sum + (tonumber(mod.Score) or 0)
                                    end
                                    if sum ~= 0 then
                                        relScore = sum
                                    end
                                end
                            end)
                        end
                        pcall(function()
                            if pDiplo ~= nil and pDiplo.GetGrievancesAgainst ~= nil then
                                griev = tonumber(pDiplo:GetGrievancesAgainst(towardId)) or 0
                            end
                        end)
                        local packed = tostring(stateName) .. ";" .. tostring(relScore) .. ";" .. tostring(griev)
                        dipCache[tostring(fromId) .. "_" .. tostring(towardId)] = packed
                        pcall(function()
                            if Game.SetProperty ~= nil then
                                Game:SetProperty(
                                    EXT_AI_UI_DIP_PROP_PREFIX .. tostring(fromId) .. "_" .. tostring(towardId),
                                    packed)
                            end
                        end)
                    end
                end
            end
        end
        if ExposedMembers ~= nil then
            ExposedMembers.Haikesi_UIDipByPair = dipCache
        end
    end)
    if not okAll then
        print("[Haikesi ExtAI MP] RefreshExtAIUICache error: " .. tostring(errAll))
    end
    -- 商路独立扫描：避免嵌在大 pcall 里被前置错误整段跳过
    RefreshExtAITradeCache()
end

-- 商路缓存（InGame GetOutgoingRoutes）；失败不影响军力/时代戳记
function RefreshExtAITradeCache()
    local okTrade, errTrade = pcall(function()
        if Game == nil then
            print("[Haikesi ExtAI UI] trade skip: Game nil")
            return
        end
        local majors = nil
        pcall(function()
            majors = PlayerManager.GetAliveMajors()
        end)
        if majors == nil then
            print("[Haikesi ExtAI UI] trade skip: no majors")
            return
        end
        local ids = {}
        local tradeSumCache = {}
        local tradeRouteCache = {}
        for _, pPlayer in ipairs(majors) do
            if pPlayer ~= nil then
                local pid = pPlayer:GetID()
                table.insert(ids, pid)
                tradeSumCache[pid] = { cap = 0, out = 0, dom = 0, intlOut = 0, intlIn = 0 }
                tradeRouteCache[pid] = {}
            end
        end
        local function SafeLocName(obj)
            if obj == nil then
                return "?"
            end
            local n = "?"
            pcall(function()
                n = Locale.Lookup(obj:GetName())
            end)
            return tostring(n):gsub("|", "/")
        end
        local function SafeCivName(pid)
            local n = "?"
            pcall(function()
                n = Locale.Lookup(PlayerConfigurations[pid]:GetCivilizationShortDescription())
            end)
            return tostring(n):gsub("|", "/")
        end
        local function PushRoute(pid, packed)
            if tradeRouteCache[pid] == nil or #tradeRouteCache[pid] >= 12 then
                return
            end
            table.insert(tradeRouteCache[pid], packed)
        end
        -- 仅扫主要文明出站（城邦入向对互利海克斯次要；避免 GetAlive 兼容坑）
        for _, fromId in ipairs(ids) do
            local pOwner = Players[fromId]
            if pOwner ~= nil then
                local cap = 0
                pcall(function()
                    local tr = pOwner:GetTrade()
                    if tr ~= nil and tr.GetOutgoingRouteCapacity ~= nil then
                        cap = tonumber(tr:GetOutgoingRouteCapacity()) or 0
                    end
                end)
                tradeSumCache[fromId].cap = cap
                local seen = {}
                pcall(function()
                    for _, city in pOwner:GetCities():Members() do
                        local routes = nil
                        pcall(function()
                            local ct = city:GetTrade()
                            if ct ~= nil then
                                routes = ct:GetOutgoingRoutes()
                            end
                        end)
                        if routes ~= nil then
                            for _, r in ipairs(routes) do
                                local destPid = r.DestinationCityPlayer
                                local key = tostring(r.TraderUnitID or 0)
                                    .. "_" .. tostring(destPid)
                                    .. "_" .. tostring(r.DestinationCityID)
                                if not seen[key] then
                                    seen[key] = true
                                    local origName = "?"
                                    pcall(function()
                                        local oc = Players[r.OriginCityPlayer]
                                            :GetCities():FindID(r.OriginCityID)
                                        origName = SafeLocName(oc)
                                    end)
                                    local destName = "?"
                                    pcall(function()
                                        local dc = Players[destPid]
                                            :GetCities():FindID(r.DestinationCityID)
                                        destName = SafeLocName(dc)
                                    end)
                                    tradeSumCache[fromId].out =
                                        tradeSumCache[fromId].out + 1
                                    if destPid == fromId then
                                        tradeSumCache[fromId].dom =
                                            tradeSumCache[fromId].dom + 1
                                        PushRoute(fromId,
                                            "OUT|dom|" .. origName .. "|-|" .. destName)
                                    else
                                        tradeSumCache[fromId].intlOut =
                                            tradeSumCache[fromId].intlOut + 1
                                        PushRoute(fromId,
                                            "OUT|intl|" .. origName
                                                .. "|" .. SafeCivName(destPid)
                                                .. "|" .. destName)
                                        if tradeSumCache[destPid] ~= nil then
                                            tradeSumCache[destPid].intlIn =
                                                tradeSumCache[destPid].intlIn + 1
                                            PushRoute(destPid,
                                                "IN|intl|" .. SafeCivName(fromId)
                                                    .. "|" .. origName .. "|" .. destName)
                                        end
                                    end
                                end
                            end
                        end
                    end
                end)
            end
        end
        local tradeSumPacked = {}
        local tradeParts = {}
        for _, pid in ipairs(ids) do
            local s = tradeSumCache[pid]
            local packed = tostring(s.cap) .. ";" .. tostring(s.out) .. ";"
                .. tostring(s.dom) .. ";" .. tostring(s.intlOut) .. ";"
                .. tostring(s.intlIn)
            tradeSumPacked[pid] = packed
            pcall(function()
                if Game.SetProperty ~= nil then
                    Game:SetProperty("PROP_NW_HAIKESI_UI_TRADE_" .. tostring(pid), packed)
                    Game:SetProperty(
                        "PROP_NW_HAIKESI_UI_TROUTES_" .. tostring(pid),
                        table.concat(tradeRouteCache[pid] or {}, "#"))
                end
            end)
            table.insert(tradeParts,
                "P" .. tostring(pid) .. "=" .. tostring(s.out) .. "/"
                    .. tostring(s.cap) .. "(入" .. tostring(s.intlIn) .. ")")
        end
        if ExposedMembers ~= nil then
            ExposedMembers.Haikesi_UITradeSumByPlayer = tradeSumPacked
            ExposedMembers.Haikesi_UITradeRoutesByPlayer = tradeRouteCache
        end
        print("[Haikesi ExtAI UI] trade: " .. table.concat(tradeParts, " "))
    end)
    if not okTrade then
        print("[Haikesi ExtAI UI] trade cache error: " .. tostring(errTrade))
    end
end

local function TrimExtAIPayload(text)
    if text == nil then
        return ""
    end
    text = tostring(text)
    -- 剪贴板常见污染：BOM、零宽字符、包裹引号、换行
    text = text:gsub("^\239\187\191", "") -- UTF-8 BOM
    text = text:gsub("[\r\n\t]", "")
    text = text:gsub("^[%s\"'“”‘’]+", ""):gsub("[%s\"'“”‘’]+$", "")
    text = text:gsub("%z", "")
    -- 只保留 wire 本体。条目形如 id=RELIC*hex，多 AI 用 | 连接；
    -- request_id 可为 turn_count_requester 或 turn_count_requester_seq。
    -- 4 段 request_id（含重选序号）优先；兼容旧 3 段
    local wire = string.match(text, "(%d+_%d+_%d+_%d+#[%w_=*|]+)")
    if wire == nil then
        wire = string.match(text, "(%d+_%d+_%d+#[%w_=*|]+)")
    end
    if wire ~= nil then
        wire = wire:gsub("[^%w_=*|#%.%-]+$", "")
        return wire
    end
    return text:gsub("^%s+", ""):gsub("%s+$", "")
end

local function CountExtAIWireChoices(text)
    if text == nil or text == "" then
        return 0
    end
    local body = string.match(tostring(text), "^[^#]+#(.+)$")
    if body == nil or body == "" then
        return 0
    end
    local n = 0
    for _ in string.gmatch(body, "%d+=[%w_]+%*") do
        n = n + 1
    end
    return n
end

local function ExpectedExtAIChoiceCount()
    local ids = Game:GetProperty("PROP_NW_HAIKESI_EXT_AI_OPTION_IDS")
    if ids == nil or tostring(ids) == "" then
        return 0
    end
    local n = 0
    for _ in string.gmatch(tostring(ids), "[^,]+") do
        n = n + 1
    end
    return n
end

local function LooksLikeExtAIApply(text)
    if text == nil or text == "" then
        return false
    end
    return string.find(text, "^[%w_.%-]+#%d+=[%w_]+", 1) ~= nil
end

local function CanBroadcastExtAI()
    if Game ~= nil and Game.IsNetworkMultiplayer ~= nil and not Game.IsNetworkMultiplayer() then
        return true
    end
    return IsGameHost()
end

local function IsExtAIPending()
    -- 读档/回主菜单等帧上 Game 可能暂为 nil；横幅 tick 每帧调用
    if Game == nil or Game.GetProperty == nil then
        return false
    end
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

-- 托管给 AI / 观战后 GetLocalPlayer 常为 -1，仍需用原席位发 EXECUTE_SCRIPT
local function ResolveExtAIExecutePlayer()
    local localPlayer = Game.GetLocalPlayer()
    if localPlayer ~= nil and localPlayer >= 0 then
        return localPlayer
    end
    local requester = tonumber(Game:GetProperty(EXT_AI_REQUESTER_PROP) or -1)
    if requester ~= nil and requester >= 0 and Players[requester] ~= nil then
        print("[Haikesi ExtAI MP] localPlayer invalid; use requester P" .. tostring(requester))
        return requester
    end
    local netId = nil
    pcall(function()
        if Network ~= nil and Network.GetLocalPlayerID ~= nil then
            netId = Network.GetLocalPlayerID()
        end
    end)
    if netId ~= nil and netId >= 0 then
        print("[Haikesi ExtAI MP] localPlayer invalid; use Network.GetLocalPlayerID P" .. tostring(netId))
        return netId
    end
    return nil
end

local function BroadcastExtAIApplyFromMP(payload)
    if not CanBroadcastExtAI() then
        print("[Haikesi ExtAI MP] skip apply: not host / no authority")
        return false
    end
    local localPlayer = ResolveExtAIExecutePlayer()
    if localPlayer == nil or localPlayer < 0 then
        print("[Haikesi ExtAI MP] skip apply: no local player (human→AI/observer?)")
        return false
    end
    local param = {}
    param['OnStart'] = 'HaikesiSelectRelic'
    param['ExtAIApply'] = payload
    UI.RequestPlayerOperation(localPlayer, PlayerOperations.EXECUTE_SCRIPT, param)
    print("[Haikesi ExtAI MP] EXECUTE_SCRIPT ExtAIApply len=" .. tostring(#payload)
        .. " via P" .. tostring(localPlayer))
    return true
end

-- watch 写入 Logs/haikesi_extai_apply.txt；UI Context 可读盘（Gameplay 通常不能）
local function ReadExtAIWireFromApplyFile()
    local paths = {}
    pcall(function()
        local la = os.getenv("LOCALAPPDATA")
        if la ~= nil and la ~= "" then
            table.insert(paths, la .. "\\Firaxis Games\\Sid Meier's Civilization VI\\Logs\\haikesi_extai_apply.txt")
        end
    end)
    pcall(function()
        local up = os.getenv("USERPROFILE")
        if up ~= nil and up ~= "" then
            table.insert(paths, up .. "\\Documents\\My Games\\Sid Meier's Civilization VI\\Logs\\haikesi_extai_apply.txt")
            table.insert(paths, up .. "\\文档\\My Games\\Sid Meier's Civilization VI\\Logs\\haikesi_extai_apply.txt")
            table.insert(paths, up .. "\\OneDrive\\Documents\\My Games\\Sid Meier's Civilization VI\\Logs\\haikesi_extai_apply.txt")
        end
    end)
    if io == nil or io.open == nil then
        return nil
    end
    for _, path in ipairs(paths) do
        local ok, text = pcall(function()
            local f = io.open(path, "r")
            if f == nil then
                return nil
            end
            local body = f:read("*a")
            f:close()
            return body
        end)
        if ok and text ~= nil then
            local raw = TrimExtAIPayload(text)
            if LooksLikeExtAIApply(raw) then
                return raw, path
            end
        end
    end
    return nil
end

local function ApplyExtAIPayload(raw, source)
    raw = TrimExtAIPayload(raw)
    if raw == "" then
        return false
    end
    if not LooksLikeExtAIApply(raw) then
        print("[Haikesi ExtAI MP] payload shape rejected (" .. tostring(source) .. ") len="
            .. tostring(#raw))
        return false
    end
    -- 粘贴未完成 / 旧 Trim 截断：条目数不足时拒绝，避免只生效第一个 AI 并清 pending
    local gotN = CountExtAIWireChoices(raw)
    local expectN = ExpectedExtAIChoiceCount()
    if gotN < 1 then
        print("[Haikesi ExtAI MP] payload has 0 choices (" .. tostring(source) .. ") len="
            .. tostring(#raw))
        return false
    end
    if expectN > 0 and gotN < expectN then
        print(string.format(
            "[Haikesi ExtAI MP] incomplete wire (%s): choices=%d expected=%d len=%d — wait full paste/apply.txt",
            tostring(source), gotN, expectN, #raw))
        return false
    end
    -- 仍 pending 时允许重贴同一 wire（上次广播可能 Gameplay 拒收 / 无席位）
    if raw == g_ExtAILastAutoApply and not IsExtAIPending() then
        print("[Haikesi ExtAI MP] skip duplicate wire (already applied, no pending)")
        return false
    end
    local pendingId = Game:GetProperty("PROP_NW_HAIKESI_EXT_AI_REQUEST_ID")
    local wireId = string.match(raw, "^([^#]+)#")
    print(string.format(
        "[Haikesi ExtAI MP] apply try source=%s wireId=%s pendingId=%s pending=%s len=%d choices=%d/%d",
        tostring(source), tostring(wireId), tostring(pendingId),
        tostring(IsExtAIPending()), #raw, gotN, expectN))

    -- 联机：先 EXECUTE_SCRIPT 广播；主机再直调 Gameplay 兜底（脚本未进时仍能落地）
    local broadcastOk = BroadcastExtAIApplyFromMP(raw)
    local localOk = false
    pcall(function()
        if not CanBroadcastExtAI() then
            return
        end
        local fn = ExposedMembers and ExposedMembers.Haikesi_ApplyExtAIWire
        if type(fn) == "function" and IsExtAIPending() then
            localOk = fn(raw) == true
            print("[Haikesi ExtAI MP] ExposedMembers.Haikesi_ApplyExtAIWire => "
                .. tostring(localOk))
        end
    end)
    if not broadcastOk and not localOk and IsExtAIPending() then
        return false
    end

    -- 直调成功或 pending 已清：立刻藏横幅（Gameplay→UI 的 Cleared 事件常丢）
    local pendingGone = (not IsExtAIPending()) or localOk
    if pendingGone then
        g_ExtAILastAutoApply = raw
        if Controls ~= nil and Controls.ExtAIPayloadEdit ~= nil then
            Controls.ExtAIPayloadEdit:SetText("")
        end
        g_ExtAIUiConsumed = true
        g_ExtAIPendingNotified = false
        g_ExtAIBannerRetryFrames = 0
        SetExtAIBannerVisible(false)
        print("[Haikesi ExtAI MP] apply OK + banner hidden (" .. tostring(source) .. ")")
    else
        print("[Haikesi ExtAI MP] apply sent but still pending — check Lua.log ExtAIApply* ("
            .. tostring(source) .. ")")
        FocusExtAIEditBox()
    end
    return true
end

local function ApplyExtAIFromEditBox(source)
    if Controls == nil or Controls.ExtAIPayloadEdit == nil then
        print("[Haikesi ExtAI MP] EditBox missing")
        return false
    end
    local raw = TrimExtAIPayload(Controls.ExtAIPayloadEdit:GetText())
    if LooksLikeExtAIApply(raw) then
        return ApplyExtAIPayload(raw, source)
    end
    return false
end

local function TryApplyExtAIAnySource(source)
    if not IsExtAIPending() and not g_ExtAIPendingNotified then
        return false
    end
    if ApplyExtAIFromEditBox(source .. ":edit") then
        return true
    end
    local fileWire, path = ReadExtAIWireFromApplyFile()
    if fileWire ~= nil then
        print("[Haikesi ExtAI MP] loaded apply.txt: " .. tostring(path))
        return ApplyExtAIPayload(fileWire, source .. ":file")
    end
    print("[Haikesi ExtAI MP] no wire in EditBox/apply.txt (" .. tostring(source) .. ")")
    return false
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

local function OnExtAIClearedUI(source)
    g_ExtAIPendingNotified = false
    g_ExtAIUiConsumed = false
    g_ExtAIBannerRetryFrames = 0
    SetExtAIBannerVisible(false)
    print("[Haikesi ExtAI MP] pending cleared (" .. tostring(source or "event") .. ")")
end

local function ShowExtAIPendingBannerNow(source)
    RefreshExtAIMilitaryCache()
    if not CanBroadcastExtAI() then
        SetExtAIBannerVisible(false)
        return false
    end
    -- 单机走 FireTuner Stage→广播，不弹联机 Ctrl+V 横幅；顺带捞一次 staged
    if not IsNetworkMultiplayerGame() then
        SetExtAIBannerVisible(false)
        ProcessStagedExtAI()
        return false
    end
    if not IsExtAIPending() then
        return false
    end
    -- 已消费成功、等 Game prop 同步：禁止横幅重弹
    if g_ExtAIUiConsumed then
        SetExtAIBannerVisible(false)
        return false
    end
    g_ExtAIBannerRetryFrames = 0
    -- 新 pending：允许重贴上一局同内容的 exchange
    g_ExtAILastAutoApply = ""
    if Controls == nil or Controls.ExtAIPayloadEdit == nil then
        print("[Haikesi ExtAI MP] pending UI skip: EditBox missing (" .. tostring(source) .. ")")
        return false
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
        local rid = Game:GetProperty("PROP_NW_HAIKESI_EXT_AI_REQUEST_ID") or "?"
        print("[Haikesi ExtAI MP] pending banner (" .. tostring(source or "event")
            .. ") request_id=" .. tostring(rid))
    end
    FocusExtAIEditBox()
    ApplyExtAIFromEditBox("pending")
    return true
end

-- 选卡确认 / Gameplay 建 pending / 读档恢复：联机显示横幅；单机仅尝试 staged
-- 横幅与 LLM 并行：pending 一建就显示，不必等 exchange 生成
local function OnExtAIPendingUI(source)
    if not IsNetworkMultiplayerGame() then
        SetExtAIBannerVisible(false)
        ProcessStagedExtAI()
        return
    end
    local ok, err = pcall(function()
        if ShowExtAIPendingBannerNow(source) then
            return
        end
        if IsExtAIPending() then
            return
        end
        -- pending 尚未回写：短重试（watch 已能看到 dump 时常见）
        g_ExtAIBannerRetryFrames = EXT_AI_BANNER_RETRY_MAX
        print("[Haikesi ExtAI MP] pending not visible yet — retry banner ("
            .. tostring(source) .. ", frames=" .. tostring(EXT_AI_BANNER_RETRY_MAX) .. ")")
    end)
    if not ok then
        print("[Haikesi ExtAI MP] OnExtAIPendingUI error: " .. tostring(err))
    end
end

local g_ExtAIApplyFilePollCooldown = 0
local g_ExtAILastEditBoxSeen = ""
local g_ExtAIEditRetryCooldown = 0

local function TickExtAIBannerRetry()
    -- pending 已清：强制收横幅（不依赖跨 Context LuaEvent）
    if not IsExtAIPending() then
        if g_ExtAIPendingNotified or g_ExtAIUiConsumed then
            OnExtAIClearedUI("tick")
        else
            -- 状态已空但横幅仍露着（Cleared 丢事件）时兜底藏起
            pcall(function()
                if Controls ~= nil and Controls.ExtAIBanner ~= nil
                    and Controls.ExtAIBanner.IsHidden ~= nil
                    and not Controls.ExtAIBanner:IsHidden() then
                    SetExtAIBannerVisible(false)
                end
            end)
        end
        g_ExtAIEditRetryCooldown = 0
        return
    end
    -- 已消费：保持隐藏，不再轮询粘贴/文件
    if g_ExtAIUiConsumed then
        SetExtAIBannerVisible(false)
        g_ExtAIEditRetryCooldown = 0
        g_ExtAIBannerRetryFrames = 0
        return
    end
    if g_ExtAIBannerRetryFrames > 0 then
        g_ExtAIBannerRetryFrames = g_ExtAIBannerRetryFrames - 1
        if IsExtAIPending() then
            pcall(function()
                ShowExtAIPendingBannerNow("retry")
            end)
        elseif g_ExtAIBannerRetryFrames <= 0 then
            print("[Haikesi ExtAI MP] banner retry exhausted (still no pending) — "
                .. "Ctrl+Alt+Shift+R 聚焦，或 Ctrl+Alt+Shift+V")
        end
    end
    -- pending：轮询 EditBox（Civ6 粘贴常不触发 OnChange）+ apply.txt
    if g_ExtAIApplyFilePollCooldown > 0 then
        g_ExtAIApplyFilePollCooldown = g_ExtAIApplyFilePollCooldown - 1
        return
    end
    g_ExtAIApplyFilePollCooldown = 15 -- ~0.5s
    pcall(function()
        -- 1) EditBox：内容变化立刻试；失败则降频重试
        if Controls ~= nil and Controls.ExtAIPayloadEdit ~= nil then
            local raw = TrimExtAIPayload(Controls.ExtAIPayloadEdit:GetText())
            local changed = (raw ~= g_ExtAILastEditBoxSeen)
            if changed then
                g_ExtAILastEditBoxSeen = raw
                g_ExtAIEditRetryCooldown = 0
                if #raw > 0 then
                    print(string.format(
                        "[Haikesi ExtAI MP] EditBox poll len=%d head=%s look=%s",
                        #raw, string.sub(raw, 1, 64),
                        tostring(LooksLikeExtAIApply(raw))))
                end
            end
            if LooksLikeExtAIApply(raw) then
                if changed or g_ExtAIEditRetryCooldown <= 0 then
                    ApplyExtAIPayload(raw, changed and "editpoll" or "editretry")
                    g_ExtAIEditRetryCooldown = 8 -- 再失败约 4s 后重试
                    if not IsExtAIPending() then
                        return
                    end
                else
                    g_ExtAIEditRetryCooldown = g_ExtAIEditRetryCooldown - 1
                end
            end
        end
        -- 2) apply.txt
        local fileWire = ReadExtAIWireFromApplyFile()
        if fileWire == nil then
            return
        end
        local pendingId = tostring(
            Game:GetProperty("PROP_NW_HAIKESI_EXT_AI_REQUEST_ID") or "")
        local wireId = string.match(fileWire, "^([^#]+)#") or ""
        if pendingId ~= "" and wireId ~= pendingId then
            return
        end
        ApplyExtAIPayload(fileWire, "filepoll")
    end)
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
            if not IsNetworkMultiplayerGame() then
                ProcessStagedExtAI()
                return true
            end
            print("[Haikesi ExtAI MP] hotkey R → show banner + focus EditBox")
            if IsExtAIPending() or g_ExtAIPendingNotified then
                SetExtAIBannerVisible(true, "LOC_HAIKESI_EXT_AI_BANNER_PENDING")
            end
            FocusExtAIEditBox()
            return true
        end
        return true
    end
    if key == Keys.V then
        if uiMsg == KeyEvents.KeyDown then
            if not IsNetworkMultiplayerGame() then
                ProcessStagedExtAI()
                return true
            end
            print("[Haikesi ExtAI MP] hotkey V → apply EditBox / apply.txt")
            if IsExtAIPending() then
                SetExtAIBannerVisible(true, "LOC_HAIKESI_EXT_AI_BANNER_PENDING")
            end
            TryApplyExtAIAnySource("hotkeyV")
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
        if IsNetworkMultiplayerGame() then
            if not IsExtAIPending() and (g_ExtAIPendingNotified or g_ExtAIUiConsumed) then
                OnExtAIClearedUI("TurnBegin")
            elseif IsExtAIPending() and not g_ExtAIPendingNotified and not g_ExtAIUiConsumed then
                OnExtAIPendingUI("TurnBegin")
            end
        end
    end)
    Events.TurnEnd.Add(function()
        OnTurnPhase("TurnEnd")
    end)
    Events.LocalPlayerTurnBegin.Add(function()
        OnLocalPlayerTurnBegin()
        RefreshExtAIMilitaryCache()
        ProcessStagedExtAI()
        if IsNetworkMultiplayerGame() then
            if not IsExtAIPending() and (g_ExtAIPendingNotified or g_ExtAIUiConsumed) then
                OnExtAIClearedUI("LocalPlayerTurnBegin")
            elseif IsExtAIPending() and not g_ExtAIPendingNotified and not g_ExtAIUiConsumed then
                OnExtAIPendingUI("LocalPlayerTurnBegin")
            end
        end
    end)
    -- 攻城通知 + ExtAI：帧末捞 staged（Gameplay→UI 的 LuaEvents 常丢）+ 联机横幅重试
    Events.GameCoreEventPublishComplete.Add(function()
        pcall(ProcessAssaultNotifyQueue)
        pcall(ProcessStagedExtAI)
        pcall(TickExtAIBannerRetry)
    end)

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
    -- Gameplay dump 前经 ExposedMembers 同步刷缓存（跨 Context 比 LuaEvents 可靠）
    if ExposedMembers ~= nil then
        ExposedMembers.Haikesi_RefreshExtAIUICache = RefreshExtAIMilitaryCache
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
    print("[Haikesi UI] TriTrade/BarbNotify/ExtAI ready (Ctrl+V / apply.txt / Ctrl+Alt+Shift+V)")
end


Events.LoadScreenClose.Add(Initialize)
