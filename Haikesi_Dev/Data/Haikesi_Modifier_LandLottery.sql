-- ===========================================================================
-- LANDLOTTERYRUNE 狂野符文
-- 玩家级：抵消已标记地块的原版地形产出 + 按 Plot Property 二进制位加回随机地形产
-- 不改动 Terrain/Feature/Resource_YieldChanges（砍树/地貌仍有效）
-- ===========================================================================

-- 已随机标记
INSERT OR IGNORE INTO Requirements (RequirementId, RequirementType) VALUES
    ('NW_LL_REQ_PLOT_ACTIVE', 'REQUIREMENT_PLOT_PROPERTY_MATCHES');
INSERT OR IGNORE INTO RequirementArguments (RequirementId, Name, Value) VALUES
    ('NW_LL_REQ_PLOT_ACTIVE', 'PropertyName', 'NW_HAIKESI_LL_ACTIVE'),
    ('NW_LL_REQ_PLOT_ACTIVE', 'PropertyMinimum', '1');

-- ---------------------------------------------------------------------------
-- 负向：抵消 Terrain_YieldChanges（仅当该格已打 LL_ACTIVE）
-- ---------------------------------------------------------------------------
INSERT OR IGNORE INTO Requirements (RequirementId, RequirementType)
SELECT DISTINCT
    'NW_LL_REQ_TERRAIN_' || TerrainType,
    'REQUIREMENT_PLOT_TERRAIN_TYPE_MATCHES'
FROM Terrain_YieldChanges;

INSERT OR IGNORE INTO RequirementArguments (RequirementId, Name, Value)
SELECT DISTINCT
    'NW_LL_REQ_TERRAIN_' || TerrainType,
    'TerrainType',
    TerrainType
FROM Terrain_YieldChanges;

INSERT OR IGNORE INTO RequirementSets (RequirementSetId, RequirementSetType)
SELECT
    'NW_LL_REQS_NEGATE_' || TerrainType || '_' || YieldType,
    'REQUIREMENTSET_TEST_ALL'
FROM Terrain_YieldChanges;

INSERT OR IGNORE INTO RequirementSetRequirements (RequirementSetId, RequirementId)
SELECT
    'NW_LL_REQS_NEGATE_' || TerrainType || '_' || YieldType,
    'NW_LL_REQ_PLOT_ACTIVE'
FROM Terrain_YieldChanges;

INSERT OR IGNORE INTO RequirementSetRequirements (RequirementSetId, RequirementId)
SELECT
    'NW_LL_REQS_NEGATE_' || TerrainType || '_' || YieldType,
    'NW_LL_REQ_TERRAIN_' || TerrainType
FROM Terrain_YieldChanges;

INSERT OR IGNORE INTO Modifiers (ModifierId, ModifierType, SubjectRequirementSetId)
SELECT
    'MODIFIER_NW_LL_NEGATE_' || TerrainType || '_' || YieldType,
    'MODIFIER_PLAYER_ADJUST_PLOT_YIELD',
    'NW_LL_REQS_NEGATE_' || TerrainType || '_' || YieldType
FROM Terrain_YieldChanges;

INSERT OR IGNORE INTO ModifierArguments (ModifierId, Name, Value)
SELECT
    'MODIFIER_NW_LL_NEGATE_' || TerrainType || '_' || YieldType,
    'YieldType',
    YieldType
FROM Terrain_YieldChanges;

INSERT OR IGNORE INTO ModifierArguments (ModifierId, Name, Value)
SELECT
    'MODIFIER_NW_LL_NEGATE_' || TerrainType || '_' || YieldType,
    'Amount',
    '-' || YieldChange
FROM Terrain_YieldChanges;

INSERT OR IGNORE INTO Haikesi_Relic_Modifiers (RelicType, ModifierId)
SELECT
    'LANDLOTTERYRUNE',
    'MODIFIER_NW_LL_NEGATE_' || TerrainType || '_' || YieldType
FROM Terrain_YieldChanges;

-- ---------------------------------------------------------------------------
-- 正向：粮/锤/金 × 二进制位 1/2/4（预算通常 ≤3）
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS NW_LL_BinaryBits (
    Num INTEGER PRIMARY KEY NOT NULL
);
INSERT OR IGNORE INTO NW_LL_BinaryBits (Num) VALUES (1), (2), (4);

CREATE TABLE IF NOT EXISTS NW_LL_YieldTypes (
    YieldType TEXT PRIMARY KEY NOT NULL
);
INSERT OR IGNORE INTO NW_LL_YieldTypes (YieldType) VALUES
    ('YIELD_FOOD'),
    ('YIELD_PRODUCTION'),
    ('YIELD_GOLD'),
    ('YIELD_FAITH');

INSERT OR IGNORE INTO Requirements (RequirementId, RequirementType)
SELECT
    'NW_LL_REQ_PROP_' || YieldType || '_' || Num,
    'REQUIREMENT_PLOT_PROPERTY_MATCHES'
FROM NW_LL_YieldTypes, NW_LL_BinaryBits;

INSERT OR IGNORE INTO RequirementArguments (RequirementId, Name, Value)
SELECT
    'NW_LL_REQ_PROP_' || YieldType || '_' || Num,
    'PropertyName',
    'NW_HAIKESI_LL_' || YieldType || '_' || Num
FROM NW_LL_YieldTypes, NW_LL_BinaryBits;

INSERT OR IGNORE INTO RequirementArguments (RequirementId, Name, Value)
SELECT
    'NW_LL_REQ_PROP_' || YieldType || '_' || Num,
    'PropertyMinimum',
    '1'
FROM NW_LL_YieldTypes, NW_LL_BinaryBits;

INSERT OR IGNORE INTO RequirementSets (RequirementSetId, RequirementSetType)
SELECT
    'NW_LL_REQS_PROP_' || YieldType || '_' || Num,
    'REQUIREMENTSET_TEST_ALL'
FROM NW_LL_YieldTypes, NW_LL_BinaryBits;

INSERT OR IGNORE INTO RequirementSetRequirements (RequirementSetId, RequirementId)
SELECT
    'NW_LL_REQS_PROP_' || YieldType || '_' || Num,
    'NW_LL_REQ_PROP_' || YieldType || '_' || Num
FROM NW_LL_YieldTypes, NW_LL_BinaryBits;

INSERT OR IGNORE INTO Modifiers (ModifierId, ModifierType, SubjectRequirementSetId)
SELECT
    'MODIFIER_NW_LL_ADD_' || YieldType || '_' || Num,
    'MODIFIER_PLAYER_ADJUST_PLOT_YIELD',
    'NW_LL_REQS_PROP_' || YieldType || '_' || Num
FROM NW_LL_YieldTypes, NW_LL_BinaryBits;

INSERT OR IGNORE INTO ModifierArguments (ModifierId, Name, Value)
SELECT
    'MODIFIER_NW_LL_ADD_' || YieldType || '_' || Num,
    'YieldType',
    YieldType
FROM NW_LL_YieldTypes, NW_LL_BinaryBits;

INSERT OR IGNORE INTO ModifierArguments (ModifierId, Name, Value)
SELECT
    'MODIFIER_NW_LL_ADD_' || YieldType || '_' || Num,
    'Amount',
    Num
FROM NW_LL_YieldTypes, NW_LL_BinaryBits;

INSERT OR IGNORE INTO Haikesi_Relic_Modifiers (RelicType, ModifierId)
SELECT
    'LANDLOTTERYRUNE',
    'MODIFIER_NW_LL_ADD_' || YieldType || '_' || Num
FROM NW_LL_YieldTypes, NW_LL_BinaryBits;
