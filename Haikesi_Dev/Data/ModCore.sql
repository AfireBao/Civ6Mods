-- ============================================================
-- ModCore.sql — 海克斯通用支持模块
-- 搬运自枯木逢春（DeadTreesMeetSpring.sql）的 Lua Support + 通用 REQS 预制件
--   ① TRAIT → PROPERTY 绑定：每个 Trait 给玩家 set PROPERTY_<Trait>=1
--      Lua 端 pPlayer:GetProperty('PROPERTY_'..traitType) > 0 即可判断玩家是否拥有该 Trait
--      （替代遍历 CivilizationTraits，更轻量且支持运行时 Trait 变化）
--   ② 通用 RequirementSet 预制件：NW_DISTRICT_IS_* / NW_PLAYER_HAS_<Tech> / NW_PLAYER_HAS_<Civic>
--      / NW_CITY_HAS_<District|Building> / NW_PLAYER_HAS_<Building> / NW_PLAYER_IS_<Leader>
--      海克斯各效果直接引用，避免每个海克斯重复自建 ReqSet
-- ============================================================

-- ============================================================
-- 一、Lua Support：TRAIT → PROPERTY 绑定
-- 原版 Trait 不会自动 set PROPERTY，需通过 MODIFIER_PLAYER_ADJUST_PROPERTY 挂到 TraitModifiers
-- 玩家拥有该 Trait 时 modifier 生效，set PROPERTY_<Trait>=1
-- ============================================================
CREATE TABLE IF NOT EXISTS Nwflower_MOD_Traits
(
    TraitType TEXT NOT NULL,
    PRIMARY KEY (TraitType),
    FOREIGN KEY (TraitType) REFERENCES Traits (TraitType) ON DELETE CASCADE ON UPDATE CASCADE
);

-- 绑定所有文明/领袖 Trait（含特色区域 Trait，其 Description 为 NULL，原 Description IS NOT NULL 条件会漏掉）
INSERT OR IGNORE INTO Nwflower_MOD_Traits (TraitType)
    SELECT DISTINCT TraitType FROM CivilizationTraits
    UNION
    SELECT DISTINCT TraitType FROM LeaderTraits;

INSERT OR IGNORE INTO TraitModifiers (TraitType, ModifierId)
    SELECT TraitType, 'MODFEAT_TRAIT_PROPERTY_' || TraitType FROM Nwflower_MOD_Traits;
INSERT OR IGNORE INTO Modifiers (ModifierId, ModifierType)
    SELECT 'MODFEAT_TRAIT_PROPERTY_' || TraitType, 'MODIFIER_PLAYER_ADJUST_PROPERTY' FROM Nwflower_MOD_Traits;
INSERT OR IGNORE INTO ModifierArguments (ModifierId, Name, Value)
    SELECT 'MODFEAT_TRAIT_PROPERTY_' || TraitType, 'Key', 'PROPERTY_' || TraitType FROM Nwflower_MOD_Traits
    UNION
    SELECT 'MODFEAT_TRAIT_PROPERTY_' || TraitType, 'Amount', 1 FROM Nwflower_MOD_Traits;

-- ============================================================
-- 一·二、通用 ModifierType 注册：PLAYER_DISTRICTS_ATTACH
-- 原版 DynamicModifiers 给 COLLECTION_PLAYER_DISTRICTS 只配了 ADJUST_*，没配 EFFECT_ATTACH_MODIFIER；
-- 自插一行注册 MODIFIER_NW_PLAYER_DISTRICTS_ATTACH_MODIFIER，供海克斯挂"本玩家区域"效果，
-- 替代 MODIFIER_ALL_DISTRICTS_ATTACH_MODIFIER（全图集合，会泄露给同文明对手）。
-- ============================================================
INSERT OR IGNORE INTO Types (Type, Kind) VALUES
    ('MODIFIER_NW_PLAYER_DISTRICTS_ATTACH_MODIFIER', 'KIND_MODIFIER');
INSERT OR IGNORE INTO DynamicModifiers (ModifierType, CollectionType, EffectType) VALUES
    ('MODIFIER_NW_PLAYER_DISTRICTS_ATTACH_MODIFIER', 'COLLECTION_PLAYER_DISTRICTS', 'EFFECT_ATTACH_MODIFIER');

-- PLAYER_DISTRICTS + GRANT_INFLUENCE_TOKEN：每个指定区域送使者（配合 SubjectReqSet 限定区域类型，
-- 替代 ADJUST_SPECIFIC_DISTRICT_GRANT_ENVOYS）
INSERT OR IGNORE INTO Types (Type, Kind) VALUES
    ('MODIFIER_NW_PLAYER_GRANT_INFLUENCE_TOKEN', 'KIND_MODIFIER');
