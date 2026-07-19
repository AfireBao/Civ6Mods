
drop table if exists counter_m;
drop table if exists counter;

create table "counter_m" (
'numbers' INTEGER NOT NULL,
PRIMARY KEY(numbers)
);

WITH RECURSIVE
  Indices(i) AS (SELECT 0 UNION ALL SELECT (i + 1) FROM Indices LIMIT 8)
  insert into counter_m(numbers) select i from Indices;


create table "counter" (
'numbers' INTEGER NOT NULL,
PRIMARY KEY(numbers)
);

WITH RECURSIVE
  Indices(i) AS (SELECT -50 UNION ALL SELECT (i + 1) FROM Indices LIMIT 100)
  insert into counter(numbers) select i from Indices;

-- 食物和矿物改良 REQ
INSERT OR IGNORE INTO Vocabularies
		(Vocabulary)
VALUES	('IMPROVEMENT_CLASS');

-- req/rs from da
--单元格魅力值 REQ/RS
insert or ignore into RequirementArguments(RequirementId,	Name,	Value)
	select 'REQ_PLOT_APPEAL_AT_LEAST_' || numbers, 'MinimumAppeal', numbers from counter where numbers >= -4 and numbers <= 20;

insert or ignore into Requirements (RequirementId, RequirementType)
	select 'REQ_PLOT_APPEAL_AT_LEAST_' || numbers, 'REQUIREMENT_PLOT_IS_APPEAL_BETWEEN' 
from counter where numbers >= -4 and numbers <= 20;

insert or ignore into RequirementSets
    (RequirementSetId,                                  RequirementSetType)
select	'RS_PLOT_APPEAL_AT_LEAST_' || numbers,			'REQUIREMENTSET_TEST_ALL'
from counter where numbers >= -4 and numbers <= 20;

insert or ignore into RequirementSetRequirements
    (RequirementSetId,                                  RequirementId)
select	'RS_PLOT_APPEAL_AT_LEAST_' || numbers,			'REQ_PLOT_APPEAL_AT_LEAST_' || numbers
from counter where numbers >= -4 and numbers <= 20;


--对象离自己1-10格 REQ/RS

insert or ignore into Requirements (RequirementId, RequirementType)
select 'REQ_OBJECT_WITHIN_'||numbers||'_TILES', 'REQUIREMENT_PLOT_ADJACENT_TO_OWNER'
from counter where numbers >= 1 and numbers <= 10;

insert or ignore into RequirementArguments (RequirementId, Name, Value)
select 'REQ_OBJECT_WITHIN_'||numbers||'_TILES', 'MinDistance', '0'
from counter where numbers >= 1 and numbers <= 10;

insert or ignore into RequirementArguments (RequirementId, Name, Value)
select 'REQ_OBJECT_WITHIN_'||numbers||'_TILES', 'MaxDistance', numbers
from counter where numbers >= 1 and numbers <= 10;

insert or ignore into RequirementSets
    (RequirementSetId,                                  RequirementSetType)
select	'RS_OBJECT_WITHIN_'||numbers||'_TILES',				'REQUIREMENTSET_TEST_ALL'
from counter where numbers >= 1 and numbers <= 10;

insert or ignore into RequirementSetRequirements
    (RequirementSetId,                                  RequirementId)
select	'RS_OBJECT_WITHIN_'||numbers||'_TILES',				'REQ_OBJECT_WITHIN_'||numbers||'_TILES'
from counter where numbers >= 1 and numbers <= 10;


--地块有某区域  RS/REQ
insert or ignore into Requirements (RequirementId, RequirementType)
select 'REQ_PLOT_HAS_'||DistrictType, 'REQUIREMENT_DISTRICT_TYPE_MATCHES'
from Districts;

insert or ignore into RequirementArguments (RequirementId, Name, Value)
select 'REQ_PLOT_HAS_'||DistrictType, 'DistrictType', DistrictType
from Districts;


insert or ignore into RequirementSets
    (RequirementSetId,                                  RequirementSetType)
select	'RS_PLOT_HAS_'||DistrictType,				'REQUIREMENTSET_TEST_ALL'
from Districts;

insert or ignore into RequirementSetRequirements
    (RequirementSetId,                                  RequirementId)
select	'RS_PLOT_HAS_'||DistrictType,				'REQ_PLOT_HAS_'||DistrictType
from Districts;

--城市有几个专业区域  REQ/RS
insert or ignore into Requirements (RequirementId, RequirementType)
select 'REQ_CITY_HAS_'||numbers||'_DISTRICTS', 'REQUIREMENT_CITY_HAS_X_SPECIALTY_DISTRICTS'
from counter where numbers >= 0 and numbers <= 8;

insert or ignore into RequirementArguments (RequirementId, Name, Value)
select 'REQ_CITY_HAS_'||numbers||'_DISTRICTS', 'Amount', numbers
from counter where numbers >= 0 and numbers <= 8;


insert or ignore into RequirementSets
    (RequirementSetId,                                  RequirementSetType)
select	'RS_CITY_HAS_'||numbers||'_DISTRICTS',				'REQUIREMENTSET_TEST_ALL'
from counter where numbers >= 0 and numbers <= 8;

insert or ignore into RequirementSetRequirements
    (RequirementSetId,                                  RequirementId)
select	'RS_CITY_HAS_'||numbers||'_DISTRICTS',				'REQ_CITY_HAS_'||numbers||'_DISTRICTS'
from counter where numbers >= 0 and numbers <= 8;


insert or ignore into Types
	(Type,									Kind)
values
	-- Pantheon
	('BELIEF_GOD_OF_BEAUTY',				'KIND_BELIEF'),
	('BELIEF_ORAL_TRADITION',				'KIND_BELIEF'),
	('BELIEF_GOD_OF_WINE',					'KIND_BELIEF'),
	('BELIEF_GGV',							'KIND_BELIEF'),
	('BELIEF_GOD_OF_MIRACLES',				'KIND_BELIEF'),
	('BELIEF_SHENNONG',						'KIND_BELIEF');


insert or ignore into Beliefs
	(BeliefType,						Name,										Description,											BeliefClassType)
values
	-- Pantheon
	('BELIEF_GOD_OF_BEAUTY',			'LOC_BELIEF_GOD_OF_BEAUTY_NAME',			'LOC_BELIEF_GOD_OF_BEAUTY_DESCRIPTION',					'BELIEF_CLASS_PANTHEON'),
	('BELIEF_ORAL_TRADITION',			'LOC_BELIEF_ORAL_TRADITION_NAME',			'LOC_BELIEF_ORAL_TRADITION_DESCRIPTION',				'BELIEF_CLASS_PANTHEON'),
	('BELIEF_GOD_OF_WINE',				'LOC_BELIEF_GOD_OF_WINE_NAME',				'LOC_BELIEF_GOD_OF_WINE_DESCRIPTION',					'BELIEF_CLASS_PANTHEON'),
	('BELIEF_GOD_OF_MIRACLES',			'LOC_BELIEF_GOD_OF_MIRACLES_NAME',			'LOC_BELIEF_GOD_OF_MIRACLES_DESCRIPTION',				'BELIEF_CLASS_PANTHEON'),
	('BELIEF_GGV',						'LOC_BELIEF_GGV_NAME',						'LOC_BELIEF_GGV_DESCRIPTION',							'BELIEF_CLASS_PANTHEON'),
	('BELIEF_SHENNONG',					'LOC_BELIEF_SHENNONG_NAME',					'LOC_BELIEF_SHENNONG_DESCRIPTION',						'BELIEF_CLASS_PANTHEON');




--select * from Modifiers where ModifierId like '%CITY_PATRON_GODDESS%';
/*
insert or ignore into PantheonModifiers(GodhoodType,	PowerType, ModifierId) select
	GodhoodType,	'FERTILITY_RITES',	GodhoodType||'_FERTILITY_RITES_PLOT_YIELD_FOOD'
	from Godhood where ghClass in ('IMPROVEMENT',	'FEATURE',	'TERRAIN', 'APPEAL');
*/

create table 'Godhood'(
	'GodhoodType' TEXT NOT NULL,
	'ghClass' TEXT NOT NULL,
	'ghParam1' TEXT,
	'ghParam2' INT,
	'ghParam3' INT,	
	'ghParam4' INT,	
	PRIMARY KEY('GodhoodType', 'ghClass', 'ghParam1')
);


create table 'Power'(
	'PowerType' TEXT NOT NULL,
	'pwClass' TEXT NOT NULL,
	'pwParam1' TEXT,
	'pwParam2' INT,
	'pwParam3' INT,
	'pwParam4' INT,
	PRIMARY KEY('PowerType', 'pwClass', 'pwParam1')
);

