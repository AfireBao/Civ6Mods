
--This code is for DarkAge mod
--Create your pantheon is a part of DarkAge

GameEvents = ExposedMembers.GameEvents;
ExposedMembers.DA = ExposedMembers.DA or {};
ExposedMembers.DA.Utils = ExposedMembers.DA.Utils or {};
Utils = ExposedMembers.DA.Utils;

GameEvents.GetDistrictCount.Add(function(playerID,	cityID)
	local pCity = CityManager:GetCity(playerID, cityID)
	if pCity == nil then
		return
	end
	local amount = pCity:GetDistricts():GetCount()
	--print(amount)
	GameEvents.UpdateDistrictCount.Call(playerID,	cityID, amount)
end)

function CallQuestFinished( CityStateID, CompletedQuestPlayerID)
    local pCityState = Players[CityStateID]
    local pPlayer = Players[CompletedQuestPlayerID]
    if(pCityState == nil or pPlayer == nil) then return end

    local iFirstMeet = Utils.GetPlayerProperty(CompletedQuestPlayerID, 'FIRST_MEET_CITYSTATE_'..CityStateID)
    if iFirstMeet == nil then
     	GameEvents.SetPlayerProperty.Call(CompletedQuestPlayerID, 'FIRST_MEET_CITYSTATE_'..CityStateID, 0)
        return
    end
    local era = Game.GetEras():GetCurrentEra()
    local iFinishedThisEra = Utils.GetPlayerProperty(CompletedQuestPlayerID, era..'ERA_FINISHED_CITYSTATE_'..CityStateID)
    if iFinishedThisEra == 1 then
        print('just era change')
        return
    end
    GameEvents.QuestFinished.Call(CompletedQuestPlayerID, CityStateID)
    GameEvents.SetPlayerProperty.Call(CompletedQuestPlayerID, era..'ERA_FINISHED_CITYSTATE_'..CityStateID, 1)
    --GameEvents.SendEnvoytoCityState.Call(CompletedQuestPlayerID, CityStateID)
    print('double envoy')

end

Events.QuestChanged.Add( CallQuestFinished );

Utils.GetDiplomaticAI = function(playerID)
    local player= Players[playerID];
    return player:GetDiplomaticAI()
end

Utils.HasEmbassyAt = function(iPlayer1, iPlayer2)
    local player= Players[iPlayer1];
    return player:GetDiplomacy():HasEmbassyAt(iPlayer2)
end

Utils.HasDelegationAt = function(iPlayer1, iPlayer2)
    local player= Players[iPlayer1];
    return player:GetDiplomacy():HasDelegationAt(iPlayer2)
end
--[[
for _, player in ipairs(PlayerManager.GetAliveMajors()) do
        local iRelation = Utils.GetDiplomaticAI(player:GetID()):GetDiplomaticStateIndex(0);
        if iRelation ~= nil and iRelation ~= -1 then
            local sRelation = GameInfo.DiplomaticStates[iRelation].StateType;
            if (sRelation ~= 'DIPLO_STATE_ALLIED' or sRelation == 'DIPLO_STATE_DECLARED_FRIEND') and player:GetID() ~= 0 then
                local PurchasePantheonNotificationHash = DB.MakeHash("NOTIFICATION_PURCHASE_PANTHEON");
                local sTitle = Locale.Lookup('LOC_PURCHASE_PANTHEON_TITLE');
                local sDesc = Locale.Lookup('LOC_PURCHASE_PANTHEON_DESCRIPTION', GameInfo.Civilizations[PlayerConfigurations[player:GetID()]:GetCivilizationTypeName()].Name);
                local notificationData = {};
                notificationData[ParameterTypes.MESSAGE] = sTitle;
                notificationData[ParameterTypes.SUMMARY] = sDesc
                notificationData.AlwaysUnique = true; 
                notificationData.SellPlayer = player:GetID();
                NotificationManager.SendNotification(0, PurchasePantheonNotificationHash, notificationData);
            end
        end
    end
]]

Utils.IsAI = function(playerID)
    local player= Players[playerID];
    return player:IsAI()
end

Utils.GetCurrentGovernments = function(playerID)
    local player= Players[playerID];
    return player:GetCulture():GetCurrentGovernment();
end


Utils.GetCurrentlyBuildingProgress = function(playerID, cityID, buildingID)
    local pCity = CityManager.GetCity(playerID,    cityID);
    return pCity:GetBuildQueue():GetBuildingProgress(buildingID);
end

Utils.GetCurrentlyBuildProgress = function(playerID, cityID)
    local pCity = CityManager.GetCity(playerID,    cityID);
    local pBuildQueue = pCity:GetBuildQueue();
    local iBuildHash = pBuildQueue:GetCurrentProductionTypeHash();
    local buildingDef   :table = GameInfo.Buildings[iBuildHash];
    local districtDef   :table = GameInfo.Districts[iBuildHash];
    local unitDef       :table = GameInfo.Units[iBuildHash];
    local projectDef    :table = GameInfo.Projects[iBuildHash];

    if( buildingDef ~= nil ) then
        return pBuildQueue:GetBuildingProgress(buildingDef.Index);
    elseif( districtDef ~= nil ) then
        return pBuildQueue:GetDistrictProgress(districtDef.Index);
    elseif( unitDef ~= nil ) then
        return pBuildQueue:GetUnitProgress(unitDef.Index);
    elseif (projectDef ~= nil) then
        return pBuildQueue:GetProjectProgress(projectDef.Index);
    else
        return 0;
    end
end





Utils.IsMajor = function(playerID)
    local pPlayer = Players[playerID];
    return pPlayer:IsMajor();
end

Utils.IsMinor = function(playerID)
    local pPlayer = Players[playerID];
    return pPlayer:IsMinor();
end
