"""Haikesi mod — external LLM AI relic decision protocol over FireTuner."""
from __future__ import annotations
import json
import re
from pathlib import Path
from dataclasses import dataclass, field
from typing import Any
from civ_mcp.lua._helpers import SENTINEL
from civ_mcp.lua.models import CivReligionBeliefs, ReligionBeliefOption
HAIKESI_GAMEPLAY_STATE = "Haikesi_GamePlay_Script"
_DEFAULT_TEXT_XML = Path(__file__).resolve().parents[4] / "Haikesi_Dev" / "Text" / "Haikesi_Text.xml"
_CATALOG: dict[str, dict[str, str]] | None = None
_RESOURCE_SPAWN_MAP: dict[str, str] | None = None

# Vanilla Resource_YieldChanges (tile bonus from the resource itself).
_RESOURCE_TILE_YIELDS: dict[str, list[tuple[str, int]]] = {
    "RESOURCE_COTTON": [("金币", 3)],
    "RESOURCE_SILK": [("文化", 1)],
    "RESOURCE_SUGAR": [("食物", 2)],
    "RESOURCE_TEA": [("科技", 1)],
    "RESOURCE_TOBACCO": [("信仰", 1)],
}

_DEFAULT_SPAWN_SQL = (
    Path(__file__).resolve().parents[4]
    / "Haikesi_Dev"
    / "Data"
    / "Haikesi_Relic_ResourceSpawns.sql"
)

def build_get_ai_request_lua() -> str:
    return (
        'if type(Haikesi_GetExternalAIRequest) == "function" then '
        "Haikesi_GetExternalAIRequest() "
        'else print("NOT_READY") end\n'
        f'print("{SENTINEL}")'
    )

def _escape_lua_string(value: str) -> str:
    """Emit ASCII-safe Lua 5.1 string literal for identifiers / ASCII values.
    Non-ASCII must not go through ``\\xNN`` (unsupported) or raw UTF-8 (FireTuner
    mangling). Prefer :func:`_utf8_to_lua_hex_call` for Chinese reasons.
    """
    parts: list[str] = []
    for ch in value:
        if ch == "\\":
            parts.append("\\\\")
        elif ch == '"':
            parts.append('\\"')
        elif ch == "\n":
            parts.append("\\n")
        elif ch == "\r":
            parts.append("\\r")
        elif ch == "\t":
            parts.append("\\t")
        elif ord(ch) < 32:
            parts.append(f"\\{ord(ch):03d}")
        elif ord(ch) < 127:
            parts.append(ch)
        else:
            # Fallback for unexpected non-ASCII in keys: decimal bytes
            for byte in ch.encode("utf-8"):
                parts.append(f"\\{byte:03d}")
    return "".join(parts)

def _utf8_to_hex(value: str) -> str:
    return value.encode("utf-8").hex()

def _build_lua_table(mapping: dict[str, str]) -> str:
    parts: list[str] = []
    for key, value in mapping.items():
        parts.append(f'["{_escape_lua_string(str(key))}"]="{_escape_lua_string(value)}"')
    return "{" + ", ".join(parts) + "}"

def _build_lua_reasons_table_hex(mapping: dict[str, str]) -> str:
    """Reasons as H(\"hex\") so FireTuner only carries ASCII; Lua decodes UTF-8."""
    parts: list[str] = []
    for key, value in mapping.items():
        parts.append(
            f'["{_escape_lua_string(str(key))}"]=H("{_utf8_to_hex(str(value))}")'
        )
    return "{" + ", ".join(parts) + "}"
# Injected ahead of Submit so reasons never travel as raw UTF-8 / \\x escapes.
_LUA_HEX_DECODE_HELPER = (
    "local function H(h) local t={} "
    "for i=1,#h,2 do "
    't[#t+1]=string.char(tonumber(string.sub(h,i,i+1),16)) '
    "end "
    "return table.concat(t) end "
)

def build_submit_ai_choices_lua(
    request_id: str,
    choices: dict[str, str],
    reasons: dict[str, str] | None = None,
) -> str:
    if not request_id:
        raise ValueError("request_id is required")
    if not choices:
        raise ValueError("choices must not be empty")
    rid = _escape_lua_string(request_id)
    choices_literal = _build_lua_table({str(k): v for k, v in choices.items()})
    submit_call = f'Haikesi_SubmitExternalAIChoices("{rid}", {choices_literal}'
    prefix = ""
    if reasons:
        prefix = _LUA_HEX_DECODE_HELPER
        reasons_literal = _build_lua_reasons_table_hex(
            {str(k): v for k, v in reasons.items()}
        )
        submit_call += f", {reasons_literal}"
    submit_call += ")"
    return (
        f"{prefix}"
        'if type(Haikesi_SubmitExternalAIChoices) == "function" then '
        f"{submit_call} "
        'else print("ERR:not ready") end\n'
        f'print("{SENTINEL}")'
    )

def _parse_kv_line(line: str) -> tuple[str, str] | None:
    if "=" not in line:
        return None
    key, _, value = line.partition("=")
    return key.strip(), value.strip()

def _parse_ai_line(line: str) -> dict[str, Any] | None:
    # AI|playerID|civLabel|options,list|selected:sel1,sel2|name:DisplayName
    if not line.startswith("AI|"):
        return None
    parts = line.split("|")
    if len(parts) < 5:
        return None
    _, player_id, civ_label, options_raw, selected_raw = parts[:5]
    options = [x for x in options_raw.split(",") if x]
    selected_part = selected_raw
    if selected_part.startswith("selected:"):
        selected_part = selected_part[len("selected:") :]
    selected = [x for x in selected_part.split(",") if x]
    player_name = ""
    for extra in parts[5:]:
        if extra.startswith("name:"):
            player_name = extra[len("name:") :]
    return {
        "player_id": int(player_id),
        "civ_label": civ_label,
        "player_name": player_name,
        "options": options,
        "selected": selected,
    }


def parse_game_session_value(value: str) -> dict[str, Any]:
    """Parse GAME_SESSION=seed|mapScript|mapSize|requester|civ."""
    parts = (value or "").split("|")
    while len(parts) < 5:
        parts.append("")
    seed, map_script, map_size, requester_raw, civ = parts[:5]
    requester = int(requester_raw) if requester_raw.lstrip("-").isdigit() else 0
    return {
        "seed": seed,
        "map_script": map_script or "Unknown",
        "map_size": map_size or "Unknown",
        "requester": requester,
        "requester_civ": civ or "Unknown",
    }


def parse_game_speed_value(value: str) -> dict[str, Any]:
    """Parse GAME_SPEED=显示名|CostMultiplier from Gameplay dump."""
    parts = (value or "").split("|")
    name = parts[0].strip() if parts else ""
    mult = 100
    if len(parts) >= 2 and str(parts[1]).isdigit():
        mult = int(parts[1])
    return {"name": name or "未知", "cost_multiplier": mult}


def parse_ai_request_lines(lines: list[str]) -> dict[str, Any]:
    """Parse Haikesi_GetExternalAIRequest() print output into a JSON-serializable dict."""
    cleaned = [ln.strip() for ln in lines if ln.strip() and ln.strip() != SENTINEL]
    if not cleaned or cleaned[0] == "NONE":
        return {"status": "none"}
    if cleaned[0] == "NOT_READY":
        return {
            "status": "not_ready",
            "message": "Haikesi_GetExternalAIRequest not loaded — enter a save on the map",
        }
    result: dict[str, Any] = {"status": "pending", "ai_players": []}
    for line in cleaned:
        if line.startswith("AI|"):
            ai = _parse_ai_line(line)
            if ai is not None:
                result["ai_players"].append(ai)
            continue
        kv = _parse_kv_line(line)
        if kv is None:
            continue
        key, value = kv
        if key == "REQUEST_ID":
            result["request_id"] = value
        elif key == "TURN":
            result["turn"] = int(value) if value.isdigit() else value
        elif key == "REQUESTER":
            result["requester"] = int(value) if value.lstrip("-").isdigit() else value
        elif key == "HUMAN_RELIC":
            result["human_relic"] = value
        elif key == "COUNT_BEFORE":
            result["count_before"] = int(value) if value.isdigit() else value
        elif key == "INVASION_MUTEX":
            result["invasion_mutex"] = value == "1"
        elif key == "MP":
            result["mp"] = value == "1" or value == 1
        elif key == "GAME_SESSION":
            result["game_session"] = parse_game_session_value(value)
        elif key == "GAME_SPEED":
            result["game_speed"] = parse_game_speed_value(value)
    if "request_id" not in result:
        return {"status": "error", "message": "malformed request payload", "raw": cleaned}
    return result

def format_ai_request_json(lines: list[str]) -> str:
    return json.dumps(parse_ai_request_lines(lines), indent=2, ensure_ascii=False)

def summarize_submit_result(lines: list[str]) -> str:
    """Parse SubmitExternalAIChoices output.
    Success is ``OK:staged ...`` (host stages payload; UI broadcasts via
    EXECUTE_SCRIPT). Legacy ``OK:applied`` is still treated as ok=true.
    """
    cleaned = [ln.strip() for ln in lines if ln.strip() and ln.strip() != SENTINEL]
    if not cleaned:
        return json.dumps({"ok": False, "message": "no response from game"}, ensure_ascii=False)
    last = cleaned[-1]
    if last.startswith("OK:"):
        message = last[3:]
        staged = message.startswith("staged")
        return json.dumps(
            {
                "ok": True,
                "staged": staged,
                "message": message,
                "note": (
                    "Staged on host; Haikesi_TriTrade_Bridge will EXECUTE_SCRIPT "
                    "broadcast ExtAIApply to all peers."
                    if staged
                    else None
                ),
            },
            ensure_ascii=False,
        )
    if last.startswith("ERR:"):
        return json.dumps({"ok": False, "message": last[4:]}, ensure_ascii=False)
    return json.dumps({"ok": False, "message": last, "raw": cleaned}, ensure_ascii=False)

