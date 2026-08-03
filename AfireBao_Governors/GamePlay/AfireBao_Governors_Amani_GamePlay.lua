-- ===========================================================================
-- AfireBao_Governors_Amani_GamePlay.lua
-- Applies the UI-rebuilt Amani state to city-center plot properties consumed
-- by Governors_XP2.sql requirements.
-- ===========================================================================

local AMANI_ESTABLISHED_PROPERTY = "AMANI_ESTABLISHED_CS"
local ROUTE_TO_AMANI_PROPERTY = "TRADER_TO_AMANI_CS"

local function AmaniLog(message)
    print("[AfireBao Governors Amani Gameplay] " .. tostring(message))
end

local function ParseCityIDSet(value)
    local result = {}
    local textValue = tostring(value or "")
    for token in string.gmatch(textValue, "[^,]+") do
        local cityID = tonumber(token)
        if cityID ~= nil then
            result[cityID] = true
        end
    end
    return result
end

local function SetPlotProperty(pPlot, propertyName, enabled)
    if pPlot == nil then return end
    local desired = enabled and 1 or nil
    if pPlot:GetProperty(propertyName) ~= desired then
        pPlot:SetProperty(propertyName, desired)
    end
end

local function OnSyncAmani(playerID, parameters)
    local pPlayer = Players[playerID]
    if pPlayer == nil or parameters == nil then return end

    local established = tonumber(parameters.Established or 0) == 1
    local minorPlayerID = tonumber(parameters.MinorPlayerID or -1) or -1
    local routeCityIDs = ParseCityIDSet(parameters.RouteCityIDs)
    local pCities = pPlayer:GetCities()
    local updatedCities = 0

    if pCities ~= nil then
        for _, pCity in pCities:Members() do
            local pPlot = Map.GetPlot(pCity:GetX(), pCity:GetY())
            SetPlotProperty(pPlot, AMANI_ESTABLISHED_PROPERTY, established)
            SetPlotProperty(
                pPlot,
                ROUTE_TO_AMANI_PROPERTY,
                established and routeCityIDs[pCity:GetID()] == true
            )
            updatedCities = updatedCities + 1
        end
    end

    AmaniLog(string.format(
        "sync applied P%d established=%s minor=%d cities=%d reason=%s",
        playerID, tostring(established), minorPlayerID, updatedCities,
        tostring(parameters.Reason or "unknown")
    ))
end

local function Initialize()
    GameEvents.AfireBaoGovernorsSyncAmani.Add(OnSyncAmani)
    AmaniLog("handler initialized")
end

Initialize()