INSERT OR IGNORE INTO DynamicModifiers (ModifierType, CollectionType, EffectType) VALUES
    ('MODIFIER_NW_PLAYER_GRANT_INFLUENCE_TOKEN', 'COLLECTION_PLAYER_DISTRICTS', 'EFFECT_GRANT_INFLUENCE_TOKEN');

-- ============================================================
-- 二、通用 RequirementSet 预制件
-- ============================================================

-- 城市拥有某区域：NW_CITY_HAS_<DistrictType>
INSERT OR IGNORE INTO RequirementSets (RequirementSetId, RequirementSetType)
    SELECT 'NW_CITY_HAS_' || DistrictType, 'REQUIREMENTSET_TEST_ALL' FROM Districts;
INSERT OR IGNORE INTO RequirementSetRequirements (RequirementSetId, RequirementId)
    SELECT 'NW_CITY_HAS_' || DistrictType, 'NW_CITY_HAS_' || DistrictType || '_REQUIREMENT' FROM Districts;
INSERT OR IGNORE INTO Requirements (RequirementId, RequirementType)
    SELECT 'NW_CITY_HAS_' || DistrictType || '_REQUIREMENT', 'REQUIREMENT_CITY_HAS_DISTRICT' FROM Districts;
INSERT OR IGNORE INTO RequirementArguments (RequirementId, Name, Value)
    SELECT 'NW_CITY_HAS_' || DistrictType || '_REQUIREMENT', 'DistrictType', DistrictType FROM Districts;

-- 区域是任意专业化区域：NW_IS_SPECIALTY_DISTRICT（TEST_ANY，含所有 RequiresPopulation=1 的特色区域）
INSERT OR IGNORE INTO RequirementSets (RequirementSetId, RequirementSetType) VALUES ('NW_IS_SPECIALTY_DISTRICT', 'REQUIREMENTSET_TEST_ANY');
INSERT OR IGNORE INTO RequirementSetRequirements (RequirementSetId, RequirementId)
    SELECT 'NW_IS_SPECIALTY_DISTRICT', 'NW_DISTRICT_IS_' || DistrictType || '_REQUIREMENT' FROM Districts WHERE RequiresPopulation = 1;

-- 区域类型匹配：NW_DISTRICT_IS_<DistrictType>
INSERT OR IGNORE INTO RequirementSets (RequirementSetId, RequirementSetType)
    SELECT 'NW_DISTRICT_IS_' || DistrictType, 'REQUIREMENTSET_TEST_ALL' FROM Districts;
INSERT OR IGNORE INTO RequirementSetRequirements (RequirementSetId, RequirementId)
    SELECT 'NW_DISTRICT_IS_' || DistrictType, 'NW_DISTRICT_IS_' || DistrictType || '_REQUIREMENT' FROM Districts;
INSERT OR IGNORE INTO Requirements (RequirementId, RequirementType)
    SELECT 'NW_DISTRICT_IS_' || DistrictType || '_REQUIREMENT', 'REQUIREMENT_DISTRICT_TYPE_MATCHES' FROM Districts;
INSERT OR IGNORE INTO RequirementArguments (RequirementId, Name, Value)
    SELECT 'NW_DISTRICT_IS_' || DistrictType || '_REQUIREMENT', 'DistrictType', DistrictType FROM Districts;

-- 玩家拥有某科技：NW_PLAYER_HAS_<TechnologyType>
INSERT OR IGNORE INTO RequirementSets (RequirementSetId, RequirementSetType)
    SELECT 'NW_PLAYER_HAS_' || TechnologyType, 'REQUIREMENTSET_TEST_ALL' FROM Technologies;
INSERT OR IGNORE INTO Requirements (RequirementId, RequirementType)
    SELECT 'NW_UTILS_PLAYER_HAS_' || TechnologyType || '_REQUIREMENT', 'REQUIREMENT_PLAYER_HAS_TECHNOLOGY' FROM Technologies;
INSERT OR IGNORE INTO RequirementArguments (RequirementId, Name, Value)
    SELECT 'NW_UTILS_PLAYER_HAS_' || TechnologyType || '_REQUIREMENT', 'TechnologyType', TechnologyType FROM Technologies;
INSERT OR IGNORE INTO RequirementSetRequirements (RequirementSetId, RequirementId)
    SELECT 'NW_PLAYER_HAS_' || TechnologyType, 'NW_UTILS_PLAYER_HAS_' || TechnologyType || '_REQUIREMENT' FROM Technologies;

