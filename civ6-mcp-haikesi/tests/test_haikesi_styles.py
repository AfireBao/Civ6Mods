"""Tests for ExtAI leader style classification and injection."""

from __future__ import annotations

import random

from civ_mcp.haikesi_llm import HaikesiGameContext, build_decision_prompt_slim
from civ_mcp.haikesi_styles import (
    apply_style_dice,
    assign_styles_for_payload,
    build_style_injection,
    classify_demonic_warlord,
    classify_style_for_leader,
    format_styles_dice_json,
    format_styles_meta,
    load_universal_skill,
    styles_for_session_lock,
)
from civ_mcp.haikesi_tools.runner import ChatResult, ToolLoopRunner
from civ_mcp.lua.haikesi import (
    LeaderView,
    MetCivView,
    RstStrategyView,
    VisibleThreatAgg,
)
from civ_mcp.lua.models import GameOverview


def _overview() -> GameOverview:
    return GameOverview(
        turn=40,
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
        era_name="古典时代",
        game_speed="GAMESPEED_ONLINE",
    )


def _met(*, war: bool = False, g_against: int = 0, rel: int = 0) -> MetCivView:
    return MetCivView(
        player_id=5,
        civ_name="刚果",
        leader_name="姆本巴",
        score=100,
        cities=4,
        pop=20,
        sci=40.0,
        cul=40.0,
        gold=20.0,
        mil=200,
        techs=10,
        civics=10,
        faith=10.0,
        diplomatic_state="WAR" if war else "NEUTRAL",
        relationship_score=rel,
        is_at_war=war,
        grievances=0,
        grievances_against_me=g_against,
    )


def _warlord_view() -> LeaderView:
    return LeaderView(
        player_id=1,
        civ_name="奥斯曼",
        leader_name="苏莱曼",
        cities=5,
        mil=600,
        met=[_met(war=True, g_against=80, rel=-30), _met(war=False, g_against=60, rel=-25)],
        threats=[
            VisibleThreatAgg(
                owner_id=5, owner_name="刚果", count=9, nearest_dist=1, is_at_war=True
            )
        ],
        rst=RstStrategyView(active_strategy="CONQUEST"),
    )


def test_universal_skill_loads():
    # Compat alias → payoff body
    text = load_universal_skill()
    assert "宜居" in text or "维护" in text or "即时" in text


def test_legality_and_payoff_split():
    from civ_mcp.haikesi_styles import load_legality_skill, load_payoff_skill

    assert "NW_AI_NONE" in load_legality_skill() or "候选" in load_legality_skill()
    pay = load_payoff_skill()
    assert "宜居" in pay and "维护" in pay
    assert "cosplay" in pay.lower() or "收益优先" in pay


def test_demonic_warlord_hits_on_conquest_war():
    view = _warlord_view()
    score, _reasons, excluded = classify_demonic_warlord(
        view=view,
        selected=["NW_AI_BARBARIAN_INVASION", "NW_AI_ECHO_MELEE"],
    )
    assert not excluded
    assert score >= 3
    asn = classify_style_for_leader(
        player_id=1,
        view=view,
        selected=["NW_AI_BARBARIAN_INVASION", "NW_AI_ECHO_SIEGE"],
    )
    assert asn.style_id == "demonic_warlord"


def test_militant_takes_clean_combat_echo():
    view = _warlord_view()
    asn = classify_style_for_leader(
        player_id=1, view=view, selected=["NW_AI_ECHO_SIEGE"]
    )
    assert asn.style_id == "militant_warlord"


def test_peaceful_science_is_erudite_not_warlord():
    view = LeaderView(
        player_id=5,
        civ_name="朝鲜",
        sci=40.0,
        met=[_met(war=False)],
        rst=RstStrategyView(active_strategy="SCIENCE"),
    )
    _score, _reasons, excluded = classify_demonic_warlord(
        view=view, selected=["NW_AI_STATS_2"]
    )
    assert excluded
    asn = classify_style_for_leader(player_id=5, view=view, selected=["NW_AI_STATS_2"])
    assert asn.style_id == "erudite_sage"
    assert asn.style_id != "demonic_warlord"


