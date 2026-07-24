-- ===========================================================================
-- Haikesi_WarFeed_Bridge.lua
-- 弑杀蜂群：击杀粮食飞字（Gameplay 无 WorldView UI API）
-- 生物质剩余回合悬停：见 Haikesi_CityPanelOverview（ReplaceUIScript）
-- ===========================================================================

local function ShowWarFeedFoodFloater(killerPlayerID, x, y, foodAmount)
    killerPlayerID = tonumber(killerPlayerID)
    x = tonumber(x)
    y = tonumber(y)
    foodAmount = tonumber(foodAmount) or 0
    if killerPlayerID == nil or x == nil or y == nil or foodAmount <= 0 then
        return
    end

    local localPlayer = Game.GetLocalPlayer()
    if localPlayer == nil or localPlayer < 0 or killerPlayerID ~= localPlayer then
        return
    end

    if UI == nil or UI.AddWorldViewText == nil or EventSubTypes == nil then
        print('[Haikesi WarFeed UI] AddWorldViewText unavailable')
        return
    end

    local szText = Locale.Lookup('LOC_WORLD_FOOD_INCREASE_FLOATER', foodAmount)
    if szText == nil or szText == '' then
        szText = string.format('[COLOR_FLOAT_FOOD]+%d [ICON_Food][ENDCOLOR]', foodAmount)
    end

    local subType = EventSubTypes.PLOT or EventSubTypes.DAMAGE
    pcall(function()
        UI.AddWorldViewText(subType, szText, x, y, killerPlayerID)
    end)
end

local function Initialize()
    if ExposedMembers ~= nil then
        ExposedMembers.Haikesi_WarFeedShowFoodFloater = ShowWarFeedFoodFloater
    end
    if LuaEvents ~= nil then
        LuaEvents.Haikesi_WarFeedShowFoodFloater.Add(ShowWarFeedFoodFloater)
    end
    print('[Haikesi WarFeed UI] bridge ready (food floater)')
end

Events.LoadScreenClose.Add(Initialize)
