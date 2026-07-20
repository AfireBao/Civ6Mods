

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

create table "counter_m" (
'numbers' INTEGER NOT NULL,
PRIMARY KEY(numbers)
);

WITH RECURSIVE
  Indices(i) AS (SELECT 0 UNION ALL SELECT (i + 1) FROM Indices LIMIT 8)
  insert into counter_m(numbers) select i from Indices;

create table 'ThresholdCounter'(
	'Delta' INT NOT NULL,
	'Threshold' INT NOT NULL,
	'MultiNumber' INT,
	PRIMARY KEY('Delta',	'Threshold')
);

insert or ignore into ThresholdCounter(Delta,	Threshold, MultiNumber) select
	a.numbers, b.numbers, ((b.numbers - 1)/a.numbers + 1)
	from counter_m a,	counter_m b;

create table 'PantheonTexts'(
	'PowerType' TEXT NOT NULL,
	'GodhoodType' TEXT NOT NULL,
	'Language' TEXT NOT NULL,
	'Texts' TEXT NOT NULL,
	PRIMARY KEY('GodhoodType', 'PowerType', 'Texts', 'Language')
);

insert or ignore into Godhood(GodhoodType,		ghClass,		ghParam1,		ghParam2,	ghParam3,	ghParam4) values
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


insert or ignore into LocalizedText    (Language,      Tag,                                                             Text) values
	('en_US',		'LOC_CHOOSE_DOMAIN',						'Choose the Domain of Pantheon'),
	('en_US',		'LOC_CHOOSE_POWER',							'Choose the Power of Pantheon'),
	('en_US',		'LOC_CREATE_YOUR_PANTHEON',					'Create Your Pantheon'),
	('en_US',		'LOC_PANTHEON_CHOSEN',						'[COLOR_RED]This pantheon has been chosen by anouther player.[ENDCOLOR]'),
	('en_US',		'LOC_CREATE_THIS_PANTHEON',					'Found this Pantheon'),

	('en_US',		'LOC_BELIEF_GGV_NAME',						'Wenquxing'),
	('en_US',		'LOC_BELIEF_SHENNONG_NAME',					'Shennong'),
	('en_US',		'LOC_BELIEF_GOD_OF_WINE_NAME',				'God of Wine'),
	('en_US',		'LOC_BELIEF_GOD_OF_BEAUTY_NAME',			'God of Beauty'),
	('en_US',		'LOC_BELIEF_GOD_OF_MIRACLES_NAME',			'God of Miracle'),
	('en_US',		'LOC_BELIEF_GGV_DESCRIPTION',				'+1 [ICON_Culture] Culture to districts and tiles with at least 2 [ICON_Religion] Devotion.'),
	('en_US',		'LOC_BELIEF_SHENNONG_DESCRIPTION',			'+1 [ICON_Food] Food to districts and tiles with at least 2 [ICON_Religion] Devotion.'),
	('en_US',		'LOC_BELIEF_GOD_OF_WINE_DESCRIPTION',		'+1 [ICON_Amenities] Amenity to districts with at least 3 [ICON_Religion] Devotion; +1 additional [ICON_Amenities] Amenity to districts with at least 5 [ICON_Religion] Devotion.'),
	('en_US',		'LOC_INITIATION_RITES',						'+{1_num} [ICON_FAITH] Faith from Pantheon effects.'),
	('en_US',		'LOC_BELIEF_GOD_OF_MIRACLES_DESCRIPTION',	'Grant tier 1 buildings to all districts with at least 6 [ICON_Religion] Devotion.'),
	('en_US',		'LOC_STONE_CIRCLES_POINTS',					'Quarries'),
	('en_US',		'LOC_DESERT_FOLKLORE_POINTS',				'Desert, Desert Hills and Desert Mountains'),
	('en_US',		'LOC_GOD_OF_THE_SEA_POINTS',				'Fishing Boats'),
	('en_US',		'LOC_GODDESS_OF_FIRE_POINTS',				'Geothermal Fissures and Volcanic Soil.'),
	('en_US',		'LOC_DANCE_OF_THE_AURORA_POINTS',			'Tundra, Tundra Hills and Tundra Mountains'),
	('en_US',		'LOC_GODDESS_OF_FESTIVALS_POINTS',			'Plantations'),
	('en_US',		'LOC_LADY_OF_THE_REEDS_AND_MARSHES_POINTS',	'Marsh, Oasis and Desert Floodplains'),
	('en_US',		'LOC_SACRED_PATH_POINTS',					'Rainforest'),
	('en_US',		'LOC_ORAL_TRADITION_POINTS',				'Woods'),
	('en_US',		'LOC_GOD_OF_THE_OPEN_SKY_POINTS',			'Pastures'),
	('en_US',		'LOC_RELIGIOUS_IDOLS_POINTS',				'Mines'),
	('en_US',		'LOC_GODDESS_OF_THE_HUNT_POINTS',			'Camps'),

	--('en_US',		'LOC_INITIATION_RITES_DIS_EFFECT',			''),
	('en_US',		'LOC_GOD_OF_CRAFTSMEN_DIS_EFFECT',			'+1 [ICON_Production] Production'),	
	('en_US',		'LOC_SHENNONG_DIS_EFFECT',					'+1 [ICON_FOOD] Food'),
	('en_US',		'LOC_GGV_DIS_EFFECT',						'+1 [ICON_CULTURE] Culture'),
	('en_US',		'LOC_DIVINE_SPARK_DIS_EFFECT',				'+1 corresponding [ICON_GreatPerson] Great Person point'),
	('en_US',		'LOC_DIVINE_SPARK_DIS_EFFECT_T2',			'+2 additional corresponding [ICON_GreatPerson] Great Person points'),
	('en_US',		'LOC_RELIGIOUS_SETTLEMENTS_DIS_EFFECT',		'+1 [ICON_Housing] Housing'),
	('en_US',		'LOC_GOD_OF_WINE_DIS_EFFECT',				'+1 [ICON_Amenities] Amenity'),
	('en_US',		'LOC_CITY_PATRON_GODDESS_DIS_EFFECT',		'may construct one more district than usual if there is at least one specialty district'),
	('en_US',		'LOC_MONUMENT_TO_THE_GODS_DIS_EFFECT',		'+25% [ICON_Production] Production toward Ancient and Classical wonders');



