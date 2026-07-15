"""Tests for per-viewer victory progress rankings in ExtAI prompts."""

from __future__ import annotations

from civ_mcp.lua import haikesi as haikesi_lua
from civ_mcp.lua.haikesi import LeaderView, VictoryPeerStat
from civ_mcp.lua.models import GameOverview
from civ_mcp.haikesi_llm import (
    HaikesiGameContext,
    _victory_rank_block,
    build_decision_prompt,
)


def test_parse_vstat_into_leader_view():
    lines = [
        "RST_MOD|0",
        "VIEWER|1|匈牙利|匈雅提|40|2|4|5.0|3.0|8.0|120|2|1|2.0|写作|技艺",
        "VSTAT|1|1|匈牙利|40|0|50|0|2|120|2|1|0|0|1|10",
        "VSTAT|1|0|马普切|37|0|50|0|1|27|0|1|0|0|1|5",
        "---END---",
    ]
    views, _ = haikesi_lua.parse_leader_views(lines)
    assert len(views[1].victory_peers) == 2
    assert views[1].victory_peers[0].player_id == 1
    assert views[1].victory_peers[1].civ_name == "马普切"


def test_victory_rank_block_and_prompt():
    view = LeaderView(
        player_id=1,
        civ_name="匈牙利",
        leader_name="匈雅提",
        victory_peers=[
            VictoryPeerStat(
                player_id=1,
                civ_name="匈牙利",
                score=40,
                science_vp=0,
                techs=2,
                mil=200,
                tourism=3,
            ),
            VictoryPeerStat(
                player_id=2,
                civ_name="巴比伦",
                score=58,
                science_vp=0,
                techs=7,
                mil=100,
                tourism=1,
            ),
            VictoryPeerStat(
                player_id=0,
                civ_name="马普切",
                score=37,
                science_vp=0,
                techs=0,
                mil=27,
                tourism=0,
            ),
        ],
    )
    block = _victory_rank_block(view)
    assert "【已知文明胜利进度排名】" in block
    assert "分数:" in block
    assert "我#" in block
    assert "巴比伦" in block

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
    )
    prompt = build_decision_prompt(
        {
            "turn": 21,
            "human_relic": "X",
            "invasion_mutex": False,
            "ai_players": [
                {"player_id": 1, "options": ["NW_AI_STATS_2"], "selected": []}
            ],
        },
        HaikesiGameContext(overview=overview, leader_views={1: view}, human_player_id=0),
    )
    assert "已知文明胜利进度排名" in prompt
    assert "已知胜利进度排名" in prompt
