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
    assert "文化+1" in silk or "+1文化" in silk or "文化" in silk
    assert "原版固有收益" in silk or "奢侈品本身" in silk
    assert "需已有城市" in silk
    assert "宜居" in silk
    assert "食物+2" in sugar or "+2食物" in sugar or "食物" in sugar
    assert "创建" not in stats or "资源" not in stats  # non-spawn unchanged shape
    assert "—" in stats


def test_resource_spawn_tag_warns_when_zero_cities():
    zero = haikesi_lua.format_option_lines(["NW_AI_MAMA_BORN"], cities=0)[0]
    one = haikesi_lua.format_option_lines(["NW_AI_MAMA_BORN"], cities=1)[0]
    assert "空放" in zero and "0城" in zero
    assert "需已有城市" in one
    assert "空放" not in one


def test_enrich_avoids_duplicate_when_xml_has_yields():
    note = haikesi_lua.format_resource_tile_yield_note("RESOURCE_TEA")
    assert "科技+1" in note
    assert "原版固有收益" in note
    # XML already clarifies vanilla luxury yields; enrich should not double-append
    desc = (
        "创建茶。以下为该奢侈品本身的原版固有收益（非本词条额外加成）："
        "茶地块+1科技；需改良后收获，并提供奢侈品宜居。"
    )
    out = haikesi_lua.enrich_relic_description("NW_AI_DRINK_TEA", desc)
    assert out.count("原版固有收益") == 1
    assert "科技" in out
