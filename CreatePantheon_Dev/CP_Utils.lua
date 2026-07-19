
--This code is for DarkAge mod
--Create your pantheon is a part of DarkAge

ExposedMembers.GameEvents = GameEvents
ExposedMembers.DA = ExposedMembers.DA or {};
ExposedMembers.DA.Utils = ExposedMembers.DA.Utils or {};
Utils = ExposedMembers.DA.Utils;
GameEvents.SetPlotProperty.Add(function(plotID, key, value)
    local plot = Map.GetPlotByIndex(plotID)
  --  print(plot:GetX(), plot:GetY(), plot)
    plot:SetProperty(key, value)
end)

GameEvents.GetGameProperty.Add(function(key)
    return Game.GetProperty(key)
end)

GameEvents.SetGameProperty.Add(function(key, value)
    Game.SetProperty(key, value)
end)

GameEvents.GetPlayerProperty.Add(function(playerID, key)
    local player = Players[playerID]
    return player:GetProperty(key)
end)

GameEvents.SetPlayerProperty.Add(function(playerID, key, value)
    local player = Players[playerID]
    player:SetProperty(key, value)
end)

GameEvents.SetUnitProperty.Add(function(playerID, unitID, key, value)
    local player = Players[playerID]
    local pUnits = player:GetUnits()
    local pUnit = pUnits:FindID(unitID)
    if pUnit ~= nil then
        pUnit:SetProperty(key, value)
    end
end)

--[[GameEvents.GetPlotWonderType.Add(function(plotID)
    local plot = Map.GetPlotByIndex(plotID)
    print(plot:GetWonderType())
    return plot:GetWonderType()
end)
--]]

Utils.SetPlayerProperty = function(playerID, key, value)
    local player = Players[playerID]
    player:SetProperty(key, value)
end

Utils.SetGameProperty = function(key, value)
    Game.SetProperty(key, value)
end

Utils.GetGameProperty = function(key)
    return Game.GetProperty(key)
end

Utils.GetPlotProperty = function(plot, key)
    return plot:GetProperty(key)
end

Utils.GetPlayerProperty = function(playerID, key)
    local pPlayer = Players[playerID]
    if pPlayer ~= nil then
        return pPlayer:GetProperty(key)
    end
end





--Utils.SetPlotProperty.Add(function(plotID, key, value)
--    local plot = Map.GetPlotByIndex(plotID)
--    print(plot:GetX(), plot:GetY(), plot)
--    plot:SetProperty(key, value)
--end)

function ChangeFaithBalance(playerID, amount)
    local player = Players[playerID]
    if player ~= nil then
        player:GetReligion():ChangeFaithBalance(amount)
    end
end
GameEvents.RequestChangeFaithBalance.Add(ChangeFaithBalance)


function GetCurrentlyBuilding(playerID, cityID)
    local city = CityManager.GetCity(playerID, cityID);
    return city:GetBuildQueue():CurrentlyBuilding();
end

Utils.GetCurrentlyBuilding = GetCurrentlyBuilding;
--GameEvents.GetCurrentlyBuilding.Add(Get_CurrentlyBuilding)


GameEvents.RequestFinishProgress.Add(function(playerID, cityID)
    local city = CityManager.GetCity(playerID,    cityID);    
    city:GetBuildQueue():FinishProgress();
end)

GameEvents.RequestAddProgress.Add(function(playerID, cityID,produnction)   
    local city = CityManager.GetCity(playerID,    cityID);
    city:GetBuildQueue():AddProgress(produnction);
end)

GameEvents.AddGreatPeoplePoints.Add(function(playerID, gppID, amount)
    local player = Players[playerID]
    if player ~= nil then
        print('DA DEBUG add great people point', playerID, gppID, amount)
        player:GetGreatPeoplePoints():ChangePointsTotal(gppID, amount)
    end
end)

GameEvents.RequestCreateBuilding.Add(function (playerID, cityID, buildingID)
    local city = CityManager.GetCity(playerID, cityID)
    print('DA DEBUG create building requested', playerID, cityID, buildingID)
    if city then
        local buildingQueue = city:GetBuildQueue()
        -- print(city, buildingQueue)
        buildingQueue:CreateBuilding(buildingID) 
    end
end)

GameEvents.RequestRemoveBuilding.Add(function (playerID, cityID, buildingID)
    local city = CityManager.GetCity(playerID, cityID)
    print('DA DEBUG remove building requested', playerID, cityID, buildingID)
    if city ~= nil then
        local buildings = city:GetBuildings()
        buildings:RemoveBuilding(buildingID)
    end
end)

GameEvents.StrategicResourcesChange.Add(function(playerID, ResourceType, amount)
    local player = Players[playerID]
    local playerResources = Players[playerID]:GetResources()
    local resource_id = GameInfo.Resources[ResourceType].Index
    playerResources:ChangeResourceAmount(resource_id, amount)
end)

GameEvents.SetAbilityCount.Add(function(playerID, unitID, sAbility, count)
    local player = Players[playerID]
    local pUnits = player:GetUnits()
    local pUnit = pUnits:FindID(unitID)
    local pUnitAbility = pUnit:GetAbility()
    local oldCount = pUnitAbility:GetAbilityCount(sAbility)
    pUnitAbility:ChangeAbilityCount(sAbility, count - oldCount)
end)