def get_ai_relic_catalog(text_xml: Path | None = None) -> dict[str, dict[str, str]]:
    """Load Haikesi relic Chinese name/description (human + AI) for LLM prompts."""
    global _CATALOG
    if _CATALOG is not None:
        return _CATALOG

    path = text_xml or _DEFAULT_TEXT_XML
    catalog: dict[str, dict[str, str]] = {}
    if not path.is_file():
        _CATALOG = catalog
        return catalog

    content = path.read_text(encoding="utf-8")
    name_re = re.compile(
        r'Tag="LOC_HAIKESI_RELIC_([A-Z0-9_]+)_NAME".*?<Text>(.*?)</Text>',
        re.DOTALL,
    )
    desc_re = re.compile(
        r'Tag="LOC_HAIKESI_RELIC_([A-Z0-9_]+)_DESCRIPTION".*?<Text>(.*?)</Text>',
        re.DOTALL,
    )
    for match in name_re.finditer(content):
        relic_type, name = match.group(1), match.group(2).strip()
        catalog.setdefault(relic_type, {})["name"] = name
    for match in desc_re.finditer(content):
        relic_type, desc = match.group(1), match.group(2).strip()
        catalog.setdefault(relic_type, {})["description"] = desc

    _CATALOG = catalog
    return catalog


def clear_relic_catalog_cache() -> None:
    """Drop cached Haikesi text / resource-spawn lookups (tests / hot reload)."""
    global _CATALOG, _RESOURCE_SPAWN_MAP
    _CATALOG = None
    _RESOURCE_SPAWN_MAP = None


def get_resource_spawn_map(spawn_sql: Path | None = None) -> dict[str, str]:
    """RelicType -> ResourceType from Haikesi_Relic_ResourceSpawns.sql."""
    global _RESOURCE_SPAWN_MAP
    if _RESOURCE_SPAWN_MAP is not None:
        return _RESOURCE_SPAWN_MAP

    path = spawn_sql or _DEFAULT_SPAWN_SQL
    mapping: dict[str, str] = {}
    if path.is_file():
        # ('NW_AI_SILK_LAND', 'RESOURCE_SILK', ...)
        row_re = re.compile(
            r"\(\s*'(NW_AI_[A-Z0-9_]+)'\s*,\s*'(RESOURCE_[A-Z0-9_]+)'",
            re.IGNORECASE,
        )
        for match in row_re.finditer(path.read_text(encoding="utf-8")):
            mapping[match.group(1)] = match.group(2)
    _RESOURCE_SPAWN_MAP = mapping
    return mapping


def format_resource_tile_yield_note(resource_type: str) -> str:
    """Chinese note: yields are the luxury's vanilla benefits, not an extra hex bonus."""
    yields = _RESOURCE_TILE_YIELDS.get(resource_type)
    if not yields:
        return ""
    parts = [f"{name}+{amount}" for name, amount in yields]
    return (
        "以下为该奢侈品本身的原版固有收益（非本词条额外加成）："
        f"{'、'.join(parts)}；需改良后收获，并提供奢侈品宜居。"
    )


def enrich_relic_description(
    relic_type: str,
    description: str,
    *,
    spawn_sql: Path | None = None,
) -> str:
    """Append resource tile-yield note for resource-spawn relics if missing."""
    desc = (description or "").strip()
    resource_type = get_resource_spawn_map(spawn_sql).get(relic_type)
    if not resource_type:
        return desc
    note = format_resource_tile_yield_note(resource_type)
    if not note:
        return desc
    # XML 已写明「原版固有收益」或已含产量+宜居时，不再追加
    if "原版固有收益" in desc or "奢侈品本身" in desc:
        return desc
    if any(token in desc for token, _ in _RESOURCE_TILE_YIELDS.get(resource_type, [])):
        if "宜居" in desc or "地块" in desc:
            return desc
    if note in desc:
        return desc
    return f"{desc} {note}".strip() if desc else note


def _strip_civ_icons(text: str) -> str:
    # CTX/Localization 常见 [ICON_Gold] / [Icon_Faith] 混写
    return re.sub(r"\s*\[ICON_[^\]]+\]\s*", "", text or "", flags=re.IGNORECASE).strip()


def format_relic_display(relic_type: str, text_xml: Path | None = None) -> str:
    """Single relic as type: 中文名 — 效果; falls back to type id."""
    if not relic_type:
        return "(无)"
    info = get_ai_relic_catalog(text_xml).get(relic_type, {})
    name = _strip_civ_icons(info.get("name", relic_type))
    desc = enrich_relic_description(
        relic_type, _strip_civ_icons(info.get("description", ""))
    )
    if desc:
        return f"{relic_type}: {name} — {desc}"
    return f"{relic_type}: {name}"


def dedupe_preserve_order(items: list[str]) -> list[str]:
    """Drop duplicate strings while keeping first occurrence order."""
    seen: set[str] = set()
    out: list[str] = []
    for item in items:
        if item in seen:
            continue
        seen.add(item)
        out.append(item)
    return out


def format_relic_type_list(types: list[str], text_xml: Path | None = None) -> str:
    """Format relic type ids as Chinese display names for prompts/logs."""
    catalog = get_ai_relic_catalog(text_xml)
    if not types:
        return "无"
    labels: list[str] = []
    for relic_type in types:
        name = _strip_civ_icons(catalog.get(relic_type, {}).get("name", relic_type))
        labels.append(name)
    return "、".join(labels)


def format_relic_inventory_lines(
    types: list[str], text_xml: Path | None = None
) -> list[str]:
    """Full name+effect lines for historical inventory (prompt public section)."""
    types = dedupe_preserve_order(types)
    if not types:
        return ["  （无）"]
    return [f"  · {format_relic_display(t, text_xml)}" for t in types]


_ECHO_UNIT_LABELS: dict[str, str] = {
    "SETTLER": "开拓者",
    "BUILDER": "建造者",
    "MELEE": "近战",
    "RANGED": "远程",
    "LIGHT_CAVALRY": "轻骑兵",
    "HEAVY_CAVALRY": "重骑兵",
    "ANTI_CAVALRY": "抗骑兵",
    "SIEGE": "攻城",
}

_STATS_YIELD_HINTS: dict[str, str] = {
    "NW_AI_STATS_1": "文化",
    "NW_AI_STATS_2": "科技",
    "NW_AI_STATS_3": "金币",
    "NW_AI_STATS_4": "信仰",
    "NW_AI_STATS_5": "食物",
    "NW_AI_STATS_6": "生产力",
}


def relic_timing_tag(relic_type: str, *, cities: int | None = None) -> str:
    """Prompt label: when the hex pays off (instant vs delayed).

    cities: 当前城市数；0 城时资源创建会空放（Gameplay skip），必须醒目标出。
    """
    if relic_type == "NW_AI_BARBARIAN_INVASION":
        return "【即时·全场互斥·触发者免疫】"
    if relic_type.startswith("NW_AI_ECHO_"):
        suffix = relic_type.removeprefix("NW_AI_ECHO_")
        unit = _ECHO_UNIT_LABELS.get(suffix, suffix.replace("_", ""))
        return f"【延迟·需能生产{unit}】"
    if relic_type.startswith("NW_AI_STATS_"):
        yield_hint = _STATS_YIELD_HINTS.get(relic_type, "产出")
        return f"【即时·全城市{yield_hint}%】"
    if relic_type == "NW_AI_CELESTIAL_EMPIRE":
        return "【延迟·需国际商路生效】"
    if relic_type in get_resource_spawn_map() or "MILK" in relic_type:
        if cities is not None and cities <= 0:
            return "【空放·当前0城无落点·勿选】"
        return "【条件即时·需已有城市·落在最新城3环】"
    return "【即时】"


# 标准速度（CostMultiplier=100）下的参考回合；其它速度按 multiplier/100 缩放
_STD_EARLY_ANCIENT_END = 40
_STD_MID_GAME_END = 100
_STD_BARBARIAN_CAUTION_END = 15
_STD_ECHO_HORIZON = 10

# Civ6 GameSpeeds.CostMultiplier（与 Haikesi ScaleTurnForGameSpeed 一致）
DEFAULT_SPEED_MULTIPLIER_STANDARD = 100
DEFAULT_SPEED_MULTIPLIER_ONLINE = 50
DEFAULT_SPEED_MULTIPLIER_QUICK = 67


def scale_turn_for_game_speed(standard_turn: int, *, cost_multiplier: int = 100) -> int:
    """Match Haikesi ScaleTurnForGameSpeed: standardTurn * CostMultiplier / 100."""
    mult = cost_multiplier if cost_multiplier > 0 else 100
    return max(1, round(standard_turn * mult / 100))