--三类+区域
-- Divine Spark tier2 uses +2 (not the shared +1 DIS_EFFECT).
insert or ignore into PantheonTexts    (Language,      GodhoodType,	PowerType,		Texts) select
			'en_US',		GodhoodType,	PowerType,
			'Districts with at least '||MultiNumber||' adjacent '||'{LOC_'||GodhoodType||'_POINTS} receive '||
			case when PowerType = 'DIVINE_SPARK' and pwParam1 = 'THRESHOLD2'
				then '{LOC_DIVINE_SPARK_DIS_EFFECT_T2}'
				else '{LOC_'||PowerType||'_DIS_EFFECT}'
			end||'.'
	from Godhood, Power, ThresholdCounter where ghClass in ('IMPROVEMENT',	'FEATURE',	'TERRAIN') and pwClass = 'DISTRICT'
	and pwParam1 in ('THRESHOLD1', 'THRESHOLD2') and ghParam2 = Delta and pwParam2 = Threshold;
--三类+城市
insert or ignore into PantheonTexts    (Language,      GodhoodType,	PowerType,		Texts) select
			'en_US',		GodhoodType,	PowerType,
			'Cities whose City Center has at least '||MultiNumber||' adjacent '||'{LOC_'||GodhoodType||'_POINTS} receive '||
			case when PowerType = 'DIVINE_SPARK' and pwParam1 = 'THRESHOLD2'
				then '{LOC_DIVINE_SPARK_DIS_EFFECT_T2}'
				else '{LOC_'||PowerType||'_DIS_EFFECT}'
			end||'.'
	from Godhood, Power, ThresholdCounter where ghClass in ('IMPROVEMENT',	'FEATURE',	'TERRAIN') and pwClass = 'CITY'
	and pwParam1 in ('THRESHOLD1', 'THRESHOLD2') and ghParam2 = Delta and pwParam2 = Threshold;
--三类+封禅
insert or ignore into PantheonTexts    (Language,      GodhoodType,	PowerType,		Texts) select
			'en_US',		GodhoodType,	'INITIATION_RITES',	'Each {LOC_'||GodhoodType||'_POINTS} within 1 tile of a Holy Site provide +'||ghParam2||' [ICON_FAITH] Faith adjacency bonus.'
	from Godhood where ghClass in ('IMPROVEMENT',	'FEATURE',	'TERRAIN');
--三类+丰产仪式
insert or ignore into PantheonTexts    (Language,      GodhoodType,	PowerType,		Texts) select
			'en_US',		GodhoodType,	'FERTILITY_RITES',	'Tiles of {LOC_'||GodhoodType||'_POINTS} receive +'||ghParam3||' [ICON_FAITH] Faith.'
	from Godhood where ghClass in ('IMPROVEMENT',	'FEATURE',	'TERRAIN');
--三类+神农/文曲星/工匠之神
insert or ignore into PantheonTexts    (Language,      GodhoodType,	PowerType,		Texts) select
			'en_US',		GodhoodType,	PowerType,	'Tiles with {LOC_'||GodhoodType||'_POINTS} receive '||'{LOC_'||PowerType||'_DIS_EFFECT}.'
	from Godhood, Power where ghClass in ('IMPROVEMENT',	'FEATURE',	'TERRAIN') and pwClass = 'YIELD'
	 and ghParam3 >= pwParam2;


--大地女神+区域
insert or ignore into PantheonTexts    (Language,      GodhoodType,	PowerType,		Texts) select
			'en_US',		'EARTH_GODDESS',	PowerType,
			'Districts with at least '||(pwParam2 * 2)||' Appeal receive '||
			case when PowerType = 'DIVINE_SPARK' and pwParam1 = 'THRESHOLD2'
				then '{LOC_DIVINE_SPARK_DIS_EFFECT_T2}'
				else '{LOC_'||PowerType||'_DIS_EFFECT}'
			end||'.'
	from  Power where  pwClass = 'DISTRICT'
	and pwParam1 in ('THRESHOLD1', 'THRESHOLD2');
--大地女神+城市
insert or ignore into PantheonTexts    (Language,      GodhoodType,	PowerType,		Texts) select
			'en_US',		'EARTH_GODDESS',	PowerType,
			'City centers with at least '||(pwParam2 * 2)||' Appeal receive '||
			case when PowerType = 'DIVINE_SPARK' and pwParam1 = 'THRESHOLD2'
				then '{LOC_DIVINE_SPARK_DIS_EFFECT_T2}'
				else '{LOC_'||PowerType||'_DIS_EFFECT}'
			end||'.'
	from  Power where  pwClass = 'CITY'
	and pwParam1 in ('THRESHOLD1', 'THRESHOLD2');
--大地女神+封禅/丰产仪式
insert or ignore into PantheonTexts    (Language,      GodhoodType,	PowerType,		Texts) values
			('en_US',		'EARTH_GODDESS',	'INITIATION_RITES',		'Holy Sites receive +1 [ICON_FAITH] Faith adjacency bonus per 2 Appeal.'),
			('en_US',		'EARTH_GODDESS',	'FERTILITY_RITES',		'Tiles receive +1 [ICON_Faith] Faith per 2 Appeal.');
--大地女神+神农/文曲星
insert or ignore into PantheonTexts    (Language,      GodhoodType,	PowerType,		Texts) select
			'en_US',		'EARTH_GODDESS',	PowerType,	'Tiles with at least '||(pwParam2 * 2)||' Appeal receive {LOC_'||PowerType||'_DIS_EFFECT}。'
	from  Power where  pwClass = 'YIELD';


--美神+区域
insert or ignore into PantheonTexts    (Language,      GodhoodType,	PowerType,		Texts) select
			'en_US',		'GOD_OF_BEAUTY',	PowerType,
			'Districts with at least '||pwParam2||' Appeal receive '||
			case when PowerType = 'DIVINE_SPARK' and pwParam1 = 'THRESHOLD2'
				then '{LOC_DIVINE_SPARK_DIS_EFFECT_T2}'
				else '{LOC_'||PowerType||'_DIS_EFFECT}'
			end||'.'
	from  Power where  pwClass = 'DISTRICT'
	and pwParam1 in ('THRESHOLD1', 'THRESHOLD2');
