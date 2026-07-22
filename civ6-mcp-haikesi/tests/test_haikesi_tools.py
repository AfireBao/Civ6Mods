"""Tests for Haikesi ExtAI ToolLoop handlers (SP/MP shared cache)."""

from __future__ import annotations

from civ_mcp.haikesi_llm import (
    HaikesiGameContext,
    build_decision_prompt_slim,
    expected_choice_ids,
    is_legal_ai_relic_id,
    picks_needed_by_player,
    validate_choices_against_options,
)
from civ_mcp.haikesi_tools.context_cache import DecisionToolContext
from civ_mcp.haikesi_tools.handlers import resolve_tool
from civ_mcp.haikesi_tools.runner import ChatResult, ToolCallSpec, ToolLoopRunner
from civ_mcp.lua.haikesi import (
    CityView,
    LeaderView,
    MetCivView,
    VisibleThreatAgg,
    normalize_extai_choices,
)
from civ_mcp.lua.models import GameOverview


def _overview() -> GameOverview:
    return GameOverview(
        turn=12,
        player_id=0,
        civ_name="人类",
        leader_name="玩家",
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
        game_speed="GAMESPEED_STANDARD",
    )


def _payload() -> dict:
    return {
        "request_id": "t1",
        "turn": 12,
        "ai_players": [
            {
                "player_id": 2,
                "civ_label": "罗马",
                "options": ["NW_AI_ECHO_MELEE", "NW_AI_STATS_1", "NW_AI_SILK_LAND"],
                "selected": ["NW_AI_STATS_2"],
                "picks": 1,
                "age": "NORMAL",
            },
            {
                "player_id": 3,
                "civ_label": "希腊",
                "options": ["NW_AI_ECHO_BUILDER", "NW_AI_STATS_3"],
                "selected": [],
                "picks": 1,
                "age": "NORMAL",
            },
            {
                "player_id": 4,
                "civ_label": "空池国",
                "options": [],
                "selected": ["NW_AI_STATS_1"] * 20,
                "picks": 0,
                "age": "GOLDEN",
            },
        ],
        "human_relic": "NW_AI_STATS_1",
    }


def _view(pid: int, *, cities: int = 2) -> LeaderView:
    return LeaderView(
        player_id=pid,
        civ_name=f"Civ{pid}",
        leader_name=f"Leader{pid}",
        cities=cities,
        pop=8,
        sci=12,
        cul=10,
        gold=20,
        mil=40,
        met=[
            MetCivView(
                player_id=0,
                civ_name="人类",
                leader_name="玩家",
                score=100,
                cities=3,
                pop=10,
                sci=15,
                cul=12,
                gold=30,
                mil=50,
                techs=5,
                civics=4,
                faith=2,
                diplomatic_state="FRIENDLY",
                relationship_score=20,
                is_at_war=False,
                grievances=0,
            )
        ],
        own_cities=[
            CityView(
                city_id=1,
                name="首都",
                pop=5,
                food=10,
                prod=12,
                gold=4,
                sci=6,
                cul=5,
                faith=1,
                housing=8,
                amenities=3,
                amenities_needed=2,
                districts="学院",
                producing="石弩",
                turns_left=2,
                loyalty=100,
            )
        ],
        threats=[
            VisibleThreatAgg(
                owner_id=9,
                owner_name="蛮族",
                count=3,
                nearest_dist=1,
                is_at_war=True,
                is_minor=True,
            )
        ],
    )


class _FakeToolClient:
    def __init__(self) -> None:
        self.n = 0

    def complete_with_tools(self, messages, tools, *, allow_tool_use=True):
        self.n += 1
        if allow_tool_use and self.n == 1:
            return ChatResult(
                text="",
                tool_calls=[
                    ToolCallSpec(
                        id="c1",
                        name="city_pressure",
                        arguments_json='{"player_id": 2}',
                    )
                ],
            )
        return ChatResult(
            text='{"choices": {"2": "NW_AI_STATS_1", "3": "NW_AI_ECHO_BUILDER"}, "reasons": {}}',
            tool_calls=[],
        )


def test_fog_rejects_other_leader():
    ctx = DecisionToolContext(
        context=HaikesiGameContext(
            overview=_overview(),
            leader_views={2: _view(2), 3: _view(3)},
            human_player_id=0,
        ),
        payload=_payload(),
        channel="tuner",
    )
    denied = resolve_tool(ctx, "leader_snapshot", '{"player_id": 99}')
    assert "拒绝" in denied or "不是本轮" in denied
    ok = resolve_tool(ctx, "leader_snapshot", '{"player_id": 2}')
    assert "Civ2" in ok
    assert "channel=tuner" in ok


def test_missing_view_honest_blank_log_channel():
    ctx = DecisionToolContext(
        context=HaikesiGameContext(
            overview=_overview(),
            leader_views={},
            human_player_id=0,
            fetch_notes=["联机 LOG 通道：局势来自 Gameplay Lua.log CTX"],
        ),
        payload=_payload(),
        channel="log",
    )
    out = resolve_tool(ctx, "leader_snapshot", '{"player_id": 2}')
    assert "Nothing surfaces" in out or "未包含" in out


def test_lookup_relic_and_echo():
    ctx = DecisionToolContext(
        context=HaikesiGameContext(
            overview=_overview(),
            leader_views={2: _view(2, cities=0)},
            human_player_id=0,
        ),
        payload=_payload(),
        channel="tuner",
    )
    relic = resolve_tool(ctx, "lookup_relic", '{"relic_type": "NW_AI_SILK_LAND"}')
    assert "NW_AI_SILK_LAND" in relic
    echo = resolve_tool(
        ctx,
        "check_echo_feasibility",
        '{"player_id": 2, "relic_type": "NW_AI_SILK_LAND"}',
    )
    assert "空放" in echo or "不建议" in echo or "判定" in echo


