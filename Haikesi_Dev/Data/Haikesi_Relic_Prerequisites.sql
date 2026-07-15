-- ===========================================================================
-- Haikesi_Relic_Prerequisites.sql — 海克斯泛型前置条件表
-- 一条记录表示 RelicType 进入刷新池前必须满足的一个条件。
--
-- PrerequisiteKind:
--   RELIC      PrerequisiteType = 另一个 Haikesi_Relics.RelicType
--   TECHNOLOGY PrerequisiteType = Technologies.TechnologyType
--   TRAIT      PrerequisiteType = Traits.TraitType（玩家文明须拥有该特色区域 Trait，海克斯才进刷新池）
--   EXCLUDE_TRAIT PrerequisiteType = Traits.TraitType(玩家文明拥有该 Trait 时,海克斯【不】进刷新池,即负关联)
--   CAPABILITY PrerequisiteType = GameCapabilities.GameCapability（当局须启用该 Capability，如秘密结社）
--
-- AllowInProgress:
--   0 = 必须已完成
--   1 = 已完成或当前正在研究
-- 多条前置条件按 AND 处理。
-- ===========================================================================

DROP TABLE IF EXISTS Haikesi_Relic_Prerequisites;
CREATE TABLE Haikesi_Relic_Prerequisites (
    RelicType        TEXT NOT NULL,
    PrerequisiteKind TEXT NOT NULL,
    PrerequisiteType TEXT NOT NULL,
    AllowInProgress INTEGER NOT NULL DEFAULT 0,
    PRIMARY KEY (RelicType, PrerequisiteKind, PrerequisiteType),
    FOREIGN KEY (RelicType) REFERENCES Haikesi_Relics(RelicType) ON DELETE CASCADE ON UPDATE CASCADE,
    CHECK (PrerequisiteKind IN ('RELIC', 'TECHNOLOGY', 'TRAIT', 'EXCLUDE_TRAIT', 'CAPABILITY')),
    CHECK (AllowInProgress IN (0, 1))
);

-- 信仰值 / 圣地相关海克斯：已研究占星术，或当前正在研究占星术，才进入刷新池。
-- BACKTOBASICSRUNE / PRIMITIVEMADNESSRUNE 已应需求取消占星术前置，改为无前置常驻刷新池。
INSERT INTO Haikesi_Relic_Prerequisites
    (RelicType, PrerequisiteKind, PrerequisiteType, AllowInProgress) VALUES
    ('MIKAELSBLESSINGRUNE',   'TECHNOLOGY', 'TECH_ASTROLOGY', 1);

-- District 升级套：须拥有对应特色区域 Trait 才进刷新池（AllowInProgress=0 对 TRAIT 无意义，保留默认值）
-- Lua 端 TRAIT 分支按 PlayerConfigurations 匹配 CivilizationTraits / LeaderTraits。
INSERT INTO Haikesi_Relic_Prerequisites
    (RelicType, PrerequisiteKind, PrerequisiteType, AllowInProgress) VALUES
    ('DRAWYOURSWORDRUNE',     'TRAIT', 'TRAIT_CIVILIZATION_ROYAL_NAVY_DOCKYARD', 0),
    ('DUALWIELDRUNE',         'TRAIT', 'TRAIT_CIVILIZATION_DISTRICT_COTHON',     0),
    ('EXPLOSIONARTRUNE',      'TRAIT', 'TRAIT_CIVILIZATION_DISTRICT_HANSA',      0),
    ('FEELTHEBURNRUNE',       'TRAIT', 'TRAIT_CIVILIZATION_DISTRICT_SUGUBA',     0),
    ('FEYMAGICRUNE',          'TRAIT', 'TRAIT_CIVILIZATION_DISTRICT_ACROPOLIS',  0),
    -- FINALFORMRUNE (园丁天文台) 已删除
    ('FLYINGKICKRUNE',        'TRAIT', 'TRAIT_CIVILIZATION_DISTRICT_SEOWON',     0),
    ('CANTTOUCHTHISRUNE',     'TRAIT', 'TRAIT_CIVILIZATION_DISTRICT_BATH',       0),
    ('FORBIDDENGRIMOIRERUNE', 'TRAIT', 'TRAIT_CIVILIZATION_DISTRICT_MBANZA',     0),
    ('GHOSTFORMRUNE',         'TRAIT', 'TRAIT_CIVILIZATION_DISTRICT_STREET_CARNIVAL', 0),
    ('GIANTSLAYERRUNE',       'TRAIT', 'TRAIT_CIVILIZATION_DISTRICT_IKANDA',     0),
    ('GOLIATHRUNE',           'TRAIT', 'TRAIT_CIVILIZATION_DISTRICT_HIPPODROME', 0),
    ('JEWELEDGAUNTLETRUNE',   'TRAIT', 'TRAIT_CIVILIZATION_DISTRICT_OPPIDUM',    0),
    ('MASTEROFDUALITYRUNE',   'TRAIT', 'TRAIT_CIVILIZATION_DISTRICT_THANH',      0),
    ('LAVRAUPGRADERUNE',      'TRAIT', 'TRAIT_CIVILIZATION_DISTRICT_LAVRA',     0);

-- 超负荷 (COREOVERLOADRUNE) 负关联:高卢/德国已有类似专属工业区海克斯
-- (JEWELEDGAUNTLETRUNE 奥皮杜姆 / EXPLOSIONARTRUNE 同业公会改组),故排除超负荷出池
INSERT INTO Haikesi_Relic_Prerequisites
    (RelicType, PrerequisiteKind, PrerequisiteType, AllowInProgress) VALUES
    ('COREOVERLOADRUNE', 'EXCLUDE_TRAIT', 'TRAIT_CIVILIZATION_DISTRICT_HANSA',    0),  -- 德国
    ('COREOVERLOADRUNE', 'EXCLUDE_TRAIT', 'TRAIT_CIVILIZATION_DISTRICT_OPPIDUM',  0);  -- 高卢

-- 德古拉 (DRACULARUNE): 仅秘密结社模式可进刷新池（依赖 UNIT_VAMPIRE）
INSERT INTO Haikesi_Relic_Prerequisites
    (RelicType, PrerequisiteKind, PrerequisiteType, AllowInProgress) VALUES
    ('DRACULARUNE', 'CAPABILITY', 'CAPABILITY_SECRETSOCIETIES', 0);
