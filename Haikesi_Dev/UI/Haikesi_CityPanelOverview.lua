-- ===========================================================================
-- Haikesi_CityPanelOverview.lua
-- ReplaceUIScript → CityPanelOverview（LoadOrder > Expansion2）
-- 生物质：悬停显示剩余/到期回合；列表名附「剩X回合」
-- ===========================================================================

local files = {
    "CityPanelOverview_Expansion2",
    "CityPanelOverview_Expansion1",
    "CityPanelOverview",
}
for _, file in ipairs(files) do
    include(file)
    if ViewPanelBreakdown ~= nil then
        print("[Haikesi WarFeed Tip] loaded base: " .. file)
        break
    end
end

local BIOMASS_CITY_PROP = 'PROP_NW_WARFEED_BIOMASS'
local GENESIS_RELIC = 'GENESISRUNE'
local RelicsPropertyKey = 'PROP_NW_HAIKESI_RELICS'
local RelicsCountPropertyKey = 'PROP_NW_HAIKESI_RELIC_COUNT'
local RelicsSlotPropertyPrefix = 'PROP_NW_HAIKESI_RELIC_'

local function GetRelicTypeFromIndex(index)
    if GameInfo.Haikesi_Relics == nil then return nil end
    for row in GameInfo.Haikesi_Relics() do
        if row.Index == index then
            return row.RelicType
        end
    end
    return nil
end

local function PlayerHasRelic(playerId, relicType)
    if playerId == nil or playerId < 0 or relicType == nil then return false end
    local player = Players[playerId]
    if player == nil then return false end

    local count = tonumber(player:GetProperty(RelicsCountPropertyKey) or 0) or 0
    for i = 1, count do
        if player:GetProperty(RelicsSlotPropertyPrefix .. i) == relicType then
            return true
        end
    end

    local prop = player:GetProperty(RelicsPropertyKey) or ''
    for idxStr in string.gmatch(tostring(prop), '[^|]+') do
        local idx = tonumber(idxStr)
        if idx ~= nil and GetRelicTypeFromIndex(idx) == relicType then
            return true
        end
    end
    return false
end