--美神+城市
insert or ignore into PantheonTexts    (Language,      GodhoodType,	PowerType,		Texts) select
			'en_US',		'GOD_OF_BEAUTY',	PowerType,
			'City centers with at least '||pwParam2||' Appeal receive '||
			case when PowerType = 'DIVINE_SPARK' and pwParam1 = 'THRESHOLD2'
				then '{LOC_DIVINE_SPARK_DIS_EFFECT_T2}'
				else '{LOC_'||PowerType||'_DIS_EFFECT}'
			end||'.'
	from  Power where  pwClass = 'CITY'
	and pwParam1 in ('THRESHOLD1', 'THRESHOLD2');

--美神+封禅
insert or ignore into PantheonTexts    (Language,      GodhoodType,	PowerType,		Texts) values
	('en_US',		'GOD_OF_BEAUTY',	'INITIATION_RITES',		'Holy Sites receive +1 [ICON_FAITH] Faith adjacency bonus per Appeal.');
--美神+丰产
insert or ignore into PantheonTexts    (Language,      GodhoodType,	PowerType,		Texts) values
	('en_US',		'GOD_OF_BEAUTY',	'FERTILITY_RITES',	'No effects.');

insert or ignore into LocalizedText    (Language,      Tag,                                                             Text) select
	'en_US',			'LOC_BELIEF_'||GodhoodType||'_WITH_'||PowerType||'_NAME',	'{LOC_BELIEF_'||GodhoodType||'_NAME}+{LOC_BELIEF_'||PowerType||'_NAME}'
	from Godhood, Power;



--insert or ignore into EnglishText	 (      Tag,                                                             Text) values
--	('LOC_ORAL_TRADITION_DIVINE_SPARK_THRESHOLD1',	'Districts with at least '||3||'ge'||'{LOC_DANCE_OF_THE_AURORA_POINTS}');


--单个万神
insert or replace into LocalizedText
    (Language,      Tag,                                                         Text)
