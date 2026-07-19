"""Tests for per-game decision archive."""

from __future__ import annotations

import json

from civ_mcp.decision_archive import DecisionArchive, GameSessionKey, reset_decision_archive_cache
from civ_mcp.lua.haikesi import parse_game_session_value


def test_parse_game_session_value():
    parsed = parse_game_session_value("998877|Continents.lua|MAPSIZE_STANDARD|0|Germany")
    assert parsed["seed"] == "998877"
    assert parsed["map_script"] == "Continents.lua"
    assert parsed["requester"] == 0
    assert parsed["requester_civ"] == "Germany"


def test_decision_archive_new_session_on_seed_change(tmp_path):
    reset_decision_archive_cache()
    archive = DecisionArchive(tmp_path)
    payload_a = {
        "turn": 2,
        "requester": 0,
        "human_relic": "FOO",
        "game_session": parse_game_session_value("111|MapA|SMALL|0|Rome"),
    }
    path_a = archive.append_decision(
        payload_a,
        body="decision A",
        request_id="2_0_0",
        model="test-model",
    )
    assert path_a.is_file()
    assert path_a.suffix == ".md"
    assert (tmp_path / "index.jsonl").exists() is False
    assert (path_a.parent / "index.jsonl").is_file()

    payload_b = {
        "turn": 2,
        "requester": 0,
        "human_relic": "BAR",
        "game_session": parse_game_session_value("222|MapB|SMALL|0|Rome"),
    }
    path_b = archive.append_decision(
        payload_b,
        body="decision B",
        request_id="2_0_0",
        model="test-model",
    )
    assert path_a.parent != path_b.parent
    assert len(list(tmp_path.iterdir())) >= 3  # two session dirs + .active_session.json


def test_decision_archive_reuses_session(tmp_path):
    reset_decision_archive_cache()
    archive = DecisionArchive(tmp_path)
    payload = {
        "turn": 5,
        "requester": 0,
        "game_session": parse_game_session_value("555|Map|STD|0|Korea"),
    }
    p1 = archive.append_decision(payload, body="one", request_id="5_1_0", model="m")
    payload["turn"] = 8
    p2 = archive.append_decision(payload, body="two", request_id="8_2_0", model="m")
    assert p1.parent == p2.parent
    index_lines = (p1.parent / "index.jsonl").read_text(encoding="utf-8").strip().splitlines()
    assert len(index_lines) == 2
    session = json.loads((p1.parent / "session.json").read_text(encoding="utf-8"))
    assert session["decision_count"] == 2


def test_decision_archive_keeps_same_turn_reselects(tmp_path):
    """同 request_id、不同 human_relic 的重测应保留各自文件，不互相覆盖。"""
    reset_decision_archive_cache()
    archive = DecisionArchive(tmp_path)
    payload = {
        "turn": 110,
        "requester": 0,
        "human_relic": "BLADEWALTZRUNE",
        "game_session": parse_game_session_value("700|Map|STD|0|Aztec"),
    }
    p1 = archive.append_decision(
        payload, body="blade", request_id="110_10_0_1", model="m"
    )
    payload["human_relic"] = "ETERNALBANDRUNE"
    p2 = archive.append_decision(
        payload, body="band", request_id="110_10_0_2", model="m"
    )
    assert p1 != p2
    assert p1.is_file() and p2.is_file()
    assert "BLADEWALTZRUNE" in p1.name
    assert "ETERNALBANDRUNE" in p2.name
    assert p1.read_text(encoding="utf-8") == "blade"
    assert p2.read_text(encoding="utf-8") == "band"
