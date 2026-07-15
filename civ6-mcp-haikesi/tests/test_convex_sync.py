"""Unit tests for pure helper functions in convex_sync.py."""

import json
import sys
from pathlib import Path

# convex_sync.py is a standalone script, not a package — add scripts/ to path
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "scripts"))

from convex_sync import (
    _chunk_map_frames,
    _extract_outcome,
    _extract_outcome_from_tool_calls,
    classify_file,
    extract_game_id,
)


# ---------------------------------------------------------------------------
# classify_file
# ---------------------------------------------------------------------------


class TestClassifyFile:
    def test_diary(self):
        assert classify_file("diary_india_123.jsonl") == "diary"

    def test_cities(self):
        assert classify_file("diary_india_123_cities.jsonl") == "cities"

    def test_spatial(self):
        assert classify_file("spatial_india_123.jsonl") == "spatial"

    def test_mapturns(self):
        assert classify_file("mapturns_india_123.jsonl") == "mapturns"

    def test_unknown(self):
        assert classify_file("random_file.txt") is None

    def test_wrong_suffix(self):
        assert classify_file("diary_india_123.txt") is None

    def test_cities_takes_priority_over_diary(self):
        """Cities suffix is checked before diary prefix."""
        result = classify_file("diary_foo_cities.jsonl")
        assert result == "cities"


# ---------------------------------------------------------------------------
# extract_game_id
# ---------------------------------------------------------------------------


class TestExtractGameId:
    def test_diary(self):
        assert extract_game_id("diary_india_123.jsonl") == "india_123"

    def test_cities(self):
        assert extract_game_id("diary_india_123_cities.jsonl") == "india_123"

    def test_spatial(self):
        assert extract_game_id("spatial_india_123.jsonl") == "india_123"

    def test_mapturns(self):
        assert extract_game_id("mapturns_india_123.jsonl") == "india_123"

    def test_mapstatic(self):
        assert extract_game_id("mapstatic_india_123.json") == "india_123"

    def test_complex_game_id(self):
        """Game IDs with multiple underscores and hash suffixes."""
        assert (
            extract_game_id("diary_babylon_stk_-1851106432_4fee9865.jsonl")
            == "babylon_stk_-1851106432_4fee9865"
        )


# ---------------------------------------------------------------------------
# _extract_outcome
# ---------------------------------------------------------------------------


class TestExtractOutcome:
    def test_no_game_over(self):
        lines = [
            json.dumps({"type": "turn_start", "turn": 1}),
            json.dumps({"type": "action", "tool": "move"}),
        ]
        assert _extract_outcome(lines) is None

    def test_victory(self):
        lines = [
            json.dumps({"type": "turn_start", "turn": 100}),
            json.dumps(
                {
                    "type": "game_over",
                    "turn": 100,
                    "outcome": {
                        "is_defeat": False,
                        "winner_civ": "CIVILIZATION_INDIA",
                        "winner_leader": "Gandhi",
                        "victory_type": "SCIENCE",
                        "player_alive": True,
                    },
                }
            ),
        ]
        result = _extract_outcome(lines)
        assert result is not None
        assert result["result"] == "victory"
        assert result["winnerCiv"] == "CIVILIZATION_INDIA"
        assert result["winnerLeader"] == "Gandhi"
        assert result["victoryType"] == "SCIENCE"
        assert result["turn"] == 100
        assert result["playerAlive"] is True

    def test_defeat(self):
        lines = [
            json.dumps(
                {
                    "type": "game_over",
                    "turn": 200,
                    "outcome": {
                        "is_defeat": True,
                        "winner_civ": "CIVILIZATION_SUMERIA",
                        "winner_leader": "Gilgamesh",
                        "victory_type": "DOMINATION",
                        "player_alive": False,
                    },
                }
            ),
        ]
        result = _extract_outcome(lines)
        assert result["result"] == "defeat"
        assert result["playerAlive"] is False

    def test_malformed_json_skipped(self):
        lines = [
            "this is not json",
            json.dumps({"type": "game_over", "turn": 50, "outcome": {}}),
        ]
        result = _extract_outcome(lines)
        assert result is not None
        assert result["result"] == "victory"  # is_defeat defaults falsy
        assert result["turn"] == 50

    def test_multiple_game_over_last_wins(self):
        lines = [
            json.dumps(
                {"type": "game_over", "turn": 50, "outcome": {"winner_civ": "A"}}
            ),
            json.dumps(
                {"type": "game_over", "turn": 100, "outcome": {"winner_civ": "B"}}
            ),
        ]
        result = _extract_outcome(lines)
        assert result["winnerCiv"] == "B"
        assert result["turn"] == 100

    def test_empty_lines(self):
        assert _extract_outcome([]) is None


# ---------------------------------------------------------------------------
# _extract_outcome_from_tool_calls
# ---------------------------------------------------------------------------