values
    ("en_US",  "LOC_BELIEF_ORAL_TRADITION_NAME",                           		"Oral Tradition"),
    ("en_US",  "LOC_BELIEF_ORAL_TRADITION_DESCRIPTION",                 		"Woods provide +1 [ICON_Religion] Devotion to their tiles, and +1 [ICON_Religion] Devotion to adjacent districts."),
    ("en_US",  "LOC_BELIEF_SEA_GODDESSS_NAME",                   				"Ocean Goddess"),
    ("en_US",  "LOC_BELIEF_SEA_GODDESSS_DESCRIPTION",                      		"？？？？"),
    ("en_US",  "LOC_BELIEF_MOUNTAIN_GODDESS_NAME",                 				"Mountain Goddess"),
    ("en_US",  "LOC_BELIEF_MOUNTAIN_GODDESS_DESCRIPTION",          				"？？？？"),
    ("en_US",  "LOC_BELIEF_GODDESS_OF_THE_HARVEST_NAME",						"Goddess of Harvest"),
    ("en_US",  "LOC_BELIEF_GODDESS_OF_THE_HARVEST_DESCRIPTION",            		"？？？？"),
    ("en_US",  "LOC_BELIEF_GOD_OF_THE_FORGE_NAME",                     			"God of the Forge"),
    ("en_US",  "LOC_BELIEF_GOD_OF_THE_FORGE_DESCRIPTION",           			"？？？？"),
    ("en_US",  "LOC_BELIEF_CITY_PATRON_GODDESS_NAME",                     		"City Patron Goddess"),
    ("en_US",  "LOC_BELIEF_CITY_PATRON_GODDESS_DESCRIPTION",           			"City Centers with at least 4 [ICON_Religion] Devotion may construct one more district than usual if there is at least one specialty district."),
    ("en_US",  "LOC_BELIEF_DIVINE_SPARK_NAME",                     				"Divine Spark"),
    ("en_US",  "LOC_BELIEF_DIVINE_SPARK_DESCRIPTION",           				"Districts with at least 2 [ICON_Religion] Devotion receive +1 corresponding [ICON_GreatPerson] Great Person point; districts with at least 4 [ICON_Religion] Devotion receive an additional +2 corresponding [ICON_GreatPerson] Great Person points."),
    ("en_US",  "LOC_BELIEF_GOD_OF_WAR_NAME",                     				"God of War"),
    ("en_US",  "LOC_BELIEF_GOD_OF_WAR_DESCRIPTION",           					"？？？？"),
    ("en_US",  "LOC_BELIEF_MONUMENT_TO_THE_GODS_NAME",                     		"Monument to the Gods"),
    ("en_US",  "LOC_BELIEF_MONUMENT_TO_THE_GODS_DESCRIPTION",           		"City Centers with at least 4 [ICON_Religion] Devotion receive +25% [ICON_Production] Production towards Ancient and Classical wonders."),
    ("en_US",  "LOC_BELIEF_FERTILITY_RITES_NAME",                     			"Fertility Rites"),
    ("en_US",  "LOC_BELIEF_FERTILITY_RITES_DESCRIPTION",           				"Each [ICON_Religion] Devotion of the tile provides +1 [ICON_FAITH] Faith."),
    ("en_US",  "LOC_BELIEF_GOD_OF_CRAFTSMEN_NAME",                     			"God of Craftsmen"),
	("en_US",  "LOC_BELIEF_GOD_OF_CRAFTSMEN_DESCRIPTION",						"+1 [ICON_Production] Production to districts and tiles with at least 2 [ICON_Religion] Devotion."),
    -- ("en_US",  "LOC_BELIEF_GOD_OF_CRAFTSMEN_DESCRIPTION",           			"Improved strategic resources provide +3 [ICON_Religion] Devotion to their tiles, and +1 [ICON_Religion] Devotion to the City Center."),
    ("en_US",  "LOC_BELIEF_GOD_OF_THE_OPEN_SKY_NAME",                     		"God of the Open Sky"),
    ("en_US",  "LOC_BELIEF_GOD_OF_THE_OPEN_SKY_DESCRIPTION",           			"Pastures provide +3 [ICON_Religion] Devotion to their tiles, and +3 [ICON_Religion] Devotion to adjacent districts."),
    ("en_US",  "LOC_BELIEF_GOD_OF_THE_SEA_NAME",                     			"God of the Sea"),
    ("en_US",  "LOC_BELIEF_GOD_OF_THE_SEA_DESCRIPTION",           				"Fishing Boats provide +3 [ICON_Religion] Devotion to their tiles, and +3 [ICON_Religion] Devotion to adjacent districts."),
    ("en_US",  "LOC_BELIEF_STONE_CIRCLES_NAME",                     			"Stone Circles"),
    ("en_US",  "LOC_BELIEF_STONE_CIRCLES_DESCRIPTION",           				"Quarries provide +2 [ICON_Religion] Devotion to their tiles, and +3 [ICON_Religion] Devotion to adjacent districts."),
    ("en_US",  "LOC_BELIEF_GODDESS_OF_THE_HUNT_NAME",                     		"Goddess of the Hunt"),
    ("en_US",  "LOC_BELIEF_GODDESS_OF_THE_HUNT_DESCRIPTION",           			"Camps provide +1 [ICON_Religion] Devotion to their tiles, and +1 [ICON_Religion] Devotion to adjacent districts."),
    ("en_US",  "LOC_BELIEF_GODDESS_OF_FESTIVALS_NAME",                     		"Goddess of Festivals"),
    ("en_US",  "LOC_BELIEF_GODDESS_OF_FESTIVALS_DESCRIPTION",           		"Plantations provide +2 [ICON_Religion] Devotion to their tiles, and +3 [ICON_Religion] Devotion to adjacent districts."),
    ("en_US",  "LOC_BELIEF_RELIGIOUS_IDOLS_NAME",                     			"Religious Idols"),
    ("en_US",  "LOC_BELIEF_RELIGIOUS_IDOLS_DESCRIPTION",           				"Mines provide +1 [ICON_Religion] Devotion to their tiles, and +1 [ICON_Religion] Devotion to adjacent districts."),
    ("en_US",  "LOC_BELIEF_LADY_OF_THE_REEDS_AND_MARSHES_NAME",                 "Lady of the Reeds and Marshes"),
    ("en_US",  "LOC_BELIEF_LADY_OF_THE_REEDS_AND_MARSHES_DESCRIPTION",          "Marsh, Oasis and Desert Floodplains provide +2 [ICON_Religion] Devotion to their tiles, and +2 [ICON_Religion] Devotion to adjacent districts."),
    ("en_US",  "LOC_BELIEF_GODDESS_OF_FIRE_NAME",                     			"Goddess of Fire"),
    ("en_US",  "LOC_BELIEF_GODDESS_OF_FIRE_DESCRIPTION",           				"Geothermal Fissures and Volcanic Soil provide +2 [ICON_Religion] Devotion to their tiles, and +2 [ICON_Religion] Devotion to adjacent districts."),
    ("en_US",  "LOC_BELIEF_SACRED_PATH_NAME",                     				"Sacred Path"),
    ("en_US",  "LOC_BELIEF_SACRED_PATH_DESCRIPTION",           					"Rainforests provide +1 [ICON_Religion] Devotion to their tiles, and +1 [ICON_Religion] Devotion to adjacent districts."),
    ("en_US",  "LOC_BELIEF_DANCE_OF_THE_AURORA_NAME",                     		"Dance of the Aurora"),
    ("en_US",  "LOC_BELIEF_DANCE_OF_THE_AURORA_DESCRIPTION",           			"Tundra, Tundra Hills and Tundra Mountains provide +2 [ICON_Religion] Devotion to their tiles, and +1 [ICON_Religion] Devotion to adjacent districts."),
    ("en_US",  "LOC_BELIEF_DESERT_FOLKLORE_NAME",                     			"Desert Forklore"),
    ("en_US",  "LOC_BELIEF_DESERT_FOLKLORE_DESCRIPTION",           				"Desert, Desert Hills and Desert Mountains provide +2 [ICON_Religion] Devotion to their tiles, and +1 [ICON_Religion] Devotion to adjacent districts."),
    ("en_US",  "LOC_BELIEF_RIVER_GODDESS_NAME",                     			"River Goddess"),
    ("en_US",  "LOC_BELIEF_RIVER_GODDESS_DESCRIPTION",           				"Rivers provide +1 [ICON_Religion] Devotion to their tiles, and +1 [ICON_Religion] Devotion to adjacent districts."),
    ("en_US",  "LOC_BELIEF_EARTH_GODDESS_NAME",                     			"Earth Goddess"),
    ("en_US",  "LOC_BELIEF_EARTH_GODDESS_DESCRIPTION",           				"Tiles provide +1 [ICON_Religion] Devotion per 2 Appeal."),
    ("en_US",  "LOC_BELIEF_GOD_OF_BEAUTY_NAME",                     			"God of Beauty"),
    ("en_US",  "LOC_BELIEF_GOD_OF_BEAUTY_DESCRIPTION",          	 			"Districts provide +1 [ICON_Religion] Devotion per Appeal."),
    ("en_US",  "LOC_BELIEF_INITIATION_RITES_NAME",                     			"Fengshan Rites"),
    ("en_US",  "LOC_BELIEF_INITIATION_RITES_DESCRIPTION",           			"Holy Sites receive +1 adjacency bonus from each [ICON_Religion] Devotion."),
    ("en_US",  "LOC_BELIEF_GOD_OF_HEALING_NAME",                     			"God of Healing"),
    ("en_US",  "LOC_BELIEF_GOD_OF_HEALING_DESCRIPTION",           				"Units heal +30 hit points on tiles with [ICON_Religion] Devotion"),
	("en_US",  "LOC_BELIEF_RELIGIOUS_SETTLEMENTS_NAME",                     	"Household Deities"),
    ("en_US",  "LOC_BELIEF_RELIGIOUS_SETTLEMENTS_DESCRIPTION",           		"Districts with at least 2 [ICON_Religion] Devotion provide +1 [ICON_Housing] Housing; districts with at least 4 [ICON_Religion] Devotion provide an additional +1 [ICON_Housing] Housing.");
   