def test_tool_loop_runner():
    ctx = DecisionToolContext(
        context=HaikesiGameContext(
            overview=_overview(),
            leader_views={2: _view(2), 3: _view(3)},
            human_player_id=0,
        ),
        payload=_payload(),
        channel="tuner",
    )
    result = ToolLoopRunner.run(
        _FakeToolClient(),
        user_prompt="选卡",
        tool_ctx=ctx,
        max_rounds=2,
    )
    assert "choices" in result.text
    assert any(t["name"] == "city_pressure" for t in result.tool_trace)


def test_slim_prompt_keeps_candidate_ids():
    payload = _payload()
    context = HaikesiGameContext(
        overview=_overview(),
        leader_views={2: _view(2), 3: _view(3)},
        human_player_id=0,
    )
    prompt = build_decision_prompt_slim(payload, context)
    assert "NW_AI_ECHO_MELEE" in prompt
    assert "NW_AI_ECHO_BUILDER" in prompt
    assert "city_pressure" in prompt
    assert "border_threats" in prompt
    assert "极短况" in prompt
    assert "科12/文10" not in prompt
    assert "### 领袖 4" not in prompt
    assert "效果说明（同词条只列一次）" not in prompt


def test_empty_pool_excluded_from_required_ids():
    payload = _payload()
    ids = expected_choice_ids(payload)
    assert ids == ["2", "3"]
    assert "4" not in ids
    needs = picks_needed_by_player(payload)
    assert needs["2"] == 1
    assert "4" not in needs


def test_reject_none_and_zero_relic_ids():
    assert not is_legal_ai_relic_id("NW_AI_NONE")
    assert not is_legal_ai_relic_id("0")
    assert not is_legal_ai_relic_id("123")
    assert is_legal_ai_relic_id("NW_AI_STATS_1")
    payload = _payload()
    bad = validate_choices_against_options(
        {"2": "NW_AI_NONE", "3": "0"},
        payload,
    )
    assert any("illegal" in e or "NW_AI_NONE" in e for e in bad)
    assert any("illegal" in e or "'0'" in e or " 0" in e for e in bad)
    wire = normalize_extai_choices(
        {"2": "NW_AI_NONE", "3": "NW_AI_ECHO_BUILDER", "4": "NW_AI_STATS_1"},
        payload.get("ai_players"),
    )
    assert "2" not in wire
    assert wire.get("3") == "NW_AI_ECHO_BUILDER"
    assert "4" not in wire


def test_picks_clamped_to_options_len():
    payload = {
        "ai_players": [
            {
                "player_id": 5,
                "options": ["NW_AI_A", "NW_AI_B"],
                "picks": 2,
                "age": "GOLDEN",
            }
        ]
    }
    assert picks_needed_by_player(payload)["5"] == 2
    payload["ai_players"][0]["options"] = ["NW_AI_A"]
    assert picks_needed_by_player(payload)["5"] == 1


def test_city_pressure_and_border_threats():
    ctx = DecisionToolContext(
        context=HaikesiGameContext(
            overview=_overview(),
            leader_views={2: _view(2)},
            human_player_id=0,
        ),
        payload=_payload(),
        channel="tuner",
    )
    cities = resolve_tool(ctx, "city_pressure", '{"player_id": 2}')
    assert "石弩" in cities
    assert "首都" in cities
    threats = resolve_tool(ctx, "border_threats", '{"player_id": 2}')
    assert "蛮族" in threats
    assert "1格" in threats


def test_sp_mp_same_handler_contract():
    payload = _payload()
    view = _view(2)
    for channel in ("tuner", "log"):
        ctx = DecisionToolContext(
            context=HaikesiGameContext(
                overview=_overview(),
                leader_views={2: view, 3: _view(3)},
                human_player_id=0,
            ),
            payload=payload,
            channel=channel,  # type: ignore[arg-type]
        )
        snap = resolve_tool(ctx, "leader_snapshot", '{"player_id": 2}')
        assert f"channel={channel}" in snap
        inv = resolve_tool(ctx, "inventory_brief", '{"player_id": 2}')
        assert "NW_AI_STATS_2" in inv or "历史库存" in inv


def test_civ6_kb_offline():
    ctx = DecisionToolContext(
        context=HaikesiGameContext(overview=_overview(), human_player_id=0),
        payload=_payload(),
        channel="tuner",
    )
    text = resolve_tool(ctx, "civ6_kb", '{"topic": "amenity"}')
    assert "宜居" in text
    assert "Nothing surfaces" not in text


def test_civilopedia_lookup_unit_and_haikesi():
    from civ_mcp import civilopedia_index

    civ_n, hk_n = civilopedia_index.chapter_counts()
    assert civ_n >= 100
    assert hk_n >= 50

    ctx = DecisionToolContext(
        context=HaikesiGameContext(overview=_overview(), human_player_id=0),
        payload=_payload(),
        channel="tuner",
    )
    balloon = resolve_tool(
        ctx,
        "civilopedia_lookup",
        '{"query": "UNIT_OBSERVATION_BALLOON", "limit": 1}',
    )
    assert "UNIT_OBSERVATION_BALLOON" in balloon
    assert "观测气球" in balloon or "气球" in balloon

    punch = resolve_tool(
        ctx,
        "civilopedia_lookup",
        '{"query": "秘术冲拳", "chapter": "haikesi", "limit": 1}',
    )
    assert "ARCANEPUNCHRUNE" in punch
    assert "武僧" in punch or "战斗力" in punch

    via_kb = resolve_tool(ctx, "civ6_kb", '{"topic": "观测气球"}')
    assert "UNIT_OBSERVATION_BALLOON" in via_kb or "气球" in via_kb