class TestExtractOutcomeFromToolCalls:
    def test_defeat_from_end_turn_result(self):
        lines = [
            json.dumps(
                {"type": "tool_call", "tool": "get_units", "turn": 320, "result": "..."}
            ),
            json.dumps(
                {
                    "type": "tool_call",
                    "tool": "end_turn",
                    "turn": 326,
                    "result": (
                        "GAME OVER — DEFEAT. Hojo Tokimune of Japan won a Culture victory. "
                        "The game has ended. No further actions are possible."
                    ),
                }
            ),
        ]
        result = _extract_outcome_from_tool_calls(
            lines, civ="Babylon", leader="Hammurabi"
        )
        assert result is not None
        assert result["result"] == "defeat"
        assert result["winnerLeader"] == "Hojo Tokimune"
        assert result["winnerCiv"] == "Japan"
        assert result["victoryType"] == "Culture"
        assert result["turn"] == 326
        assert result["playerAlive"] is True

    def test_victory_from_end_turn_result(self):
        lines = [
            json.dumps(
                {
                    "type": "tool_call",
                    "tool": "end_turn",
                    "turn": 238,
                    "result": (
                        "Turn 237 -> 238\n"
                        "GAME OVER — VICTORY! You won a Technology victory! The game has ended."
                    ),
                }
            ),
        ]
        result = _extract_outcome_from_tool_calls(
            lines, civ="Babylon", leader="Hammurabi"
        )
        assert result is not None
        assert result["result"] == "victory"
        assert result["winnerCiv"] == "Babylon"
        assert result["winnerLeader"] == "Hammurabi"
        assert result["victoryType"] == "Technology"
        assert result["turn"] == 238
        assert result["playerAlive"] is True

    def test_no_game_over_in_tool_calls(self):
        lines = [
            json.dumps(
                {
                    "type": "tool_call",
                    "tool": "end_turn",
                    "turn": 10,
                    "result": "Turn 10 -> 11",
                }
            ),
            json.dumps(
                {"type": "tool_call", "tool": "get_units", "turn": 11, "result": "..."}
            ),
        ]
        assert _extract_outcome_from_tool_calls(lines) is None

    def test_ignores_non_tool_call_entries(self):
        lines = [
            json.dumps({"type": "game_over", "turn": 100, "outcome": {}}),
            json.dumps({"type": "diary", "turn": 100}),
        ]
        assert _extract_outcome_from_tool_calls(lines) is None

    def test_empty_lines(self):
        assert _extract_outcome_from_tool_calls([]) is None

    def test_elimination_detected(self):
        lines = [
            json.dumps(
                {
                    "type": "tool_call",
                    "tool": "end_turn",
                    "turn": 150,
                    "result": (
                        "GAME OVER — DEFEAT. Alexander of Macedon won a Domination victory. "
                        "You have been eliminated. The game has ended."
                    ),
                }
            ),
        ]
        result = _extract_outcome_from_tool_calls(
            lines, civ="Egypt", leader="Cleopatra"
        )
        assert result is not None
        assert result["result"] == "defeat"
        assert result["playerAlive"] is False


# ---------------------------------------------------------------------------
# _chunk_map_frames
# ---------------------------------------------------------------------------


class TestChunkMapFrames:
    def test_empty_input(self):
        assert _chunk_map_frames([]) == []

    def test_single_turn_fits_one_chunk(self):
        entries = [
            {
                "turn": 1,
                "owners": [10, 0, 15, 1],  # 2 ownership changes
                "cities": [{"x": 5, "y": 6, "pid": 0, "pop": 3}],
                "roads": [],
            }
        ]
        chunks = _chunk_map_frames(entries)
        assert len(chunks) == 1
        # Verify the packed format
        owners = json.loads(chunks[0]["ownerFrames"])
        assert owners[0] == 1  # turn
        assert owners[1] == 2  # count (4 ints / 2)
        assert owners[2:] == [10, 0, 15, 1]

        cities = json.loads(chunks[0]["cityFrames"])
        assert cities[0] == 1  # turn
        assert cities[1] == 1  # count
        assert cities[2:] == [5, 6, 0, 3]

    def test_empty_fields(self):
        """Turn with no changes — nothing to pack, so no chunks emitted."""
        entries = [{"turn": 5, "owners": [], "cities": [], "roads": []}]
        chunks = _chunk_map_frames(entries)
        assert len(chunks) == 0

    def test_round_trip_multiple_turns(self):
        """Multiple turns in one chunk should concatenate correctly."""
        entries = [
            {"turn": 1, "owners": [0, 1], "cities": [], "roads": []},
            {"turn": 2, "owners": [5, 2, 6, 3], "cities": [], "roads": []},
        ]
        chunks = _chunk_map_frames(entries)
        assert len(chunks) == 1
        owners = json.loads(chunks[0]["ownerFrames"])
        # Turn 1: [1, 1, 0, 1] + Turn 2: [2, 2, 5, 2, 6, 3]
        assert owners == [1, 1, 0, 1, 2, 2, 5, 2, 6, 3]

    def test_large_data_splits(self):
        """Data exceeding chunk limit should produce multiple chunks."""
        # Create entries large enough to exceed the 700KB limit
        # Each int takes ~5 chars in JSON, so 200K ints ~ 1MB
        big_owners = list(range(200_000))
        entries = [
            {"turn": i, "owners": big_owners, "cities": [], "roads": []}
            for i in range(3)
        ]
        chunks = _chunk_map_frames(entries)
        assert len(chunks) > 1
        # Each chunk should be valid JSON
        for chunk in chunks:
            json.loads(chunk["ownerFrames"])
            json.loads(chunk["cityFrames"])
            json.loads(chunk["roadFrames"])
