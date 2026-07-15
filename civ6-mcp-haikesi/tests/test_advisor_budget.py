"""Tests for the per-turn advisor call budget in GameState.

Gemini Pro's `divine-vermil-monument-72` run died in an infinite
`get_wonder_advisor` loop — 1,567 calls in a single turn. The budget cap
prevents this class of failure by short-circuiting further calls after
the hard limit.
"""

import types


def _make_gs():
    """Build a GameState-like object with just the advisor budget fields."""
    # Import the real class so we pick up the ADVISOR_BUDGET_* constants and
    # the _advisor_budget_check() method logic.
    from civ_mcp.game_state import GameState

    gs = types.SimpleNamespace()
    gs._advisor_calls_this_turn = 0
    gs._advisor_budget_warning = None
    # Bind the real method so threshold logic is exercised
    gs.ADVISOR_BUDGET_SOFT = GameState.ADVISOR_BUDGET_SOFT
    gs.ADVISOR_BUDGET_HARD = GameState.ADVISOR_BUDGET_HARD
    gs._advisor_budget_check = types.MethodType(GameState._advisor_budget_check, gs)
    return gs


class TestAdvisorBudget:
    def test_first_call_is_clean(self):
        gs = _make_gs()
        hard, soft = gs._advisor_budget_check()
        assert hard is None
        assert soft is None
        assert gs._advisor_calls_this_turn == 1

    def test_under_soft_limit_no_warning(self):
        gs = _make_gs()
        for _ in range(9):  # soft limit is 10
            hard, soft = gs._advisor_budget_check()
            assert hard is None
            assert soft is None

    def test_soft_warning_at_limit(self):
        gs = _make_gs()
        # First 9 calls: no warning
        for _ in range(9):
            gs._advisor_budget_check()
        # 10th call: soft warning
        hard, soft = gs._advisor_budget_check()
        assert hard is None
        assert soft is not None
        assert "ADVISOR BUDGET WARNING" in soft
        assert "10/20" in soft

    def test_soft_warning_continues_in_warning_zone(self):
        gs = _make_gs()
        # Jump to call 15 — still in warning zone, not yet hard-capped
        for _ in range(15):
            hard, soft = gs._advisor_budget_check()
        assert hard is None
        assert soft is not None
        assert "15/20" in soft

    def test_hard_cap_at_21(self):
        gs = _make_gs()
        # Calls 1-20 are allowed (with soft warnings from 10+)
        for i in range(20):
            hard, soft = gs._advisor_budget_check()
            assert hard is None, f"call {i + 1} should not be hard-capped"
        # Call 21: HARD STOP
        hard, soft = gs._advisor_budget_check()
        assert hard is not None
        assert "ADVISOR_BUDGET_EXCEEDED" in hard
        assert "21" in hard

    def test_budget_persists_until_reset(self):
        gs = _make_gs()
        # Exceed budget
        for _ in range(25):
            gs._advisor_budget_check()
        # Still over budget
        hard, _ = gs._advisor_budget_check()
        assert hard is not None

    def test_manual_reset_clears_budget(self):
        gs = _make_gs()
        # Exceed budget
        for _ in range(25):
            gs._advisor_budget_check()
        # Reset (as end_turn would do)
        gs._advisor_calls_this_turn = 0
        # Fresh budget
        hard, soft = gs._advisor_budget_check()
        assert hard is None
        assert soft is None

    def test_hard_error_format_is_actionable(self):
        gs = _make_gs()
        for _ in range(21):
            hard, _ = gs._advisor_budget_check()
        # The last one returned hard; check its contents
        assert "rank placements" in hard
        assert "resets next turn" in hard
        assert "ERR:" in hard

    def test_soft_warning_format_is_informative(self):
        gs = _make_gs()
        for _ in range(10):
            hard, soft = gs._advisor_budget_check()
        assert "Consolidate your queries" in soft
