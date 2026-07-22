"""Resolve ExtAI tools against DecisionToolContext (no GameConnection)."""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from civ_mcp import civilopedia_index
from civ_mcp.lua import haikesi as haikesi_lua

from civ_mcp.haikesi_tools.context_cache import DecisionToolContext

NOTHING_SURFACES = "Nothing surfaces — 本轮缓存中没有可用情报（勿臆造）。"

_KB_DIR = Path(__file__).resolve().parents[3] / "knowledge" / "civ6"

_KB_ALIASES: dict[str, str] = {
    "amenity": "amenity.md",
    "amenities": "amenity.md",
    "宜居": "amenity.md",
    "district": "district.md",
    "districts": "district.md",
    "区域": "district.md",
    "victory": "victory.md",
    "胜利": "victory.md",
    "trade": "trade.md",
    "商路": "trade.md",
}


def resolve_tool(ctx: DecisionToolContext, name: str, arguments_json: str) -> str:
    try:
        args = json.loads(arguments_json) if arguments_json else {}
    except json.JSONDecodeError:
        args = {}
    if not isinstance(args, dict):
        args = {}

    try:
        if name == "leader_snapshot":
            result = _leader_snapshot(ctx, args)
        elif name == "met_civ_detail":
            result = _met_civ_detail(ctx, args)
        elif name == "lookup_relic":
            result = _lookup_relic(args)
        elif name == "inventory_brief":
            result = _inventory_brief(ctx, args)
        elif name == "check_echo_feasibility":
            result = _check_echo_feasibility(ctx, args)
        elif name == "civ6_kb":
            result = _civ6_kb(args)
        elif name == "civilopedia_lookup":
            result = _civilopedia_lookup(args)
        else:
            result = f"未知工具: {name}"
    except Exception as exc:  # noqa: BLE001
        result = f"{NOTHING_SURFACES}（内部错误: {exc}）"

    if not (result or "").strip():
        result = NOTHING_SURFACES
    ctx.record(name, args, result)
    return result


def _pid(args: dict[str, Any], key: str = "player_id") -> int | None:
    raw = args.get(key)
    try:
        return int(raw)
    except (TypeError, ValueError):
        return None


def _require_allowed(ctx: DecisionToolContext, pid: int | None) -> str | None:
    if pid is None:
        return "缺少合法 player_id。"
    if pid not in ctx.allowed_player_ids:
        return (
            f"拒绝：player_id={pid} 不是本轮待决策领袖 "
            f"（允许: {sorted(ctx.allowed_player_ids)}）。禁止跨领袖偷看。"
        )
    return None


def _view(ctx: DecisionToolContext, pid: int):
    return (ctx.context.leader_views or {}).get(pid)


def _leader_snapshot(ctx: DecisionToolContext, args: dict[str, Any]) -> str:
    pid = _pid(args)
    err = _require_allowed(ctx, pid)
    if err:
        return err
    assert pid is not None
    view = _view(ctx, pid)
    if view is None:
        return (
            f"{NOTHING_SURFACES} channel={ctx.channel}："
            f"领袖 {pid} 的视图未包含在本轮缓存（联机 CTX 缺段或单机 gather 失败）。"
        )

    rst = ""
    if view.rst is not None:
        rst = f"主战略={view.rst.active_strategy}"
    war = any(m.is_at_war for m in view.met)
    threat_n = len(view.threats or [])
    city_n = int(view.cities or 0)
    amenity_notes: list[str] = []
    for c in (view.own_cities or [])[:6]:
        if c.amenities < c.amenities_needed:
            amenity_notes.append(
                f"{c.name}宜居{c.amenities}/{c.amenities_needed}"
            )
    lines = [
        f"领袖 {pid}：{view.civ_name}（{view.leader_name}）channel={ctx.channel}",
        (
            f"国力：{city_n}城/人口{view.pop}，科{view.sci}/文{view.cul}/金{view.gold}，"
            f"军力{view.mil}，科技{view.techs}/市政{view.civics}，信仰{view.faith}"
        ),
        f"在研：{view.current_research} / 市政：{view.current_civic}",
        rst or "Real Strategy：无",
        f"交战标记={'是' if war else '否'}；边境可见威胁组={threat_n}",
    ]
    if amenity_notes:
        lines.append("宜居压力：" + "；".join(amenity_notes))
    else:
        lines.append("宜居压力：未见赤字（或无城市明细）")
    if view.trade is not None and view.trade.capacity >= 0:
        t = view.trade
        lines.append(
            f"商路：容量{t.capacity} 已用{t.active} 国际入向{t.intl_in}"
        )
    return "\n".join(lines)


