-- ===========================================================================
-- Haikesi_Config_FE.sql — 海克斯大乱斗 FrontEnd 游戏模式配置
-- ===========================================================================

INSERT INTO Parameters(ParameterId, Name, Description, Domain, DefaultValue, ConfigurationGroup, ConfigurationId, GroupId, SortIndex) VALUES
('NW_HAIKESI_MODE', 'LOC_NW_HAIKESI_MODE_NAME', 'LOC_NW_HAIKESI_MODE_DESC', 'NwHaikesiMode', 0, 'Game', 'NW_HAIKESI_MODE', 'AdvancedOptions', 1700),
('NW_HAIKESI_AI_RELIC', 'LOC_NW_HAIKESI_AI_RELIC_NAME', 'LOC_NW_HAIKESI_AI_RELIC_DESC', 'bool', 0, 'Game', 'NW_HAIKESI_AI_RELIC', 'AdvancedOptions', 1701),
('NW_HAIKESI_EXTERNAL_AI', 'LOC_NW_HAIKESI_EXTERNAL_AI_NAME', 'LOC_NW_HAIKESI_EXTERNAL_AI_DESC', 'bool', 0, 'Game', 'NW_HAIKESI_EXTERNAL_AI', 'AdvancedOptions', 1702);

INSERT INTO DomainValues(Domain, Value, Name, Description, SortIndex) VALUES
('NwHaikesiMode', 0, 'LOC_NW_HAIKESI_MODE_CLASSIC_NAME', 'LOC_NW_HAIKESI_MODE_CLASSIC_DESC', 10),
('NwHaikesiMode', 1, 'LOC_NW_HAIKESI_MODE_HAIKESI_NAME', 'LOC_NW_HAIKESI_MODE_HAIKESI_DESC', 20),
('NwHaikesiMode', 2, 'LOC_NW_HAIKESI_MODE_PVE_NAME',     'LOC_NW_HAIKESI_MODE_PVE_DESC',     30),
('NwHaikesiMode', 3, 'LOC_NW_HAIKESI_MODE_DEV_NAME',      'LOC_NW_HAIKESI_MODE_DEV_DESC',     40),
('NwHaikesiMode', 4, 'LOC_NW_HAIKESI_MODE_MP_NAME',       'LOC_NW_HAIKESI_MODE_MP_DESC',      50);


