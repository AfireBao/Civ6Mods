"""Tests for run_id generation — hostname differentiation + hour bucket."""

from civ_mcp.run_id import generate_run_id


class TestRunId:
    def test_deterministic_same_inputs(self):
        a = generate_run_id(
            model_id="opus",
            scenario_id="ground_control",
            timestamp=1775915000,
            hostname="solomon",
        )
        b = generate_run_id(
            model_id="opus",
            scenario_id="ground_control",
            timestamp=1775915000,
            hostname="solomon",
        )
        assert a == b

    def test_hostname_differentiates(self):
        kwargs = dict(
            model_id="gpt-5.4",
            scenario_id="ground_control",
            timestamp=1775915000,
        )
        sol = generate_run_id(hostname="solomon", **kwargs)
        ste = generate_run_id(hostname="steed", **kwargs)
        mae = generate_run_id(hostname="maeve", **kwargs)
        assert sol != ste
        assert ste != mae
        assert sol != mae

    def test_hour_bucket_stable_within_hour(self):
        # 5 minutes apart, same hour bucket
        a = generate_run_id(
            model_id="opus",
            scenario_id="snowflake",
            timestamp=1775915000,
            hostname="test",
        )
        b = generate_run_id(
            model_id="opus",
            scenario_id="snowflake",
            timestamp=1775915300,
            hostname="test",
        )
        assert a == b

    def test_hour_bucket_changes_across_hours(self):
        a = generate_run_id(
            model_id="opus",
            scenario_id="snowflake",
            timestamp=1775915000,
            hostname="test",
        )
        b = generate_run_id(
            model_id="opus",
            scenario_id="snowflake",
            timestamp=1775918700,  # > 1 hour later
            hostname="test",
        )
        assert a != b

    def test_regression_gemini_pro_collision_fixed(self):
        """The specific case that caused the production collision: 3 machines
        launching gemini-3.1-pro + ground_control at the same moment."""
        kwargs = dict(
            model_id="gemini-3.1-pro-preview",
            scenario_id="ground_control",
            timestamp=1775915000,
        )
        ids = {
            generate_run_id(hostname=h, **kwargs) for h in ("solomon", "steed", "maeve")
        }
        assert len(ids) == 3

    def test_format(self):
        rid = generate_run_id(
            model_id="opus",
            scenario_id="ground_control",
            timestamp=1775915000,
            hostname="test",
        )
        parts = rid.split("-")
        assert len(parts) == 4
        assert parts[3].isdigit()
        assert len(parts[3]) == 2
