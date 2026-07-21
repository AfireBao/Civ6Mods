"""Decision prompt / archive markdown formatting helpers."""

from __future__ import annotations

from civ_mcp import haikesi_llm
from civ_mcp.lua import haikesi as haikesi_lua
from civ_mcp.lua.haikesi import LeaderView


def test_strip_civ_icons_mixed_case():
    raw = "获得+2 [Icon_Faith] 信仰值和 +3 [ICON_Gold] 金币。"
    cleaned = haikesi_lua._strip_civ_icons(raw)
    assert "[Icon_" not in cleaned
    assert "[ICON_" not in cleaned
    assert "信仰值" in cleaned


def test_historical_hexes_dedupe_effect_text():
    payload = {
        "ai_players": [
            {
                "player_id": 1,
                "civ_label": "LEADER_A",
                "selected": ["NW_AI_DRINK_TEA", "NW_AI_MAMA_BORN"],
            },
            {
                "player_id": 2,
                "civ_label": "LEADER_B",
                "selected": ["NW_AI_DRINK_TEA"],
            },
        ]
    }
    text = haikesi_llm._format_historical_hexes_public(payload)
    assert "持有（仅名称）" in text
    assert "效果说明（同词条只列一次）" in text
    assert text.count("NW_AI_DRINK_TEA:") == 1
    assert "LEADER_A：" in text
    assert "LEADER_B：" in text
    assert "饮茶先啦" in text


def test_leader_sections_not_absorbed_into_trait_list():
    """Blank line after trait bullets so 【本国国力】/城表可独立成段并渲染表格。"""
    view = LeaderView(
        player_id=1,
        civ_name="波斯",
        leader_name="纳迪尔沙阿",
        score=11,
        cities=1,
        pop=1,
        sci=2.7,
        cul=1.4,
        gold=7.2,
        mil=20,
        current_research="制陶术",
        current_civic="法典",
        leader_traits=[("波斯之剑", "攻击+5。+2 [Icon_Faith] 信仰")],
        agendas=[("贾扎耶尔契精英兵团", "喜欢拥有大量陆地单位的文明。")],
    )
    ai = {
        "player_id": 1,
        "options": ["NW_AI_STATS_3"],
        "selected": ["NW_AI_MILK_DRAGON"],
    }
    block = haikesi_llm._format_leader_block(ai, view, human_player_id=0)
    assert "[Icon_Faith]" not in block
    assert "【你的身份】" in block and "【本国国力】" in block
    idx = block.index("【本国国力】")
    assert block[idx - 2 : idx] == "\n\n"
    assert "| 项 | 值 |" in block
    assert "【历史库存摘要】" in block
    hist_idx = block.index("【历史库存摘要】")
    assert "\n（完整效果见上文" in block[hist_idx:]


def test_mutual_trade_relics_share_delayed_tag():
    for relic in (
        "NW_AI_CELESTIAL_EMPIRE",
        "NW_AI_FERTILE_CRESCENT",
        "NW_AI_PAX_ROMANA",
    ):
        assert "商路" in haikesi_lua.relic_timing_tag(relic)
        assert "入向" in haikesi_lua.relic_timing_tag(relic, intl_inbound=2)


def test_parse_trade_wire_into_leader_view():
    views, _ = haikesi_lua.parse_leader_views(
        [
            "VIEWER|2|马普切|劳塔罗|90|4|12|48.5|41.5|26.0|190|8|8|5.0|建筑学|戏剧和诗歌|0",
            "TRADE|2|2|1|0|1|0",
            "TROUTE|2|OUT|intl|特木科|蒙古|卡拉库姆",
        ]
    )
    v = views[2]
    assert v.trade is not None
    assert v.trade.capacity == 2
    assert v.trade.active == 1
    assert v.trade.intl_out == 1
    assert v.trade.intl_in == 0
    assert len(v.trade.routes) == 1
    assert v.trade.routes[0].direction == "OUT"
    block = haikesi_llm._trade_block(v)
    assert "国际入向 0" in block
    assert "特木科→蒙古·卡拉库姆" in block


def test_markdownify_keeps_blank_line_before_gfm_table():
    raw = (
        "【本国城市】\n"
        "| 城名 | 人口 |\n"
        "| --- | --- |\n"
        "| 甲 | 1 |\n"
        "【与人类】\n"
        "已接触"
    )
    md = haikesi_llm.markdownify_pipe_tables(raw)
    assert "【本国城市】\n\n| 城名 |" in md