--create table 'PowerModifiers'(
--	'PowerType' TEXT NOT NULL,
--	'ModifierType' TEXT NOT NULL,

create table 'PantheonModifiers'(
	'PowerType' TEXT NOT NULL,
	'GodhoodType' TEXT NOT NULL,
	'ModifierId' TEXT NOT NULL,
	PRIMARY KEY('GodhoodType', 'PowerType', 'ModifierId')
);


insert or ignore into Godhood(GodhoodType,		ghClass,		ghParam1,		ghParam2,	ghParam3,	ghParam4) values  --2是区域，3是单元格
	('GOD_OF_BEAUTY',					'APPEAL',		'PLACEHOLDER',					NULL,	NULL,	NULL),

	('EARTH_GODDESS',					'APPEAL',		'PLACEHOLDER',					NULL,	NULL,	NULL),
--	('GOD_OF_CRAFTS_MAN',				'RESOURCE_COUNT',	'RESOURCECLASS_STRATEGIC',		NULL,	NULL,	NULL),
	('STONE_CIRCLES',					'IMPROVEMENT',	'IMPROVEMENT_QUARRY',			3,	3,	NULL),
	('DESERT_FOLKLORE',					'TERRAIN',		'TERRAIN_DESERT',				1,	2,	NULL),
	('DESERT_FOLKLORE',					'TERRAIN',		'TERRAIN_DESERT_HILLS',			1,	2,	NULL),
	('DESERT_FOLKLORE',					'TERRAIN',		'TERRAIN_DESERT_MOUNTAIN',		1,	2,	NULL),
	--('DESERT_FOLK_LORE',				'FEATURE',		'FEATURE_FLOODPLAINS',			-3,	-3,	NULL),	
	('GOD_OF_THE_SEA',					'IMPROVEMENT',	'IMPROVEMENT_FISHING_BOATS',	3,	3,	NULL),
	('GODDESS_OF_FIRE',					'FEATURE',		'FEATURE_GEOTHERMAL_FISSURE',	2,	2,	NULL),
	('GODDESS_OF_FIRE',					'FEATURE',		'FEATURE_VOLCANIC_SOIL',		2,	2,	NULL),
	('DANCE_OF_THE_AURORA',				'TERRAIN',		'TERRAIN_TUNDRA',				1,	2,	NULL),
	('DANCE_OF_THE_AURORA',				'TERRAIN',		'TERRAIN_TUNDRA_HILLS',			1,	2,	NULL),
	('DANCE_OF_THE_AURORA',				'TERRAIN',		'TERRAIN_TUNDRA_MOUNTAIN',		1,	2,	NULL),
	('GODDESS_OF_FESTIVALS',			'IMPROVEMENT',	'IMPROVEMENT_PLANTATION',		3,	2,	NULL),
	('LADY_OF_THE_REEDS_AND_MARSHES',	'FEATURE',		'FEATURE_MARSH',				2,	2,	NULL),
	('LADY_OF_THE_REEDS_AND_MARSHES',	'FEATURE',		'FEATURE_OASIS',				2,	2,	NULL),
	('LADY_OF_THE_REEDS_AND_MARSHES',	'FEATURE',		'FEATURE_FLOODPLAINS',			2,	2,	NULL),
	('SACRED_PATH',						'FEATURE',		'FEATURE_JUNGLE',				1,	1,	NULL),
	('ORAL_TRADITION',					'FEATURE',		'FEATURE_FOREST',				1,	1,	NULL),
	('GOD_OF_THE_OPEN_SKY',				'IMPROVEMENT',	'IMPROVEMENT_PASTURE',			3,	3,	NULL),
	('RELIGIOUS_IDOLS',					'IMPROVEMENT',	'IMPROVEMENT_MINE',				1,	1,	NULL),
	('GODDESS_OF_THE_HUNT',				'IMPROVEMENT',	'IMPROVEMENT_CAMP',				3,	2,	NULL);

insert or ignore into Power(PowerType,		pwClass,		pwParam1,		pwParam2,	pwParam3,	pwParam4) values

	('DIVINE_SPARK',					'DISTRICT',		'THRESHOLD1',					2,	NULL,	NULL),
	('DIVINE_SPARK',					'DISTRICT',		'THRESHOLD2',					4,	NULL,	NULL),
	('RELIGIOUS_SETTLEMENTS',			'DISTRICT',		'THRESHOLD1',					2,	NULL,	NULL),
	('RELIGIOUS_SETTLEMENTS',			'DISTRICT',		'THRESHOLD2',					4,	NULL,	NULL),
	('GOD_OF_WINE',						'DISTRICT',		'THRESHOLD1',					3,	NULL,	NULL),
	('GOD_OF_WINE',						'DISTRICT',		'THRESHOLD2',					5,	NULL,	NULL),
	('CITY_PATRON_GODDESS',				'CITY',			'THRESHOLD1',					4,	NULL,	NULL),
	('INITIATION_RITES',				'ADJACENCY',	'YIELD_FAITH',					1,	NULL,	NULL),

	('GOD_OF_CRAFTSMEN',				'DISTRICT',		'THRESHOLD1',					2,	NULL,	NULL),
	('GGV',								'DISTRICT',		'THRESHOLD1',					2,	NULL,	NULL),
	('SHENNONG',						'DISTRICT',		'THRESHOLD1',					2,	NULL,	NULL),
	('GOD_OF_MIRACLES',					'DISTRICT',		'THRESHOLD1',					6,	NULL,	NULL),
	('GOD_OF_CRAFTSMEN',				'YIELD',		'YIELD_PRODUCTION',				2,	1,		NULL),
	('GGV',								'YIELD',		'YIELD_CULTURE',				2,	1,		NULL),
	('SHENNONG',						'YIELD',		'YIELD_FOOD',					2,	1,		NULL),
	('FERTILITY_RITES',					'YIELD_COPY',	'YIELD_FAITH',					1,	NULL,	NULL),
	--('AESCULAPIUS',						'UNIT',			'PLACEHOLDER',					1,	NULL,	NULL),
	('MONUMENT_TO_THE_GODS',			'CITY',			'THRESHOLD1',					4,	NULL,	NULL);

update Beliefs set Description = 'LOC_'||BeliefType||'_DESCRIPTION' where BeliefClassType == 'BELIEF_CLASS_PANTHEON';

--保存并转移万神殿
create table 'Pantheons'(
	'BeliefType' TEXT NOT NULL,
	'Name' TEXT NOT NULL,
	'Description' TEXT NOT NULL,
	PRIMARY KEY('BeliefType')
);

insert or ignore into Pantheons(BeliefType,	Name,	Description) select
	BeliefType,	Name,	Description
	from Beliefs, Godhood where BeliefType == 'BELIEF_'||GodhoodType;

insert or ignore into Pantheons(BeliefType,	Name,	Description) select
	BeliefType,	Name,	Description
	from Beliefs, Power where BeliefType == 'BELIEF_'||PowerType;


--确保万神殿在百科内的显示
insert into CivilopediaPageQueries(SectionId,	PageGroupIdColumn,	TooltipColumn,	SortIndex,
	SQL) values
	('RELIGIONS',	'PageGroupId',	'Tooltip',	10,
	'SELECT BeliefType as PageId, "BELIEF_CLASS_PANTHEON" as PageGroupId, "Belief" as PageLayoutId, Name, null as Tooltip FROM Pantheons');


insert or ignore into CivilopediaPageExcludes(SectionId,	PageId)	select
	'RELIGIONS',	'BELIEF_'||GodhoodType||'_WITH_'||PowerType
	from Godhood, Power;


-- Combo beliefs use a non-engine class (must exist before Beliefs insert — FK).
insert or ignore into BeliefClasses
	(BeliefClassType, Name, MaxInReligion, AdoptionOrder)
values
	('BELIEF_CLASS_CP_DISABLED', 'LOC_BELIEF_CLASS_PANTHEON_NAME', 0, 99),
	('BELIEF_CLASS_CP_COMBO', 'LOC_BELIEF_CLASS_PANTHEON_NAME', 1, 1);

insert or ignore into Types
	(Type,									Kind) select
	'BELIEF_'||GodhoodType||'_WITH_'||PowerType,	'KIND_BELIEF'
	from Godhood, Power;

-- Combinations use BELIEF_CLASS_CP_COMBO (not PANTHEON): engine AI must not auto-pick
-- (it stacks Dance of the Aurora). Humans/CP_AI found via Lua FoundPantheon.
insert or ignore into Beliefs
	(BeliefType,						Name,										Description,											BeliefClassType) select
	'BELIEF_'||GodhoodType||'_WITH_'||PowerType,	'LOC_BELIEF_'||GodhoodType||'_WITH_'||PowerType||'_NAME',	'LOC_BELIEF_'||GodhoodType||'_WITH_'||PowerType||'_DESCRIPTION',	'BELIEF_CLASS_CP_COMBO'
	from Godhood, Power;


--地貌类别
insert or ignore into Requirements(RequirementId,	RequirementType) select
'REQ_'||GodhoodType||'_TAG_MATCHES',	'REQUIREMENT_PLOT_FEATURE_TAG_MATCHES'
from GodHood where ghClass = 'FEATURE';

insert or ignore into RequirementArguments(RequirementId,	Name, Value) select
	'REQ_'||GodhoodType||'_TAG_MATCHES',	'Tag',	'CLASS_'||GodhoodType
from GodHood where ghClass = 'FEATURE';

insert or ignore into Tags
		(Tag,						Vocabulary) select
		'CLASS_'||GodhoodType,	'FEATURE_CLASS'
		from GodHood where ghClass = 'FEATURE';

insert or ignore into TypeTags
		(Tag,						Type) select
		'CLASS_'||GodhoodType,	ghParam1
		from GodHood where ghClass = 'FEATURE';

--改良类别
insert or ignore into Requirements(RequirementId,	RequirementType) select
'REQ_'||GodhoodType||'_TAG_MATCHES',	'REQUIREMENT_PLOT_IMPROVEMENT_TAG_MATCHES'
from GodHood where ghClass = 'IMPROVEMENT';

insert or ignore into RequirementArguments(RequirementId,	Name, Value) select
	'REQ_'||GodhoodType||'_TAG_MATCHES',	'Tag',	'CLASS_'||GodhoodType
from GodHood where ghClass = 'IMPROVEMENT';

insert or ignore into Tags
		(Tag,						Vocabulary) select
		'CLASS_'||GodhoodType,	'IMPROVEMENT_CLASS'
		from GodHood where ghClass = 'IMPROVEMENT';

insert or ignore into TypeTags
		(Tag,					Type) select
		'CLASS_'||GodhoodType,	ghParam1
		from GodHood where ghClass = 'IMPROVEMENT';

--地形类别
insert or ignore into Requirements(RequirementId,	RequirementType) select
'REQ_'||GodhoodType||'_TAG_MATCHES',	'REQUIREMENT_PLOT_TERRAIN_CLASS_MATCHES'
from GodHood where ghClass = 'TERRAIN';

insert or ignore into RequirementArguments(RequirementId,	Name, Value) select
	'REQ_'||GodhoodType||'_TAG_MATCHES',	'TerrainClass',	'TERRAIN_CLASS_'||GodhoodType
from GodHood where ghClass = 'TERRAIN';


insert or ignore into TerrainClasses
	(TerrainClassType,		Name) select
	'TERRAIN_CLASS_'||GodhoodType,	'LOC_TERRAIN_CLASS_'||GodhoodType||'_NAME'
from GodHood where ghClass = 'TERRAIN';

insert or ignore into TerrainClass_Terrains
	(TerrainClassType,		TerrainType) select
	'TERRAIN_CLASS_'||GodhoodType,	ghParam1
from GodHood where ghClass = 'TERRAIN';

--阈值计数器
create table 'ThresholdCounter'(
	'Delta' INT NOT NULL,
	'Threshold' INT NOT NULL,
	'MultiNumber' INT,
	PRIMARY KEY('Delta',	'Threshold')
);

insert or ignore into ThresholdCounter(Delta,	Threshold, MultiNumber) select
	a.numbers, b.numbers, ((b.numbers - 1)/a.numbers + 1)
	from counter_m a,	counter_m b;


--一环内某神格的点数达到某阈值
--地形/地貌/改良类  
--阈值req
insert or ignore into Requirements(RequirementId,	RequirementType) select
	'REQ_'||GodhoodType||'_THRESHOLD_'||numbers,	'REQUIREMENT_COLLECTION_COUNT_ATLEAST'
	from GodHood, counter_m where ghClass in ('IMPROVEMENT',	'FEATURE',	'TERRAIN');

insert or ignore into RequirementArguments(RequirementId, Name, Value) select
	'REQ_'||GodhoodType||'_THRESHOLD_'||numbers,	'CollectionType',	'COLLECTION_ALL_PLOT_YIELDS'
	from GodHood, counter_m where ghClass in ('IMPROVEMENT',	'FEATURE',	'TERRAIN');

-- Count = adjacent matching plots needed for devotion threshold.
-- MultiNumber = ((Threshold-1)/Delta + 1). Do NOT +1 for improvements:
-- that old "bugfix" required one extra plot (e.g. 3 fishing boats for
-- miracle threshold 6 instead of 2), breaking community-reported combos.
insert or ignore into RequirementArguments(RequirementId, Name, Value) select
	'REQ_'||GodhoodType||'_THRESHOLD_'||numbers,	'Count',	MultiNumber
	from GodHood, counter_m, ThresholdCounter 
	where ghClass in ('IMPROVEMENT',	'FEATURE',	'TERRAIN')
	and Delta = ghParam2 and Threshold = numbers;



insert or ignore into RequirementArguments(RequirementId, Name, Value) select
	'REQ_'||GodhoodType||'_THRESHOLD_'||numbers,	'RequirementSetId',	'RS_REQ_'||GodhoodType||'_THRESHOLD'
	from GodHood, counter_m where ghClass in ('IMPROVEMENT',	'FEATURE',	'TERRAIN');

--阈值rs
insert or ignore into RequirementSets(RequirementSetId, RequirementSetType) select
	'RS_'||GodhoodType||'_THRESHOLD_'||numbers,		'REQUIREMENTSET_TEST_ALL'
	from GodHood, counter_m where ghClass in ('IMPROVEMENT',	'FEATURE',	'TERRAIN');

insert or ignore into RequirementSetRequirements(RequirementSetId, RequirementId) select
	'RS_'||GodhoodType||'_THRESHOLD_'||numbers,		'REQ_'||GodhoodType||'_THRESHOLD_'||numbers
	from GodHood join counter_m where ghClass in ('IMPROVEMENT',	'FEATURE',	'TERRAIN');




insert or ignore into RequirementSets(RequirementSetId, RequirementSetType) select
	'RS_REQ_'||GodhoodType||'_THRESHOLD',		'REQUIREMENTSET_TEST_ALL'
	from GodHood, counter_m where ghClass in ('IMPROVEMENT',	'FEATURE',	'TERRAIN');

insert or ignore into RequirementSetRequirements(RequirementSetId, RequirementId) select
	'RS_REQ_'||GodhoodType||'_THRESHOLD',		'REQ_OBJECT_WITHIN_1_TILES'
	from GodHood, counter_m where ghClass in ('IMPROVEMENT',	'FEATURE',	'TERRAIN');

insert or ignore into RequirementSetRequirements(RequirementSetId, RequirementId) select
	'RS_REQ_'||GodhoodType||'_THRESHOLD',		'REQ_'||GodhoodType||'_TAG_MATCHES'
	from GodHood, counter_m where ghClass in ('IMPROVEMENT',	'FEATURE',	'TERRAIN');	

--大地女神 魅力类
--阈值rs
insert or ignore into RequirementSets(RequirementSetId, RequirementSetType) select
	'RS_EARTH_GODDESS_THRESHOLD_'||numbers,	'REQUIREMENTSET_TEST_ALL'
	from counter_m;

insert or ignore into RequirementSetRequirements(RequirementSetId, RequirementId) select
	'RS_EARTH_GODDESS_THRESHOLD_'||numbers,	'REQ_EARTH_GODDESS_THRESHOLD_'||numbers
	from counter_m;
--阈值req
insert or ignore into Requirements(RequirementId,	RequirementType) select
	'REQ_EARTH_GODDESS_THRESHOLD_'||numbers,	'REQUIREMENT_PLOT_IS_APPEAL_BETWEEN'
	from counter_m;

insert or ignore into RequirementArguments(RequirementId, Name, Value) select
	'REQ_EARTH_GODDESS_THRESHOLD_'||numbers,	'MinimumAppeal',	numbers * 2
	from counter_m;

--美神 魅力类
--阈值rs
insert or ignore into RequirementSets(RequirementSetId, RequirementSetType) select
	'RS_GOD_OF_BEAUTY_THRESHOLD_'||numbers,	'REQUIREMENTSET_TEST_ALL'
	from counter_m;

insert or ignore into RequirementSetRequirements(RequirementSetId, RequirementId) select
	'RS_GOD_OF_BEAUTY_THRESHOLD_'||numbers,	'REQ_GOD_OF_BEAUTY_THRESHOLD_'||numbers
	from counter_m;
--阈值req
insert or ignore into Requirements(RequirementId,	RequirementType) select
	'REQ_GOD_OF_BEAUTY_THRESHOLD_'||numbers,	'REQUIREMENT_PLOT_IS_APPEAL_BETWEEN'
	from counter_m;

insert or ignore into RequirementArguments(RequirementId, Name, Value) select
	'REQ_GOD_OF_BEAUTY_THRESHOLD_'||numbers,	'MinimumAppeal',	numbers
	from counter_m;


------------------------------------------

-- Religious Settlements / God of Wine: exclusive-band modifiers live after Divine Spark
-- (they share PROP_CP_B24_*/B35_* flags). See v15 block below.

--原主神纪念碑
insert or ignore into PantheonModifiers(GodhoodType,	PowerType, ModifierId) select
	GodhoodType,	'MONUMENT_TO_THE_GODS',	GodhoodType||'_MONUMENT_TO_THE_GODS_PRODUCTION_FOR_A_E_WONDERS'
	from Godhood where ghClass in ('IMPROVEMENT',	'FEATURE',	'TERRAIN', 'APPEAL');

insert or ignore into Modifiers(ModifierId,	ModifierType, SubjectRequirementSetId) select
	GodhoodType||'_MONUMENT_TO_THE_GODS_PRODUCTION_FOR_A_E_WONDERS',		'MODIFIER_PLAYER_CITIES_ADJUST_WONDER_ERA_PRODUCTION',		'RS_'||GodhoodType||'_THRESHOLD_4'
	from Godhood where ghClass in ('IMPROVEMENT',	'FEATURE',	'TERRAIN', 'APPEAL');

insert or ignore into ModifierArguments(ModifierId,	Name,	Value) select
	GodhoodType||'_MONUMENT_TO_THE_GODS_PRODUCTION_FOR_A_E_WONDERS',		'Amount',	25
	from Godhood where ghClass in ('IMPROVEMENT',	'FEATURE',	'TERRAIN', 'APPEAL');
insert or ignore into ModifierArguments(ModifierId,	Name,	Value) select
	GodhoodType||'_MONUMENT_TO_THE_GODS_PRODUCTION_FOR_A_E_WONDERS',		'EndEra',	'ERA_CLASSICAL'
	from Godhood where ghClass in ('IMPROVEMENT',	'FEATURE',	'TERRAIN', 'APPEAL');
insert or ignore into ModifierArguments(ModifierId,	Name,	Value) select
	GodhoodType||'_MONUMENT_TO_THE_GODS_PRODUCTION_FOR_A_E_WONDERS',		'IsWonder',	'true'
	from Godhood where ghClass in ('IMPROVEMENT',	'FEATURE',	'TERRAIN', 'APPEAL');
insert or ignore into ModifierArguments(ModifierId,	Name,	Value) select
	GodhoodType||'_MONUMENT_TO_THE_GODS_PRODUCTION_FOR_A_E_WONDERS',		'StartEra',	'ERA_ANCIENT'
	from Godhood where ghClass in ('IMPROVEMENT',	'FEATURE',	'TERRAIN', 'APPEAL');

--原城市守护女神
insert or ignore into PantheonModifiers(GodhoodType,	PowerType, ModifierId) select
	GodhoodType,	'CITY_PATRON_GODDESS',	GodhoodType||'_CITY_PATRON_GODDESS_EXTRA_DISTRICT'
	from Godhood where ghClass in ('IMPROVEMENT',	'FEATURE',	'TERRAIN', 'APPEAL');

insert or ignore into Modifiers(ModifierId,	ModifierType, SubjectRequirementSetId) select
	GodhoodType||'_CITY_PATRON_GODDESS_EXTRA_DISTRICT',		'QGG_MODIFIER_PLAYER_CITIES_EXTRA_DISTRICT',		'RS_'||GodhoodType||'_THRESHOLD_4_HAS_1_DISTRICT'
	from Godhood where ghClass in ('IMPROVEMENT',	'FEATURE',	'TERRAIN', 'APPEAL');

insert or ignore into ModifierArguments(ModifierId,	Name,	Value) select
	GodhoodType||'_CITY_PATRON_GODDESS_EXTRA_DISTRICT',		'Amount',	1
	from Godhood where ghClass in ('IMPROVEMENT',	'FEATURE',	'TERRAIN', 'APPEAL');

--城市守护女神rs
    insert or ignore into RequirementSets(RequirementSetId, RequirementSetType) select
	'RS_'||GodhoodType||'_THRESHOLD_4_HAS_1_DISTRICT',		'REQUIREMENTSET_TEST_ALL'
	from GodHood where ghClass in ('IMPROVEMENT',	'FEATURE',	'TERRAIN', 'APPEAL');

    insert or ignore into RequirementSetRequirements(RequirementSetId, RequirementId) select
	'RS_'||GodhoodType||'_THRESHOLD_4_HAS_1_DISTRICT',		'REQ_'||GodhoodType||'_THRESHOLD_4'
	from GodHood where ghClass in ('IMPROVEMENT',	'FEATURE',	'TERRAIN', 'APPEAL');

    insert or ignore into RequirementSetRequirements(RequirementSetId, RequirementId) select
	'RS_'||GodhoodType||'_THRESHOLD_4_HAS_1_DISTRICT',		'REQ_CITY_HAS_1_DISTRICTS'
	from GodHood where ghClass in ('IMPROVEMENT',	'FEATURE',	'TERRAIN', 'APPEAL');

-- 城市守护女神modifier
insert or ignore into Types (Type, Kind) VALUES 
('QGG_MODIFIER_PLAYER_CITIES_EXTRA_DISTRICT', 'KIND_MODIFIER');

insert or ignore into DynamicModifiers (ModifierType, CollectionType, EffectType) VALUES 
('QGG_MODIFIER_PLAYER_CITIES_EXTRA_DISTRICT', 'COLLECTION_PLAYER_CITIES', 'EFFECT_ADJUST_CITY_EXTRA_DISTRICTS');





--神圣之光rs（保留：其它逻辑/探针可能引用；DS 效果改用分离的 district-only + threshold-only）
    insert or ignore into RequirementSets(RequirementSetId, RequirementSetType) select
	'RS_'||GodhoodType||'_THRESHOLD_2_'||DistrictType,		'REQUIREMENTSET_TEST_ALL'
	from GodHood,  District_GreatPersonPoints where ghClass in ('IMPROVEMENT',	'FEATURE',	'TERRAIN', 'APPEAL');

    insert or ignore into RequirementSetRequirements(RequirementSetId, RequirementId) select
	'RS_'||GodhoodType||'_THRESHOLD_2_'||DistrictType,		'REQ_'||GodhoodType||'_THRESHOLD_2'
	from GodHood,  District_GreatPersonPoints where ghClass in ('IMPROVEMENT',	'FEATURE',	'TERRAIN', 'APPEAL');

    insert or ignore into RequirementSetRequirements(RequirementSetId, RequirementId) select
	'RS_'||GodhoodType||'_THRESHOLD_2_'||DistrictType,		'REQ_PLOT_HAS_'||DistrictType
	from GodHood,  District_GreatPersonPoints where ghClass in ('IMPROVEMENT',	'FEATURE',	'TERRAIN', 'APPEAL');

    insert or ignore into RequirementSets(RequirementSetId, RequirementSetType) select
	'RS_'||GodhoodType||'_THRESHOLD_4_'||DistrictType,		'REQUIREMENTSET_TEST_ALL'
	from GodHood,  District_GreatPersonPoints where ghClass in ('IMPROVEMENT',	'FEATURE',	'TERRAIN', 'APPEAL');

    insert or ignore into RequirementSetRequirements(RequirementSetId, RequirementId) select
	'RS_'||GodhoodType||'_THRESHOLD_4_'||DistrictType,		'REQ_'||GodhoodType||'_THRESHOLD_4'
	from GodHood,  District_GreatPersonPoints where ghClass in ('IMPROVEMENT',	'FEATURE',	'TERRAIN', 'APPEAL');

    insert or ignore into RequirementSetRequirements(RequirementSetId, RequirementId) select
	'RS_'||GodhoodType||'_THRESHOLD_4_'||DistrictType,		'REQ_PLOT_HAS_'||DistrictType
	from GodHood,  District_GreatPersonPoints where ghClass in ('IMPROVEMENT',	'FEATURE',	'TERRAIN', 'APPEAL');

-- =============================================================================
-- Divine Spark (v15) — mutually exclusive bands (never two GPP mods on one district)
-- Bug: two ADJUST_GREAT_PERSON_POINTS on the same district+GP class doubles
-- (base+mods)×2. Fix: only one modifier active at a time.
--   2 ≤ devotion < 4  → +1
--   devotion ≥ 4      → +3  (equals old +1 then +2, single modifier)
-- v13/v14 used Inverse LT_4 on PROP_CP_DEV_* — Inverse does not exclude the high
-- band (Sea+3 boats → (1+1+3)×2=10). v15: Lua writes exclusive PROP_CP_B24_LO/HI.
-- =============================================================================
delete from PantheonModifiers where PowerType = 'DIVINE_SPARK';
delete from ModifierArguments where ModifierId like '%_DIVINE_SPARK_%' or ModifierId like 'CPDS_%';
delete from Modifiers where ModifierId like '%_DIVINE_SPARK_%' or ModifierId like 'CPDS_%';
delete from RequirementSetRequirements where RequirementSetId like 'RS_CPDS_%';
delete from RequirementSets where RequirementSetId like 'RS_CPDS_%';
delete from RequirementArguments where RequirementId like 'REQ_CP_DEV_%'
	or RequirementId like 'REQ_CP_B24_%' or RequirementId like 'REQ_CP_B35_%';
delete from Requirements where RequirementId like 'REQ_CP_DEV_%'
	or RequirementId like 'REQ_CP_B24_%' or RequirementId like 'REQ_CP_B35_%';

-- Exclusive band flags (Lua SetCachedDevotion writes 0/1; never both LO and HI)
insert or ignore into Requirements (RequirementId, RequirementType) select
	'REQ_CP_B24_LO_'||GodhoodType, 'REQUIREMENT_PLOT_PROPERTY_MATCHES'
	from GodHood where ghClass in ('IMPROVEMENT', 'FEATURE', 'TERRAIN', 'APPEAL');
insert or ignore into RequirementArguments (RequirementId, Name, Value) select
	'REQ_CP_B24_LO_'||GodhoodType, 'PropertyName', 'PROP_CP_B24_LO_'||GodhoodType
	from GodHood where ghClass in ('IMPROVEMENT', 'FEATURE', 'TERRAIN', 'APPEAL');
insert or ignore into RequirementArguments (RequirementId, Name, Value) select
	'REQ_CP_B24_LO_'||GodhoodType, 'PropertyMinimum', '1'
	from GodHood where ghClass in ('IMPROVEMENT', 'FEATURE', 'TERRAIN', 'APPEAL');

insert or ignore into Requirements (RequirementId, RequirementType) select
	'REQ_CP_B24_HI_'||GodhoodType, 'REQUIREMENT_PLOT_PROPERTY_MATCHES'
	from GodHood where ghClass in ('IMPROVEMENT', 'FEATURE', 'TERRAIN', 'APPEAL');
insert or ignore into RequirementArguments (RequirementId, Name, Value) select
	'REQ_CP_B24_HI_'||GodhoodType, 'PropertyName', 'PROP_CP_B24_HI_'||GodhoodType
	from GodHood where ghClass in ('IMPROVEMENT', 'FEATURE', 'TERRAIN', 'APPEAL');
insert or ignore into RequirementArguments (RequirementId, Name, Value) select
	'REQ_CP_B24_HI_'||GodhoodType, 'PropertyMinimum', '1'
	from GodHood where ghClass in ('IMPROVEMENT', 'FEATURE', 'TERRAIN', 'APPEAL');

insert or ignore into Requirements (RequirementId, RequirementType) select
	'REQ_CP_B35_LO_'||GodhoodType, 'REQUIREMENT_PLOT_PROPERTY_MATCHES'
	from GodHood where ghClass in ('IMPROVEMENT', 'FEATURE', 'TERRAIN', 'APPEAL');
insert or ignore into RequirementArguments (RequirementId, Name, Value) select
	'REQ_CP_B35_LO_'||GodhoodType, 'PropertyName', 'PROP_CP_B35_LO_'||GodhoodType
	from GodHood where ghClass in ('IMPROVEMENT', 'FEATURE', 'TERRAIN', 'APPEAL');
insert or ignore into RequirementArguments (RequirementId, Name, Value) select
	'REQ_CP_B35_LO_'||GodhoodType, 'PropertyMinimum', '1'
	from GodHood where ghClass in ('IMPROVEMENT', 'FEATURE', 'TERRAIN', 'APPEAL');

insert or ignore into Requirements (RequirementId, RequirementType) select
	'REQ_CP_B35_HI_'||GodhoodType, 'REQUIREMENT_PLOT_PROPERTY_MATCHES'
	from GodHood where ghClass in ('IMPROVEMENT', 'FEATURE', 'TERRAIN', 'APPEAL');
insert or ignore into RequirementArguments (RequirementId, Name, Value) select
	'REQ_CP_B35_HI_'||GodhoodType, 'PropertyName', 'PROP_CP_B35_HI_'||GodhoodType
	from GodHood where ghClass in ('IMPROVEMENT', 'FEATURE', 'TERRAIN', 'APPEAL');
insert or ignore into RequirementArguments (RequirementId, Name, Value) select
	'REQ_CP_B35_HI_'||GodhoodType, 'PropertyMinimum', '1'
	from GodHood where ghClass in ('IMPROVEMENT', 'FEATURE', 'TERRAIN', 'APPEAL');

-- Low band SubjectReq: district type + B24_LO flag
insert or ignore into RequirementSets (RequirementSetId, RequirementSetType) select
	'RS_CPDS_'||GodhoodType||'_'||DistrictType||'_'||GreatPersonClassType||'_LO',
	'REQUIREMENTSET_TEST_ALL'
	from GodHood, District_GreatPersonPoints
	where ghClass in ('IMPROVEMENT', 'FEATURE', 'TERRAIN', 'APPEAL')
	and DistrictType not in (select CivUniqueDistrictType from DistrictReplaces);

insert or ignore into RequirementSetRequirements (RequirementSetId, RequirementId) select
	'RS_CPDS_'||GodhoodType||'_'||DistrictType||'_'||GreatPersonClassType||'_LO',
	case DistrictType
		when 'DISTRICT_CAMPUS' then 'REQUIRES_DISTRICT_IS_CAMPUS'
		when 'DISTRICT_HOLY_SITE' then 'REQUIRES_DISTRICT_IS_HOLY_SITE'
		when 'DISTRICT_HARBOR' then 'REQUIRES_DISTRICT_IS_HARBOR'
		when 'DISTRICT_COMMERCIAL_HUB' then 'REQUIRES_DISTRICT_IS_COMMERCIAL_HUB'
		when 'DISTRICT_ENCAMPMENT' then 'REQUIRES_DISTRICT_IS_ENCAMPMENT'
		when 'DISTRICT_INDUSTRIAL_ZONE' then 'REQUIRES_DISTRICT_IS_INDUSTRIAL_ZONE'
		when 'DISTRICT_THEATER' then 'REQUIRES_DISTRICT_IS_THEATER'
		when 'DISTRICT_ENTERTAINMENT_COMPLEX' then 'REQUIRES_DISTRICT_IS_ENTERTAINMENT_COMPLEX'
		else 'REQ_PLOT_HAS_'||DistrictType
	end
	from GodHood, District_GreatPersonPoints
	where ghClass in ('IMPROVEMENT', 'FEATURE', 'TERRAIN', 'APPEAL')
	and DistrictType not in (select CivUniqueDistrictType from DistrictReplaces);

insert or ignore into RequirementSetRequirements (RequirementSetId, RequirementId) select
	'RS_CPDS_'||GodhoodType||'_'||DistrictType||'_'||GreatPersonClassType||'_LO',
	'REQ_CP_B24_LO_'||GodhoodType
	from GodHood, District_GreatPersonPoints
	where ghClass in ('IMPROVEMENT', 'FEATURE', 'TERRAIN', 'APPEAL')
	and DistrictType not in (select CivUniqueDistrictType from DistrictReplaces);

-- High band SubjectReq: district type + B24_HI flag
insert or ignore into RequirementSets (RequirementSetId, RequirementSetType) select
	'RS_CPDS_'||GodhoodType||'_'||DistrictType||'_'||GreatPersonClassType||'_HI',
	'REQUIREMENTSET_TEST_ALL'
	from GodHood, District_GreatPersonPoints
	where ghClass in ('IMPROVEMENT', 'FEATURE', 'TERRAIN', 'APPEAL');

insert or ignore into RequirementSetRequirements (RequirementSetId, RequirementId) select
	'RS_CPDS_'||GodhoodType||'_'||DistrictType||'_'||GreatPersonClassType||'_HI',
	case DistrictType
		when 'DISTRICT_CAMPUS' then 'REQUIRES_DISTRICT_IS_CAMPUS'
		when 'DISTRICT_HOLY_SITE' then 'REQUIRES_DISTRICT_IS_HOLY_SITE'
		when 'DISTRICT_HARBOR' then 'REQUIRES_DISTRICT_IS_HARBOR'
		when 'DISTRICT_COMMERCIAL_HUB' then 'REQUIRES_DISTRICT_IS_COMMERCIAL_HUB'
		when 'DISTRICT_ENCAMPMENT' then 'REQUIRES_DISTRICT_IS_ENCAMPMENT'
		when 'DISTRICT_INDUSTRIAL_ZONE' then 'REQUIRES_DISTRICT_IS_INDUSTRIAL_ZONE'
		when 'DISTRICT_THEATER' then 'REQUIRES_DISTRICT_IS_THEATER'
		when 'DISTRICT_ENTERTAINMENT_COMPLEX' then 'REQUIRES_DISTRICT_IS_ENTERTAINMENT_COMPLEX'
		else 'REQ_PLOT_HAS_'||DistrictType
	end
	from GodHood, District_GreatPersonPoints
	where ghClass in ('IMPROVEMENT', 'FEATURE', 'TERRAIN', 'APPEAL');

insert or ignore into RequirementSetRequirements (RequirementSetId, RequirementId) select
	'RS_CPDS_'||GodhoodType||'_'||DistrictType||'_'||GreatPersonClassType||'_HI',
	'REQ_CP_B24_HI_'||GodhoodType
	from GodHood, District_GreatPersonPoints
	where ghClass in ('IMPROVEMENT', 'FEATURE', 'TERRAIN', 'APPEAL');

-- Low: +1 (only when high is off)
insert or ignore into PantheonModifiers(GodhoodType, PowerType, ModifierId) select
	GodhoodType, 'DIVINE_SPARK',
	'CPDS_'||GodhoodType||'_'||DistrictType||'_'||GreatPersonClassType||'_LO'
	from GodHood, District_GreatPersonPoints
	where ghClass in ('IMPROVEMENT', 'FEATURE', 'TERRAIN', 'APPEAL')
	and DistrictType not in (select CivUniqueDistrictType from DistrictReplaces);

insert or ignore into Modifiers(ModifierId, ModifierType, SubjectRequirementSetId) select
	'CPDS_'||GodhoodType||'_'||DistrictType||'_'||GreatPersonClassType||'_LO',
	'MODIFIER_PLAYER_DISTRICTS_ADJUST_GREAT_PERSON_POINTS',
	'RS_CPDS_'||GodhoodType||'_'||DistrictType||'_'||GreatPersonClassType||'_LO'
	from GodHood, District_GreatPersonPoints
	where ghClass in ('IMPROVEMENT', 'FEATURE', 'TERRAIN', 'APPEAL')
	and DistrictType not in (select CivUniqueDistrictType from DistrictReplaces);

insert or ignore into ModifierArguments(ModifierId, Name, Value) select
	'CPDS_'||GodhoodType||'_'||DistrictType||'_'||GreatPersonClassType||'_LO',
	'Amount', 1
	from GodHood, District_GreatPersonPoints
	where ghClass in ('IMPROVEMENT', 'FEATURE', 'TERRAIN', 'APPEAL')
	and DistrictType not in (select CivUniqueDistrictType from DistrictReplaces);

insert or ignore into ModifierArguments(ModifierId, Name, Value) select
	'CPDS_'||GodhoodType||'_'||DistrictType||'_'||GreatPersonClassType||'_LO',
	'GreatPersonClassType', GreatPersonClassType
	from GodHood, District_GreatPersonPoints
	where ghClass in ('IMPROVEMENT', 'FEATURE', 'TERRAIN', 'APPEAL')
	and DistrictType not in (select CivUniqueDistrictType from DistrictReplaces);

-- High: +3 in one modifier (include unique districts)
insert or ignore into PantheonModifiers(GodhoodType, PowerType, ModifierId) select
	GodhoodType, 'DIVINE_SPARK',
	'CPDS_'||GodhoodType||'_'||DistrictType||'_'||GreatPersonClassType||'_HI'
	from GodHood, District_GreatPersonPoints
	where ghClass in ('IMPROVEMENT', 'FEATURE', 'TERRAIN', 'APPEAL');

insert or ignore into Modifiers(ModifierId, ModifierType, SubjectRequirementSetId) select
	'CPDS_'||GodhoodType||'_'||DistrictType||'_'||GreatPersonClassType||'_HI',
	'MODIFIER_PLAYER_DISTRICTS_ADJUST_GREAT_PERSON_POINTS',
	'RS_CPDS_'||GodhoodType||'_'||DistrictType||'_'||GreatPersonClassType||'_HI'
	from GodHood, District_GreatPersonPoints
	where ghClass in ('IMPROVEMENT', 'FEATURE', 'TERRAIN', 'APPEAL');

insert or ignore into ModifierArguments(ModifierId, Name, Value) select
	'CPDS_'||GodhoodType||'_'||DistrictType||'_'||GreatPersonClassType||'_HI',
	'Amount', 3
	from GodHood, District_GreatPersonPoints
	where ghClass in ('IMPROVEMENT', 'FEATURE', 'TERRAIN', 'APPEAL');

insert or ignore into ModifierArguments(ModifierId, Name, Value) select
	'CPDS_'||GodhoodType||'_'||DistrictType||'_'||GreatPersonClassType||'_HI',
	'GreatPersonClassType', GreatPersonClassType
	from GodHood, District_GreatPersonPoints
	where ghClass in ('IMPROVEMENT', 'FEATURE', 'TERRAIN', 'APPEAL');

-- =============================================================================
-- Religious Settlements (v15) — mutually exclusive housing via B24 flags
--   2 ≤ devotion < 4  → +1
--   devotion ≥ 4      → +2
-- =============================================================================
delete from PantheonModifiers where PowerType = 'RELIGIOUS_SETTLEMENTS';
delete from ModifierArguments where ModifierId like '%_RELIGIOUS_SETTLEMENTS_HOUSING%' or ModifierId like 'CPRS_%';
delete from Modifiers where ModifierId like '%_RELIGIOUS_SETTLEMENTS_HOUSING%' or ModifierId like 'CPRS_%';
delete from RequirementSetRequirements where RequirementSetId like 'RS_CPRS_%';
delete from RequirementSets where RequirementSetId like 'RS_CPRS_%';

insert or ignore into RequirementSets (RequirementSetId, RequirementSetType) select
	'RS_CPRS_'||GodhoodType||'_LO', 'REQUIREMENTSET_TEST_ALL'
	from GodHood where ghClass in ('IMPROVEMENT', 'FEATURE', 'TERRAIN', 'APPEAL');

insert or ignore into RequirementSetRequirements (RequirementSetId, RequirementId) select
	'RS_CPRS_'||GodhoodType||'_LO', 'REQ_CP_B24_LO_'||GodhoodType
	from GodHood where ghClass in ('IMPROVEMENT', 'FEATURE', 'TERRAIN', 'APPEAL');

insert or ignore into RequirementSets (RequirementSetId, RequirementSetType) select
	'RS_CPRS_'||GodhoodType||'_HI', 'REQUIREMENTSET_TEST_ALL'
	from GodHood where ghClass in ('IMPROVEMENT', 'FEATURE', 'TERRAIN', 'APPEAL');

insert or ignore into RequirementSetRequirements (RequirementSetId, RequirementId) select
	'RS_CPRS_'||GodhoodType||'_HI', 'REQ_CP_B24_HI_'||GodhoodType
	from GodHood where ghClass in ('IMPROVEMENT', 'FEATURE', 'TERRAIN', 'APPEAL');

insert or ignore into PantheonModifiers(GodhoodType, PowerType, ModifierId) select
	GodhoodType, 'RELIGIOUS_SETTLEMENTS', 'CPRS_'||GodhoodType||'_HOUSING_LO'
	from Godhood where ghClass in ('IMPROVEMENT', 'FEATURE', 'TERRAIN', 'APPEAL');

insert or ignore into Modifiers(ModifierId, ModifierType, SubjectRequirementSetId) select
	'CPRS_'||GodhoodType||'_HOUSING_LO',
	'MODIFIER_PLAYER_DISTRICTS_ADJUST_HOUSING',
	'RS_CPRS_'||GodhoodType||'_LO'
	from Godhood where ghClass in ('IMPROVEMENT', 'FEATURE', 'TERRAIN', 'APPEAL');

insert or ignore into ModifierArguments(ModifierId, Name, Value) select
	'CPRS_'||GodhoodType||'_HOUSING_LO', 'Amount', 1
	from Godhood where ghClass in ('IMPROVEMENT', 'FEATURE', 'TERRAIN', 'APPEAL');

insert or ignore into PantheonModifiers(GodhoodType, PowerType, ModifierId) select
	GodhoodType, 'RELIGIOUS_SETTLEMENTS', 'CPRS_'||GodhoodType||'_HOUSING_HI'
	from Godhood where ghClass in ('IMPROVEMENT', 'FEATURE', 'TERRAIN', 'APPEAL');

insert or ignore into Modifiers(ModifierId, ModifierType, SubjectRequirementSetId) select
	'CPRS_'||GodhoodType||'_HOUSING_HI',
	'MODIFIER_PLAYER_DISTRICTS_ADJUST_HOUSING',
	'RS_CPRS_'||GodhoodType||'_HI'
	from Godhood where ghClass in ('IMPROVEMENT', 'FEATURE', 'TERRAIN', 'APPEAL');

insert or ignore into ModifierArguments(ModifierId, Name, Value) select
	'CPRS_'||GodhoodType||'_HOUSING_HI', 'Amount', 2
	from Godhood where ghClass in ('IMPROVEMENT', 'FEATURE', 'TERRAIN', 'APPEAL');

-- =============================================================================
-- God of Wine (v15) — mutually exclusive amenity via B35 flags
--   3 ≤ devotion < 5  → +1
--   devotion ≥ 5      → +2
-- =============================================================================
delete from PantheonModifiers where PowerType = 'GOD_OF_WINE';
delete from ModifierArguments where ModifierId like '%_GOD_OF_WINE_AMENITY%' or ModifierId like 'CPWN_%';
delete from Modifiers where ModifierId like '%_GOD_OF_WINE_AMENITY%' or ModifierId like 'CPWN_%';
delete from RequirementSetRequirements where RequirementSetId like 'RS_CPWN_%';
delete from RequirementSets where RequirementSetId like 'RS_CPWN_%';

insert or ignore into RequirementSets (RequirementSetId, RequirementSetType) select
	'RS_CPWN_'||GodhoodType||'_LO', 'REQUIREMENTSET_TEST_ALL'
	from GodHood where ghClass in ('IMPROVEMENT', 'FEATURE', 'TERRAIN', 'APPEAL');

insert or ignore into RequirementSetRequirements (RequirementSetId, RequirementId) select
	'RS_CPWN_'||GodhoodType||'_LO', 'REQ_CP_B35_LO_'||GodhoodType
	from GodHood where ghClass in ('IMPROVEMENT', 'FEATURE', 'TERRAIN', 'APPEAL');

insert or ignore into RequirementSets (RequirementSetId, RequirementSetType) select
	'RS_CPWN_'||GodhoodType||'_HI', 'REQUIREMENTSET_TEST_ALL'
	from GodHood where ghClass in ('IMPROVEMENT', 'FEATURE', 'TERRAIN', 'APPEAL');

insert or ignore into RequirementSetRequirements (RequirementSetId, RequirementId) select
	'RS_CPWN_'||GodhoodType||'_HI', 'REQ_CP_B35_HI_'||GodhoodType
	from GodHood where ghClass in ('IMPROVEMENT', 'FEATURE', 'TERRAIN', 'APPEAL');

insert or ignore into PantheonModifiers(GodhoodType, PowerType, ModifierId) select
	GodhoodType, 'GOD_OF_WINE', 'CPWN_'||GodhoodType||'_AMENITY_LO'
	from Godhood where ghClass in ('IMPROVEMENT', 'FEATURE', 'TERRAIN', 'APPEAL');

insert or ignore into Modifiers(ModifierId, ModifierType, SubjectRequirementSetId) select
	'CPWN_'||GodhoodType||'_AMENITY_LO',
	'MODIFIER_PLAYER_DISTRICTS_ADJUST_EXTRA_ENTERTAINMENT',
	'RS_CPWN_'||GodhoodType||'_LO'
	from Godhood where ghClass in ('IMPROVEMENT', 'FEATURE', 'TERRAIN', 'APPEAL');

insert or ignore into ModifierArguments(ModifierId, Name, Value) select
	'CPWN_'||GodhoodType||'_AMENITY_LO', 'Amount', 1
	from Godhood where ghClass in ('IMPROVEMENT', 'FEATURE', 'TERRAIN', 'APPEAL');

insert or ignore into PantheonModifiers(GodhoodType, PowerType, ModifierId) select
	GodhoodType, 'GOD_OF_WINE', 'CPWN_'||GodhoodType||'_AMENITY_HI'
	from Godhood where ghClass in ('IMPROVEMENT', 'FEATURE', 'TERRAIN', 'APPEAL');

insert or ignore into Modifiers(ModifierId, ModifierType, SubjectRequirementSetId) select
	'CPWN_'||GodhoodType||'_AMENITY_HI',
	'MODIFIER_PLAYER_DISTRICTS_ADJUST_EXTRA_ENTERTAINMENT',
	'RS_CPWN_'||GodhoodType||'_HI'
	from Godhood where ghClass in ('IMPROVEMENT', 'FEATURE', 'TERRAIN', 'APPEAL');

insert or ignore into ModifierArguments(ModifierId, Name, Value) select
	'CPWN_'||GodhoodType||'_AMENITY_HI', 'Amount', 2
	from Godhood where ghClass in ('IMPROVEMENT', 'FEATURE', 'TERRAIN', 'APPEAL');




--文曲星神农单元格rs
    insert or ignore into RequirementSets(RequirementSetId, RequirementSetType) select
	'RS_'||GodhoodType||'_THRESHOLD_2_PLOT_TAG_MATCHES',		'REQUIREMENTSET_TEST_ALL'
	from GodHood where ghClass in ('IMPROVEMENT',	'FEATURE',	'TERRAIN') and ghParam3>1;

    insert or ignore into RequirementSetRequirements(RequirementSetId, RequirementId) select
	'RS_'||GodhoodType||'_THRESHOLD_2_PLOT_TAG_MATCHES',		'REQ_'||GodhoodType||'_TAG_MATCHES'
	from GodHood where ghClass in ('IMPROVEMENT',	'FEATURE',	'TERRAIN') and ghParam3>1;


--文曲星单元格产出

insert or ignore into PantheonModifiers(GodhoodType,	PowerType, ModifierId) select
	GodhoodType,	'GGV',	GodhoodType||'_GGV_PLOT_YIELD_CULTURE'
	from GodHood where (ghClass in ('IMPROVEMENT',	'FEATURE',	'TERRAIN')) and ghParam3>1;

insert or ignore into Modifiers(ModifierId,	ModifierType, SubjectRequirementSetId) select
	GodhoodType||'_GGV_PLOT_YIELD_CULTURE',		'MODIFIER_PLAYER_ADJUST_PLOT_YIELD',		'RS_'||GodhoodType||'_THRESHOLD_2_PLOT_TAG_MATCHES'
	from GodHood where (ghClass in ('IMPROVEMENT',	'FEATURE',	'TERRAIN')) and ghParam3>1;

insert or ignore into ModifierArguments(ModifierId,	Name,	Value) select distinct
	GodhoodType||'_GGV_PLOT_YIELD_CULTURE',		'Amount',	1
	from GodHood where (ghClass in ('IMPROVEMENT',	'FEATURE',	'TERRAIN')) and ghParam3>1;

insert or ignore into ModifierArguments(ModifierId,	Name,	Value) select distinct
	GodhoodType||'_GGV_PLOT_YIELD_CULTURE',		'YieldType',	'YIELD_CULTURE'
	from GodHood where (ghClass in ('IMPROVEMENT',	'FEATURE',	'TERRAIN')) and ghParam3>1;

--文曲星区域产出

insert or ignore into PantheonModifiers(GodhoodType,	PowerType, ModifierId) select
	GodhoodType,	'GGV',	GodhoodType||'_GGV_DISTRICT_YIELD_CULTURE'
	from GodHood where (ghClass in ('IMPROVEMENT',	'FEATURE',	'TERRAIN', 'APPEAL'));

insert or ignore into Modifiers(ModifierId,	ModifierType, SubjectRequirementSetId) select
	GodhoodType||'_GGV_DISTRICT_YIELD_CULTURE',		'MODIFIER_PLAYER_DISTRICTS_ADJUST_YIELD_CHANGE',		'RS_'||GodhoodType||'_THRESHOLD_2'
	from GodHood where (ghClass in ('IMPROVEMENT',	'FEATURE',	'TERRAIN', 'APPEAL'));

insert or ignore into ModifierArguments(ModifierId,	Name,	Value) select
	GodhoodType||'_GGV_DISTRICT_YIELD_CULTURE',		'Amount',	1
	from GodHood where (ghClass in ('IMPROVEMENT',	'FEATURE',	'TERRAIN', 'APPEAL'));

insert or ignore into ModifierArguments(ModifierId,	Name,	Value) select
	GodhoodType||'_GGV_DISTRICT_YIELD_CULTURE',		'YieldType',	'YIELD_CULTURE'
	from GodHood where (ghClass in ('IMPROVEMENT',	'FEATURE',	'TERRAIN', 'APPEAL'));

--文曲星 + 大地女神
insert or ignore into PantheonModifiers(GodhoodType,	PowerType, ModifierId) values
	('EARTH_GODDESS',	'GGV',		'EARTH_GODDESS_GGV_PLOT_YIELD_CULTURE');

insert or ignore into Modifiers(ModifierId,	ModifierType, SubjectRequirementSetId) values
	('EARTH_GODDESS_GGV_PLOT_YIELD_CULTURE',	'MODIFIER_PLAYER_ADJUST_PLOT_YIELD',		'RS_EARTH_GODDESS_THRESHOLD_2');

insert or ignore into ModifierArguments(ModifierId,	Name,	Value) values
	('EARTH_GODDESS_GGV_PLOT_YIELD_CULTURE',	'Amount',			1),
	('EARTH_GODDESS_GGV_PLOT_YIELD_CULTURE',	'YieldType',		'YIELD_CULTURE');




--神农单元格产出

insert or ignore into PantheonModifiers(GodhoodType,	PowerType, ModifierId) select
	GodhoodType,	'SHENNONG',	GodhoodType||'_SHENNONG_PLOT_YIELD_FOOD'
	from GodHood where (ghClass in ('IMPROVEMENT',	'FEATURE',	'TERRAIN')) and ghParam3>1;

insert or ignore into Modifiers(ModifierId,	ModifierType, SubjectRequirementSetId) select
	GodhoodType||'_SHENNONG_PLOT_YIELD_FOOD',		'MODIFIER_PLAYER_ADJUST_PLOT_YIELD',		'RS_'||GodhoodType||'_THRESHOLD_2_PLOT_TAG_MATCHES'
	from GodHood where (ghClass in ('IMPROVEMENT',	'FEATURE',	'TERRAIN')) and ghParam3>1;

insert or ignore into ModifierArguments(ModifierId,	Name,	Value) select distinct
	GodhoodType||'_SHENNONG_PLOT_YIELD_FOOD',		'Amount',	1
	from GodHood where (ghClass in ('IMPROVEMENT',	'FEATURE',	'TERRAIN')) and ghParam3>1;

insert or ignore into ModifierArguments(ModifierId,	Name,	Value) select distinct
	GodhoodType||'_SHENNONG_PLOT_YIELD_FOOD',		'YieldType',	'YIELD_FOOD'
	from GodHood where (ghClass in ('IMPROVEMENT',	'FEATURE',	'TERRAIN')) and ghParam3>1;


--神农区域产出

insert or ignore into PantheonModifiers(GodhoodType,	PowerType, ModifierId) select
	GodhoodType,	'SHENNONG',	GodhoodType||'_SHENNONG_DISTRICT_YIELD_FOOD'
	from GodHood where (ghClass in ('IMPROVEMENT',	'FEATURE',	'TERRAIN', 'APPEAL'));

insert or ignore into Modifiers(ModifierId,	ModifierType, SubjectRequirementSetId) select
	GodhoodType||'_SHENNONG_DISTRICT_YIELD_FOOD',		'MODIFIER_PLAYER_DISTRICTS_ADJUST_YIELD_CHANGE',		'RS_'||GodhoodType||'_THRESHOLD_2'
	from GodHood where (ghClass in ('IMPROVEMENT',	'FEATURE',	'TERRAIN', 'APPEAL'));

insert or ignore into ModifierArguments(ModifierId,	Name,	Value) select
	GodhoodType||'_SHENNONG_DISTRICT_YIELD_FOOD',		'Amount',	1
	from GodHood where (ghClass in ('IMPROVEMENT',	'FEATURE',	'TERRAIN', 'APPEAL'));

insert or ignore into ModifierArguments(ModifierId,	Name,	Value) select
	GodhoodType||'_SHENNONG_DISTRICT_YIELD_FOOD',		'YieldType',	'YIELD_FOOD'
	from GodHood where (ghClass in ('IMPROVEMENT',	'FEATURE',	'TERRAIN', 'APPEAL'));

--神农 + 大地女神
insert or ignore into PantheonModifiers(GodhoodType,	PowerType, ModifierId) values
	('EARTH_GODDESS',	'SHENNONG',		'EARTH_GODDESS_SHENNONG_PLOT_YIELD_FOOD');

insert or ignore into Modifiers(ModifierId,	ModifierType, SubjectRequirementSetId) values
	('EARTH_GODDESS_SHENNONG_PLOT_YIELD_FOOD',	'MODIFIER_PLAYER_ADJUST_PLOT_YIELD',		'RS_EARTH_GODDESS_THRESHOLD_2');

insert or ignore into ModifierArguments(ModifierId,	Name,	Value) values
	('EARTH_GODDESS_SHENNONG_PLOT_YIELD_FOOD',	'Amount',			1),
	('EARTH_GODDESS_SHENNONG_PLOT_YIELD_FOOD',	'YieldType',		'YIELD_FOOD');

--工匠之神单元格产出

insert or ignore into PantheonModifiers(GodhoodType,	PowerType, ModifierId) select
	GodhoodType,	'GOD_OF_CRAFTSMEN',	GodhoodType||'_CRAFTSMEN_PLOT_YIELD_PRODUCTION'
	from GodHood where (ghClass in ('IMPROVEMENT',	'FEATURE',	'TERRAIN')) and ghParam3>1;

insert or ignore into Modifiers(ModifierId,	ModifierType, SubjectRequirementSetId) select
	GodhoodType||'_CRAFTSMEN_PLOT_YIELD_PRODUCTION',		'MODIFIER_PLAYER_ADJUST_PLOT_YIELD',		'RS_'||GodhoodType||'_THRESHOLD_2_PLOT_TAG_MATCHES'
	from GodHood where (ghClass in ('IMPROVEMENT',	'FEATURE',	'TERRAIN')) and ghParam3>1;

insert or ignore into ModifierArguments(ModifierId,	Name,	Value) select distinct
	GodhoodType||'_CRAFTSMEN_PLOT_YIELD_PRODUCTION',		'Amount',	1
	from GodHood where (ghClass in ('IMPROVEMENT',	'FEATURE',	'TERRAIN')) and ghParam3>1;

insert or ignore into ModifierArguments(ModifierId,	Name,	Value) select distinct
	GodhoodType||'_CRAFTSMEN_PLOT_YIELD_PRODUCTION',		'YieldType',	'YIELD_PRODUCTION'
	from GodHood where (ghClass in ('IMPROVEMENT',	'FEATURE',	'TERRAIN')) and ghParam3>1;


--工匠之神区域产出

insert or ignore into PantheonModifiers(GodhoodType,	PowerType, ModifierId) select
	GodhoodType,	'GOD_OF_CRAFTSMEN',	GodhoodType||'_CRAFTSMEN_DISTRICT_YIELD_PRODUCTION'
	from GodHood where (ghClass in ('IMPROVEMENT',	'FEATURE',	'TERRAIN', 'APPEAL'));

insert or ignore into Modifiers(ModifierId,	ModifierType, SubjectRequirementSetId) select
	GodhoodType||'_CRAFTSMEN_DISTRICT_YIELD_PRODUCTION',		'MODIFIER_PLAYER_DISTRICTS_ADJUST_YIELD_CHANGE',		'RS_'||GodhoodType||'_THRESHOLD_2'
	from GodHood where (ghClass in ('IMPROVEMENT',	'FEATURE',	'TERRAIN', 'APPEAL'));

insert or ignore into ModifierArguments(ModifierId,	Name,	Value) select
	GodhoodType||'_CRAFTSMEN_DISTRICT_YIELD_PRODUCTION',		'Amount',	1
	from GodHood where (ghClass in ('IMPROVEMENT',	'FEATURE',	'TERRAIN', 'APPEAL'));

insert or ignore into ModifierArguments(ModifierId,	Name,	Value) select
	GodhoodType||'_CRAFTSMEN_DISTRICT_YIELD_PRODUCTION',		'YieldType',	'YIELD_PRODUCTION'
	from GodHood where (ghClass in ('IMPROVEMENT',	'FEATURE',	'TERRAIN', 'APPEAL'));

--工匠之神 + 大地女神
insert or ignore into PantheonModifiers(GodhoodType,	PowerType, ModifierId) values
	('EARTH_GODDESS',	'GOD_OF_CRAFTSMEN',		'EARTH_GODDESS_GOD_OF_CRAFTSMEN_PLOT_YIELD_PRODUCTION');

insert or ignore into Modifiers(ModifierId,	ModifierType, SubjectRequirementSetId) values
	('EARTH_GODDESS_GOD_OF_CRAFTSMEN_PLOT_YIELD_PRODUCTION',	'MODIFIER_PLAYER_ADJUST_PLOT_YIELD',		'RS_EARTH_GODDESS_THRESHOLD_2');

insert or ignore into ModifierArguments(ModifierId,	Name,	Value) values
	('EARTH_GODDESS_GOD_OF_CRAFTSMEN_PLOT_YIELD_PRODUCTION',	'Amount',			1),
	('EARTH_GODDESS_GOD_OF_CRAFTSMEN_PLOT_YIELD_PRODUCTION',	'YieldType',		'YIELD_PRODUCTION');

--原丰产仪式单元格产出

insert or ignore into PantheonModifiers(GodhoodType,	PowerType, ModifierId) select
	GodhoodType,	'FERTILITY_RITES',	GodhoodType||'_FERTILITY_RITES_PLOT_YIELD_FOOD'
	from Godhood where ghClass in ('IMPROVEMENT',	'FEATURE',	'TERRAIN');

insert or ignore into Modifiers(ModifierId,	ModifierType, SubjectRequirementSetId) select
	GodhoodType||'_FERTILITY_RITES_PLOT_YIELD_FOOD',		'MODIFIER_PLAYER_ADJUST_PLOT_YIELD',		'RS_'||GodhoodType||'_THRESHOLD_PLOT_TAG_MATCHES'
	from Godhood where ghClass in ('IMPROVEMENT',	'FEATURE',	'TERRAIN');

insert or ignore into ModifierArguments(ModifierId,	Name,	Value) select
	GodhoodType||'_FERTILITY_RITES_PLOT_YIELD_FOOD',		'Amount',	ghParam3
	from Godhood where ghClass in ('IMPROVEMENT',	'FEATURE',	'TERRAIN');

insert or ignore into ModifierArguments(ModifierId,	Name,	Value) select
	GodhoodType||'_FERTILITY_RITES_PLOT_YIELD_FOOD',		'YieldType',	'YIELD_FAITH'
	from Godhood where ghClass in ('IMPROVEMENT',	'FEATURE',	'TERRAIN');

--丰产仪式单元格req
insert or ignore into RequirementSets(RequirementSetId, RequirementSetType) select
	'RS_'||GodhoodType||'_THRESHOLD_PLOT_TAG_MATCHES',		'REQUIREMENTSET_TEST_ALL'
	from Godhood where ghClass in ('IMPROVEMENT',	'FEATURE',	'TERRAIN');

insert or ignore into RequirementSetRequirements(RequirementSetId, RequirementId) select
	'RS_'||GodhoodType||'_THRESHOLD_PLOT_TAG_MATCHES',		'REQ_'||GodhoodType||'_TAG_MATCHES'
	from Godhood where ghClass in ('IMPROVEMENT',	'FEATURE',	'TERRAIN');

--大地女神+丰产仪式
insert or ignore into PantheonModifiers(GodhoodType,	PowerType, ModifierId) select
	'EARTH_GODDESS',	'FERTILITY_RITES',	'EARTH_GODDESS_FERTILITY_RITES_PLOT_YIELD_FOOD_'||numbers
	from counter where numbers > 0 and numbers < 11;

insert or ignore into Modifiers(ModifierId,	ModifierType, SubjectRequirementSetId) select  -- rs来自rs.sql
	'EARTH_GODDESS_FERTILITY_RITES_PLOT_YIELD_FOOD_'||numbers,		'MODIFIER_PLAYER_ADJUST_PLOT_YIELD',		'RS_PLOT_APPEAL_AT_LEAST_' || (numbers * 2)
	from counter where numbers > 0 and numbers < 11;

insert or ignore into ModifierArguments(ModifierId,	Name,	Value) select
	'EARTH_GODDESS_FERTILITY_RITES_PLOT_YIELD_FOOD_'||numbers,		'Amount',	1
	from counter where numbers > 0 and numbers < 11;

insert or ignore into ModifierArguments(ModifierId,	Name,	Value) select
	'EARTH_GODDESS_FERTILITY_RITES_PLOT_YIELD_FOOD_'||numbers,		'YieldType',	'YIELD_FAITH'
	from counter where numbers > 0 and numbers < 11;






-- 改良相邻ModifierType

insert or ignore into Types (Type, Kind) VALUES 
('MODIFIER_PLAYER_CITIES_IMPROVEMENT_ADJACENCY', 'KIND_MODIFIER');

insert or ignore into DynamicModifiers (ModifierType, CollectionType, EffectType) VALUES 
('MODIFIER_PLAYER_CITIES_IMPROVEMENT_ADJACENCY', 'COLLECTION_PLAYER_CITIES', 'EFFECT_IMPROVEMENT_ADJACENCY');

--封禅 + 美神
insert or ignore into PantheonModifiers(GodhoodType,	PowerType, ModifierId) select
	'GOD_OF_BEAUTY',	'INITIATION_RITES',	'GOD_OF_BEAUTY_INITIATION_RITES_'||numbers
	from counter where numbers > 0 and numbers < 10;

insert or ignore into Modifiers(ModifierId,	ModifierType) select
	'GOD_OF_BEAUTY_INITIATION_RITES_'||numbers,		'MODIFIER_PLAYER_DISTRICTS_ADJUST_YIELD_BASED_ON_APPEAL'		
	from counter where numbers > 0 and numbers < 10;

insert or ignore into ModifierArguments(ModifierId,	Name,	Value) select
	'GOD_OF_BEAUTY_INITIATION_RITES_'||numbers,		'YieldType',	'YIELD_FAITH'
	from counter where numbers > 0 and numbers < 10;

insert or ignore into ModifierArguments(ModifierId,	Name,	Value) select
	'GOD_OF_BEAUTY_INITIATION_RITES_'||numbers,		'Description',	'LOC_INITIATION_RITES'
	from counter where numbers > 0 and numbers < 10;

insert or ignore into ModifierArguments(ModifierId,	Name,	Value) select
	'GOD_OF_BEAUTY_INITIATION_RITES_'||numbers,		'DistrictType',	'DISTRICT_HOLY_SITE'
	from counter where numbers > 0 and numbers < 10;

insert or ignore into ModifierArguments(ModifierId,	Name,	Value) select
	'GOD_OF_BEAUTY_INITIATION_RITES_'||numbers,		'RequiredAppeal',	numbers
	from counter where numbers > 0 and numbers < 10;

insert or ignore into ModifierArguments(ModifierId,	Name,	Value) select
	'GOD_OF_BEAUTY_INITIATION_RITES_'||numbers,		'YieldChange',	1
	from counter where numbers > 0 and numbers < 10;

--封禅原启蒙会改良
insert or ignore into PantheonModifiers(GodhoodType,	PowerType, ModifierId) select
	GodhoodType,	'INITIATION_RITES',	GodhoodType||'_INITIATION_RITES_'||ghParam1
	from Godhood where ghClass='IMPROVEMENT';

insert or ignore into Modifiers(ModifierId,	ModifierType) select
	GodhoodType||'_INITIATION_RITES_'||ghParam1,		'MODIFIER_PLAYER_CITIES_IMPROVEMENT_ADJACENCY'	
	from Godhood where ghClass='IMPROVEMENT';

insert or ignore into ModifierArguments(ModifierId,	Name,	Value) select
	GodhoodType||'_INITIATION_RITES_'||ghParam1,		'DistrictType',	'DISTRICT_HOLY_SITE'
	from Godhood where ghClass='IMPROVEMENT';

insert or ignore into ModifierArguments(ModifierId,	Name,	Value) select
	GodhoodType||'_INITIATION_RITES_'||ghParam1,		'YieldType',	'YIELD_FAITH'
	from Godhood where ghClass='IMPROVEMENT';

insert or ignore into ModifierArguments(ModifierId,	Name,	Value) select
	GodhoodType||'_INITIATION_RITES_'||ghParam1,		'Amount',	ghParam3
	from Godhood where ghClass='IMPROVEMENT';

insert or ignore into ModifierArguments(ModifierId,	Name,	Value) select
	GodhoodType||'_INITIATION_RITES_'||ghParam1,		'TilesRequired',	1
	from Godhood where ghClass='IMPROVEMENT';

insert or ignore into ModifierArguments(ModifierId,	Name,	Value) select
	GodhoodType||'_INITIATION_RITES_'||ghParam1,		'Description',	'LOC_INITIATION_RITES'
	from Godhood where ghClass='IMPROVEMENT';

insert or ignore into ModifierArguments(ModifierId,	Name,	Value) select
	GodhoodType||'_INITIATION_RITES_'||ghParam1,		'ImprovementType',	ghParam1
	from Godhood where ghClass='IMPROVEMENT';

--封禅原启蒙会地貌
insert or ignore into PantheonModifiers(GodhoodType,	PowerType, ModifierId) select
	GodhoodType,	'INITIATION_RITES',	GodhoodType||'_INITIATION_RITES_'||ghParam1
	from Godhood where ghClass='FEATURE';

insert or ignore into Modifiers(ModifierId,	ModifierType) select
	GodhoodType||'_INITIATION_RITES_'||ghParam1,		'MODIFIER_PLAYER_CITIES_FEATURE_ADJACENCY'	
	from Godhood where ghClass='FEATURE';

insert or ignore into ModifierArguments(ModifierId,	Name,	Value) select
	GodhoodType||'_INITIATION_RITES_'||ghParam1,		'DistrictType',	'DISTRICT_HOLY_SITE'
	from Godhood where ghClass='FEATURE';

insert or ignore into ModifierArguments(ModifierId,	Name,	Value) select
	GodhoodType||'_INITIATION_RITES_'||ghParam1,		'YieldType',	'YIELD_FAITH'
	from Godhood where ghClass='FEATURE';

insert or ignore into ModifierArguments(ModifierId,	Name,	Value) select
	GodhoodType||'_INITIATION_RITES_'||ghParam1,		'Amount',	ghParam2
	from Godhood where ghClass='FEATURE';

insert or ignore into ModifierArguments(ModifierId,	Name,	Value) select
	GodhoodType||'_INITIATION_RITES_'||ghParam1,		'TilesRequired',	1
	from Godhood where ghClass='FEATURE';

insert or ignore into ModifierArguments(ModifierId,	Name,	Value) select
	GodhoodType||'_INITIATION_RITES_'||ghParam1,		'Description',	'LOC_INITIATION_RITES'
	from Godhood where ghClass='FEATURE';

insert or ignore into ModifierArguments(ModifierId,	Name,	Value) select
	GodhoodType||'_INITIATION_RITES_'||ghParam1,		'FeatureType',	ghParam1
	from Godhood where ghClass='FEATURE';

--封禅原启蒙会地形
insert or ignore into PantheonModifiers(GodhoodType,	PowerType, ModifierId) select
	GodhoodType,	'INITIATION_RITES',	GodhoodType||'_INITIATION_RITES_'||ghParam1
	from Godhood where ghClass='TERRAIN';

insert or ignore into Modifiers(ModifierId,	ModifierType) select
	GodhoodType||'_INITIATION_RITES_'||ghParam1,		'MODIFIER_PLAYER_CITIES_TERRAIN_ADJACENCY'		
	from Godhood where ghClass='TERRAIN';

insert or ignore into ModifierArguments(ModifierId,	Name,	Value) select
	GodhoodType||'_INITIATION_RITES_'||ghParam1,		'DistrictType',	'DISTRICT_HOLY_SITE'
	from Godhood where ghClass='TERRAIN';

insert or ignore into ModifierArguments(ModifierId,	Name,	Value) select
	GodhoodType||'_INITIATION_RITES_'||ghParam1,		'YieldType',	'YIELD_FAITH'
	from Godhood where ghClass='TERRAIN';

insert or ignore into ModifierArguments(ModifierId,	Name,	Value) select
	GodhoodType||'_INITIATION_RITES_'||ghParam1,		'Amount',	ghParam2
	from Godhood where ghClass='TERRAIN';

insert or ignore into ModifierArguments(ModifierId,	Name,	Value) select
	GodhoodType||'_INITIATION_RITES_'||ghParam1,		'TilesRequired',	1
	from Godhood where ghClass='TERRAIN';

insert or ignore into ModifierArguments(ModifierId,	Name,	Value) select
	GodhoodType||'_INITIATION_RITES_'||ghParam1,		'Description',	'LOC_INITIATION_RITES'
	from Godhood where ghClass='TERRAIN';

insert or ignore into ModifierArguments(ModifierId,	Name,	Value) select
	GodhoodType||'_INITIATION_RITES_'||ghParam1,		'TerrainType',	ghParam1
	from Godhood where ghClass='TERRAIN';

--封禅 + 大地女神
insert or ignore into PantheonModifiers(GodhoodType,	PowerType, ModifierId) select
	'EARTH_GODDESS',	'INITIATION_RITES',	'EARTH_GODDESS_INITIATION_RITES_'||numbers
	from counter where numbers > 0 and numbers < 10;

insert or ignore into Modifiers(ModifierId,	ModifierType) select
	'EARTH_GODDESS_INITIATION_RITES_'||numbers,		'MODIFIER_PLAYER_DISTRICTS_ADJUST_YIELD_BASED_ON_APPEAL'		
	from counter where numbers > 0 and numbers < 10;

insert or ignore into ModifierArguments(ModifierId,	Name,	Value) select
	'EARTH_GODDESS_INITIATION_RITES_'||numbers,		'YieldType',	'YIELD_FAITH'
	from counter where numbers > 0 and numbers < 10;

insert or ignore into ModifierArguments(ModifierId,	Name,	Value) select
	'EARTH_GODDESS_INITIATION_RITES_'||numbers,		'Description',	'LOC_INITIATION_RITES'
	from counter where numbers > 0 and numbers < 10;

insert or ignore into ModifierArguments(ModifierId,	Name,	Value) select
	'EARTH_GODDESS_INITIATION_RITES_'||numbers,		'DistrictType',	'DISTRICT_HOLY_SITE'
	from counter where numbers > 0 and numbers < 10;

insert or ignore into ModifierArguments(ModifierId,	Name,	Value) select
	'EARTH_GODDESS_INITIATION_RITES_'||numbers,		'RequiredAppeal',	numbers * 2
	from counter where numbers > 0 and numbers < 10;

insert or ignore into ModifierArguments(ModifierId,	Name,	Value) select
	'EARTH_GODDESS_INITIATION_RITES_'||numbers,		'YieldChange',	1
	from counter where numbers > 0 and numbers < 10;

-- 封禅原启蒙会ModifierType

insert or ignore into Types (Type, Kind) VALUES 
('MODIFIER_PLAYER_DISTRICTS_ADJUST_BASE_YIELD_CHANGE', 'KIND_MODIFIER');

insert or ignore into DynamicModifiers (ModifierType, CollectionType, EffectType) VALUES 
('MODIFIER_PLAYER_DISTRICTS_ADJUST_BASE_YIELD_CHANGE', 'COLLECTION_PLAYER_DISTRICTS', 'EFFECT_ADJUST_DISTRICT_BASE_YIELD_CHANGE');

--封禅原启蒙会建立于地貌--哼哼啊啊啊啊啊啊啊啊啊啊啊啊啊啊啊啊啊啊啊啊啊啊啊啊啊--
--和地形
insert or ignore into PantheonModifiers(GodhoodType,	PowerType, ModifierId) select
	GodhoodType,	'INITIATION_RITES',	GodhoodType||'_INITIATION_RITES_BONUS'
	from Godhood where ghClass in ('FEATURE',	'TERRAIN');

insert or ignore into Modifiers(ModifierId,	ModifierType, SubjectRequirementSetId) select
	GodhoodType||'_INITIATION_RITES_BONUS',		'MODIFIER_PLAYER_DISTRICTS_ADJUST_BASE_YIELD_CHANGE',		'RS_'||GodhoodType||'_INITIATION_RITES_BONUS_'||ghParam1
	from Godhood where ghClass in ('FEATURE',	'TERRAIN');

insert or ignore into ModifierArguments(ModifierId,	Name,	Value) select
	GodhoodType||'_INITIATION_RITES_BONUS',		'YieldType',	'YIELD_FAITH'
	from Godhood where ghClass in ('FEATURE',	'TERRAIN');

insert or ignore into ModifierArguments(ModifierId,	Name,	Value) select
	GodhoodType||'_INITIATION_RITES_BONUS',		'Amount',	ghParam2
	from Godhood where ghClass in ('FEATURE',	'TERRAIN');

--封禅原启蒙会rs
    insert or ignore into RequirementSets(RequirementSetId, RequirementSetType) select
	'RS_'||GodhoodType||'_INITIATION_RITES_BONUS_'||ghParam1,		'REQUIREMENTSET_TEST_ALL'
	from Godhood where ghClass in ('FEATURE',	'TERRAIN');

    insert or ignore into RequirementSetRequirements(RequirementSetId, RequirementId) select
	'RS_'||GodhoodType||'_INITIATION_RITES_BONUS_'||ghParam1,		'REQ_PLOT_HAS_DISTRICT_HOLY_SITE'
	from Godhood where ghClass in ('FEATURE',	'TERRAIN');

	insert or ignore into RequirementSetRequirements(RequirementSetId, RequirementId) select
	'RS_'||GodhoodType||'_INITIATION_RITES_BONUS_'||ghParam1,		'REQ_'||GodhoodType||'_TAG_MATCHES'
	from Godhood where ghClass in ('FEATURE',	'TERRAIN');

--




--愈合之神

/*
insert or ignore into PantheonModifiers(GodhoodType,	PowerType, ModifierId) select
	GodhoodType,	'AESCULAPIUS',	GodhoodType||'_AESCULAPIUS_HEAL'
	from Godhood where ghClass in ('IMPROVEMENT',	'FEATURE',	'TERRAIN', 'APPEAL');

insert or ignore into Modifiers(ModifierId,	ModifierType, SubjectRequirementSetId) select
	GodhoodType||'_AESCULAPIUS_HEAL',		'MODIFIER_PLAYER_UNITS_ADJUST_HEAL_PER_TURN',		'RS_'||GodhoodType||'_AESCULAPIUS_HEAL'
	from Godhood where ghClass in ('IMPROVEMENT',	'FEATURE',	'TERRAIN', 'APPEAL');

insert or ignore into ModifierArguments(ModifierId,	Name,	Value) select
	GodhoodType||'_AESCULAPIUS_HEAL',		'Amount',	30
	from Godhood where ghClass in ('IMPROVEMENT',	'FEATURE',	'TERRAIN', 'APPEAL');

insert or ignore into ModifierArguments(ModifierId,	Name,	Value) select
	GodhoodType||'_AESCULAPIUS_HEAL',		'Type',	'ALL'
	from Godhood where ghClass in ('IMPROVEMENT',	'FEATURE',	'TERRAIN', 'APPEAL');
*/






/*
--文本
create table 'PantheonTexts'(
	'PowerType' TEXT NOT NULL,
	'GodhoodType' TEXT NOT NULL,
	'Language' TEXT NOT NULL,
	'Texts' TEXT NOT NULL,
	PRIMARY KEY('GodhoodType', 'PowerType', 'Texts')
);

insert or ignore into PantheonTexts	 (Language,      GodhoodType,      PowerType,                                                       Texts) select
	'zh_Hans_CN',		GodhoodType,	PowerType,			'LOC_'||GodhoodType||'_'||PowerType||'_'||pwParam1
	from Godhood, Power, ThresholdCounter where ghClass in ('IMPROVEMENT',	'FEATURE',	'TERRAIN') and pwClass in ('DISTRICT', 'CITY')
	and pwParam1 in ('THRESHOLD1', 'THRESHOLD2') and ghParam3 = Delta and pwParam2 = Threshold;

insert or ignore into PantheonTexts	 (Language,      GodhoodType,      PowerType,                                                       Texts) select
	'zh_Hans_CN',		GodhoodType,	PowerType,			'LOC_'||GodhoodType||'_'||PowerType||'_'||pwParam1
	from Godhood, Power where ghClass in ('IMPROVEMENT',	'FEATURE',	'TERRAIN') and pwClass = 'YIELD'
	 and ghParam3 >= pwParam2;

insert or ignore into PantheonTexts	 (Language,      GodhoodType,      PowerType,                                                       Texts) select
	'zh_Hans_CN',		GodhoodType,	PowerType,			'LOC_'||GodhoodType||'_'||PowerType||'_'||pwParam1
	from Godhood, Power where ghClass = 'APPEAL' and pwClass in ('DISTRICT', 'CITY', 'YIELD');

*/


--奇迹之神 神力为6的区域获得1级建筑 'RS_'||GodhoodType||'_THRESHOLD_7'

-- Custom ModifierType

insert or ignore into Types (Type, Kind) VALUES 
('QGG_CP_MODIFIER_PLAYER_CITIES_GRANT_BUILDING_IN_CITY', 'KIND_MODIFIER');

insert or ignore into DynamicModifiers (ModifierType, CollectionType, EffectType) VALUES 
('QGG_CP_MODIFIER_PLAYER_CITIES_GRANT_BUILDING_IN_CITY', 'COLLECTION_PLAYER_DISTRICTS', 'EFFECT_GRANT_BUILDING_IN_CITY');

insert or ignore into RequirementSets(RequirementSetId, RequirementSetType)
select
    'RS_' || A.GodhoodType || '_THRESHOLD_6_' || D.DistrictType, 
    'REQUIREMENTSET_TEST_ALL'
from 
    Godhood A,
    Districts D
where 
    A.ghClass in ('IMPROVEMENT', 'FEATURE', 'TERRAIN', 'APPEAL')
    and D.TraitType is NULL;


insert or ignore into RequirementSetRequirements(RequirementSetId, RequirementId)
select
    'RS_' || A.GodhoodType || '_THRESHOLD_6_' || D.DistrictType,
    'REQ_' || A.GodhoodType || '_THRESHOLD_6'
from 
    Godhood A,
    Districts D
where 
    A.ghClass in ('IMPROVEMENT', 'FEATURE', 'TERRAIN', 'APPEAL')
    and D.TraitType is NULL;


insert or ignore into RequirementSetRequirements(RequirementSetId, RequirementId)
select
    'RS_' || A.GodhoodType || '_THRESHOLD_6_' || D.DistrictType,
    'REQ_PLOT_HAS_' || D.DistrictType
from 
    Godhood A,
    Districts D
where 
    A.ghClass in ('IMPROVEMENT', 'FEATURE', 'TERRAIN', 'APPEAL')
    and D.TraitType is NULL;



insert or ignore into PantheonModifiers(GodhoodType, PowerType, ModifierId) 
select
    A.GodhoodType, 'GOD_OF_MIRACLES', A.GodhoodType || '_GOD_OF_MIRACLES_' || B.BuildingType || '_' || D.DistrictType
from 
    Godhood A
join 
    Buildings B on B.InternalOnly != 1
    and B.MustPurchase != 1
    and B.PrereqDistrict is not NULL
join 
    Districts D on B.PrereqDistrict = D.DistrictType
    and D.TraitType is NULL
where 
    A.ghClass in ('IMPROVEMENT', 'FEATURE', 'TERRAIN', 'APPEAL')
    and B.BuildingType not in (
        select Building 
        from BuildingPrereqs
        where B.BuildingType = Building
    );






insert or ignore into Modifiers(ModifierId, ModifierType, SubjectRequirementSetId, RunOnce, Permanent) 
select
    A.GodhoodType || '_GOD_OF_MIRACLES_' || B.BuildingType || '_' || D.DistrictType,
    'QGG_CP_MODIFIER_PLAYER_CITIES_GRANT_BUILDING_IN_CITY',
    'RS_' || A.GodhoodType || '_THRESHOLD_6_' || D.DistrictType,
    0, 
    1
from 
    Godhood A
join 
    Buildings B on B.InternalOnly != 1
    and B.MustPurchase != 1
    and B.PrereqDistrict is not NULL
join 
    Districts D on B.PrereqDistrict = D.DistrictType
    and D.TraitType is NULL
where 
    A.ghClass in ('IMPROVEMENT', 'FEATURE', 'TERRAIN', 'APPEAL')
    and B.BuildingType not in (
        select Building 
        from BuildingPrereqs
        where B.BuildingType = Building
    );




insert or ignore into ModifierArguments(ModifierId, Name, Value)
select
    A.GodhoodType || '_GOD_OF_MIRACLES_' || B.BuildingType || '_' || D.DistrictType,
    'BuildingType',  
    BuildingType          
from 
    Godhood A
join 
    Buildings B on B.InternalOnly != 1
    and B.MustPurchase != 1
    and B.PrereqDistrict is not NULL
join 
    Districts D on B.PrereqDistrict = D.DistrictType
    and D.TraitType is NULL
where 
    A.ghClass in ('IMPROVEMENT', 'FEATURE', 'TERRAIN', 'APPEAL')
    and B.BuildingType not in (
        select Building 
        from BuildingPrereqs
        where B.BuildingType = Building
    );

-- =============================================================================
-- Apply path: Player:AttachModifierByID (original Create Pantheon).
-- BeliefModifiers alone do NOT correctly evaluate devotion-threshold SubjectReqs
-- for these custom modifiers (confirmed in-game: SEA+DIVINE_SPARK rows=30 but
-- Holy Site GPP stayed at base 1 with adjacent fishing boats).
-- =============================================================================
delete from BeliefModifiers
where BeliefType like 'BELIEF_%_WITH_%';

-- =============================================================================
-- Engine pantheon pool must be empty: otherwise AI turn auto-founds Aurora combos
-- before CP_AI (TurnBegin is too late; even PlayerTurnActivated can race yields).
-- Domain/power rows stay in custom Pantheons table for the chooser UI.
-- BeliefClasses has no Types FK — class string is enough.
-- =============================================================================
insert or ignore into BeliefClasses
	(BeliefClassType, Name, MaxInReligion, AdoptionOrder)
values
	('BELIEF_CLASS_CP_DISABLED', 'LOC_BELIEF_CLASS_PANTHEON_NAME', 0, 99),
	('BELIEF_CLASS_CP_COMBO', 'LOC_BELIEF_CLASS_PANTHEON_NAME', 1, 1);

-- Sole (non-combo) pantheon rows: not choosable by engine/AI.
update Beliefs
set BeliefClassType = 'BELIEF_CLASS_CP_DISABLED'
where BeliefClassType = 'BELIEF_CLASS_PANTHEON'
  and BeliefType not like '%_WITH_%';

-- Combo rows: Lua-only founding (CP_AI + human chooser GameEvents).
update Beliefs
set BeliefClassType = 'BELIEF_CLASS_CP_COMBO'
where BeliefType like 'BELIEF_%_WITH_%';