insert or ignore into LocalizedText    (Language,      Tag,                                                             Text) values
	('zh_Hans_CN',		'LOC_CHOOSE_DOMAIN',						'选择神格'),
	('zh_Hans_CN',		'LOC_CHOOSE_POWER',							'选择权柄'),
	('zh_Hans_CN',		'LOC_CREATE_YOUR_PANTHEON',					'创造神灵'),
	('zh_Hans_CN',		'LOC_PANTHEON_CHOSEN',						'[COLOR_RED]该万神殿已被选择[ENDCOLOR]'),
	('zh_Hans_CN',		'LOC_CREATE_THIS_PANTHEON',					'建立该万神殿信仰'),

	('zh_Hans_CN',		'LOC_BELIEF_GGV_NAME',						'文曲星'),
	('zh_Hans_CN',		'LOC_BELIEF_SHENNONG_NAME',					'神农'),
	('zh_Hans_CN',		'LOC_BELIEF_GOD_OF_WINE_NAME',				'酒神'),
	('zh_Hans_CN',		'LOC_BELIEF_GOD_OF_MIRACLES_NAME',			'奇迹之神'),
	('zh_Hans_CN',		'LOC_BELIEF_GOD_OF_BEAUTY_NAME',			'美神'),

	('zh_Hans_CN',		'LOC_BELIEF_GGV_DESCRIPTION',				'至少拥有2 [ICON_Religion] 神力的区域或单元格+1 [ICON_CULTURE] 文化值'),
	('zh_Hans_CN',		'LOC_BELIEF_SHENNONG_DESCRIPTION',			'至少拥有2 [ICON_Religion] 神力的区域或单元格+1 [ICON_FOOD] 食物'),
	('zh_Hans_CN',		'LOC_BELIEF_GOD_OF_WINE_DESCRIPTION',		'至少拥有3 [ICON_Religion] 神力的区域+1 [ICON_Amenities] 宜居度；至少拥有5 [ICON_Religion] 神力的区域则再+1 [ICON_Amenities] 宜居度'),

	('zh_Hans_CN',		'LOC_BELIEF_GOD_OF_MIRACLES_DESCRIPTION',	'至少拥有6 [ICON_Religion] 神力的区域获得一级建筑。'),
	('zh_Hans_CN',		'LOC_INITIATION_RITES',						'+{1_num} [ICON_FAITH] 信仰值来自所选神格。'),

	('zh_Hans_CN',		'LOC_STONE_CIRCLES_POINTS',					'采石场'),
	('zh_Hans_CN',		'LOC_DESERT_FOLKLORE_POINTS',				'沙漠，沙漠丘陵或沙漠山脉'),
	('zh_Hans_CN',		'LOC_GOD_OF_THE_SEA_POINTS',				'渔船'),
	('zh_Hans_CN',		'LOC_GODDESS_OF_FIRE_POINTS',				'地热裂缝或火山土'),
	('zh_Hans_CN',		'LOC_DANCE_OF_THE_AURORA_POINTS',			'冻土，冻土丘陵或冻土山脉'),
	('zh_Hans_CN',		'LOC_GODDESS_OF_FESTIVALS_POINTS',			'种植园'),
	('zh_Hans_CN',		'LOC_LADY_OF_THE_REEDS_AND_MARSHES_POINTS',	'沼泽，绿洲或沙漠泛滥平原'),
	('zh_Hans_CN',		'LOC_SACRED_PATH_POINTS',					'雨林'),
	('zh_Hans_CN',		'LOC_ORAL_TRADITION_POINTS',				'森林'),
	('zh_Hans_CN',		'LOC_GOD_OF_THE_OPEN_SKY_POINTS',			'牧场'),
	('zh_Hans_CN',		'LOC_RELIGIOUS_IDOLS_POINTS',				'矿山'),
	('zh_Hans_CN',		'LOC_GODDESS_OF_THE_HUNT_POINTS',			'营地'),

	--('zh_Hans_CN',		'LOC_INITIATION_RITES_DIS_EFFECT',			''),
	('zh_Hans_CN',		'LOC_GOD_OF_CRAFTSMEN_DIS_EFFECT',			'+1 [ICON_Production] 生产力'),
	('zh_Hans_CN',		'LOC_SHENNONG_DIS_EFFECT',					'+1 [ICON_FOOD] 食物'),
	('zh_Hans_CN',		'LOC_GGV_DIS_EFFECT',						'+1 [ICON_CULTURE] 文化值'),
	('zh_Hans_CN',		'LOC_DIVINE_SPARK_DIS_EFFECT',				'+1 [ICON_GreatPerson] 对应伟人点数'),
	('zh_Hans_CN',		'LOC_DIVINE_SPARK_DIS_EFFECT_T2',			'再+2 [ICON_GreatPerson] 对应伟人点数'),
	('zh_Hans_CN',		'LOC_GOD_OF_MIRACLES_DIS_EFFECT',				'赠送一级建筑'),
	('zh_Hans_CN',		'LOC_RELIGIOUS_SETTLEMENTS_DIS_EFFECT',		'+1 [ICON_Housing] 住房'),
	('zh_Hans_CN',		'LOC_GOD_OF_WINE_DIS_EFFECT',				'+1 [ICON_Amenities] 宜居度'),
	('zh_Hans_CN',		'LOC_CITY_PATRON_GODDESS_DIS_EFFECT',		'在拥有一个专业区域后，可以无视人口限制额外建造一个专业区域'),
	('zh_Hans_CN',		'LOC_MONUMENT_TO_THE_GODS_DIS_EFFECT',		'建造远古和古典奇观时+25%建造速度');



--三类+区域
--三类+区域（修正「拥有至少拥有」；神圣之光二档为再+2）
insert or ignore into PantheonTexts    (Language,      GodhoodType,	PowerType,		Texts) select
			'zh_Hans_CN',		GodhoodType,	PowerType,
			'境内相邻六格中至少有'||MultiNumber||'个'||'{LOC_'||GodhoodType||'_POINTS}的区域'||
			case when PowerType = 'DIVINE_SPARK' and pwParam1 = 'THRESHOLD2'
				then '{LOC_DIVINE_SPARK_DIS_EFFECT_T2}'
				else '{LOC_'||PowerType||'_DIS_EFFECT}'
			end||'。'
	from Godhood, Power, ThresholdCounter where ghClass in ('IMPROVEMENT',	'FEATURE',	'TERRAIN') and pwClass = 'DISTRICT'
	and pwParam1 in ('THRESHOLD1', 'THRESHOLD2') and ghParam2 = Delta and pwParam2 = Threshold;