def test_new_styles_classify():
    from civ_mcp.lua.haikesi import TradeView

    # 工匠商人：SCIENCE + 商路 + 金币库存
    merchant = LeaderView(
        player_id=2,
        civ_name="马普切",
        sci=50.0,
        gold=25.0,
        met=[_met(war=False)],
        trade=TradeView(capacity=3, active=3, intl_out=2),
        rst=RstStrategyView(active_strategy="SCIENCE"),
    )
    asn = classify_style_for_leader(
        player_id=2,
        view=merchant,
        selected=["NW_AI_STATS_3", "NW_AI_STATS_6"],
    )
    assert asn.style_id == "artisan_merchant"

    # 威权外交官：DIPLO + favor + 友好
    diplo = LeaderView(
        player_id=3,
        civ_name="瑞典",
        cul=40.0,
        favor=30,
        met=[
            _met(war=False, g_against=0, rel=10),
            MetCivView(
                player_id=6,
                civ_name="城A",
                leader_name="L",
                score=50,
                cities=2,
                pop=10,
                sci=10.0,
                cul=10.0,
                gold=10.0,
                mil=50,
                techs=5,
                civics=5,
                faith=5.0,
                diplomatic_state="FRIEND",
                relationship_score=5,
                is_at_war=False,
                grievances=0,
                grievances_against_me=0,
            ),
        ],
        rst=RstStrategyView(active_strategy="DIPLO"),
    )
    asn = classify_style_for_leader(
        player_id=3, view=diplo, selected=["NW_AI_STATS_1"]
    )
    assert asn.style_id == "authoritarian_diplomat"

    # 狂热隐士：RELIGION + 高信仰 + 商路少
    fanatic = LeaderView(
        player_id=4,
        civ_name="刚果",
        faith=35.0,
        met=[_met(war=False)],
        trade=TradeView(capacity=1, active=0),
        rst=RstStrategyView(active_strategy="RELIGION"),
    )
    asn = classify_style_for_leader(
        player_id=4, view=fanatic, selected=["NW_AI_STATS_4"]
    )
    assert asn.style_id == "fanatic_isolationist"

    # 博学贤者：SCIENCE + 高科 + 和平
    sage = LeaderView(
        player_id=5,
        civ_name="朝鲜",
        sci=55.0,
        met=[_met(war=False)],
        rst=RstStrategyView(active_strategy="SCIENCE"),
    )
    asn = classify_style_for_leader(
        player_id=5, view=sage, selected=["NW_AI_STATS_2"]
    )
    assert asn.style_id == "erudite_sage"


def test_eight_new_styles_classify():
    from civ_mcp.lua.haikesi import TradeView

    # 帝国督军：CONQUEST + 多城 + 工人
    imperial = LeaderView(
        player_id=10,
        cities=6,
        mil=300,
        met=[_met(war=False)],
        rst=RstStrategyView(active_strategy="CONQUEST"),
    )
    assert (
        classify_style_for_leader(
            player_id=10, view=imperial, selected=["NW_AI_ECHO_BUILDER", "NW_AI_STATS_3"]
        ).style_id
        == "imperial_warlord"
    )

    # 经济督军：高金 + 交战
    economic = LeaderView(
        player_id=11,
        gold=40.0,
        mil=400,
        met=[_met(war=True, g_against=40, rel=-10)],
        rst=RstStrategyView(active_strategy="CONQUEST"),
    )
    assert (
        classify_style_for_leader(
            player_id=11, view=economic, selected=["NW_AI_STATS_6"]
        ).style_id
        == "economic_warlord"
    )

    # 谋略督军：交战 + SCIENCE + 战斗 echo
    strategist = LeaderView(
        player_id=12,
        sci=50.0,
        mil=350,
        met=[_met(war=True)],
        rst=RstStrategyView(active_strategy="SCIENCE"),
    )
    assert (
        classify_style_for_leader(
            player_id=12,
            view=strategist,
            selected=["NW_AI_STATS_2", "NW_AI_ECHO_RANGED"],
        ).style_id
        == "strategist_warlord"
    )

    # 孤僻隐士：商路少 + 边境压力 + 低信仰
    solitary = LeaderView(
        player_id=13,
        faith=5.0,
        met=[_met(war=False)],
        trade=TradeView(capacity=1, active=0),
        threats=[
            VisibleThreatAgg(
                owner_id=5, owner_name="刚果", count=4, nearest_dist=2, is_at_war=False
            )
        ],
        rst=RstStrategyView(active_strategy="NONE"),
    )
    assert (
        classify_style_for_leader(
            player_id=13, view=solitary, selected=["NW_AI_STATS_3"]
        ).style_id
        == "solitary_isolationist"
    )

    # 竞争商人：高金商路，非科文工人主线
    competitive = LeaderView(
        player_id=14,
        gold=35.0,
        met=[_met(war=False)],
        trade=TradeView(capacity=4, active=3, intl_out=2),
        rst=RstStrategyView(active_strategy="NONE"),
    )
    assert (
        classify_style_for_leader(
            player_id=14, view=competitive, selected=["NW_AI_STATS_6"]
        ).style_id
        == "competitive_merchant"
    )

    # 侠义外交官：DIPLO + 友好 + favor 不高
    chivalrous = LeaderView(
        player_id=15,
        favor=10,
        cul=30.0,
        met=[
            _met(war=False, g_against=0, rel=15),
            MetCivView(
                player_id=7,
                civ_name="友邦",
                leader_name="L",
                score=40,
                cities=2,
                pop=8,
                sci=8.0,
                cul=8.0,
                gold=8.0,
                mil=40,
                techs=4,
                civics=4,
                faith=4.0,
                diplomatic_state="FRIEND",
                relationship_score=12,
                is_at_war=False,
                grievances=0,
                grievances_against_me=0,
            ),
        ],
        rst=RstStrategyView(active_strategy="DIPLO"),
    )
    assert (
        classify_style_for_leader(
            player_id=15, view=chivalrous, selected=["NW_AI_STATS_1"]
        ).style_id
        == "chivalrous_diplomat"
    )

    # 欺诈间谍：CULTURE + favor 中等
    spy = LeaderView(
        player_id=16,
        favor=12,
        cul=35.0,
        met=[_met(war=False, rel=5)],
        rst=RstStrategyView(active_strategy="CULTURE"),
    )
    assert (
        classify_style_for_leader(
            player_id=16, view=spy, selected=["NW_AI_STATS_1"]
        ).style_id
        == "deceptive_spy"
    )