local function AppendExtraLines(baseTip, lines)
    if lines == nil or #lines == 0 then return baseTip end
    local parts = {}
    if baseTip ~= nil and baseTip ~= '' then
        parts[#parts + 1] = baseTip
    end
    parts[#parts + 1] = '[NEWLINE]'
    for i = 1, #lines do
        if i > 1 then
            parts[#parts + 1] = '[NEWLINE]'
        end
        parts[#parts + 1] = lines[i]
    end
    return table.concat(parts, '')
end

local function ParseBiomassPin(buildingType)
    if buildingType == nil then return nil end
    local pinStr = string.match(buildingType, '^BUILDING_NW_WARFEED_BIOMASS_P(%d+)$')
    return tonumber(pinStr)
end

local function ParseCityBiomassProp(raw)
    local byPin = {}
    if raw == nil or raw == '' then return byPin end
    for piece in string.gmatch(tostring(raw), '[^|]+') do
        local pinStr, expStr = string.match(piece, '^(%d+):(%-?%d+)$')
        local pin = tonumber(pinStr)
        local exp = tonumber(expStr)
        if pin ~= nil and exp ~= nil then
            byPin[pin] = exp
        end
    end
    return byPin
end

local function GetCityBiomassProp(city)
    if city == nil then return '' end
    local fn = ExposedMembers and ExposedMembers.Haikesi_WarFeedGetCityBiomassProp
    if type(fn) == 'function' then
        local ok, raw = pcall(fn, city:GetOwner(), city:GetID())
        if ok and raw ~= nil then
            return tostring(raw)
        end
    end
    if city.GetProperty ~= nil then
        return tostring(city:GetProperty(BIOMASS_CITY_PROP) or '')
    end
    return ''
end

local function FormatDurationLines(pin, byPin)
    local now = Game.GetCurrentGameTurn()
    local lines = {}
    local expire = byPin[pin]
    if expire ~= nil then
        local remain = expire - now
        if remain < 0 then remain = 0 end
        local s = Locale.Lookup('LOC_HAIKESI_BIOMASS_DURATION_LINE', remain, expire)
        if s == nil or s == '' or s == 'LOC_HAIKESI_BIOMASS_DURATION_LINE' then
            s = string.format('本层生物质：剩余 %d 回合（到期回合 %d）', remain, expire)
        end
        lines[#lines + 1] = s
    else
        local s = Locale.Lookup('LOC_HAIKESI_BIOMASS_DURATION_UNKNOWN')
        if s == nil or s == '' or s == 'LOC_HAIKESI_BIOMASS_DURATION_UNKNOWN' then
            s = '本层生物质：未找到到期记录（可能来自旧档）'
        end
        lines[#lines + 1] = s
    end

    local totalFood = 0
    local soonest = nil
    for _, exp in pairs(byPin) do
        if exp ~= nil and now < exp then
            totalFood = totalFood + 1
            if soonest == nil or exp < soonest then
                soonest = exp
            end
        end
    end
    if totalFood > 0 and soonest ~= nil then
        local s = Locale.Lookup(
            'LOC_HAIKESI_BIOMASS_CITY_SUMMARY',
            totalFood,
            soonest,
            math.max(0, soonest - now))
        if s == nil or s == '' or s == 'LOC_HAIKESI_BIOMASS_CITY_SUMMARY' then
            s = string.format(
                '本城生物质合计 +%d 食物；最早到期回合 %d（剩余 %d 回合）',
                totalFood, soonest, math.max(0, soonest - now))
        end
        lines[#lines + 1] = s
    end
    return lines
end

local function AppendBiomassToolTip(baseTip, buildingHash, playerId, city)
    local building = GameInfo.Buildings[buildingHash]
    if building == nil then return baseTip end
    local pin = ParseBiomassPin(building.BuildingType)
    if pin == nil then return baseTip end

    local byPin = ParseCityBiomassProp(GetCityBiomassProp(city))
    local extra = FormatDurationLines(pin, byPin)
    if #extra == 0 then return baseTip end

    return AppendExtraLines(baseTip, extra)
end

local function AppendGenesisGranaryToolTip(baseTip, buildingHash, playerId, city)
    local building = GameInfo.Buildings[buildingHash]
    if building == nil or building.BuildingType ~= 'BUILDING_GRANARY' then
        return baseTip
    end

    local ownerId = playerId
    if (ownerId == nil or ownerId < 0) and city ~= nil then
        ownerId = city:GetOwner()
    end
    if not PlayerHasRelic(ownerId, GENESIS_RELIC) then
        return baseTip
    end

    local line = Locale.Lookup('LOC_HAIKESI_GENESIS_GRANARY_HOUSING_TOOLTIP')
    if line == nil or line == '' or line == 'LOC_HAIKESI_GENESIS_GRANARY_HOUSING_TOOLTIP' then
        line = '创世纪：粮仓额外 +1 [ICON_Housing] 住房（总计 +3 [ICON_Housing] 住房）。'
    end
    return AppendExtraLines(baseTip, { line })
end

local function GetRemainSuffix(buildingType, city)
    local pin = ParseBiomassPin(buildingType)
    if pin == nil or city == nil then return nil end
    local byPin = ParseCityBiomassProp(GetCityBiomassProp(city))
    local expire = byPin[pin]
    if expire == nil then return nil end
    local remain = expire - Game.GetCurrentGameTurn()
    if remain < 0 then remain = 0 end
    local s = Locale.Lookup('LOC_HAIKESI_BIOMASS_NAME_REMAIN', remain)
    if s == nil or s == '' or s == 'LOC_HAIKESI_BIOMASS_NAME_REMAIN' then
        s = string.format('（剩%d回合）', remain)
    end
    return s
end

if ToolTipHelper ~= nil and ToolTipHelper.GetBuildingToolTip ~= nil
    and not ToolTipHelper._HaikesiWarFeedBiomassHooked then
    local original = ToolTipHelper.GetBuildingToolTip
    ToolTipHelper.GetBuildingToolTip = function(buildingHash, playerId, city)
        local tip = original(buildingHash, playerId, city)
        local ok, patched = pcall(AppendBiomassToolTip, tip, buildingHash, playerId, city)
        if ok and patched ~= nil then
            tip = patched
        end
        if not ok then
            print('[Haikesi WarFeed Tip] Append error: ' .. tostring(patched))
        end
        ok, patched = pcall(AppendGenesisGranaryToolTip, tip, buildingHash, playerId, city)
        if ok and patched ~= nil then
            tip = patched
        end
        if not ok then
            print('[Haikesi Building Tip] Genesis append error: ' .. tostring(patched))
        end
        return tip
    end
    if ToolTipHelper.TOOLTIP_GENERATORS ~= nil then
        ToolTipHelper.TOOLTIP_GENERATORS['KIND_BUILDING'] = ToolTipHelper.GetBuildingToolTip
    end
    ToolTipHelper._HaikesiWarFeedBiomassHooked = true
    print('[Haikesi WarFeed Tip] hooked GetBuildingToolTip via CityPanelOverview ReplaceUIScript')
else
    print('[Haikesi WarFeed Tip] WARN: ToolTipHelper.GetBuildingToolTip unavailable after base include')
end

if ViewPanelBreakdown ~= nil then
    local BASE_ViewPanelBreakdown = ViewPanelBreakdown
    function ViewPanelBreakdown(data)
        local city = UI.GetHeadSelectedCity()
        if data ~= nil and data.BuildingsAndDistricts ~= nil and city ~= nil then
            for _, district in ipairs(data.BuildingsAndDistricts) do
                if district.Buildings ~= nil then
                    for _, building in ipairs(district.Buildings) do
                        local suffix = GetRemainSuffix(building.Type, city)
                        if suffix ~= nil and building.Name ~= nil then
                            local baseName = string.gsub(
                                building.Name, '（剩%d+回合）$', '')
                            building.Name = baseName .. suffix
                        end
                    end
                end
            end
        end
        BASE_ViewPanelBreakdown(data)
    end
    print('[Haikesi WarFeed Tip] wrapped ViewPanelBreakdown for biomass remain suffix')
else
    print('[Haikesi WarFeed Tip] WARN: ViewPanelBreakdown missing')
end
