-- ===========================================================================
-- AfireBao_Governors_Amani_Bridge.lua
-- City:GetTrade():GetOutgoingRoutes() is available in UI context. This bridge
-- rebuilds Amani's complete state and submits one deterministic Gameplay sync.
-- ===========================================================================

local AMANI_GOVERNOR_TYPE = "GOVERNOR_THE_AMBASSADOR"
local SYNC_EVENT = "AfireBaoGovernorsSyncAmani"

local function AmaniLog(message)
    print("[AfireBao Governors Amani UI] " .. tostring(message))
end

local function GetAmaniDefinition()
    if GameInfo.Governors == nil then return nil end
    return GameInfo.Governors[AMANI_GOVERNOR_TYPE]
end

local function GetAppointedAmani(playerID)
    local pPlayer = Players[playerID]
    local definition = GetAmaniDefinition()
    if pPlayer == nil or definition == nil then return nil end

    local pGovernors = pPlayer:GetGovernors()
    if pGovernors == nil or not pGovernors:HasGovernor(definition.Hash) then
        return nil
    end

    local hasGovernors, governorList = pGovernors:GetGovernorList()
    if not hasGovernors or governorList == nil then return nil end
    for _, governor in ipairs(governorList) do
        if governor:GetType() == definition.Index then
            return governor
        end
    end
    return nil
end

local function IsMinorCity(pCity)
    if pCity == nil then return false end
    local ownerID = pCity:GetOwner()
    local pOwner = Players[ownerID]
    return pOwner ~= nil and not pOwner:IsMajor() and not pOwner:IsBarbarian()
end

local function CityHasRouteToPlayer(pCity, targetPlayerID)
    if pCity == nil or targetPlayerID == nil or targetPlayerID < 0 then
        return false
    end
    local pTrade = pCity:GetTrade()
    if pTrade == nil then return false end
    local routes = pTrade:GetOutgoingRoutes()
    if routes == nil then return false end
    for _, route in ipairs(routes) do
        if route.DestinationCityPlayer == targetPlayerID then
            return true
        end
    end
    return false
end

local function BuildAmaniState(playerID)
    local pPlayer = Players[playerID]
    local definition = GetAmaniDefinition()
    if pPlayer == nil or definition == nil then
        return false, -1, ""
    end

    local governor = GetAppointedAmani(playerID)
    if governor == nil then
        return false, -1, ""
    end

    local assignedCity = governor:GetAssignedCity()
    if not IsMinorCity(assignedCity)
        or not governor:IsEstablished(definition.Index) then
        return false, -1, ""
    end

    local minorPlayerID = assignedCity:GetOwner()
    local routeCityIDs = {}
    local pCities = pPlayer:GetCities()
    if pCities ~= nil then
        for _, pCity in pCities:Members() do
            if CityHasRouteToPlayer(pCity, minorPlayerID) then
                table.insert(routeCityIDs, tostring(pCity:GetID()))
            end
        end
    end
    table.sort(routeCityIDs)
    return true, minorPlayerID, table.concat(routeCityIDs, ",")
end

local function RequestAmaniSync(playerID, reason)
    if playerID == nil or playerID < 0 then return end
    local pPlayer = Players[playerID]
    if pPlayer == nil or not pPlayer:IsMajor() then return end

    local established, minorPlayerID, routeCityIDs = BuildAmaniState(playerID)
    local parameters = {}
    parameters.OnStart = SYNC_EVENT
    parameters.Established = established and 1 or 0
    parameters.MinorPlayerID = minorPlayerID
    parameters.RouteCityIDs = routeCityIDs
    parameters.Reason = tostring(reason or "unknown")
    UI.RequestPlayerOperation(playerID, PlayerOperations.EXECUTE_SCRIPT, parameters)
    AmaniLog(string.format(
        "sync requested P%d established=%s minor=%d cities=%s reason=%s",
        playerID, tostring(established), minorPlayerID,
        routeCityIDs ~= "" and routeCityIDs or "none", tostring(reason)
    ))
end

local function OnGovernorAssigned(cityOwnerID, cityID, governorOwnerID, governorType)
    local definition = GetAmaniDefinition()
    if definition ~= nil and governorType == definition.Index then
        RequestAmaniSync(governorOwnerID, "GovernorAssigned")
    end
end

local function OnGovernorChanged(governorOwnerID, governorType)
    local definition = GetAmaniDefinition()
    if definition ~= nil and governorType == definition.Index then
        RequestAmaniSync(governorOwnerID, "GovernorChanged")
    end
end

local function OnTradeRouteActivityChanged(
    playerID, originPlayerID, originCityID, targetPlayerID, targetCityID
)
    RequestAmaniSync(originPlayerID, "TradeRouteActivityChanged")
end

local function SyncLocalPlayer(reason)
    local localPlayerID = Game.GetLocalPlayer()
    if localPlayerID ~= nil and localPlayerID >= 0 then
        RequestAmaniSync(localPlayerID, reason)
    end
end

local function Initialize()
    Events.GovernorAssigned.Add(OnGovernorAssigned)
    Events.GovernorChanged.Add(OnGovernorChanged)
    Events.TradeRouteActivityChanged.Add(OnTradeRouteActivityChanged)
    Events.LocalPlayerTurnBegin.Add(function()
        SyncLocalPlayer("LocalPlayerTurnBegin")
    end)
    if Events.LoadGameViewStateDone ~= nil then
        Events.LoadGameViewStateDone.Add(function()
            SyncLocalPlayer("LoadGameViewStateDone")
        end)
    end
    AmaniLog("bridge initialized")
end

Initialize()
