"""Resource-spawn hex descriptions include tile yields in ExtAI prompts."""

from __future__ import annotations

from civ_mcp.lua import haikesi as haikesi_lua


def setup_function() -> None:
    haikesi_lua.clear_relic_catalog_cache()


def test_resource_spawn_map_loaded():
    mapping = haikesi_lua.get_resource_spawn_map()
    assert mapping["NW_AI_SILK_LAND"] == "RESOURCE_SILK"
    assert mapping["NW_AI_MILK_DRAGON"] == "RESOURCE_SUGAR"
    assert mapping["NW_AI_BRAVE_WOOD"] == "RESOURCE_COTTON"


def test_option_lines_include_tile_yields():
    lines = haikesi_lua.format_option_lines(
        ["NW_AI_SILK_LAND", "NW_AI_MILK_DRAGON", "NW_AI_STATS_2"],
        cities=1,
    )
    silk = next(x for x in lines if "SILK_LAND" in x)
    sugar = next(x for x in lines if "MILK_DRAGON" in x)
    stats = next(x for x in lines if "STATS_2" in x)
    assert "RESOURCE_SILK" in silk
    assert "YIELD_CULTURE" in silk
    assert "amenity" in silk
    assert "需已有城市" in silk
    assert "RESOURCE_SUGAR" in sugar
    assert "YIELD_FOOD" in sugar
    assert "YIELD_SCIENCE" in stats
    assert "—" in stats


def test_ai_llm_descriptions_use_keys_not_cn_nouns():
    lines = haikesi_lua.format_option_lines(
        [
            "NW_AI_SPY_BUREAU",
            "NW_AI_WALL_ENGINEERING",
            "NW_AI_ECHO_MELEE",
            "NW_AI_CELESTIAL_EMPIRE",
        ],
        cities=1,
    )
    spy = next(x for x in lines if "SPY_BUREAU" in x)
    wall = next(x for x in lines if "WALL_ENGINEERING" in x)
    echo = next(x for x in lines if "ECHO_MELEE" in x)
    trade = next(x for x in lines if "CELESTIAL" in x)
    assert "UNIT_SPY" in spy
    assert "CIVIC_DIPLOMATIC_SERVICE" in spy
    assert "间谍" not in spy.split("—", 1)[-1]
    assert "BUILDING_WALLS" in wall
    assert "BUILDING_CASTLE" in wall
    assert "BUILDING_STAR_FORT" in wall
    assert "CLASS_MELEE" in echo
    assert "近战" not in echo.split("—", 1)[-1]
    assert "YIELD_SCIENCE" in trade
    assert "[ICON_" not in trade


def test_resource_spawn_tag_warns_when_zero_cities():
    zero = haikesi_lua.format_option_lines(["NW_AI_MAMA_BORN"], cities=0)[0]
    one = haikesi_lua.format_option_lines(["NW_AI_MAMA_BORN"], cities=1)[0]
    assert "空放" in zero and "0城" in zero
    assert "需已有城市" in one
    assert "空放" not in one


def test_format_resource_tile_yield_note_uses_keys():
    note = haikesi_lua.format_resource_tile_yield_note("RESOURCE_TEA")
    assert "YIELD_SCIENCE" in note
    assert "+1 YIELD_SCIENCE" in note
    assert "amenity" in note
    assert "RESOURCE_TEA" in note
    # Overlay already has full note; enrich should not double-append
    desc = haikesi_lua.AI_LLM_DESCRIPTIONS["NW_AI_DRINK_TEA"]
    out = haikesi_lua.enrich_relic_description("NW_AI_DRINK_TEA", desc)
    assert out.count("Vanilla tile") == 1
    assert "YIELD_SCIENCE" in out