def test_session_lock_any_style():
    sage = LeaderView(
        player_id=5,
        sci=55.0,
        met=[_met(war=False)],
        rst=RstStrategyView(active_strategy="SCIENCE"),
    )
    asn = classify_style_for_leader(
        player_id=5,
        view=sage,
        selected=["NW_AI_STATS_2"],
        locked_id="erudite_sage",
    )
    assert asn.style_id == "erudite_sage"
    assert asn.locked

    chaos_sel = ["NW_AI_BARBARIAN_INVASION", "NW_AI_ECHO_MELEE"]
    asn = classify_style_for_leader(
        player_id=1,
        view=_warlord_view(),
        selected=chaos_sel,
    )
    assert asn.style_id == "demonic_warlord"
    apply_style_dice({1: asn}, request_id="t", rng=random.Random(0), cosplay_p=0.5)
    assert asn.mode in {"cosplay", "payoff"}
    assert asn.dice_u is not None
    assert 0.0 <= asn.dice_u < 1.0
    token = asn.audit_token()
    assert "demonic_warlord" in token
    assert asn.mode in token
    assert "u=" in token

    asn2 = classify_style_for_leader(
        player_id=1, view=_warlord_view(), selected=chaos_sel
    )
    apply_style_dice({1: asn2}, rng=random.Random(1), cosplay_p=0.0)
    assert asn2.mode == "payoff"

    asn3 = classify_style_for_leader(
        player_id=1, view=_warlord_view(), selected=chaos_sel
    )
    apply_style_dice({1: asn3}, rng=random.Random(1), cosplay_p=1.0)
    assert asn3.mode == "cosplay"


def test_assign_and_inject_respects_dice_mode():
    payload = {
        "request_id": "t-dice",
        "turn": 40,
        "ai_players": [
            {
                "player_id": 1,
                "options": ["NW_AI_BARBARIAN_INVASION", "NW_AI_STATS_1"],
                "selected": ["NW_AI_BARBARIAN_INVASION", "NW_AI_ECHO_MELEE"],
                "picks": 1,
                "age": "NORMAL",
            }
        ],
        "human_relic": "X",
    }
    ctx = HaikesiGameContext(
        overview=_overview(),
        leader_views={1: _warlord_view()},
        human_player_id=0,
    )
    assignments = assign_styles_for_payload(payload, ctx, rng=random.Random(42))
    apply_style_dice(assignments, rng=random.Random(0), cosplay_p=0.0)
    assert assignments[1].mode == "payoff"
    inj_pay = build_style_injection(assignments)
    assert "收益优先策略" in inj_pay
    assert "宜居" in inj_pay or "维护" in inj_pay
    assert "合法性底线" in inj_pay
    assert "风格 Skill（cosplay）" not in inj_pay

    apply_style_dice(assignments, rng=random.Random(0), cosplay_p=1.0)
    assert assignments[1].mode == "cosplay"
    inj_cos = build_style_injection(assignments)
    assert "风格 Skill（cosplay）" in inj_cos
    assert "混乱" in inj_cos or "恶魔" in inj_cos
    assert "收益优先策略（payoff）" not in inj_cos
    assert "合法性底线" in inj_cos

    prompt = build_decision_prompt_slim(payload, ctx, style_by_pid=assignments)
    assert "风格:" in prompt
    meta = format_styles_meta(assignments)
    assert "cosplay" in meta and "u=" in meta
    dice_json = format_styles_dice_json(assignments)
    assert '"mode": "cosplay"' in dice_json
    locks = styles_for_session_lock(assignments)
    assert locks.get("1") == "demonic_warlord"

    from civ_mcp.haikesi_tools.context_cache import DecisionToolContext

    class _Client:
        def complete_with_tools(self, messages, tools, *, allow_tool_use=True):
            return ChatResult(
                text='{"choices":{"1":"NW_AI_BARBARIAN_INVASION"},"reasons":{"1":"乱"}}',
                tool_calls=[],
            )

    tool_ctx = DecisionToolContext(context=ctx, payload=payload, channel="tuner")
    result = ToolLoopRunner.run(
        _Client(),
        user_prompt=prompt,
        tool_ctx=tool_ctx,
        style_injection=inj_cos,
        max_rounds=1,
    )
    assert "BARBARIAN" in result.text