def scrape_ctx_wire_meta(ctx_lines: list[str]) -> dict[str, str]:
    """Extract ERA/SPEED from raw CTX wire when full overview parse fails (MP)."""
    meta: dict[str, str] = {}
    for ln in ctx_lines:
        if ln.startswith("ERA|"):
            parts = ln.split("|")
            if len(parts) >= 2 and parts[1]:
                meta["era_name"] = parts[1]
        elif ln.startswith("SPEED|"):
            parts = ln.split("|")
            if len(parts) >= 3 and parts[2]:
                meta["game_speed_name"] = parts[2]
            if len(parts) >= 4 and str(parts[3]).isdigit():
                meta["speed_cost_multiplier"] = parts[3]
    return meta


def recover_overview_lines(ctx_lines: list[str]) -> list[str]:
    """Re-slice overview wire from CTX body when split left ov_lines empty."""
    view_idx = next(
        (
            i
            for i, ln in enumerate(ctx_lines)
            if ln.startswith("RST_MOD|") or ln.startswith("VIEWER|")
        ),
        len(ctx_lines),
    )
    wc_idx = next(
        (i for i in range(view_idx) if ctx_lines[i].startswith("WC_")),
        view_idx,
    )
    chunk = ctx_lines[:wc_idx]
    start = next(
        (i for i, ln in enumerate(chunk) if re.match(r"^\d+\|\d+\|", ln)),
        None,
    )
    if start is None:
        return []
    return chunk[start:]


def infer_era_label(
    *,
    turn: int,
    era_name: str = "",
    cost_multiplier: int = 100,
) -> str:
    if era_name and era_name not in ("Unknown", "未知"):
        return era_name
    ancient_end = scale_turn_for_game_speed(_STD_EARLY_ANCIENT_END, cost_multiplier=cost_multiplier)
    mid_end = scale_turn_for_game_speed(_STD_MID_GAME_END, cost_multiplier=cost_multiplier)
    if turn <= ancient_end:
        return f"远古早期（Turn {turn}；CTX 未提供时代名时的推断）"
    if turn <= mid_end:
        return f"古典—中世纪（Turn {turn}；CTX 未提供时代名时的推断）"
    return f"中后期（Turn {turn}；CTX 未提供时代名时的推断）"


def early_game_phase_thresholds(*, cost_multiplier: int = 100) -> dict[str, int]:
    """Speed-scaled turn windows for prompt heuristics."""
    return {
        "ancient_end": scale_turn_for_game_speed(
            _STD_EARLY_ANCIENT_END, cost_multiplier=cost_multiplier
        ),
        "barbarian_caution_end": scale_turn_for_game_speed(
            _STD_BARBARIAN_CAUTION_END, cost_multiplier=cost_multiplier
        ),
        "echo_horizon": scale_turn_for_game_speed(
            _STD_ECHO_HORIZON, cost_multiplier=cost_multiplier
        ),
    }


def human_relic_strategy_hint(relic_type: str, text_xml: Path | None = None) -> str:
    """Structured follow/counter hint from human hex name+effect (keyword-driven)."""
    if not relic_type:
        return ""
    info = get_ai_relic_catalog(text_xml).get(relic_type, {})
    blob = _strip_civ_icons(
        f"{info.get('name', '')} {info.get('description', '')}"
    )
    # 建造者/种植类必须先于「单位」匹配（种地仙人描述含「该单位为特殊建造者」）
    if any(
        k in blob
        for k in ("建造者", "改良", "种植", "种地", "农场", "伐木", "矿山", "收获资源")
    ):
        return (
            "人类倾向：基建/地块开发。可跟风：工人 echo、食物/生产力百分比；"
            "可对抗：军事骚扰或抢扩张窗口。勿仅因文案出现「单位」二字判为军事。"
        )
    if any(k in blob for k in ("港口", "灯塔", "海运", "海岸", "航海", "商业")):
        return (
            "人类倾向：海运/金币成长。可跟风：引国际商路、贸易互利类；"
            "可对抗：南蛮入侵拖延沿海节奏、或抢军事/扩张窗口。"
        )
    if any(k in blob for k in ("科技", "学院", "科研", "太空")):
        return "人类倾向：科技成长。可跟风：百分比科技/工人改良；可对抗：干扰扩张或军事施压。"
    if any(k in blob for k in ("文化", "旅游", "巨作", "剧院")):
        return "人类倾向：文化/旅游。可跟风：文化百分比；可对抗：军事或宗教压力。"
    if any(k in blob for k in ("信仰", "宗教", "传教")):
        return "人类倾向：宗教。可跟风：信仰/商路传教；可对抗：抢先知窗口或军事干扰。"
    if any(k in blob for k in ("军队", "战斗", "征兵", "战士", "骑兵", "军事单位")):
        return "人类倾向：军事。可跟风：军事 echo/扩张；可对抗：经济/科技长线或外交合纵。"
    if any(k in blob for k in ("食物", "人口", "成长")):
        return "人类倾向：人口/粮食。可跟风：食物百分比或资源创建；可对抗：军事骚扰或抢地。"
    if any(k in blob for k in ("金币", "金锭", "商路")):
        return "人类倾向：经济/金币。可跟风：金币百分比或贸易互利；可对抗：军事施压。"
    return (
        "人类倾向：不明（文案未匹配常见路线）。"
        "请只根据效果正文判断跟风/对抗/忽略，勿臆造军事或科技倾向。"
    )


def format_option_lines(
    options: list[str],
    text_xml: Path | None = None,
    *,
    cities: int | None = None,
) -> list[str]:
    catalog = get_ai_relic_catalog(text_xml)
    lines: list[str] = []
    for opt in options:
        info = catalog.get(opt, {})
        name = _strip_civ_icons(info.get("name", opt))
        desc = enrich_relic_description(
            opt, _strip_civ_icons(info.get("description", ""))
        )
        tag = relic_timing_tag(opt, cities=cities)
        lines.append(f"- {tag} {opt}: {name} — {desc}")
    return lines


# ---------------------------------------------------------------------------
# Per-leader diplomatic / fog-of-war views (InGame)
# ---------------------------------------------------------------------------

# Real Strategy (Infixo) victory-route labels for prompts
RST_STRATEGY_LABELS: dict[str, str] = {
    "CONQUEST": "征服",
    "SCIENCE": "科技",
    "CULTURE": "文化",
    "RELIGION": "宗教",
    "DIPLO": "外交",
    "NONE": "未定",
}

BELIEF_CLASS_LABELS: dict[str, str] = {
    "BELIEF_CLASS_PANTHEON": "万神殿",
    "BELIEF_CLASS_FOLLOWER": "信徒",
    "BELIEF_CLASS_FOUNDER": "创始人",
    "BELIEF_CLASS_ENHANCER": "强化",
    "BELIEF_CLASS_WORSHIP": "崇拜",
}


@dataclass
class RstStrategyView:
    """Soft-read snapshot from Real Strategy (ExposedMembers.RST.Data)."""

    active_strategy: str = "NONE"
    priorities: dict[str, float] = field(default_factory=dict)
    active_defense: bool | None = None
    active_catching: bool | None = None


def build_rst_strategies_query(viewer_ids: list[int]) -> str:
    """Soft-read Real Strategy ActiveStrategy/Priorities for AI viewers.

    Safe when Real Strategy is absent (emits RST_MOD|0). Prefer Haikesi
    GamePlay or InGame — both share ExposedMembers with Real Strategy.
    """
    ids = sorted({int(i) for i in viewer_ids if int(i) >= 0})
    if not ids:
        return f'print("RST_MOD|0")\nprint("{SENTINEL}")'
    id_list = ", ".join(str(i) for i in ids)
    return f"""
local viewers = {{{id_list}}}
local rstMod = 0
pcall(function()
  local RST = ExposedMembers.RST
  if RST and RST.Data then rstMod = 1 end
end)
print("RST_MOD|" .. rstMod)
if rstMod == 1 then
  for _, vid in ipairs(viewers) do
    pcall(function()
      local d = ExposedMembers.RST.Data[vid]
      if not d then return end
      local active = tostring(d.ActiveStrategy or "NONE")
      local pri = d.Priorities or {{}}
      local def, catch = -1, -1
      if d.ActiveDefense ~= nil then def = d.ActiveDefense and 1 or 0 end
      if d.ActiveCatching ~= nil then catch = d.ActiveCatching and 1 or 0 end
      print("RST|" .. vid .. "|" .. active
        .. "|" .. string.format("%.1f", tonumber(pri.CONQUEST) or 0)
        .. "|" .. string.format("%.1f", tonumber(pri.SCIENCE) or 0)
        .. "|" .. string.format("%.1f", tonumber(pri.CULTURE) or 0)
        .. "|" .. string.format("%.1f", tonumber(pri.RELIGION) or 0)
        .. "|" .. string.format("%.1f", tonumber(pri.DIPLO) or 0)
        .. "|" .. def .. "|" .. catch)
    end)
  end
end
print("{SENTINEL}")
"""


def parse_rst_line(line: str) -> tuple[int, RstStrategyView] | None:
    """Parse one RST|vid|active|c|s|cu|r|d|def|catch line."""
    if not line.startswith("RST|"):
        return None
    p = line.split("|")
    if len(p) < 8:
        return None
    priorities = {
        "CONQUEST": float(p[3] or 0),
        "SCIENCE": float(p[4] or 0),
        "CULTURE": float(p[5] or 0),
        "RELIGION": float(p[6] or 0),
        "DIPLO": float(p[7] or 0),
    }
    def_flag = int(float(p[8])) if len(p) > 8 else -1
    catch_flag = int(float(p[9])) if len(p) > 9 else -1
    return int(p[1]), RstStrategyView(
        active_strategy=p[2] or "NONE",
        priorities=priorities,
        active_defense=None if def_flag < 0 else bool(def_flag),
        active_catching=None if catch_flag < 0 else bool(catch_flag),
    )