-- 玩家拥有某市政：NW_PLAYER_HAS_<CivicType>
INSERT OR IGNORE INTO RequirementSets (RequirementSetId, RequirementSetType)
    SELECT 'NW_PLAYER_HAS_' || CivicType, 'REQUIREMENTSET_TEST_ALL' FROM Civics;
INSERT OR IGNORE INTO Requirements (RequirementId, RequirementType)
    SELECT 'NW_UTILS_PLAYER_HAS_' || CivicType || '_REQUIREMENT', 'REQUIREMENT_PLAYER_HAS_CIVIC' FROM Civics;
INSERT OR IGNORE INTO RequirementArguments (RequirementId, Name, Value)
    SELECT 'NW_UTILS_PLAYER_HAS_' || CivicType || '_REQUIREMENT', 'CivicType', CivicType FROM Civics;
INSERT OR IGNORE INTO RequirementSetRequirements (RequirementSetId, RequirementId)
    SELECT 'NW_PLAYER_HAS_' || CivicType, 'NW_UTILS_PLAYER_HAS_' || CivicType || '_REQUIREMENT' FROM Civics;

-- 玩家拥有某建筑：NW_PLAYER_HAS_<BuildingType>
INSERT OR IGNORE INTO RequirementSets (RequirementSetId, RequirementSetType)
    SELECT 'NW_PLAYER_HAS_' || BuildingType, 'REQUIREMENTSET_TEST_ALL' FROM Buildings;
INSERT OR IGNORE INTO RequirementSetRequirements (RequirementSetId, RequirementId)
    SELECT 'NW_PLAYER_HAS_' || BuildingType, 'REQ_NW_PLAYER_HAS_' || BuildingType FROM Buildings;
INSERT OR IGNORE INTO Requirements (RequirementId, RequirementType)
    SELECT 'REQ_NW_PLAYER_HAS_' || BuildingType, 'REQUIREMENT_PLAYER_HAS_BUILDING' FROM Buildings;
INSERT OR IGNORE INTO RequirementArguments (RequirementId, Name, Value)
    SELECT 'REQ_NW_PLAYER_HAS_' || BuildingType, 'BuildingType', BuildingType FROM Buildings;

-- 城市拥有某建筑：NW_CITY_HAS_<BuildingType>
INSERT OR IGNORE INTO RequirementSets (RequirementSetId, RequirementSetType)
    SELECT 'NW_CITY_HAS_' || BuildingType, 'REQUIREMENTSET_TEST_ALL' FROM Buildings;
INSERT OR IGNORE INTO RequirementSetRequirements (RequirementSetId, RequirementId)
    SELECT 'NW_CITY_HAS_' || BuildingType, 'REQ_NW_CITY_HAS_' || BuildingType FROM Buildings;
INSERT OR IGNORE INTO Requirements (RequirementId, RequirementType)
    SELECT 'REQ_NW_CITY_HAS_' || BuildingType, 'REQUIREMENT_CITY_HAS_BUILDING' FROM Buildings;
INSERT OR IGNORE INTO RequirementArguments (RequirementId, Name, Value)
    SELECT 'REQ_NW_CITY_HAS_' || BuildingType, 'BuildingType', BuildingType FROM Buildings;

-- 玩家是某指定领袖：NW_PLAYER_IS_<LeaderType>
INSERT OR IGNORE INTO RequirementSets (RequirementSetId, RequirementSetType)
    SELECT 'NW_PLAYER_IS_' || LeaderType, 'REQUIREMENTSET_TEST_ANY' FROM Leaders WHERE InheritFrom = 'LEADER_DEFAULT';
INSERT OR IGNORE INTO RequirementSetRequirements (RequirementSetId, RequirementId)
    SELECT 'NW_PLAYER_IS_' || LeaderType, 'NW_PLAYER_IS_' || LeaderType || '_REQUIREMENT' FROM Leaders WHERE InheritFrom = 'LEADER_DEFAULT';
INSERT OR IGNORE INTO Requirements (RequirementId, RequirementType)
    SELECT 'NW_PLAYER_IS_' || LeaderType || '_REQUIREMENT', 'REQUIREMENT_PLAYER_LEADER_TYPE_MATCHES' FROM Leaders WHERE InheritFrom = 'LEADER_DEFAULT';
INSERT OR IGNORE INTO RequirementArguments (RequirementId, Name, Value)
    SELECT 'NW_PLAYER_IS_' || LeaderType || '_REQUIREMENT', 'LeaderType', LeaderType FROM Leaders WHERE InheritFrom = 'LEADER_DEFAULT';
