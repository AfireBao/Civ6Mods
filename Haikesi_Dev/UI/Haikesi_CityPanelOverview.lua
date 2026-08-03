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

local BIOMASS_CITY_PROP = 'PROP_NW_WARFEED_BIOMASS_V2'
local GENESIS_RELIC = 'GENESISRUNE'
local DEATH_CULT_RELIC = 'DEATHCULTRUNE'
local RelicsCountPropertyKey = 'PROP_NW_HAIKESI_RELIC_COUNT'
local RelicsSlotPropertyPrefix = 'PROP_NW_HAIKESI_RELIC_'

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

local function LookupOrFallback(tag, fallback)
    local s = Locale.Lookup(tag)
    if s == nil or s == '' or s == tag then
        return fallback
    end
    return s
end

local function SetToolTipIfPossible(control, tip)
    if control ~= nil and control.SetToolTipString ~= nil then
        control:SetToolTipString(tip or '')
    end
end

local function FormatPlusMinusPercent(value)
    local rounded = value
    if Round ~= nil then
        rounded = Round(value, 0)
    else
        rounded = math.floor(value + 0.5)
    end

    if toPlusMinusString ~= nil then
        return toPlusMinusString(rounded) .. '%'
    end
    if rounded > 0 then
        return '+' .. tostring(rounded) .. '%'
    end
    return tostring(rounded) .. '%'
end

local function ParseBiomassLevel(buildingType)
    if buildingType == nil then return nil end
    local levelStr = string.match(buildingType, '^BUILDING_NW_WARFEED_BIOMASS_P(%d+)$')
    return tonumber(levelStr)
end

local function IsHaikesiHiddenBuilding(buildingType)
    return buildingType == 'BUILDING_NW_DEATH_CULT_PROJECT_UNLOCK'
end