def parse_rst_strategies(lines: list[str]) -> tuple[dict[int, RstStrategyView], bool | None]:
    """Parse build_rst_strategies_query output."""
    out: dict[int, RstStrategyView] = {}
    rst_available: bool | None = None
    for raw in lines:
        line = raw.strip()
        if not line or line == SENTINEL:
            continue
        if line.startswith("RST_MOD|"):
            p = line.split("|")
            if len(p) >= 2:
                rst_available = p[1] == "1"
            continue
        parsed = parse_rst_line(line)
        if parsed is not None:
            vid, view = parsed
            out[vid] = view
    return out, rst_available


@dataclass
class DiploModifierView:
    """One diplomatic opinion modifier (other civ → viewer)."""

    score: int
    text: str


@dataclass
class MetCivView:
    player_id: int
    civ_name: str
    leader_name: str
    score: int
    cities: int
    pop: int
    sci: float
    cul: float
    gold: float
    mil: int
    techs: int
    civics: int
    faith: float
    diplomatic_state: str
    relationship_score: int
    is_at_war: bool
    grievances: int  # viewer → them (我对彼不满)
    grievances_against_me: int = 0  # them → viewer (彼对我不满)
    modifiers: list[DiploModifierView] = field(default_factory=list)


@dataclass
class VisibleThreatAgg:
    owner_id: int
    owner_name: str
    count: int
    nearest_dist: int
    is_at_war: bool = False
    is_minor: bool = False  # 城邦等非主要文明


@dataclass
class VictoryPeerStat:
    """Victory-relevant stats for self or a met major (viewer fog)."""

    player_id: int
    civ_name: str
    score: int = 0
    science_vp: int = 0
    science_needed: int = 50
    diplo_vp: int = 0
    tourism: int = 0  # 每回合旅游业绩（WorldRankings 行李箱）
    mil: int = 0
    techs: int = 0
    civics: int = 0
    rel_cities: int = 0
    spaceports: int = 0
    holds_own_capital: bool = True
    staycationers: int = 0  # 国内游客
    visiting_tourists: int = 0  # 国际游客累计（GetTouristsTo）


@dataclass
class CityView:
    """Viewer's own city detail (full knowledge)."""

    city_id: int
    name: str
    pop: int
    food: float
    prod: float
    gold: float
    sci: float
    cul: float
    faith: float
    housing: float
    amenities: int
    amenities_needed: int
    districts: str
    producing: str
    turns_left: int
    loyalty: float


@dataclass
class LeaderView:
    """One AI leader's self-knowledge + fog/diplo-filtered world view."""

    player_id: int
    civ_name: str = ""
    leader_name: str = ""
    score: int = 0
    cities: int = 0
    pop: int = 0
    sci: float = 0.0
    cul: float = 0.0
    gold: float = 0.0
    mil: int = 0
    techs: int = 0
    civics: int = 0
    faith: float = 0.0
    current_research: str = "无"
    current_civic: str = "无"
    leader_traits: list[tuple[str, str]] = field(default_factory=list)
    civ_traits: list[tuple[str, str]] = field(default_factory=list)
    agendas: list[tuple[str, str]] = field(default_factory=list)
    own_cities: list[CityView] = field(default_factory=list)
    met: list[MetCivView] = field(default_factory=list)
    threats: list[VisibleThreatAgg] = field(default_factory=list)
    rst: RstStrategyView | None = None
    religion: CivReligionBeliefs | None = None
    victory_peers: list[VictoryPeerStat] = field(default_factory=list)
    favor: int = 0  # diplomatic favor (世界会议投票资源)


def _leader_trait_corpus(view: LeaderView) -> str:
    chunks: list[str] = []
    for name, desc in view.leader_traits + view.civ_traits + view.agendas:
        chunks.append(name)
        chunks.append(desc)
    return _strip_civ_icons(" ".join(chunks))


def _rst_strategy_hint(rst: RstStrategyView | None, relic_type: str) -> str | None:
    if rst is None or not rst.active_strategy or rst.active_strategy == "NONE":
        return None
    strat = rst.active_strategy
    if strat == "CONQUEST" and (
        "BARBARIAN" in relic_type or relic_type.startswith("NW_AI_ECHO_")
    ):
        return "Real Strategy 主战略=征服，军事/混乱类候选偏高"
    if strat == "SCIENCE" and (
        relic_type.startswith("NW_AI_STATS_2")
        or relic_type.startswith("NW_AI_ECHO_BUILDER")
        or relic_type in get_resource_spawn_map()
    ):
        return "Real Strategy 主战略=科技，发展/改良类候选偏高"
    if strat == "CULTURE" and relic_type.startswith("NW_AI_STATS_1"):
        return "Real Strategy 主战略=文化，文化产出类候选偏高"
    if strat == "RELIGION" and (
        relic_type.startswith("NW_AI_STATS_4") or "CELESTIAL" in relic_type
    ):
        return "Real Strategy 主战略=宗教，信仰/商路类候选偏高"
    if strat == "DIPLO" and "CELESTIAL" in relic_type:
        return "Real Strategy 主战略=外交，贸易互利类候选偏高"
    return None


def build_trait_option_synergy_hints(
    view: LeaderView,
    options: list[str],
    text_xml: Path | None = None,
) -> str:
    """Auto-match leader trait/agenda text to candidate relic types (no civ hardcode)."""
    corpus = _leader_trait_corpus(view)
    if not corpus or not options:
        return ""

    lines: list[str] = []
    for opt in options:
        hints: list[str] = []
        if "BARBARIAN" in opt and any(
            k in corpus for k in ("蛮族", "哨站", "部落", "肃清", "征集")
        ):
            hints.append("能力与蛮族/清营相关；南蛮类需权衡全场连带（触发者免疫）")
        if "CELESTIAL" in opt and any(
            k in corpus for k in ("贸易", "商路", "商人", "同盟", "Camp", "牧场")
        ):
            hints.append("贸易/同盟特性与国际商路互利协同")
        if opt.startswith("NW_AI_ECHO_SETTLER") and any(
            k in corpus for k in ("扩张", "城市", "冻土", "领土", "定居")
        ):
            hints.append("扩张/铺城特性与开拓者翻倍协同")
        if opt.startswith("NW_AI_ECHO_BUILDER") and any(
            k in corpus for k in ("改良", "建造", "梯田", "山脉", "地块")
        ):
            hints.append("改良/地形特性与工人翻倍协同")
        if opt.startswith("NW_AI_ECHO_") and any(
            k in corpus for k in ("征集", "雇佣", "军队", "战斗力", "黑军", "骑兵")
        ):
            suffix = opt.removeprefix("NW_AI_ECHO_")
            unit = _ECHO_UNIT_LABELS.get(suffix, "")
            if unit and unit in corpus:
                hints.append(f"能力文案提及{unit}，与对应 echo 直接协同")
        if (
            opt in get_resource_spawn_map()
            and int(view.cities or 0) > 0
            and any(k in corpus for k in ("资源", "奢侈", "食物", "人口", "宜居"))
        ):
            hints.append("资源/人口特性与资源生成协同（需已有城市）")
        rst_hint = _rst_strategy_hint(view.rst, opt)
        if rst_hint and rst_hint not in hints:
            hints.append(rst_hint)
        if hints:
            catalog = get_ai_relic_catalog(text_xml)
            short = _strip_civ_icons(catalog.get(opt, {}).get("name", opt))
            lines.append(f"  · {short}（{opt}）：{'；'.join(hints[:2])}")

    if not lines:
        return ""
    return (
        "【能力与候选协同提示·弱提示可忽略】"
        "（自动匹配；贴脸威胁/交战/生存压力时优先局面，可完全忽略本段；"
        "已有≥3种不同奢侈时资源创建类提示失效）\n"
        + "\n".join(lines)
    )


