"""Unit tests for Real Strategy soft-read parsing / prompt formatting."""

from __future__ import annotations

from civ_mcp.lua import haikesi as haikesi_lua
from civ_mcp.haikesi_llm import _rst_block, build_decision_prompt
from civ_mcp.lua.haikesi import LeaderView, RstStrategyView
from civ_mcp.lua.models import GameOverview
from civ_mcp.haikesi_llm import HaikesiGameContext


def test_parse_rst_strategies_absent():
    views, avail = haikesi_lua.parse_rst_strategies(["RST_MOD|0", "---END---"])
    assert avail is False
    assert views == {}


def test_parse_rst_strategies_present():
    lines = [
        "RST_MOD|1",
        "RST|3|SCIENCE|10.0|80.5|20.0|5.0|15.0|0|1",
        "---END---",
    ]
    views, avail = haikesi_lua.parse_rst_strategies(lines)
    assert avail is True
    assert 3 in views
    assert views[3].active_strategy == "SCIENCE"
    assert views[3].priorities["SCIENCE"] == 80.5
    assert views[3].active_defense is False
    assert views[3].active_catching is True


def test_parse_leader_views_merges_rst():
    lines = [
        "RST_MOD|1",
        "VIEWER|2|巴比伦|汉谟拉比|50|2|5|10.0|4.0|8.0|100|3|2|0.0|写作|技艺",
        "RST|2|CONQUEST|90.0|40.0|30.0|10.0|20.0|1|0",
        "---END---",
    ]
    views, avail = haikesi_lua.parse_leader_views(lines)
    assert avail is True
    assert views[2].rst is not None
    assert views[2].rst.active_strategy == "CONQUEST"
    assert views[2].rst.active_defense is True


def test_rst_block_and_prompt_include_strategy():
    view = LeaderView(
        player_id=1,
        civ_name="匈牙利",
        leader_name="匈雅提",
        rst=RstStrategyView(
            active_strategy="CONQUEST",
            priorities={
                "CONQUEST": 100,
                "SCIENCE": 40,
                "CULTURE": 30,
                "RELIGION": 10,
                "DIPLO": 20,
            },
            active_defense=False,
            active_catching=True,
        ),
    )
    block = _rst_block(view)
    assert "主战略: 征服" in block
    assert "军力追赶态势开启" in block

    overview = GameOverview(
        turn=21,
        player_id=0,
        civ_name="马普切",
        leader_name="莱夫扎茹",
        gold=0,
        gold_per_turn=0,
        science_yield=0,
        culture_yield=0,
        faith=0,
        current_research="",
        current_civic="",
        num_cities=1,
        num_units=1,
        era_name="远古时代",
        difficulty="神",
        game_speed="GAMESPEED_STANDARD",
        game_speed_name="标准",
    )
    ctx = HaikesiGameContext(
        overview=overview,
        leader_views={1: view},
        human_player_id=0,
    )
    payload = {
        "turn": 21,
        "human_relic": "ORBSYMBIOSISRUNE",
        "invasion_mutex": False,
        "ai_players": [
            {
                "player_id": 1,
                "options": ["NW_AI_STATS_2"],
                "selected": [],
            }
        ],
    }
    prompt = build_decision_prompt(payload, ctx)
    assert "Real Strategy 战略意图" in prompt
    assert "主战略: 征服" in prompt
    assert "仅作选卡倾向参考" in prompt or "主战略仅作倾向" in prompt


def test_build_rst_query_soft():
    lua = haikesi_lua.build_rst_strategies_query([1, 4])
    assert "ExposedMembers.RST" in lua
    assert "RST_MOD|" in lua
    assert "1" in lua and "4" in lua