local function ParseCityBiomassProp(raw)
    local entries = {}
    if raw == nil or raw == '' then return entries end
    for piece in string.gmatch(tostring(raw), '[^|]+') do
        local amountStr, expStr = string.match(piece, '^(%d+):(%-?%d+)$')
        local amount = tonumber(amountStr)
        local exp = tonumber(expStr)
        if amount ~= nil and amount > 0 and exp ~= nil then
            entries[#entries + 1] = { amount = amount, expire = exp }
        end
    end
    return entries
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

local function GetBiomassSummary(entries)
    local now = Game.GetCurrentGameTurn()
    local totalFood = 0
    local soonest = nil
    for i = 1, #entries do
        local entry = entries[i]
        if entry.expire ~= nil and now < entry.expire then
            totalFood = totalFood + (entry.amount or 0)
            if soonest == nil or entry.expire < soonest then
                soonest = entry.expire
            end
        end
    end
    return totalFood, soonest
end

local function FormatDurationLines(entries)
    local now = Game.GetCurrentGameTurn()
    local lines = {}
    local totalFood, soonest = GetBiomassSummary(entries)
    if totalFood > 0 and soonest ~= nil then
        local remain = math.max(0, soonest - now)
        local duration = Locale.Lookup('LOC_HAIKESI_BIOMASS_DURATION_LINE', remain, soonest)
        if duration == nil or duration == '' or duration == 'LOC_HAIKESI_BIOMASS_DURATION_LINE' then
            duration = string.format('最早一批生物质：剩余 %d 回合（到期回合 %d）', remain, soonest)
        end
        lines[#lines + 1] = duration

        local s = Locale.Lookup(
            'LOC_HAIKESI_BIOMASS_CITY_SUMMARY',
            totalFood,
            soonest,
            remain)
        if s == nil or s == '' or s == 'LOC_HAIKESI_BIOMASS_CITY_SUMMARY' then
            s = string.format(
                '本城生物质合计 +%d 食物；最早到期回合 %d（剩余 %d 回合）',
                totalFood, soonest, remain)
        end
        lines[#lines + 1] = s
    else
        local s = Locale.Lookup('LOC_HAIKESI_BIOMASS_DURATION_UNKNOWN')
        if s == nil or s == '' or s == 'LOC_HAIKESI_BIOMASS_DURATION_UNKNOWN' then
            s = '生物质：状态记录缺失'
        end
        lines[#lines + 1] = s
    end
    return lines
end

local function AppendBiomassToolTip(baseTip, buildingHash, playerId, city)
    local building = GameInfo.Buildings[buildingHash]
    if building == nil then return baseTip end
    local level = ParseBiomassLevel(building.BuildingType)
    if level == nil then return baseTip end

    local entries = ParseCityBiomassProp(GetCityBiomassProp(city))
    local extra = FormatDurationLines(entries)
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

local function RefreshDeathCultGrowthRow(data)
    if Controls == nil or Controls.OtherGrowthBonuses == nil then
        return
    end

    local tip = ''
    local city = UI.GetHeadSelectedCity()
    if city ~= nil
        and (data == nil or data.TurnsUntilGrowth == nil or data.TurnsUntilGrowth > -1)
        and PlayerHasRelic(city:GetOwner(), DEATH_CULT_RELIC) then
        tip = LookupOrFallback(
            'LOC_HAIKESI_DEATH_CULT_GROWTH_TOOLTIP',
            '死亡崇拜：城市增长速度 +50%。')

        if data ~= nil and data.OtherGrowthModifiers ~= nil and Controls.OtherGrowthBonuses.SetText ~= nil then
            local percentText = FormatPlusMinusPercent((tonumber(data.OtherGrowthModifiers) or 0) * 100)
            local rowText = Locale.Lookup('LOC_HAIKESI_DEATH_CULT_GROWTH_ROW', percentText)
            if rowText == nil or rowText == '' or rowText == 'LOC_HAIKESI_DEATH_CULT_GROWTH_ROW' then
                rowText = percentText
            end
            Controls.OtherGrowthBonuses:SetText(rowText)
        end
    end

    SetToolTipIfPossible(Controls.OtherGrowthBonuses, tip)
end

local function GetRemainSuffix(buildingType, city)
    local level = ParseBiomassLevel(buildingType)
    if level == nil or city == nil then return nil end
    local entries = ParseCityBiomassProp(GetCityBiomassProp(city))
    local totalFood, soonest = GetBiomassSummary(entries)
    if totalFood <= 0 or soonest == nil then return nil end
    local remain = soonest - Game.GetCurrentGameTurn()
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

if ViewPanelCitizensGrowth ~= nil then
    local BASE_ViewPanelCitizensGrowth_HaikesiDeathCult = ViewPanelCitizensGrowth
    function ViewPanelCitizensGrowth(data)
        BASE_ViewPanelCitizensGrowth_HaikesiDeathCult(data)
        local ok, err = pcall(RefreshDeathCultGrowthRow, data)
        if not ok then
            print('[Haikesi City Growth Tip] Death Cult growth row error: ' .. tostring(err))
        end
    end
    print('[Haikesi City Growth Tip] wrapped ViewPanelCitizensGrowth for Death Cult growth source')
else
    print('[Haikesi City Growth Tip] WARN: ViewPanelCitizensGrowth missing')
end

if ViewPanelBreakdown ~= nil then
    local BASE_ViewPanelBreakdown = ViewPanelBreakdown
    function ViewPanelBreakdown(data)
        local city = UI.GetHeadSelectedCity()
        if data ~= nil and data.BuildingsAndDistricts ~= nil and city ~= nil then
            for _, district in ipairs(data.BuildingsAndDistricts) do
                if district.Buildings ~= nil then
                    for i = #district.Buildings, 1, -1 do
                        local building = district.Buildings[i]
                        if building ~= nil and IsHaikesiHiddenBuilding(building.Type) then
                            table.remove(district.Buildings, i)
                        end
                    end
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