def build_leader_views_query(viewer_ids: list[int]) -> str:
    """FireTuner query that simulates each AI's diplo + fog view.

    Emits VIEWER / TRAIT / AGENDA / CITY / MET / DIPMOD / THREAT lines per viewer.
    Soft-reads Real Strategy when present: RST_MOD / RST lines.
    Also emits FAITH / FBELIEF for pantheon + religion tenets.
    Also emits VSTAT for self+met victory progress (per-viewer fog).
    """
    ids = sorted({int(i) for i in viewer_ids if int(i) >= 0})
    if not ids:
        return f'print("{SENTINEL}")'
    id_list = ", ".join(str(i) for i in ids)
    return f"""
local viewers = {{{id_list}}}
local states = {{"ALLIED","DECLARED_FRIEND","FRIENDLY","NEUTRAL","UNFRIENDLY","DENOUNCED","WAR"}}
-- GetDiplomaticStateIndex / GetGrievancesAgainst 仅 UI；联机 CTX 在 Gameplay，需 Script API + UI 缓存
local function shortDiploState(raw)
  if raw == nil then return nil end
  local s = tostring(raw)
  s = s:gsub("^DIPLO_STATE_", "")
  if s == "ALLIED" or s == "DECLARED_FRIEND" or s == "FRIENDLY" or s == "NEUTRAL"
      or s == "UNFRIENDLY" or s == "DENOUNCED" or s == "WAR" then
    return s
  end
  return nil
end
local function readUiDipPacked(fromId, towardId)
  local key = tostring(fromId) .. "_" .. tostring(towardId)
  if ExposedMembers ~= nil and ExposedMembers.Haikesi_UIDipByPair ~= nil then
    local packed = ExposedMembers.Haikesi_UIDipByPair[key]
    if packed ~= nil and tostring(packed) ~= "" then
      return tostring(packed)
    end
  end
  local prop = Game:GetProperty("PROP_NW_HAIKESI_UI_DIP_" .. key)
  if prop ~= nil and tostring(prop) ~= "" then
    return tostring(prop)
  end
  return nil
end
local function resolveDiploStateName(fromId, towardId, atWar)
  -- fromId 对 towardId 的观感（与旧逻辑：对方 AI 看 viewer 一致 → 调用处传 tid, vid）
  -- 交战/同盟以 Script Diplomacy 为准（Index API 在 Gameplay 常空/恒 0）
  local name = nil
  pcall(function()
    local d = Players[fromId]:GetDiplomacy()
    if d == nil then return end
    if atWar or (d.IsAtWarWith and d:IsAtWarWith(towardId)) then
      name = "WAR"
    elseif d.HasAllied and d:HasAllied(towardId) then
      name = "ALLIED"
    elseif d.HasDeclaredFriendship and d:HasDeclaredFriendship(towardId) then
      name = "DECLARED_FRIEND"
    end
  end)
  if name == nil then
    local packed = readUiDipPacked(fromId, towardId)
    if packed ~= nil then
      local st = string.match(packed, "^([^;]*);")
      name = shortDiploState(st) or st
    end
  end
  if name == nil then
    pcall(function()
      local ai = Players[fromId]:GetDiplomaticAI()
      if ai == nil then return end
      if ai.GetDiplomaticStateIndex ~= nil then
        local idx = ai:GetDiplomaticStateIndex(towardId)
        if idx ~= nil then
          local row = GameInfo.DiplomaticStates[idx]
          if row and row.StateType then
            name = shortDiploState(row.StateType)
          end
          if name == nil then
            name = states[(tonumber(idx) or -1) + 1]
          end
        end
      end
      if name == nil and ai.GetDiplomaticState ~= nil then
        local st = ai:GetDiplomaticState(towardId)
        name = shortDiploState(st)
        if name == nil and st ~= nil then
          local row = GameInfo.DiplomaticStates[st]
          if row and row.StateType then
            name = shortDiploState(row.StateType)
          else
            for r in GameInfo.DiplomaticStates() do
              if r.Hash == st or r.Index == st then
                name = shortDiploState(r.StateType)
                break
              end
            end
          end
        end
      end
    end)
  end
  if atWar then
    name = "WAR"
  end
  return name or "NEUTRAL"
end
local function resolveGrievances(fromId, towardId)
  -- GetGrievancesAgainst 仅 UI；Gameplay 直调常 nil → 优先读 UI 缓存
  local packed = readUiDipPacked(fromId, towardId)
  if packed ~= nil then
    local _, _, gr = string.match(packed, "^([^;]*);([^;]*);([^;]*)$")
    if gr ~= nil then return tonumber(gr) or 0 end
  end
  local g = nil
  pcall(function()
    local d = Players[fromId]:GetDiplomacy()
    if d and d.GetGrievancesAgainst then
      g = d:GetGrievancesAgainst(towardId)
    end
  end)
  if g ~= nil then return tonumber(g) or 0 end
  return 0
end
local function resolveRelScore(fromId, towardId)
  -- GetDiplomaticScore 在 Gameplay 常恒 0；优先 UI 缓存，避免挡住真实分数
  local packed = readUiDipPacked(fromId, towardId)
  if packed ~= nil then
    local _, sc, _ = string.match(packed, "^([^;]*);([^;]*);([^;]*)$")
    if sc ~= nil then
      local n = tonumber(sc)
      if n ~= nil then return n end
    end
  end
  local score = 0
  local got = false
  pcall(function()
    local ai = Players[fromId]:GetDiplomaticAI()
    if ai == nil then return end
    if ai.GetDiplomaticScore ~= nil then
      local s = ai:GetDiplomaticScore(towardId)
      if s ~= nil then score = tonumber(s) or 0; got = true; return end
    end
    if ai.GetDiplomaticModifiers ~= nil then
      local mods = ai:GetDiplomaticModifiers(towardId)
      if mods then
        local sum = 0
        for _, mod in ipairs(mods) do sum = sum + (mod.Score or 0) end
        score = sum
        got = true
      end
    end
  end)
  if got then return score end
  return 0
end
local function safeLookup(key)
  if not key or key == "" then return "" end
  local ok, t = pcall(function() return Locale.Lookup(key) end)
  if ok and t and t ~= "" then return tostring(t):gsub("|","/") end
  return tostring(key):gsub("|","/")
end
-- Real Strategy soft dependency (Infixo): ExposedMembers.RST.Data
local rstMod = 0
pcall(function()
  local RST = ExposedMembers.RST
  if RST and RST.Data then rstMod = 1 end
end)
print("RST_MOD|" .. rstMod)
local function printRst(vid)
  if rstMod ~= 1 then return end
  pcall(function()
    local d = ExposedMembers.RST.Data[vid]
    if not d then return end
    local active = tostring(d.ActiveStrategy or "NONE")
    local pri = d.Priorities or {{}}
    local def, catch = -1, -1
    if d.ActiveDefense ~= nil then def = d.ActiveDefense and 1 or 0 end
    if d.ActiveCatching ~= nil then catch = d.ActiveCatching and 1 or 0 end
    print("RST|" .. vid .. "|" .. active
      .. "|" .. string.format("%.1f", tonumber(pri.CONQUEST) or 0)
      .. "|" .. string.format("%.1f", tonumber(pri.SCIENCE) or 0)
      .. "|" .. string.format("%.1f", tonumber(pri.CULTURE) or 0)
      .. "|" .. string.format("%.1f", tonumber(pri.RELIGION) or 0)
      .. "|" .. string.format("%.1f", tonumber(pri.DIPLO) or 0)
      .. "|" .. def .. "|" .. catch)
  end)
end
local function printFaith(vid)
  local panType, panName = "NONE", ""
  local relType, relName = "NONE", ""
  pcall(function()
    local pr = Players[vid]:GetReligion()
    local pan = pr:GetPantheon()
    if pan and pan >= 0 and GameInfo.Beliefs[pan] then
      local b = GameInfo.Beliefs[pan]
      panType = b.BeliefType
      panName = safeLookup(b.Name)
    end
    local rt = pr:GetReligionTypeCreated()
    if rt and rt >= 0 and GameInfo.Religions[rt] then
      local r = GameInfo.Religions[rt]
      if r.ReligionType ~= "RELIGION_PANTHEON" then
        relType = r.ReligionType
        relName = safeLookup(r.Name)
      end
    end
  end)
  local cfg = PlayerConfigurations[vid]
  local civName = cfg and safeLookup(cfg:GetCivilizationShortDescription()) or ""
  local leaderName = cfg and safeLookup(cfg:GetLeaderName()) or ""
  print("FAITH|" .. vid .. "|" .. civName .. "|" .. leaderName
    .. "|" .. panType .. "|" .. panName .. "|" .. relType .. "|" .. relName)
  if panType ~= "NONE" and GameInfo.Beliefs[panType] then
    local b = GameInfo.Beliefs[panType]
    local desc = safeLookup(b.Description):gsub("\\n", " ")
    print("FBELIEF|" .. vid .. "|BELIEF_CLASS_PANTHEON|" .. panType .. "|" .. panName .. "|" .. desc)
  end
  pcall(function()
    local religions = Game.GetReligion():GetReligions()
    if not religions then return end
    for _, religion in ipairs(religions) do
      if religion.Founder == vid and religion.Beliefs then
        for _, beliefIdx in ipairs(religion.Beliefs) do
          local b = GameInfo.Beliefs[beliefIdx]
          if b and b.BeliefClassType ~= "BELIEF_CLASS_PANTHEON" then
            local desc = safeLookup(b.Description):gsub("\\n", " ")
            print("FBELIEF|" .. vid .. "|" .. tostring(b.BeliefClassType)
              .. "|" .. b.BeliefType .. "|" .. safeLookup(b.Name) .. "|" .. desc)
          end
        end
      end
    end
  end)
end
-- GetNumTechsResearched / 军力·旅游·外交VP 在 Gameplay 常空；优先 UI 缓存。
-- 军力：失败返回 -1（未知），禁止用假 0 冒充「无军队」。
local function countTechsResearched(p)
  local n = nil
  pcall(function()
    local te = p:GetTechs()
    if te == nil then return end
    if te.GetNumTechsResearched ~= nil then
      n = tonumber(te:GetNumTechsResearched())
      return
    end
    local c = 0
    for row in GameInfo.Technologies() do
      if te:HasTech(row.Index) then c = c + 1 end
    end
    n = c
  end)
  return n
end
local function countCivicsCompleted(p)
  local n = nil
  pcall(function()
    local cu = p:GetCulture()
    if cu == nil then return end
    if cu.GetNumCivicsCompleted ~= nil then
      n = tonumber(cu:GetNumCivicsCompleted())
      return
    end
    local c = 0
    for row in GameInfo.Civics() do
      if cu:HasCivic(row.Index) then c = c + 1 end
    end
    n = c
  end)
  return n
end
local function readUiVstatPacked(pid)
  if ExposedMembers ~= nil and ExposedMembers.Haikesi_UIVstatByPlayer ~= nil then
    local packed = ExposedMembers.Haikesi_UIVstatByPlayer[pid]
    if packed ~= nil and tostring(packed) ~= "" then
      return tostring(packed)
    end
  end
  local prop = Game:GetProperty("PROP_NW_HAIKESI_UI_VSTAT_" .. tostring(pid))
  if prop ~= nil and tostring(prop) ~= "" then
    return tostring(prop)
  end
  return nil
end
local function resolveMilitaryStrength(pid, p)
  -- 优先 UI 缓存（仅在 UI 成功读到时写入；缺键=未知）
  if ExposedMembers ~= nil and ExposedMembers.Haikesi_UIMilitaryByPlayer ~= nil then
    local cached = ExposedMembers.Haikesi_UIMilitaryByPlayer[pid]
    if cached ~= nil then
      return tonumber(cached) or 0
    end
  end
  local prop = Game:GetProperty("PROP_NW_HAIKESI_UI_MIL_" .. tostring(pid))
  if prop ~= nil then
    local n = tonumber(prop)
    if n ~= nil then return n end
  end
  local mil = nil
  pcall(function()
    local st = p:GetStats()
    if st.GetMilitaryStrengthWithoutTreasury ~= nil then
      mil = st:GetMilitaryStrengthWithoutTreasury()
    elseif st.GetMilitaryStrength ~= nil then
      mil = st:GetMilitaryStrength()
    end
  end)
  if mil == nil then return -1 end
  return tonumber(mil) or -1
end
local function printVStat(vid, tid, civName)
  pcall(function()
    local p = Players[tid]
    if not p then return end
    local st = p:GetStats()
    local sciVP, sciNeed, diploVP, tourism = 0, 50, 0, 0
    local milStr, techs, civics, relCities, stay, visiting = -1, -1, -1, 0, 0, 0
    local score, spaceports, holds = 0, 0, 1
    pcall(function() score = p:GetScore() end)
    pcall(function() sciVP = st:GetScienceVictoryPoints() or 0 end)
    pcall(function() sciNeed = st:GetScienceVictoryPointsTotalNeeded() or 50 end)
    pcall(function() diploVP = st:GetDiplomaticVictoryPoints() or 0 end)
    pcall(function() tourism = st:GetTourism() or 0 end)
    pcall(function() stay = p:GetCulture():GetStaycationers() or 0 end)
    pcall(function() visiting = p:GetCulture():GetTouristsTo() or 0 end)
    -- packed: diplo;tourism;stay;favor;visiting[;techs;civics]（后两段可空=未知）
    local packed = readUiVstatPacked(tid)
    if packed ~= nil then
      local parts = {{}}
      local start = 1
      while true do
        local i = string.find(packed, ";", start, true)
        if not i then
          table.insert(parts, string.sub(packed, start))
          break
        end
        table.insert(parts, string.sub(packed, start, i - 1))
        start = i + 1
      end
      if parts[1] ~= nil then diploVP = tonumber(parts[1]) or diploVP end
      if parts[2] ~= nil then tourism = tonumber(parts[2]) or tourism end
      if parts[3] ~= nil then stay = tonumber(parts[3]) or stay end
      if parts[5] ~= nil and parts[5] ~= "" then visiting = tonumber(parts[5]) or visiting end
      if parts[6] ~= nil and parts[6] ~= "" then techs = tonumber(parts[6]) or techs end
      if parts[7] ~= nil and parts[7] ~= "" then civics = tonumber(parts[7]) or civics end
    end
    milStr = resolveMilitaryStrength(tid, p)
    if techs < 0 then
      local n = countTechsResearched(p)
      if n ~= nil then techs = n else techs = -1 end
    end
    if civics < 0 then
      local n = countCivicsCompleted(p)
      if n ~= nil then civics = n else civics = -1 end
    end
    pcall(function() relCities = st:GetNumCitiesFollowingReligion() or 0 end)
    pcall(function()
      for _, city in p:GetCities():Members() do
        for _, d in city:GetDistricts():Members() do
          local dInfo = GameInfo.Districts[d:GetType()]
          if dInfo and dInfo.DistrictType == "DISTRICT_SPACEPORT" and d:IsComplete() then
            spaceports = spaceports + 1
          end
        end
      end
    end)
    pcall(function()
      local cap = p:GetCities():GetCapitalCity()
      if cap and not cap:IsOriginalCapital() then holds = 0 end
      if not cap then holds = 0 end
    end)
    print("VSTAT|" .. vid .. "|" .. tid .. "|" .. civName
      .. "|" .. score .. "|" .. sciVP .. "|" .. sciNeed .. "|" .. diploVP
      .. "|" .. math.floor(tonumber(tourism) or 0) .. "|" .. milStr .. "|" .. techs .. "|" .. civics
      .. "|" .. relCities .. "|" .. spaceports .. "|" .. holds .. "|" .. stay
      .. "|" .. visiting)
  end)
end
local hashName = {{}}
for u in GameInfo.Units() do hashName[u.Hash] = u.UnitType end
for b in GameInfo.Buildings() do hashName[b.Hash] = b.BuildingType end
for d in GameInfo.Districts() do hashName[d.Hash] = d.DistrictType end
for p in GameInfo.Projects() do hashName[p.Hash] = p.ProjectType end
local function prodLabel(typeKey)
  if not typeKey or typeKey == "" or typeKey == "nothing" then return "IDLE" end
  local row = GameInfo.Units[typeKey] or GameInfo.Buildings[typeKey] or GameInfo.Districts[typeKey] or GameInfo.Projects[typeKey]
  if row and row.Name then return safeLookup(row.Name) end
  return tostring(typeKey):gsub("UNIT_",""):gsub("BUILDING_",""):gsub("DISTRICT_",""):gsub("PROJECT_","")
end
local function yieldTriple(p)
  local sci, cul, gold = 0, 0, 0
  pcall(function() sci = p:GetTechs():GetScienceYield() end)
  pcall(function() cul = p:GetCulture():GetCultureYield() end)
  pcall(function()
    gold = p:GetTreasury():GetGoldYield() - p:GetTreasury():GetTotalMaintenance()
  end)
  return sci, cul, gold
end
local function empireStats(pid)
  local p = Players[pid]
  local score = 0
  pcall(function() score = p:GetScore() end)
  local nCities, totalPop = 0, 0
  pcall(function()
    for _, c in p:GetCities():Members() do
      nCities = nCities + 1
      totalPop = totalPop + c:GetPopulation()
    end
  end)
  local sci, cul, gold = yieldTriple(p)
  local mil = resolveMilitaryStrength(pid, p)
  local techs = countTechsResearched(p)
  local civics = countCivicsCompleted(p)
  if techs == nil then techs = -1 end
  if civics == nil then civics = -1 end
  -- VIEWER 也吃 UI 科技/市政缓存（Gameplay 遍历 HasTech 常失败→假 0）
  local packed = readUiVstatPacked(pid)
  if packed ~= nil then
    local parts = {{}}
    local start = 1
    while true do
      local i = string.find(packed, ";", start, true)
      if not i then
        table.insert(parts, string.sub(packed, start))
        break
      end
      table.insert(parts, string.sub(packed, start, i - 1))
      start = i + 1
    end
    if parts[6] ~= nil and parts[6] ~= "" then techs = tonumber(parts[6]) or techs end
    if parts[7] ~= nil and parts[7] ~= "" then civics = tonumber(parts[7]) or civics end
  end
  local faith = 0
  pcall(function() faith = p:GetReligion():GetFaithYield() end)
  local research, civic = "无", "无"
  pcall(function()
    local t = p:GetTechs():GetResearchingTech()
    if t and t >= 0 and GameInfo.Technologies[t] then
      research = safeLookup(GameInfo.Technologies[t].Name)
    end
  end)
  pcall(function()
    local c = p:GetCulture():GetProgressingCivic()
    if c and c >= 0 and GameInfo.Civics[c] then
      civic = safeLookup(GameInfo.Civics[c].Name)
    end
  end)
  return score, nCities, totalPop, sci, cul, gold, mil, techs, civics, faith, research, civic
end
local function printTraits(vid, leaderType, civType)
  if leaderType and leaderType ~= "" then
    for row in GameInfo.LeaderTraits() do
      if row.LeaderType == leaderType then
        local tr = GameInfo.Traits[row.TraitType]
        if tr and tr.Name and tr.Description then
          local n = safeLookup(tr.Name)
          local d = safeLookup(tr.Description)
          if n ~= "" and d ~= "" and not string.find(n, "^LOC_") and not string.find(d, "^LOC_")
             and not string.find(tostring(tr.TraitType), "MAJOR_CIV")
             and not string.find(tostring(tr.TraitType), "IGNORE") then
            print("TRAIT|" .. vid .. "|LEADER|" .. n .. "|" .. d)
          end
        end
      end
    end
  end
  if civType and civType ~= "" then
    for row in GameInfo.CivilizationTraits() do
      if row.CivilizationType == civType then
        local tr = GameInfo.Traits[row.TraitType]
        if tr and tr.Name and tr.Description then
          local n = safeLookup(tr.Name)
          local d = safeLookup(tr.Description)
          if n ~= "" and d ~= "" and not string.find(n, "^LOC_") and not string.find(d, "^LOC_")
             and not string.find(tostring(tr.TraitType), "MAJOR_CIV")
             and not string.find(tostring(tr.TraitType), "IGNORE") then
            print("TRAIT|" .. vid .. "|CIV|" .. n .. "|" .. d)
          end
        end
      end
    end
  end
end
local function printAgendas(vid, leaderType)
  -- 历史议程来自静态表，不依赖 GetAgendaTypes（联机 Gameplay 常拿不到）
  local seen = {{}}
  if leaderType and leaderType ~= "" then
    for ha in GameInfo.HistoricalAgendas() do
      if ha.LeaderType == leaderType then
        local aDef = GameInfo.Agendas[ha.AgendaType]
        if aDef then
          local n = safeLookup(aDef.Name)
          local d = safeLookup(aDef.Description)
          if n ~= "" and d ~= "" and not string.find(n, "^LOC_") and not string.find(d, "^LOC_") then
            print("AGENDA|" .. vid .. "|" .. n .. "|" .. d)
            seen[aDef.Index] = true
            seen[ha.AgendaType] = true
          end
        end
      end
    end
  end
  -- 随机议程：仅当 API 可用时补全（领袖自己应知道）
  local okAg, agendas = pcall(function() return Players[vid]:GetAgendaTypes() end)
  if okAg and agendas then
    for _, agIdx in pairs(agendas) do
      if not seen[agIdx] then
        local aDef = GameInfo.Agendas[agIdx]
        if aDef and not seen[aDef.Index] then
          local n = safeLookup(aDef.Name)
          local d = safeLookup(aDef.Description)
          if n ~= "" and d ~= "" and not string.find(n, "^LOC_") and not string.find(d, "^LOC_") then
            print("AGENDA|" .. vid .. "|" .. n .. "|" .. d)
            seen[aDef.Index] = true
          end
        end
      end
    end
  end
end
for _, vid in ipairs(viewers) do
  if Players[vid] and Players[vid]:IsAlive() and Players[vid]:IsMajor() then
    local cfg = PlayerConfigurations[vid]
    local civName = safeLookup(cfg:GetCivilizationShortDescription())
    local leaderName = safeLookup(cfg:GetLeaderName())
    local leaderType = ""
    local civType = ""
    pcall(function() leaderType = cfg:GetLeaderTypeName() end)
    pcall(function() civType = cfg:GetCivilizationTypeName() end)
    local score, cities, pop, sci, cul, gold, mil, techs, civics, faith, research, civic = empireStats(vid)
    local favor = 0
    pcall(function() favor = Players[vid]:GetFavor() or 0 end)
    -- GetFavor 在 Gameplay 常 0；外交条 Favor 来自 UI 缓存第四段
    if (tonumber(favor) or 0) == 0 then
      local packed = readUiVstatPacked(vid)
      if packed ~= nil then
        local _, _, _, f = string.match(
          packed, "^([^;]*);([^;]*);([^;]*);([^;]*);?([^;]*)$")
        if f ~= nil then favor = tonumber(f) or 0 end
      end
    end
    print("VIEWER|" .. vid .. "|" .. civName .. "|" .. leaderName
      .. "|" .. score .. "|" .. cities .. "|" .. pop
      .. "|" .. string.format("%.1f", sci) .. "|" .. string.format("%.1f", cul) .. "|" .. string.format("%.1f", gold)
      .. "|" .. mil .. "|" .. techs .. "|" .. civics .. "|" .. string.format("%.1f", faith)
      .. "|" .. research .. "|" .. civic .. "|" .. favor)
    printTraits(vid, leaderType, civType)
    printAgendas(vid, leaderType)
    printRst(vid)
    printFaith(vid)
    printVStat(vid, vid, civName)
    pcall(function()
      for _, c in Players[vid]:GetCities():Members() do
        local cID = c:GetID()
        local cName = safeLookup(c:GetName())
        local cPop = c:GetPopulation()
        local g = c:GetGrowth()
        local producing = "nothing"
        local turnsLeft = 0
        pcall(function()
          local bq = c:GetBuildQueue()
          if bq:GetSize() > 0 then
            local h = bq:GetCurrentProductionTypeHash()
            if h and h ~= 0 then
              producing = hashName[h] or "UNKNOWN"
              turnsLeft = bq:GetTurnsLeft() or 0
            end
          end
        end)
        local dStr = ""
        pcall(function()
          for _, d in c:GetDistricts():Members() do
            local dInfo = GameInfo.Districts[d:GetType()]
            if dInfo and dInfo.DistrictType ~= "DISTRICT_CITY_CENTER" then
              local short = safeLookup(dInfo.Name)
              if short == "" then short = dInfo.DistrictType:gsub("DISTRICT_", "") end
              dStr = dStr .. (dStr ~= "" and "," or "") .. short
            end
          end
        end)
        local amNeed, amTotal, housing = 0, 0, 0
        pcall(function()
          amNeed = g:GetAmenitiesNeeded() or 0
          amTotal = amNeed + (g:GetAmenities() or 0)
          housing = g:GetHousing() or 0
        end)
        local loyalty = 100
        pcall(function()
          local ci = c:GetCulturalIdentity()
          if ci then loyalty = ci:GetLoyalty() or 100 end
        end)
        print("CITY|" .. vid .. "|" .. cID .. "|" .. cName .. "|" .. cPop
          .. "|" .. string.format("%.1f", c:GetYield(0))
          .. "|" .. string.format("%.1f", c:GetYield(1))
          .. "|" .. string.format("%.1f", c:GetYield(2))
          .. "|" .. string.format("%.1f", c:GetYield(3))
          .. "|" .. string.format("%.1f", c:GetYield(4))
          .. "|" .. string.format("%.1f", c:GetYield(5))
          .. "|" .. string.format("%.1f", housing)
          .. "|" .. amTotal .. "|" .. amNeed
          .. "|" .. dStr .. "|" .. prodLabel(producing) .. "|" .. turnsLeft
          .. "|" .. string.format("%.0f", loyalty))
      end
    end)
    local pDiplo = Players[vid]:GetDiplomacy()
    for tid = 0, 62 do
      if tid ~= vid and Players[tid] and Players[tid]:IsAlive() and Players[tid]:IsMajor() then
        local met = false
        pcall(function() met = pDiplo:HasMet(tid) end)
        if met then
          local tcfg = PlayerConfigurations[tid]
          local tciv = safeLookup(tcfg:GetCivilizationShortDescription())
          local tleader = safeLookup(tcfg:GetLeaderName())
          local tscore, tcities, tpop, tsci, tcul, tgold, tmil, ttechs, tcivics, tfaith = empireStats(tid)
          local stateName = "NEUTRAL"
          local relScore = 0
          local war = 0
          local griev = 0
          local grievMe = 0
          pcall(function()
            if pDiplo:IsAtWarWith(tid) then war = 1 end
          end)
          -- 不满：UI API；Gameplay 读 PROP_NW_HAIKESI_UI_DIP_from_to
          griev = resolveGrievances(vid, tid)
          grievMe = resolveGrievances(tid, vid)
          -- 关系：对方(tid)对 viewer(vid) 的观感；Index 仅 UI，Script 用 GetDiplomaticState
          stateName = resolveDiploStateName(tid, vid, war == 1)
          relScore = resolveRelScore(tid, vid)
          local modLines = {{}}
          pcall(function()
            local ai = Players[tid]:GetDiplomaticAI()
            if ai == nil or ai.GetDiplomaticModifiers == nil then return end
            local mods = ai:GetDiplomaticModifiers(vid)
            if mods then
              for _, mod in ipairs(mods) do
                local txt = tostring(mod.Text or ""):gsub("|", "/"):gsub("~", "-"):gsub("\\n", " ")
                if txt ~= "" and not string.find(txt, "^LOC_") then
                  table.insert(modLines, (mod.Score or 0) .. "|" .. txt)
                end
              end
            end
          end)
          print("MET|" .. vid .. "|" .. tid .. "|" .. tciv .. "|" .. tleader
            .. "|" .. tscore .. "|" .. tcities .. "|" .. tpop
            .. "|" .. string.format("%.1f", tsci) .. "|" .. string.format("%.1f", tcul) .. "|" .. string.format("%.1f", tgold)
            .. "|" .. tmil .. "|" .. ttechs .. "|" .. tcivics .. "|" .. string.format("%.1f", tfaith)
            .. "|" .. stateName .. "|" .. relScore .. "|" .. war .. "|" .. griev .. "|" .. grievMe)
          for _, ml in ipairs(modLines) do
            print("DIPMOD|" .. vid .. "|" .. tid .. "|" .. ml)
          end
          printVStat(vid, tid, tciv)
        end
      end
    end
    local pVis = PlayersVisibility[vid]
    local myPos = {{}}
    pcall(function()
      for _, c in Players[vid]:GetCities():Members() do
        table.insert(myPos, {{c:GetX(), c:GetY()}})
      end
      for _, u in Players[vid]:GetUnits():Members() do
        local ux, uy = u:GetX(), u:GetY()
        if ux ~= -9999 then table.insert(myPos, {{ux, uy}}) end
      end
    end)
    local threatAgg = {{}}
    if pVis then
      for pid = 0, 63 do
        if pid ~= vid and Players[pid] and Players[pid]:IsAlive() then
          local ownerName = "Barbarian"
          local isMinor = 0
          if pid ~= 63 then
            local ocfg = PlayerConfigurations[pid]
            if ocfg then ownerName = safeLookup(ocfg:GetCivilizationShortDescription()) end
            if ownerName == "" then ownerName = "Player" .. tostring(pid) end
            pcall(function()
              if Players[pid]:IsMinor() then isMinor = 1 end
            end)
          end
          local atWar = 0
          pcall(function()
            if pid ~= 63 and pDiplo ~= nil and pDiplo:IsAtWarWith(pid) then
              atWar = 1
            end
          end)
          for _, bu in Players[pid]:GetUnits():Members() do
            local bx, by = bu:GetX(), bu:GetY()
            if bx ~= -9999 then
              local visible = false
              pcall(function() visible = pVis:IsVisible(bx, by) end)
              if visible then
                local uType = bu:GetType()
                local entry = uType and GameInfo.Units[uType] or nil
                local bcs = entry and entry.Combat or 0
                local brs = entry and entry.RangedCombat or 0
                if bcs > 0 or brs > 0 then
                  local minDist = 999
                  for _, pos in ipairs(myPos) do
                    local d = Map.GetPlotDistance(pos[1], pos[2], bx, by)
                    if d < minDist then minDist = d end
                  end
                  local agg = threatAgg[pid]
                  if not agg then
                    agg = {{name=ownerName, count=0, dist=999, war=atWar, minor=isMinor}}
                    threatAgg[pid] = agg
                  end
                  agg.count = agg.count + 1
                  if minDist < agg.dist then agg.dist = minDist end
                end
              end
            end
          end
        end
      end
    end
    for pid, agg in pairs(threatAgg) do
      print("THREAT|" .. vid .. "|" .. pid .. "|" .. agg.name .. "|" .. agg.count
        .. "|" .. agg.dist .. "|" .. tostring(agg.war or 0) .. "|" .. tostring(agg.minor or 0))
    end
  end
end
print("{SENTINEL}")
""".replace("{SENTINEL}", SENTINEL)