def _met_civ_detail(ctx: DecisionToolContext, args: dict[str, Any]) -> str:
    pid = _pid(args)
    err = _require_allowed(ctx, pid)
    if err:
        return err
    assert pid is not None
    view = _view(ctx, pid)
    if view is None:
        return NOTHING_SURFACES + f"（无领袖 {pid} 视图）"
    other = _pid(args, "other_id")
    mets = list(view.met or [])
    if other is not None:
        mets = [m for m in mets if m.player_id == other]
        if not mets:
            return f"领袖 {pid} 视野内未见 other_id={other}（未相遇或不在缓存）。"
    if not mets:
        return f"领袖 {pid}：尚未与其他主要文明建立接触。"
    lines = [f"领袖 {pid} 已遇文明（channel={ctx.channel}）："]
    for m in sorted(mets, key=lambda x: -x.score)[:12]:
        war = "交战" if m.is_at_war else "和平"
        mod = ""
        if m.modifiers:
            tops = [
                f"{x.text}:{x.score}"
                for x in m.modifiers[:3]
                if getattr(x, "text", None)
            ]
            if tops:
                mod = "；修饰=" + ",".join(tops)
        lines.append(
            f"- id{m.player_id} {m.civ_name}（{m.leader_name}）："
            f"分{m.score} {m.cities}城 科{m.sci}/文{m.cul}/金{m.gold} "
            f"军{m.mil} {m.diplomatic_state}({m.relationship_score}) {war} "
            f"不满我→彼{m.grievances}/彼→我{m.grievances_against_me}{mod}"
        )
    return "\n".join(lines)


def _lookup_relic(args: dict[str, Any]) -> str:
    relic = str(args.get("relic_type") or "").strip()
    if not relic:
        return "缺少 relic_type。"
    return haikesi_lua.format_relic_display(relic)


def _inventory_brief(ctx: DecisionToolContext, args: dict[str, Any]) -> str:
    pid = _pid(args)
    err = _require_allowed(ctx, pid)
    if err:
        return err
    assert pid is not None
    for ai in ctx.payload.get("ai_players") or []:
        try:
            if int(ai.get("player_id")) != pid:
                continue
        except (TypeError, ValueError):
            continue
        selected = haikesi_lua.dedupe_preserve_order(list(ai.get("selected") or []))
        if not selected:
            return f"领袖 {pid} 历史库存：（无）"
        names = haikesi_lua.format_relic_type_list(selected)
        ids = "、".join(selected)
        return f"领袖 {pid} 历史库存：{names}\n类型ID：{ids}"
    return f"payload 中无领袖 {pid}。"


def _check_echo_feasibility(ctx: DecisionToolContext, args: dict[str, Any]) -> str:
    pid = _pid(args)
    err = _require_allowed(ctx, pid)
    if err:
        return err
    assert pid is not None
    relic = str(args.get("relic_type") or "").strip()
    if not relic:
        return "缺少 relic_type。"

    view = _view(ctx, pid)
    cities = int(view.cities or 0) if view is not None else 0
    intl_in = None
    if view is not None and view.trade is not None:
        intl_in = int(view.trade.intl_in)

    timing = haikesi_lua.relic_timing_tag(
        relic, cities=cities, intl_inbound=intl_in
    )
    display = haikesi_lua.format_relic_display(relic)

    verdict = "可考虑"
    reason = timing
    if "空放" in timing or "勿选" in timing:
        verdict = "不建议/空放"
    elif relic.startswith("NW_AI_ECHO_"):
        if cities <= 0 and "SETTLER" not in relic and "BUILDER" not in relic:
            # military echo with 0 cities still can spawn near settler-less? usually need cities later
            verdict = "延迟收益"
            reason = timing + "；早期无城时军事 echo 兑现慢"
        else:
            verdict = "条件允许则优先核对在建兵种"
            reason = timing
    elif "条件即时" in timing and cities <= 0:
        verdict = "空放风险"
        reason = timing

    return f"{display}\n判定：{verdict}\n依据：{reason}"


def _civ6_kb(args: dict[str, Any]) -> str:
    raw = str(args.get("topic") or "").strip()
    topic = raw.lower()
    if not topic:
        return "缺少 topic。可用：amenity / district / victory / trade；或专名走 civilopedia_lookup"
    fname = _KB_ALIASES.get(topic)
    if fname is None:
        for key, name in _KB_ALIASES.items():
            if key in topic or topic in key:
                fname = name
                break
    if fname is None and _KB_DIR.is_dir():
        for p in _KB_DIR.glob("*.md"):
            if topic in p.stem.lower():
                fname = p.name
                break
    if fname:
        path = _KB_DIR / fname
        if path.is_file():
            text = path.read_text(encoding="utf-8").strip()
            if len(text) > 2500:
                text = text[:2500].rstrip() + "…"
            return text
        return NOTHING_SURFACES + f"（文件缺失 {fname}）"

    # Fall back to Civilopedia dictionary for entity names / ids
    hits = civilopedia_index.search(raw, limit=3)
    if hits:
        return civilopedia_index.format_search_result(raw, hits)
    return NOTHING_SURFACES + f"（无本地条目匹配 topic={raw!r}）"


def _civilopedia_lookup(args: dict[str, Any]) -> str:
    query = str(args.get("query") or "").strip()
    if not query:
        return "缺少 query。"
    chapter = str(args.get("chapter") or "").strip() or None
    if chapter and chapter not in ("civilopedia", "haikesi"):
        return f"chapter 须为 civilopedia 或 haikesi（收到 {chapter!r}）"
    try:
        limit = int(args.get("limit") or 3)
    except (TypeError, ValueError):
        limit = 3
    limit = max(1, min(limit, 8))
    hits = civilopedia_index.search(query, chapter=chapter, limit=limit)
    civ_n, hk_n = civilopedia_index.chapter_counts()
    empty = (
        f"无匹配；词典规模 civilopedia={civ_n} / haikesi={hk_n}。"
        "可换中文名、UNIT_/TECH_ ID，或 chapter=haikesi"
    )
    return civilopedia_index.format_search_result(query, hits, empty_hint=empty)