--三类+城市
insert or ignore into PantheonTexts    (Language,      GodhoodType,	PowerType,		Texts) select
			'zh_Hans_CN',		GodhoodType,	PowerType,
			'市中心境内相邻六格中至少有'||MultiNumber||'个'||'{LOC_'||GodhoodType||'_POINTS}的城市'||
			case when PowerType = 'DIVINE_SPARK' and pwParam1 = 'THRESHOLD2'
				then '{LOC_DIVINE_SPARK_DIS_EFFECT_T2}'
				else '{LOC_'||PowerType||'_DIS_EFFECT}'
			end||'。'
	from Godhood, Power, ThresholdCounter where ghClass in ('IMPROVEMENT',	'FEATURE',	'TERRAIN') and pwClass = 'CITY'
	and pwParam1 in ('THRESHOLD1', 'THRESHOLD2') and ghParam2 = Delta and pwParam2 = Threshold;
--三类+封禅
insert or ignore into PantheonTexts    (Language,      GodhoodType,	PowerType,		Texts) select
			'zh_Hans_CN',		GodhoodType,	'INITIATION_RITES',	'圣地一格范围内（境内）的每个{LOC_'||GodhoodType||'_POINTS}均为圣地+'||ghParam2||' [ICON_FAITH] 信仰值相邻加成。'
	from Godhood where ghClass in ('IMPROVEMENT',	'FEATURE',	'TERRAIN');
--三类+丰产仪式
insert or ignore into PantheonTexts    (Language,      GodhoodType,	PowerType,		Texts) select
			'zh_Hans_CN',		GodhoodType,	'FERTILITY_RITES',	'{LOC_'||GodhoodType||'_POINTS}所在单元格+'||ghParam3||' [ICON_FAITH] 信仰值。'
	from Godhood where ghClass in ('IMPROVEMENT',	'FEATURE',	'TERRAIN');
--三类+神农/文曲星/工匠之神
insert or ignore into PantheonTexts    (Language,      GodhoodType,	PowerType,		Texts) select
			'zh_Hans_CN',		GodhoodType,	PowerType,	'{LOC_'||GodhoodType||'_POINTS}所在单元格'||'{LOC_'||PowerType||'_DIS_EFFECT}。'
	from Godhood, Power where ghClass in ('IMPROVEMENT',	'FEATURE',	'TERRAIN') and pwClass = 'YIELD'
	 and ghParam3 >= pwParam2;


--大地女神+区域
insert or ignore into PantheonTexts    (Language,      GodhoodType,	PowerType,		Texts) select
			'zh_Hans_CN',		'EARTH_GODDESS',	PowerType,
			'魅力值至少为'||(pwParam2 * 2)||'的区域'||
			case when PowerType = 'DIVINE_SPARK' and pwParam1 = 'THRESHOLD2'
				then '{LOC_DIVINE_SPARK_DIS_EFFECT_T2}'
				else '{LOC_'||PowerType||'_DIS_EFFECT}'
			end||'。'
	from  Power where  pwClass = 'DISTRICT'
	and pwParam1 in ('THRESHOLD1', 'THRESHOLD2');
--大地女神+城市
insert or ignore into PantheonTexts    (Language,      GodhoodType,	PowerType,		Texts) select
			'zh_Hans_CN',		'EARTH_GODDESS',	PowerType,
			'市中心魅力值至少为'||(pwParam2 * 2)||'的城市'||
			case when PowerType = 'DIVINE_SPARK' and pwParam1 = 'THRESHOLD2'
				then '{LOC_DIVINE_SPARK_DIS_EFFECT_T2}'
				else '{LOC_'||PowerType||'_DIS_EFFECT}'
			end||'。'
	from  Power where  pwClass = 'CITY'
	and pwParam1 in ('THRESHOLD1', 'THRESHOLD2');
--大地女神+封禅/丰产仪式
insert or ignore into PantheonTexts    (Language,      GodhoodType,	PowerType,		Texts) values
			('zh_Hans_CN',		'EARTH_GODDESS',	'INITIATION_RITES',		'圣地所在单元格的每有2点魅力值就为该圣地提供+1 [ICON_FAITH] 信仰值相邻加成。'),
			('zh_Hans_CN',		'EARTH_GODDESS',	'FERTILITY_RITES',		'单元格每有2点魅力值就+1 [ICON_FAITH] 信仰值。');
--大地女神+神农/文曲星/工匠之神
insert or ignore into PantheonTexts    (Language,      GodhoodType,	PowerType,		Texts) select
			'zh_Hans_CN',		'EARTH_GODDESS',	PowerType,	'魅力值至少为'||(pwParam2 * 2)||'的单元格{LOC_'||PowerType||'_DIS_EFFECT}。'
	from  Power where  pwClass = 'YIELD';


--美神+区域
insert or ignore into PantheonTexts    (Language,      GodhoodType,	PowerType,		Texts) select
			'zh_Hans_CN',		'GOD_OF_BEAUTY',	PowerType,
			'魅力值至少为'||pwParam2||'的区域'||
			case when PowerType = 'DIVINE_SPARK' and pwParam1 = 'THRESHOLD2'
				then '{LOC_DIVINE_SPARK_DIS_EFFECT_T2}'
				else '{LOC_'||PowerType||'_DIS_EFFECT}'
			end||'。'
	from  Power where  pwClass = 'DISTRICT'
	and pwParam1 in ('THRESHOLD1', 'THRESHOLD2');
--美神+城市
insert or ignore into PantheonTexts    (Language,      GodhoodType,	PowerType,		Texts) select
			'zh_Hans_CN',		'GOD_OF_BEAUTY',	PowerType,
			'市中心魅力值至少为'||pwParam2||'的城市'||
			case when PowerType = 'DIVINE_SPARK' and pwParam1 = 'THRESHOLD2'
				then '{LOC_DIVINE_SPARK_DIS_EFFECT_T2}'
				else '{LOC_'||PowerType||'_DIS_EFFECT}'
			end||'。'
	from  Power where  pwClass = 'CITY'
	and pwParam1 in ('THRESHOLD1', 'THRESHOLD2');