def parse_leader_views(lines: list[str]) -> tuple[dict[int, LeaderView], bool | None]:
    """Parse build_leader_views_query output into per-viewer LeaderView.

    Returns (views, rst_available). rst_available is True/False when Real Strategy
    soft probe ran, or None if the RST_MOD line was absent (older query).
    """
    views: dict[int, LeaderView] = {}
    rst_available: bool | None = None
    for raw in lines:
        line = raw.strip()
        if not line or line == SENTINEL:
            continue
        if line.startswith("RST_MOD|"):
            p = line.split("|")
            if len(p) >= 2:
                rst_available = p[1] == "1"
            continue
        if line.startswith("RST|"):
            parsed = parse_rst_line(line)
            if parsed is None:
                continue
            vid, rst_view = parsed
            view = views.get(vid)
            if view is not None:
                view.rst = rst_view
            continue
        if line.startswith("FAITH|"):
            p = line.split("|")
            if len(p) < 8:
                continue
            vid = int(p[1])
            view = views.get(vid)
            if view is None:
                continue
            pan_type = p[4] if p[4] and p[4] != "NONE" else None
            rel_type = p[6] if p[6] and p[6] != "NONE" else None
            view.religion = CivReligionBeliefs(
                player_id=vid,
                civ_name=p[2] or view.civ_name,
                leader_name=p[3] or view.leader_name,
                pantheon_type=pan_type,
                pantheon_name=(p[5] or None) if pan_type else None,
                religion_type=rel_type,
                religion_name=(p[7] or None) if rel_type else None,
            )
            continue
        if line.startswith("FBELIEF|"):
            p = line.split("|", 5)
            if len(p) < 6:
                continue
            vid = int(p[1])
            view = views.get(vid)
            if view is None or view.religion is None:
                continue
            view.religion.beliefs.append(
                ReligionBeliefOption(
                    belief_class=p[2],
                    belief_type=p[3],
                    name=p[4],
                    description=p[5],
                )
            )
            continue
        if line.startswith("VSTAT|"):
            p = line.split("|")
            if len(p) < 15:
                continue
            vid = int(p[1])
            view = views.get(vid)
            if view is None:
                continue
            view.victory_peers.append(
                VictoryPeerStat(
                    player_id=int(p[2]),
                    civ_name=p[3],
                    score=int(float(p[4] or 0)),
                    science_vp=int(float(p[5] or 0)),
                    science_needed=int(float(p[6] or 50)),
                    diplo_vp=int(float(p[7] or 0)),
                    tourism=int(float(p[8] or 0)),
                    mil=int(float(p[9] or 0)),
                    techs=int(float(p[10] or 0)),
                    civics=int(float(p[11] or 0)),
                    rel_cities=int(float(p[12] or 0)),
                    spaceports=int(float(p[13] or 0)),
                    holds_own_capital=p[14] != "0",
                    staycationers=int(float(p[15] if len(p) > 15 else 0)),
                    visiting_tourists=int(float(p[16] if len(p) > 16 else 0)),
                )
            )
            continue
        if line.startswith("VIEWER|"):
            p = line.split("|")
            if len(p) < 16:
                continue
            vid = int(p[1])
            views[vid] = LeaderView(
                player_id=vid,
                civ_name=p[2],
                leader_name=p[3],
                score=int(float(p[4] or 0)),
                cities=int(float(p[5] or 0)),
                pop=int(float(p[6] or 0)),
                sci=float(p[7] or 0),
                cul=float(p[8] or 0),
                gold=float(p[9] or 0),
                mil=int(float(p[10] or 0)),
                techs=int(float(p[11] or 0)),
                civics=int(float(p[12] or 0)),
                faith=float(p[13] or 0),
                current_research=p[14] or "无",
                current_civic=p[15] or "无",
                favor=int(float(p[16] or 0)) if len(p) > 16 else 0,
            )
        elif line.startswith("TRAIT|"):
            p = line.split("|", 4)
            if len(p) < 5:
                continue
            vid = int(p[1])
            view = views.get(vid)
            if view is None:
                continue
            kind, name, desc = p[2], p[3], p[4]
            if kind == "LEADER":
                view.leader_traits.append((name, desc))
            else:
                view.civ_traits.append((name, desc))
        elif line.startswith("AGENDA|"):
            p = line.split("|", 3)
            if len(p) < 4:
                continue
            vid = int(p[1])
            view = views.get(vid)
            if view is not None:
                view.agendas.append((p[2], p[3]))
        elif line.startswith("CITY|"):
            p = line.split("|")
            if len(p) < 18:
                continue
            vid = int(p[1])
            view = views.get(vid)
            if view is None:
                continue
            producing = p[15] if p[15] != "IDLE" else "空闲"
            view.own_cities.append(
                CityView(
                    city_id=int(p[2]),
                    name=p[3],
                    pop=int(float(p[4] or 0)),
                    food=float(p[5] or 0),
                    prod=float(p[6] or 0),
                    gold=float(p[7] or 0),
                    sci=float(p[8] or 0),
                    cul=float(p[9] or 0),
                    faith=float(p[10] or 0),
                    housing=float(p[11] or 0),
                    amenities=int(float(p[12] or 0)),
                    amenities_needed=int(float(p[13] or 0)),
                    districts=p[14] or "",
                    producing=producing,
                    turns_left=int(float(p[16] or 0)),
                    loyalty=float(p[17] or 100),
                )
            )
        elif line.startswith("MET|"):
            p = line.split("|")
            if len(p) < 18:
                continue
            vid = int(p[1])
            view = views.get(vid)
            if view is None:
                continue
            view.met.append(
                MetCivView(
                    player_id=int(p[2]),
                    civ_name=p[3],
                    leader_name=p[4],
                    score=int(float(p[5] or 0)),
                    cities=int(float(p[6] or 0)),
                    pop=int(float(p[7] or 0)),
                    sci=float(p[8] or 0),
                    cul=float(p[9] or 0),
                    gold=float(p[10] or 0),
                    mil=int(float(p[11] or 0)),
                    techs=int(float(p[12] or 0)),
                    civics=int(float(p[13] or 0)),
                    faith=float(p[14] or 0),
                    diplomatic_state=p[15],
                    relationship_score=int(float(p[16] or 0)),
                    is_at_war=p[17] == "1",
                    grievances=int(float(p[18] if len(p) > 18 else 0)),
                    grievances_against_me=int(float(p[19] if len(p) > 19 else 0)),
                )
            )
        elif line.startswith("DIPMOD|"):
            p = line.split("|", 4)
            if len(p) < 5:
                continue
            vid = int(p[1])
            tid = int(p[2])
            view = views.get(vid)
            if view is None:
                continue
            met = next((m for m in view.met if m.player_id == tid), None)
            if met is not None:
                met.modifiers.append(
                    DiploModifierView(score=int(float(p[3] or 0)), text=p[4])
                )
        elif line.startswith("THREAT|"):
            p = line.split("|")
            if len(p) < 6:
                continue
            vid = int(p[1])
            view = views.get(vid)
            if view is not None:
                view.threats.append(
                    VisibleThreatAgg(
                        owner_id=int(p[2]),
                        owner_name=p[3],
                        count=int(float(p[4] or 0)),
                        nearest_dist=int(float(p[5] or 999)),
                        is_at_war=(len(p) > 6 and p[6] == "1"),
                        is_minor=(len(p) > 7 and p[7] == "1"),
                    )
                )
    return views, rst_available
