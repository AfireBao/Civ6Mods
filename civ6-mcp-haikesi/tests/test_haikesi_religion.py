"""Tests for civ pantheon / religion belief queries and ExtAI prompt wiring."""

from __future__ import annotations

from civ_mcp.lua import religion as religion_lua
from civ_mcp.lua import haikesi as haikesi_lua
from civ_mcp.lua.haikesi import LeaderView
from civ_mcp.lua.models import CivReligionBeliefs, GameOverview, ReligionBeliefOption
from civ_mcp.haikesi_llm import HaikesiGameContext, _religion_block, build_decision_prompt


def test_parse_civ_religion_beliefs():
    lines = [
        "FAITH|2|巴比伦|汉谟拉比|BELIEF_DIVINE_SPARK|神圣火花|RELIGION_BUDDHISM|佛教",
        "FBELIEF|2|BELIEF_CLASS_PANTHEON|BELIEF_DIVINE_SPARK|神圣火花|伟人点数+1",
        "FBELIEF|2|BELIEF_CLASS_FOLLOWER|BELIEF_WORK_ETHIC|工作伦理|圣地+生产力",
        "FBELIEF|2|BELIEF_CLASS_FOUNDER|BELIEF_CHURCH_PROPERTY|教会财产|信徒城+金币",
        "---END---",
    ]
    rows = religion_lua.parse_civ_religion_beliefs_response(lines)
    assert len(rows) == 1
    r = rows[0]
    assert r.player_id == 2
    assert r.pantheon_type == "BELIEF_DIVINE_SPARK"
    assert r.religion_name == "佛教"
    assert len(r.beliefs) == 3


def test_parse_leader_views_faith():
    lines = [
        "RST_MOD|0",
        "VIEWER|1|匈牙利|匈雅提|40|2|4|5.0|3.0|8.0|120|2|1|2.0|写作|技艺",
        "FAITH|1|匈牙利|匈雅提|BELIEF_GOD_OF_THE_FORGE|锻造之神|NONE|",
        "FBELIEF|1|BELIEF_CLASS_PANTHEON|BELIEF_GOD_OF_THE_FORGE|锻造之神|军工单位加速",
        "---END---",
    ]
    views, _ = haikesi_lua.parse_leader_views(lines)
    assert 1 in views
    assert views[1].religion is not None
    assert views[1].religion.pantheon_name == "锻造之神"
    assert views[1].religion.religion_type is None
    assert len(views[1].religion.beliefs) == 1


def test_religion_block_in_prompt():
    view = LeaderView(
        player_id=1,
        civ_name="匈牙利",
        leader_name="匈雅提",
        religion=CivReligionBeliefs(
            player_id=1,
            pantheon_type="BELIEF_DIVINE_SPARK",
            pantheon_name="神圣火花",
            religion_type="RELIGION_BUDDHISM",
            religion_name="佛教",
            beliefs=[
                ReligionBeliefOption(
                    belief_class="BELIEF_CLASS_PANTHEON",
                    belief_type="BELIEF_DIVINE_SPARK",
                    name="神圣火花",
                    description="伟人+1",
                ),
                ReligionBeliefOption(
                    belief_class="BELIEF_CLASS_FOLLOWER",
                    belief_type="BELIEF_WORK_ETHIC",
                    name="工作伦理",
                    description="圣地加产",
                ),
            ],
        ),
    )
    block = _religion_block(view)
    assert "万神殿: 神圣火花" in block
    assert "伟人+1" in block or "—" in block
    assert "创立宗教: 佛教" in block
    assert "[信徒] 工作伦理" in block
    assert "圣地加产" in block

    overview = GameOverview(
        turn=50,
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
    )
    prompt = build_decision_prompt(
        {
            "turn": 50,
            "human_relic": "X",
            "invasion_mutex": False,
            "ai_players": [{"player_id": 1, "options": ["NW_AI_STATS_2"], "selected": []}],
        },
        HaikesiGameContext(overview=overview, leader_views={1: view}, human_player_id=0),
    )
    assert "【本国宗教】" in prompt
    assert "本国万神殿/教义" in prompt


def test_build_civ_religion_query():
    lua = religion_lua.build_civ_religion_beliefs_query([3, 5])
    assert "GetPantheon" in lua
    assert "GetReligions" in lua
    assert "3" in lua and "5" in lua