--美神+封禅
insert or ignore into PantheonTexts    (Language,      GodhoodType,	PowerType,		Texts) values
	('zh_Hans_CN',		'GOD_OF_BEAUTY',	'INITIATION_RITES',		'圣地所在单元格的每有1点魅力值就为该圣地提供+1 [ICON_FAITH] 信仰值相邻加成。');

--美神+丰产仪式
insert or ignore into PantheonTexts    (Language,      GodhoodType,	PowerType,		Texts) values
	('zh_Hans_CN',		'GOD_OF_BEAUTY',	'FERTILITY_RITES',	'无效果。');


insert or ignore into LocalizedText    (Language,      Tag,                                                             Text) select
	'zh_Hans_CN',			'LOC_BELIEF_'||GodhoodType||'_WITH_'||PowerType||'_NAME',	'{LOC_BELIEF_'||GodhoodType||'_NAME}+{LOC_BELIEF_'||PowerType||'_NAME}'
	from Godhood, Power;

insert into LocalizedText(Language,	Tag,	Text) select
	Language,	'LOC_BELIEF_'||GodhoodType||'_WITH_'||PowerType||'_DESCRIPTION',	group_concat(Texts, ' ')
	from PantheonTexts group by  GodhoodType, Language, PowerType;



--insert or ignore into EnglishText	 (      Tag,                                                             Text) values
--	('LOC_ORAL_TRADITION_DIVINE_SPARK_THRESHOLD1',	'一格范围内拥有至少拥有'||3||'ge'||'{LOC_DANCE_OF_THE_AURORA_POINTS}的区域');


--单个万神
insert or replace into LocalizedText
    (Language,      Tag,                                                         Text)
