"""Game speed turn scaling for prompt phase heuristics."""

from __future__ import annotations

from civ_mcp.haikesi_llm import HaikesiGameContext, _early_game_rules, _resolve_game_speed
from civ_mcp.lua.haikesi import (
    early_game_phase_thresholds,
    parse_game_speed_value,
    scale_turn_for_game_speed,
)
from civ_mcp.lua.models import GameOverview


def _empty_overview() -> GameOverview:
    return GameOverview(
        turn=0,
        player_id=0,
        civ_name="",
        leader_name="",
        gold=0.0,
        gold_per_turn=0.0,
        science_yield=0.0,
        culture_yield=0.0,
        faith=0.0,
        current_research="",
        current_civic="",
        num_cities=0,
        num_units=0,
    )


def test_scale_turn_for_game_speed():
    assert scale_turn_for_game_speed(40, cost_multiplier=100) == 40
    assert scale_turn_for_game_speed(40, cost_multiplier=67) == 27
    assert scale_turn_for_game_speed(40, cost_multiplier=150) == 60
    assert scale_turn_for_game_speed(40, cost_multiplier=300) == 120
    assert scale_turn_for_game_speed(15, cost_multiplier=67) == 10
    assert scale_turn_for_game_speed(40, cost_multiplier=50) == 20


def test_early_game_rules_online_default():
    """MP without CTX speed → Online Cost×50 → ancient_end≈20."""
    ctx = HaikesiGameContext(
        overview=_empty_overview(),
        leader_views={},
        human_player_id=0,
        fetch_notes=["联机 LOG 通道：..."],
    )
    mult, name, defaulted = _resolve_game_speed(ctx, {"mp": True, "turn": 2})
    assert mult == 50
    assert defaulted is True
    rule = _early_game_rules(2, cost_multiplier=mult, speed_name=name)
    assert "T1–T20" in rule


def test_parse_game_speed_value():
    parsed = parse_game_speed_value("联机|50")
    assert parsed["cost_multiplier"] == 50
    assert parsed["name"] == "联机"
    with_type = parse_game_speed_value("联机|50|GAMESPEED_ONLINE")
    assert with_type["type"] == "GAMESPEED_ONLINE"
    assert with_type["cost_multiplier"] == 50


def test_resolve_game_speed_from_overview_type():
    """SPEED| typed wire must beat SP default Standard×100."""
    ov = _empty_overview()
    ov.game_speed = "GAMESPEED_ONLINE"
    ov.game_speed_name = "联机"
    ov.speed_cost_multiplier = 50
    ctx = HaikesiGameContext(overview=ov, human_player_id=0)
    mult, name, defaulted = _resolve_game_speed(ctx, {})
    assert defaulted is False
    assert mult == 50
    assert name == "联机"


def test_resolve_game_speed_empty_overview_defaults():
    """Unparsed overview (empty name, default mult=100) must not pretend Standard was read."""
    ctx = HaikesiGameContext(overview=_empty_overview(), human_player_id=0)
    mult, name, defaulted = _resolve_game_speed(ctx, {})
    assert defaulted is True
    assert mult == 100
    assert name == "标准"


def test_resolve_from_payload_with_type_only():
    ctx = HaikesiGameContext(overview=_empty_overview(), human_player_id=0)
    mult, name, defaulted = _resolve_game_speed(
        ctx,
        {"game_speed": {"name": "", "cost_multiplier": 50, "type": "GAMESPEED_ONLINE"}},
    )
    assert defaulted is False
    assert mult == 50
    assert name == "联机"


def test_early_game_rules_quick_vs_marathon():
    std_rule = _early_game_rules(30, cost_multiplier=100, speed_name="标准")
    quick_rule = _early_game_rules(20, cost_multiplier=67, speed_name="快速")
    assert "T1–T40" in std_rule
    assert "T1–T27" in quick_rule
    marathon_rule = _early_game_rules(80, cost_multiplier=300, speed_name="马拉松")
    assert "T1–T120" in marathon_rule
    assert early_game_phase_thresholds(cost_multiplier=150)["ancient_end"] == 60
