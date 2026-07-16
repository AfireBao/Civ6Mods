-- ===========================================================================
-- Haikesi_TriTrade_GamePlay.lua
-- 三角贸易 (TRIANGULARTRADERUNE)：从主 GamePlay 脚本拆出，避免寄存器超限。
-- ===========================================================================

local function ScaleTurnForGameSpeed(standardTurn)
    local speedType = GameConfiguration.GetGameSpeedType()
    local row = GameInfo.GameSpeeds[speedType]
    if row == nil then return standardTurn end
    return math.max(1, math.floor(standardTurn * row.CostMultiplier + 0.5))
end

local function ScalePopForGameSpeed(standardPop)
    local speedType = GameConfiguration.GetGameSpeedType()
    local row = GameInfo.GameSpeeds[speedType]
    if row == nil then return standardPop end
    return math.max(1, math.floor(standardPop * row.CostMultiplier + 0.5))
end

local function PickRandomIndex(maxCount, reason)
    if maxCount <= 0 then return 0 end
    if TerrainBuilder ~= nil and TerrainBuilder.GetRandomNumber ~= nil then
        return TerrainBuilder.GetRandomNumber(maxCount, reason)
    end
    return Game.GetRandNum(maxCount, reason) or 0
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

function Haikesi_SyncTriTradeYieldModifiersAll()
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

function Haikesi_ApplyTriangularTradeRelicEffect(iPlayer, pPlayer)
    if pPlayer == nil then return end
    pPlayer:SetProperty(TRI_TRADE_YIELD_MODS_PROP, 1)
    TriTradeLog(
        "relic enabled P%d turn=%d — route scan/logs via UI TriTrade_Bridge",
        iPlayer, Game.GetCurrentGameTurn()
    )
end

local function InitializeTriTrade()
    GameEvents.HaikesiTriTradeComplete.Add(HaikesiTriTradeComplete)
    ExposedMembers.HaikesiTriTradeCompleteFromUI = Haikesi_TriTradeCompleteFromUI
    Haikesi_SyncTriTradeYieldModifiersAll()
    print("[Haikesi TriTrade] GamePlay bridge ready")
end

Events.LoadScreenClose.Add(InitializeTriTrade)