GameEvents.RestoreUnitMovement.Add(function(playerID, unitID)
    local player = Players[playerID]
    local pUnits = player:GetUnits()
    local pUnit = pUnits:FindID(unitID)
    if pUnit ~= nil then
        UnitManager.RestoreMovement(pUnit)
    end
end)

GameEvents.ChangeUnitMovesRemaining.Add(function(playerID, unitID, amount)
    local player = Players[playerID]
    local pUnits = player:GetUnits()
    local pUnit = pUnits:FindID(unitID)
    if pUnit ~= nil then
        UnitManager.ChangeMovesRemaining(pUnit, amount);
    end
end)

GameEvents.SendEnvoytoCityState.Add(function(playerID, citystateID)
    -- Need to make sure the second is citystate
    local player = Players[playerID]
    if player ~= nil then
        player:GetInfluence():GiveFreeTokenToPlayer(citystateID)
    end
end)


GameEvents.UnlockPolicy.Add(function(playerID, policyID)
    -- Need to make sure the second is citystate
    local player = Players[playerID]
    if player ~= nil then
        local pCulture = player:GetCulture();
        pCulture:UnlockPolicy(policyID);
    end
end)

GameEvents.PlayerAttachModifierByID.Add( function(playerID, sModifierID)
    local player = Players[playerID]
    if player ~= nil then
        player:AttachModifierByID(sModifierID)
    end
end)

GameEvents.SetPlotImprovement.Add(function(plotID, iImprovement, iPlayer)
    local plot = Map.GetPlotByIndex(plotID);
    iPlayer = iPlayer or -1;
    ImprovementBuilder.SetImprovementType(plot, iImprovement, iPlayer);
end)

GameEvents.ReduceBuildCharge.Add(function(playerID, unitID)
    local pUnit = UnitManager.GetUnit(playerID, unitID);
    if pUnit ~= nil then
        local ReduceProperty = pUnit:GetProperty('PROP_REDUCE_BUILD_CHARGE') or 0;
        ReduceProperty = ReduceProperty + 1;
        GameEvents.SetAbilityCount.Call(playerID, unitID, 'ABILITY_LOSE_'..ReduceProperty..'_BUILD_CHARGES', 1);
        pUnit:SetProperty('PROP_REDUCE_BUILD_CHARGE', ReduceProperty);
    end
end)

GameEvents.GetRandNum.Add(function(iMax, sSeed)
    local iRand = Game.GetRandNum(iMax, sSeed);
    Game.SetProperty(sSeed, iRand);
end)


Utils.RequestAddWorldView = function (text, iX, iY)
    Game.AddWorldViewText(0,text,iX,iY);
end


Utils.PlayerAttachModifierByID = function(playerID, sModifierID)
    local player = Players[playerID]
    if player ~= nil then
        player:AttachModifierByID(sModifierID)
    end
end

Utils.CityAttachModifierByID = function(playerID,   cityID, sModifierID)
    local city = CityManager.GetCity(playerID, cityID)

    if city ~= nil then
        print(sModifierID)
        city:AttachModifierByID(sModifierID)
    end
end

Utils.ChangePopulation = function(playerID, iCity,  pNewPopulation)
    local pPlayer = Players[playerID]   
    local pCity = pPlayer:GetCities():FindID(iCity) 
    if pCity ~= nil then
        pCity:ChangePopulation(pNewPopulation);
    end
end

Utils.GetUnitType = function(unitID,    playerID)
    local pUnit = UnitManager.GetUnit(playerID, unitID)
    print(pUnit)
    print(pUnit:GetID())
    return pUnit:GetType()
end

Utils.GetBuildingLocation = function (playerId, cityId, buildingId)
    local city = CityManager.GetCity(playerId, cityId);
    if city ~= nil then
        return city:GetBuildings():GetBuildingLocation(buildingId);
    end
end

Utils.PlayerHasWonder = function(playerId, wonderId)
    local player = Players[playerId];
    if player == nil then return false; end
    for _, city in player:GetCities():Members() do
        if city:GetBuildings():HasBuilding(wonderId) then
            return true;
        end
    end
    return false;
end


Utils.PlayerHasTrait = function(playerID, sTrait)
    local playerConfig = PlayerConfigurations[playerID];
    local sCiv = playerConfig:GetCivilizationTypeName();
    for tRow in GameInfo.CivilizationTraits() do
        if (tRow.CivilizationType == sCiv and tRow.TraitType == sTrait) then
            return true;
        end
    end
    local sLeader = playerConfig:GetLeaderTypeName();
    for tRow in GameInfo.LeaderTraits() do
        if (tRow.LeaderType == sLeader and tRow.TraitType == sTrait) then
            return true;
        end
    end
    return false;
end

-- Gameplay must define IsAI (UI-only definition is too late / wrong context for CP_AI).
Utils.IsAI = function(playerID)
    local player = Players[playerID]
    return player ~= nil and player:IsAI()
end

Utils.GameHasTrait = function(sTrait)
    for i, player in ipairs(Players) do
        if Utils.PlayerHasTrait(i, sTrait) then 
            return true;
        end
    end
    return false;
end






function RecordUnitMove(playerID,unitID,x,y)
    local pUnit :object = Players[playerID]:GetUnits():FindID(unitID)
    --print(" unit type"..UnitManager.GetTypeName(pUnit))
    local pPlayer = Players[playerID]
    local plotID = Map.GetPlotIndex(x,y)
    pPlayer:SetProperty('UNIT_'..unitID..'_POSITION',   plotID)
end


Events.UnitMoveComplete.Add(RecordUnitMove)
