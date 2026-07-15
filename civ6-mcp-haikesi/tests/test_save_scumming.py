"""Tests for save-scumming detection in end_turn.py.

Validates that _check_save_scumming correctly distinguishes:
- Clean play (no saves)
- Legitimate deadlock debugging (many loads at a single turn cluster)
- Save scumming (loads spread across distinct turns)
"""

import types

from civ_mcp.end_turn import _check_save_scumming


def _make_gs(history: list[tuple[float, int, str]]) -> types.SimpleNamespace:
    """Build a minimal GameState-like object with just the fields the function reads."""
    return types.SimpleNamespace(
        _save_load_history=history,
        _run_aborted=False,
    )


class TestSaveScumming:
    def test_no_history_no_warning(self):
        gs = _make_gs([])
        events, hard_stop = _check_save_scumming(gs)
        assert events == []
        assert hard_stop is False

    def test_single_load_no_warning(self):
        gs = _make_gs([(1000.0, 100, "AutoSave_0100")])
        events, hard_stop = _check_save_scumming(gs)
        assert events == []
        assert hard_stop is False

    def test_two_loads_no_warning(self):
        gs = _make_gs(
            [
                (1000.0, 100, "AutoSave_0100"),
                (1001.0, 101, "AutoSave_0101"),
            ]
        )
        events, hard_stop = _check_save_scumming(gs)
        assert events == []
        assert hard_stop is False

    def test_opus_t326_deadlock_no_warning(self):
        """25 loads all clustered at T325-T326 should NOT trigger warnings —
        this is legitimate deadlock debugging."""
        history = []
        for i in range(25):
            turn = 326 if i % 2 == 0 else 325
            history.append((1000.0 + i, turn, f"AutoSave_{turn:04d}"))
        gs = _make_gs(history)
        events, hard_stop = _check_save_scumming(gs)
        # distinct turns = 2, span = 1, so no warning
        assert events == []
        assert hard_stop is False

    def test_soft_warning_3_turns_span_10(self):
        """3+ loads across 3+ turns with span >= 10 → soft warning."""
        history = [
            (1000.0, 50, "AutoSave_0050"),
            (1001.0, 55, "AutoSave_0055"),
            (1002.0, 62, "AutoSave_0062"),
        ]
        gs = _make_gs(history)
        events, hard_stop = _check_save_scumming(gs)
        assert len(events) == 1
        assert events[0].priority == 2
        assert "SAVE SCUMMING WARNING" in events[0].message
        assert hard_stop is False

    def test_strong_warning_5_turns_span_20(self):
        """5+ loads across 5+ turns with span >= 20 → strong warning."""
        history = [
            (1000.0 + i, turn, f"AutoSave_{turn:04d}")
            for i, turn in enumerate([30, 40, 50, 60, 70])
        ]
        gs = _make_gs(history)
        events, hard_stop = _check_save_scumming(gs)
        assert len(events) == 1
        assert events[0].priority == 1
        assert "SAVE SCUMMING CRITICAL" in events[0].message
        assert hard_stop is False

    def test_hard_stop_8_turns_span_30(self):
        """8+ loads across 8+ distinct turns with span >= 30 → hard stop."""
        history = [
            (1000.0 + i, turn, f"AutoSave_{turn:04d}")
            for i, turn in enumerate([30, 40, 50, 60, 70, 80, 90, 100])
        ]
        gs = _make_gs(history)
        events, hard_stop = _check_save_scumming(gs)
        assert len(events) == 1
        assert events[0].priority == 1
        assert "RUN ABORTED" in events[0].message
        assert hard_stop is True

    def test_gemini_scumming_pattern_hard_stop(self):
        """Reproduce Gemini's actual scumming pattern: loads at T106, T110,
        T114, T116, T122, T124, T152, T160, T161, T169 → hard stop."""
        history = [
            (1000.0 + i, turn, f"AutoSave_{turn:04d}")
            for i, turn in enumerate([106, 110, 114, 116, 122, 124, 152, 160, 161, 169])
        ]
        gs = _make_gs(history)
        events, hard_stop = _check_save_scumming(gs)
        assert hard_stop is True
        assert "RUN ABORTED" in events[0].message

    def test_boot_loads_ignored(self):
        """Loads at turn 0 (pre-game boot) should not trigger warnings."""
        history = [
            (1000.0, 0, "AutoSave_0000"),
            (1001.0, 0, "AutoSave_0000"),
            (1002.0, 0, "AutoSave_0000"),
        ]
        gs = _make_gs(history)
        events, hard_stop = _check_save_scumming(gs)
        assert events == []
        assert hard_stop is False

    def test_mixed_clustered_play_loads_no_warning(self):
        """Loads clustered at 2 turns (T200, T201) should stay quiet — this is
        single-point debugging."""
        history = [
            (1000.0 + i, turn, f"AutoSave_{turn:04d}")
            for i, turn in enumerate([200, 200, 201, 200, 201, 200])
        ]
        gs = _make_gs(history)
        events, hard_stop = _check_save_scumming(gs)
        # 6 loads but only 2 distinct turns, span=1 → no warning
        assert events == []
        assert hard_stop is False
