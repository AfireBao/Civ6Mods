insert into IconTextureAtlases
    (Name,                                              IconSize,   IconsPerRow,    IconsPerColumn,     Filename)
values
    ('ICON_ATLAS_PANTHEON_DA',                          256,        8,              8,                  'DA_Pantheons256'),
    ('ICON_ATLAS_PANTHEON_DA',                          64,         8,              8,                  'DA_Pantheons64'),   
    ('ICON_ATLAS_PANTHEON_DA',                          50,         8,              8,                  'DA_Pantheons50'),
    ('ICON_ATLAS_PANTHEON_DA',                          32,         8,              8,                  'DA_Pantheons32');




insert or replace into IconDefinitions
    (Name,                                              Atlas,                                              'Index')
values
    ('ICON_BELIEF_GOD_OF_BEAUTY',                       'ICON_ATLAS_PANTHEON_DA',                           7),
    ('ICON_BELIEF_GOD_OF_WINE',                         'ICON_ATLAS_PANTHEON_DA',                           0),
    ('ICON_BELIEF_GOD_OF_MIRACLES',                      'ICON_ATLAS_BELIEFS_PATHEON',                       17),
    ('ICON_BELIEF_GGV',                                 'ICON_ATLAS_PANTHEON_DA',                           2),
    ('ICON_BELIEF_SHENNONG',                            'ICON_ATLAS_PANTHEON_DA',                           6);


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
--  'PowerType' TEXT NOT NULL,
--  'ModifierType' TEXT NOT NULL,

create table 'PantheonModifiers'(
    'PowerType' TEXT NOT NULL,
    'GodhoodType' TEXT NOT NULL,
    'ModifierId' TEXT NOT NULL,
    PRIMARY KEY('GodhoodType', 'PowerType', 'ModifierId')
);


insert or ignore into Godhood(GodhoodType,      ghClass,        ghParam1,       ghParam2,   ghParam3,   ghParam4) values
    ('GOD_OF_BEAUTY',                   'APPEAL',       'PLACEHOLDER',                  NULL,   NULL,   NULL),

    ('EARTH_GODDESS',                   'APPEAL',       'PLACEHOLDER',                  NULL,   NULL,   NULL),
--  ('GOD_OF_CRAFTS_MAN',               'RESOURCE_COUNT',   'RESOURCECLASS_STRATEGIC',      NULL,   NULL,   NULL),
    ('STONE_CIRCLES',                   'IMPROVEMENT',  'IMPROVEMENT_QUARRY',           3,  3,  NULL),
    ('DESERT_FOLKLORE',                 'TERRAIN',      'TERRAIN_DESERT',               1,  2,  NULL),
    ('DESERT_FOLKLORE',                 'TERRAIN',      'TERRAIN_DESERT_HILLS',         1,  2,  NULL),
    ('DESERT_FOLKLORE',                 'TERRAIN',      'TERRAIN_DESERT_MOUNTAIN',      1,  2,  NULL),
    --('DESERT_FOLK_LORE',              'FEATURE',      'FEATURE_FLOODPLAINS',          -3, -3, NULL),  
    ('GOD_OF_THE_SEA',                  'IMPROVEMENT',  'IMPROVEMENT_FISHING_BOATS',    3,  3,  NULL),
    ('GODDESS_OF_FIRE',                 'FEATURE',      'FEATURE_GEOTHERMAL_FISSURE',   2,  2,  NULL),
    ('GODDESS_OF_FIRE',                 'FEATURE',      'FEATURE_VOLCANIC_SOIL',        2,  2,  NULL),
    ('DANCE_OF_THE_AURORA',             'TERRAIN',      'TERRAIN_TUNDRA',               1,  2,  NULL),
    ('DANCE_OF_THE_AURORA',             'TERRAIN',      'TERRAIN_TUNDRA_HILLS',         1,  2,  NULL),
    ('DANCE_OF_THE_AURORA',             'TERRAIN',      'TERRAIN_TUNDRA_MOUNTAIN',      1,  2,  NULL),
    ('GODDESS_OF_FESTIVALS',            'IMPROVEMENT',  'IMPROVEMENT_PLANTATION',       2,  3,  NULL),
    ('LADY_OF_THE_REEDS_AND_MARSHES',   'FEATURE',      'FEATURE_MARSH',                2,  2,  NULL),
    ('LADY_OF_THE_REEDS_AND_MARSHES',   'FEATURE',      'FEATURE_OASIS',                2,  2,  NULL),
    ('LADY_OF_THE_REEDS_AND_MARSHES',   'FEATURE',      'FEATURE_FLOODPLAINS',          2,  2,  NULL),
    ('SACRED_PATH',                     'FEATURE',      'FEATURE_JUNGLE',               1,  1,  NULL),
    ('ORAL_TRADITION',                  'FEATURE',      'FEATURE_FOREST',               1,  1,  NULL),
    ('GOD_OF_THE_OPEN_SKY',             'IMPROVEMENT',  'IMPROVEMENT_PASTURE',          3,  3,  NULL),
    ('RELIGIOUS_IDOLS',                 'IMPROVEMENT',  'IMPROVEMENT_MINE',             1,  1,  NULL),
    ('GODDESS_OF_THE_HUNT',             'IMPROVEMENT',  'IMPROVEMENT_CAMP',             2,  3,  NULL);

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


insert or ignore into IconDefinitions
    (Name,                                              Atlas,                                              'Index') select
    'ICON_BELIEF_'||GodHoodType||'_WITH_'||PowerType,        'ICON_ATLAS_BELIEFS_PATHEON', 5  
    from Godhood, Power;


