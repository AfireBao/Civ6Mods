"""ExtAI dual-pick wire / AI line parsing for golden-heroic ages."""

from __future__ import annotations

from civ_mcp.extai_log_channel import encode_extai_apply_payload
from civ_mcp.lua import haikesi as haikesi_lua


def test_parse_ai_line_picks_and_age():
    line = (
        "AI|2|LEADER_X|NW_AI_A,NW_AI_B,NW_AI_C,NW_AI_D,NW_AI_E,NW_AI_F|"
        "selected:NW_AI_OLD|name:Rome|picks:2|age:GOLDEN"
    )
    ai = haikesi_lua._parse_ai_line(line)
    assert ai is not None
    assert ai["player_id"] == 2
    assert ai["picks"] == 2
    assert ai["age"] == "GOLDEN"
    assert len(ai["options"]) == 6


def test_normalize_extai_choices_list_and_plus():
    ais = [{"player_id": 2, "picks": 2}, {"player_id": 3, "picks": 1}]
    out = haikesi_lua.normalize_extai_choices(
        {
            "2": ["NW_AI_A", "NW_AI_B"],
            "3": "NW_AI_C",
        },
        ais,
    )
    assert out["2"] == "NW_AI_A+NW_AI_B"
    assert out["3"] == "NW_AI_C"
    out2 = haikesi_lua.normalize_extai_choices({"2": "NW_AI_A+NW_AI_B"}, ais)
    assert out2["2"] == "NW_AI_A+NW_AI_B"


def test_encode_wire_accepts_plus_dual_pick():
    wire = encode_extai_apply_payload(
        "10_0_0_1",
        {"2": "NW_AI_A+NW_AI_B", "3": "NW_AI_C"},
        None,
        max_wire_len=505,
    )
    assert wire.startswith("10_0_0_1#")
    assert "2=NW_AI_A+NW_AI_B*" in wire
    assert "3=NW_AI_C*" in wire
    # MP completeness still counts AI entries, not relics
    assert wire.count("=") == 2
