-- ===========================================================================
-- Haikesi_Planter.sql — 「种地仙人」可种植资源白名单 + 扣充能 Ability 槽
-- 策略 B：白名单定范围；落点合法性由 Lua 的 ResourceBuilder.CanHaveResource 判定
-- ===========================================================================

CREATE TABLE IF NOT EXISTS Haikesi_PlanterResources (
    ResourceType TEXT NOT NULL PRIMARY KEY
);

-- 加成 + 奢侈；须地图可自然生成（排除垄断奢侈等 Frequency=SeaFrequency=0）
INSERT OR IGNORE INTO Haikesi_PlanterResources (ResourceType)
SELECT R.ResourceType
FROM Resources R
WHERE R.ResourceClassType IN ('RESOURCECLASS_BONUS', 'RESOURCECLASS_LUXURY')
  AND (R.Frequency > 0 OR R.SeaFrequency > 0);

-- 扣充能：每次种植启用一个 Inactive Ability（Amount=-1）
-- 槽数覆盖基础 BuildCharges + 金字塔/农奴制等加成余量
CREATE TABLE IF NOT EXISTS Haikesi_PlanterChargeSlots (
    Slot INTEGER PRIMARY KEY
);

WITH RECURSIVE ChargeSlots(Slot, MaxSlot) AS (
    SELECT 1, MAX(32, COALESCE((SELECT MAX(BuildCharges) FROM Units), 0) + 32)
    UNION ALL
    SELECT Slot + 1, MaxSlot FROM ChargeSlots WHERE Slot < MaxSlot
)
INSERT OR IGNORE INTO Haikesi_PlanterChargeSlots (Slot)
SELECT Slot FROM ChargeSlots;

INSERT OR IGNORE INTO Types (Type, Kind)
SELECT 'ABILITY_NW_PLANTER_CONSUMED_CHARGE_' || Slot, 'KIND_ABILITY'
FROM Haikesi_PlanterChargeSlots;

INSERT OR IGNORE INTO TypeTags (Type, Tag)
SELECT 'ABILITY_NW_PLANTER_CONSUMED_CHARGE_' || Slot, 'CLASS_NW_FARM_IMMORTAL'
FROM Haikesi_PlanterChargeSlots;

INSERT OR IGNORE INTO UnitAbilities (UnitAbilityType, Inactive)
SELECT 'ABILITY_NW_PLANTER_CONSUMED_CHARGE_' || Slot, 1
FROM Haikesi_PlanterChargeSlots;

INSERT OR IGNORE INTO Modifiers (ModifierId, ModifierType)
SELECT 'ABILITY_NW_PLANTER_CONSUMED_CHARGE_' || Slot || '_MODIFIER',
       'MODIFIER_UNIT_ADJUST_BUILDER_CHARGES'
FROM Haikesi_PlanterChargeSlots;

INSERT OR IGNORE INTO UnitAbilityModifiers (UnitAbilityType, ModifierId)
SELECT 'ABILITY_NW_PLANTER_CONSUMED_CHARGE_' || Slot,
       'ABILITY_NW_PLANTER_CONSUMED_CHARGE_' || Slot || '_MODIFIER'
FROM Haikesi_PlanterChargeSlots;

INSERT OR IGNORE INTO ModifierArguments (ModifierId, Name, Value)
SELECT 'ABILITY_NW_PLANTER_CONSUMED_CHARGE_' || Slot || '_MODIFIER', 'Amount', -1
FROM Haikesi_PlanterChargeSlots;
