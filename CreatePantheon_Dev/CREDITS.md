# Create Your Pantheon Dev — Credits

This folder is a **local Dev fork** of the Steam Workshop mod *Create Your Pantheon*, maintained under `Civ6Mods` with bugfixes. It is **not** an official release by the original authors.

## Upstream

- Steam Workshop: https://steamcommunity.com/sharedfiles/filedetails/?id=2990102039  
- Original Mod ID: `b85e61c0-26b7-4098-81ba-8566b8537dcb`  
- This Dev Mod ID: `c3a8f1e4-7b2d-4a91-9e5c-6d0f8b4a2c17`

## Original authors (Create Your Pantheon Project Team)

| Member | Role |
|--------|------|
| nea_baraja | Planning, architecture, programming |
| ShizukaMogami (千古歌) | Programming, testing |
| 皮皮凯 (PiPiKai / PPK) | UI design, programming |
| 夕墨岚 (XiMoLan) | Art |
| Phantagonist | English translation |

Released as part of the Dark Age Mod ecosystem; this standalone Dev build disables itself when the Dark Age integrated pack (`236af578-08bc-4278-ab57-c700ab114515`) is enabled.

## Dev changes (Civ6Mods)

- Fixed improvement devotion threshold count (removed erroneous `MultiNumber + 1`).
- Restored AI pantheon modifiers via exact Godhood+Power match.
- AI pantheon selection retries from unfounded combinations only.
- Fixed English Household Deities devotion numbers (2 / 4).
- Hardened packaging: new Mod GUID / Dev naming; clearer ImportFiles action IDs for PantheonChooser VFS override (avoid double UI context).
- Insert `Types` before combination `Beliefs`.
- **God of Miracles (A+C):** no longer attaches Permanent `COLLECTION_PLAYER_DISTRICTS` grant modifiers. Uses event-driven updates from improvement/district changes + per-district devotion cache; grants only on threshold cross / new district / load. Lua log prefix `[CP_Miracles]` (disable: `Game.SetProperty('PROP_CP_DEBUG', 0)`).
- **Hybrid apply:** non-miracle `PantheonModifiers` → `BeliefModifiers` (engine on `FoundPantheon`). UI no longer `AttachModifier`. Gameplay `PantheonFounded` handles Asuna extras + miracles register.
- **AI v5:** non-`_WITH_` pantheon beliefs moved to `BELIEF_CLASS_CP_DISABLED` (engine/AI cannot found vanilla sole pantheons). `CP_AI` weighted pick by owned terrain/resources; `GOD_OF_MIRACLES` heavily downweighted.
- **v6 apply fix:** `BeliefModifiers` did not activate devotion-threshold effects (e.g. Sea+Divine Spark Holy Site GPP). Restored Gameplay `AttachModifierByID` for exact Godhood×Power; deleted combo rows from `BeliefModifiers`. Load-time ensure for mid-game saves.
- **AI load fix:** `CP_AI.lua` used Lua `goto` which Civ6 rejects (file never loaded → engine picked combos, often stacking Aurora on tundra maps). Rewrote without goto; capped terrain bonuses; soft diversity penalty on already-used godhoods; dedupe Godhood/Power rows.
- **AI Top-K:** weighted pick only among the top 8 scoring combinations (no long-tail Aurora-at-rank-133).
- **Divine Spark double GPP:** mixing devotion threshold + district-type in one SubjectReq let GPP bleed onto other devoted districts (8 admiral GPT). Split attach: vanilla `DISTRICT_IS_*` outer → threshold-only inner on `COLLECTION_OWNER`.
- **AI Aurora stack (v10):** engine still auto-founded `_WITH_` combos on AI turns (`ApplyCombo` with no `[CP_AI] chosen`). Combos moved to `BELIEF_CLASS_CP_COMBO` (empty engine pantheon pool). Human/AI found via `GameEvents.CP_FoundPantheon` → Lua `FoundPantheon`. Also `PlayerTurnActivated` + hard godhood diversity exclude + gameplay `Utils.IsAI`.
- **Divine Spark 8 admiral (v11):** nested attach + `COLLECTION_COUNT` still doubled (expect 4 with harbor+2 boats, saw 8). DS now uses `DISTRICT_IS_*` + Lua `PROP_CP_DEV_<godhood>` plot property (≥2 / ≥4); Lua tracks devotion for spark players and writes the property on district/plot events.
- **Divine Spark still 8 (v12):** property+district SubjectReq still doubled when both tiers active. Removed all DS district GPP modifiers; Lua `SparkGrant` adds +1/+2 per devoted specialty district on `PlayerTurnActivated` via `ChangePointsTotal`. Harbor base 1 remains from the district.
- **Divine Spark SQL exclusive bands (v13):** root cause = two `ADJUST_GREAT_PERSON_POINTS` on same district (LH→9=8+1 confirmed). Mutually exclusive: `2≤dev<4` → one mod +1; `dev≥4` → one mod +3. Lua only writes `PROP_CP_DEV_*` (no turn grant). Dropped v12 SparkGrant.
- **Housing / Wine exclusive bands (v14):** same double-modifier class — Religious Settlements (`ADJUST_HOUSING`) and God of Wine (`ADJUST_EXTRA_ENTERTAINMENT`). Mutually exclusive: housing `2≤dev<4` → +1 / `dev≥4` → +2; wine `3≤dev<5` → +1 / `dev≥5` → +2. Share `PROP_CP_DEV_*`; Lua also writes city-center plots for those powers.
- **Exclusive band flags (v15):** Inverse on `PLOT_PROPERTY_MATCHES` failed — LO+HI both active → Sea harbor `(1+1+3)×2=10` admiral. Lua now writes mutually exclusive `PROP_CP_B24_LO/HI` and `PROP_CP_B35_LO/HI` (0/1); SQL gates on those flags only.
- **AI all-pick 家神:** `ScorePower(RELIGIOUS_SETTLEMENTS)` early bonus was +1.5 → 2.50 (highest of any power); × godhood flooded Top-K. Lowered to +0.85; added soft `PowerDiversityMul` so taken powers are downweighted.
- **Divine Spark Lavra path (v16):** stopped modifying district GPP. Lua now grants one mutually exclusive LO/HI marker building to the owning city; `MODIFIER_PLAYER_CITIES_ADJUST_GREAT_PERSON_POINT_BASE` supplies +1/+3 as an independent city source, matching the Lavra trait pattern.
- **Adjacent devotion + deterministic Miracle grants (v17):** district devotion now counts only the six adjacent plots (the underlying tile keeps its separate tile-devotion value). God of Miracles maps every `DistrictReplaces` row to its base district and grants exactly one tier-1 building: keep an existing player choice, otherwise prefer the civilization's `BuildingReplaces`, then use a district preset and a stable fallback. Encampments default to Stable (Mongolia receives Ordu); Government Plaza is skipped because its buildings are mutually exclusive strategic choices. Combo text now says “adjacent six tiles” explicitly.
- **Miracle grant on district completion (v18):** `DistrictAddedToMap` only caches devotion while the district is incomplete. On `DistrictBuildProgressChanged` (complete) devotion is recomputed from the six adjacent tiles, then a tier-1 building is granted and verified with `HasBuilding`; failures set `PROP_CP_MIRACLE_PENDING` for retry. Load FullScan remains the fallback. Tier-1 grants now require `PrereqTech`/`PrereqCivic` (Encampment: Stable/Ordu only after Horseback Riding, otherwise Barracks); `ResearchCompleted`/`CivicCompleted` retry pending grants.
- **Load devotion rescan (v18):** `RescanAllMiraclePlayers` now FullScans Spark / Religious Settlements / God of Wine players as well as Miracles (previously housing/wine were skipped on load).
- **PENDING VERIFY (效果待测待查):** Divine Spark v16 city GPP must be tested in a fresh game, including Russia/Lavra overlap and save/load; v17/v18 Miracle grants need Lavra/Harbor completion + tech-gated Encampment paths; housing/wine load rescan rewritten but still needs in-game confirm. Do not treat GPP/housing/amenity as confirmed fixed until retested.

Do **not** enable this Dev mod together with the Workshop original.
