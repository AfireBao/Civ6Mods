-- ===========================================================================
-- Haikesi_Relic_ResourceSpawns.sql — 海克斯「资源创建」类型配置
-- Lua 读取本表，在目标城市周边合法地块生成资源（含改良避坑）
--
-- 扩展同类型海克斯只需：
--   1) INSERT Haikesi_Relics（及文本/图标/AI 池列表若需要）
--   2) 本表再 INSERT 一行配置
--   3) 占位 Modifier（防无映射金币补偿）可选
-- ===========================================================================

CREATE TABLE IF NOT EXISTS Haikesi_Relic_ResourceSpawns (
    RelicType       TEXT NOT NULL PRIMARY KEY,   -- 对应 Haikesi_Relics.RelicType
    ResourceType    TEXT NOT NULL,               -- 如 RESOURCE_COTTON
    Amount          INTEGER NOT NULL DEFAULT 1,  -- 生成地块数量
    Radius          INTEGER NOT NULL DEFAULT 3,  -- 距城最大环数
    MinDistance     INTEGER NOT NULL DEFAULT 1,  -- 距城最小环数（1=不含城心）
    CityTarget      TEXT NOT NULL DEFAULT 'NEWEST', -- NEWEST | CAPITAL
    PreferOwned     INTEGER NOT NULL DEFAULT 1,  -- 优先己方领土
    AllowUnowned    INTEGER NOT NULL DEFAULT 1,  -- 允许无主格
    AllowForeign    INTEGER NOT NULL DEFAULT 0,  -- 允许他国领土
    ResourceCount   INTEGER NOT NULL DEFAULT 1   -- SetResourceType 数量参数
);

-- 资源创建批次：最新城市 3 环各创建 4 份指定奢侈品
INSERT OR REPLACE INTO Haikesi_Relic_ResourceSpawns
    (RelicType, ResourceType, Amount, Radius, MinDistance, CityTarget, PreferOwned, AllowUnowned, AllowForeign, ResourceCount)
VALUES
    ('NW_AI_BRAVE_WOOD',   'RESOURCE_COTTON',  4, 3, 1, 'NEWEST', 1, 1, 0, 1), -- 勇敢的木
    ('NW_AI_MAMA_BORN',    'RESOURCE_TOBACCO', 4, 3, 1, 'NEWEST', 1, 1, 0, 1), -- 妈妈生的
    ('NW_AI_MILK_DRAGON',  'RESOURCE_SUGAR',   4, 3, 1, 'NEWEST', 1, 1, 0, 1), -- 我是奶龙
    ('NW_AI_SILK_LAND',    'RESOURCE_SILK',    4, 3, 1, 'NEWEST', 1, 1, 0, 1), -- 丝绸之乡
    ('NW_AI_DRINK_TEA',    'RESOURCE_TEA',     4, 3, 1, 'NEWEST', 1, 1, 0, 1); -- 饮茶先啦