values
    ("zh_Hans_CN",  "LOC_BELIEF_ORAL_TRADITION_NAME",                           "口述传统"),
    ("zh_Hans_CN",  "LOC_BELIEF_ORAL_TRADITION_DESCRIPTION",                 	"森林+1 [ICON_Religion] 神力，为相邻区域+1 [ICON_Religion] 神力。"),
    ("zh_Hans_CN",  "LOC_BELIEF_SEA_GODDESSS_NAME",                   			"海神"),
    ("zh_Hans_CN",  "LOC_BELIEF_SEA_GODDESSS_DESCRIPTION",                      "？？？？"),
    ("zh_Hans_CN",  "LOC_BELIEF_MOUNTAIN_GODDESS_NAME",                 		"山神"),
    ("zh_Hans_CN",  "LOC_BELIEF_MOUNTAIN_GODDESS_DESCRIPTION",          		"？？？？"),
    ("zh_Hans_CN",  "LOC_BELIEF_GODDESS_OF_THE_HARVEST_NAME",					"收获女神"),
    ("zh_Hans_CN",  "LOC_BELIEF_GODDESS_OF_THE_HARVEST_DESCRIPTION",            "？？？？"),
    ("zh_Hans_CN",  "LOC_BELIEF_GOD_OF_THE_FORGE_NAME",                     	"锻造之神"),
    ("zh_Hans_CN",  "LOC_BELIEF_GOD_OF_THE_FORGE_DESCRIPTION",           		"？？？？"),
    ("zh_Hans_CN",  "LOC_BELIEF_CITY_PATRON_GODDESS_NAME",                     	"城市守护女神"),
    ("zh_Hans_CN",  "LOC_BELIEF_CITY_PATRON_GODDESS_DESCRIPTION",           	"市中心拥有4 [ICON_Religion] 神力时，建造第一个专业区域后，可以无视人口需求再造一个专业区域。"),
    ("zh_Hans_CN",  "LOC_BELIEF_DIVINE_SPARK_NAME",                     		"神圣之光"),
    ("zh_Hans_CN",  "LOC_BELIEF_DIVINE_SPARK_DESCRIPTION",           			"至少拥有2 [ICON_Religion] 神力的区域，+1伟人点产出；至少拥有4 [ICON_Religion] 神力的区域再+2。"),
    ("zh_Hans_CN",  "LOC_BELIEF_GOD_OF_WAR_NAME",                     			"战争之神"),
    ("zh_Hans_CN",  "LOC_BELIEF_GOD_OF_WAR_DESCRIPTION",           				"？？？？"),
    ("zh_Hans_CN",  "LOC_BELIEF_MONUMENT_TO_THE_GODS_NAME",                     "主神纪念碑"),
    ("zh_Hans_CN",  "LOC_BELIEF_MONUMENT_TO_THE_GODS_DESCRIPTION",           	"市中心拥有4 [ICON_Religion] 神力时，建造远古和古典奇观+25%生产力。"),
    ("zh_Hans_CN",  "LOC_BELIEF_FERTILITY_RITES_NAME",                     		"丰产仪式"),
    ("zh_Hans_CN",  "LOC_BELIEF_FERTILITY_RITES_DESCRIPTION",           		"单元格的每点 [ICON_Religion] 神力均为单元格+1 [ICON_FAITH] 信仰值。"),
    ("zh_Hans_CN",  "LOC_BELIEF_GOD_OF_CRAFTSMEN_NAME",                     	"工匠之神"),
	("zh_Hans_CN",  "LOC_BELIEF_GOD_OF_CRAFTSMEN_DESCRIPTION",					"至少拥有2 [ICON_Religion] 神力的区域或单元格+1 [ICON_Production] 生产力。"),
    -- ("zh_Hans_CN",  "LOC_BELIEF_GOD_OF_CRAFTSMEN_DESCRIPTION",           		"改良后的战略资源为本单元格+3 [ICON_Religion] 神力，为市中心+1 [ICON_Religion] 神力。"),
    ("zh_Hans_CN",  "LOC_BELIEF_GOD_OF_THE_OPEN_SKY_NAME",                     	"天空之神"),
    ("zh_Hans_CN",  "LOC_BELIEF_GOD_OF_THE_OPEN_SKY_DESCRIPTION",           	"牧场+3 [ICON_Religion] 神力，为相邻区域+3 [ICON_Religion] 神力。"),
    ("zh_Hans_CN",  "LOC_BELIEF_GOD_OF_THE_SEA_NAME",                     		"海洋之神"),
    ("zh_Hans_CN",  "LOC_BELIEF_GOD_OF_THE_SEA_DESCRIPTION",           			"渔船+3 [ICON_Religion] 神力，为相邻区域+3 [ICON_Religion] 神力。"),
    ("zh_Hans_CN",  "LOC_BELIEF_STONE_CIRCLES_NAME",                     		"石圈"),
    ("zh_Hans_CN",  "LOC_BELIEF_STONE_CIRCLES_DESCRIPTION",           			"采石场+2 [ICON_Religion] 神力，为相邻区域+3 [ICON_Religion] 神力。"),
    ("zh_Hans_CN",  "LOC_BELIEF_GODDESS_OF_THE_HUNT_NAME",                     	"狩猎女神"),
    ("zh_Hans_CN",  "LOC_BELIEF_GODDESS_OF_THE_HUNT_DESCRIPTION",           	"营地+2 [ICON_Religion] 神力，为相邻区域+3 [ICON_Religion] 神力。"),
    ("zh_Hans_CN",  "LOC_BELIEF_GODDESS_OF_FESTIVALS_NAME",                     "节庆女神"),
    ("zh_Hans_CN",  "LOC_BELIEF_GODDESS_OF_FESTIVALS_DESCRIPTION",           	"种植园+2 [ICON_Religion] 神力，为相邻区域+3 [ICON_Religion] 神力。"),
    ("zh_Hans_CN",  "LOC_BELIEF_RELIGIOUS_IDOLS_NAME",                     		"宗教偶像"),
    ("zh_Hans_CN",  "LOC_BELIEF_RELIGIOUS_IDOLS_DESCRIPTION",           		"矿山+1 [ICON_Religion] 神力，为相邻区域+1 [ICON_Religion] 神力。"),
    ("zh_Hans_CN",  "LOC_BELIEF_LADY_OF_THE_REEDS_AND_MARSHES_NAME",            "芦苇和沼泽地里的夫人"),
    ("zh_Hans_CN",  "LOC_BELIEF_LADY_OF_THE_REEDS_AND_MARSHES_DESCRIPTION",     "沼泽、绿洲、沙漠泛滥平原+2 [ICON_Religion] 神力，为相邻区域+2 [ICON_Religion] 神力。"),
    ("zh_Hans_CN",  "LOC_BELIEF_GODDESS_OF_FIRE_NAME",                     		"火之女神"),
    ("zh_Hans_CN",  "LOC_BELIEF_GODDESS_OF_FIRE_DESCRIPTION",           		"地热裂缝和火山土+2 [ICON_Religion] 神力，为相邻区域+2 [ICON_Religion] 神力。"),
    ("zh_Hans_CN",  "LOC_BELIEF_SACRED_PATH_NAME",                     			"神圣道路"),
    ("zh_Hans_CN",  "LOC_BELIEF_SACRED_PATH_DESCRIPTION",           			"雨林+1 [ICON_Religion] 神力，为相邻区域+1 [ICON_Religion] 神力。"),
    ("zh_Hans_CN",  "LOC_BELIEF_DANCE_OF_THE_AURORA_NAME",                     	"极光之舞"),
    ("zh_Hans_CN",  "LOC_BELIEF_DANCE_OF_THE_AURORA_DESCRIPTION",           	"冻土，冻土丘陵和冻土山脉+2 [ICON_Religion] 神力，为相邻区域+1 [ICON_Religion] 神力。"),
    ("zh_Hans_CN",  "LOC_BELIEF_DESERT_FOLKLORE_NAME",                     		"沙漠民俗"),
    ("zh_Hans_CN",  "LOC_BELIEF_DESERT_FOLKLORE_DESCRIPTION",           		"沙漠，沙漠丘陵和沙漠山脉+2 [ICON_Religion] 神力，为相邻区域+1 [ICON_Religion] 神力。"),
    ("zh_Hans_CN",  "LOC_BELIEF_RIVER_GODDESS_NAME",                     		"河神"),
    ("zh_Hans_CN",  "LOC_BELIEF_RIVER_GODDESS_DESCRIPTION",          	 		"河流单元格提供1 [ICON_Religion] 神力，为其上区域再+1 [ICON_Religion] 神力。"),
    ("zh_Hans_CN",  "LOC_BELIEF_EARTH_GODDESS_NAME",                     		"大地女神"),
    ("zh_Hans_CN",  "LOC_BELIEF_EARTH_GODDESS_DESCRIPTION",          	 		"单元格的每2点魅力值提供1 [ICON_Religion] 神力。"),    
    ("zh_Hans_CN",  "LOC_BELIEF_GOD_OF_BEAUTY_NAME",                     		"美神"),
    ("zh_Hans_CN",  "LOC_BELIEF_GOD_OF_BEAUTY_DESCRIPTION",          	 		"区域所在单元格的每1点魅力值提供1 [ICON_Religion] 神力。"),
    ("zh_Hans_CN",  "LOC_BELIEF_INITIATION_RITES_NAME",                     	"封禅"),
    ("zh_Hans_CN",  "LOC_BELIEF_INITIATION_RITES_DESCRIPTION",           		"圣地的每点 [ICON_Religion] 神力均为圣地+1相邻加成"),
    ("zh_Hans_CN",  "LOC_BELIEF_GOD_OF_HEALING_NAME",                     		"愈合之神"),
    ("zh_Hans_CN",  "LOC_BELIEF_GOD_OF_HEALING_DESCRIPTION",           			"在有 [ICON_Religion] 神力的单元格单位恢复+30"),
	("zh_Hans_CN",  "LOC_BELIEF_RELIGIOUS_SETTLEMENTS_NAME",                    "家神"),
    ("zh_Hans_CN",  "LOC_BELIEF_RELIGIOUS_SETTLEMENTS_DESCRIPTION",           	"至少2 [ICON_Religion] 神力的区域，+1[ICON_Housing]住房；至少4 [ICON_Religion] 神力区域再+1[ICON_Housing]住房");
   

