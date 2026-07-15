-- ===========================================================================
-- Haikesi_Bean_GamePlay.lua
-- 憨豆改名已迁至 UI/Haikesi_Bean_Bridge.lua（UnitCommandTypes.NAME_UNIT）。
-- Gameplay 侧 pUnit:SetName 为 nil，保留本文件仅作说明，避免再注册无效钩子。
-- 宜居仍由 SQL：ABILITY_NW_BEAN + REQUIREMENT_CITY_HAS_COUNTERSPY。
-- ===========================================================================

local function InitializeBean()
    print('[Haikesi Bean] GamePlay stub (rename = UI NAME_UNIT bridge)')
end

Events.LoadScreenClose.Add(InitializeBean)
