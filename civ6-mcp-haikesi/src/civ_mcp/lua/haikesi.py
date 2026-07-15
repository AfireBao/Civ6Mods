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
    """Chinese note for base tile yields of a luxury/strategic resource."""
    yields = _RESOURCE_TILE_YIELDS.get(resource_type)
    if not yields:
        return ""
    parts = [f"{name}+{amount}" for name, amount in yields]
    return f"该资源地块收益：{'、'.join(parts)}；并提供奢侈品宜居。"


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
    # Avoid duplicating when XML already contains the yield phrase.
    if any(token in desc for token, _ in _RESOURCE_TILE_YIELDS.get(resource_type, [])):
        if "宜居" in desc or "地块" in desc:
            return desc
    if note in desc:
        return desc
    return f"{desc} {note}".strip() if desc else note


def _strip_civ_icons(text: str) -> str:
    return re.sub(r"\s*\[ICON_[^\]]+\]\s*", "", text or "").strip()


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


def format_relic_type_list(types: list[str], text_xml: Path | None = None) -> str:
    """Format relic type ids as Chinese display names for prompts/logs."""
    catalog = get_ai_relic_catalog(text_xml)
    if not types:
        return "无"
    labels: list[str] = []
    for relic_type in types:
        name = catalog.get(relic_type, {}).get("name", relic_type)
        labels.append(name)
    return "、".join(labels)


def format_option_lines(options: list[str], text_xml: Path | None = None) -> list[str]:
    catalog = get_ai_relic_catalog(text_xml)
    lines: list[str] = []
    for opt in options:
        info = catalog.get(opt, {})
        name = _strip_civ_icons(info.get("name", opt))
        desc = enrich_relic_description(
            opt, _strip_civ_icons(info.get("description", ""))
        )
        lines.append(f"- {opt}: {name} — {desc}")
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
    grievances: int


@dataclass
class VisibleThreatAgg:
    owner_id: int
    owner_name: str
    count: int
    nearest_dist: int


@dataclass
class VictoryPeerStat:
    """Victory-relevant stats for self or a met major (viewer fog)."""

    player_id: int
    civ_name: str
    score: int = 0
    science_vp: int = 0
    science_needed: int = 50
    diplo_vp: int = 0
    tourism: int = 0
    mil: int = 0
    techs: int = 0
    civics: int = 0
    rel_cities: int = 0
    spaceports: int = 0
    holds_own_capital: bool = True
    staycationers: int = 0


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


def build_leader_views_query(viewer_ids: list[int]) -> str:
    """FireTuner query that simulates each AI's diplo + fog view.

    Emits VIEWER / TRAIT / AGENDA / CITY / MET / THREAT lines per viewer.
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
local function printVStat(vid, tid, civName)
  pcall(function()
    local p = Players[tid]
    if not p then return end
    local st = p:GetStats()
    local sciVP, sciNeed, diploVP, tourism = 0, 50, 0, 0
    local milStr, techs, civics, relCities, stay = 0, 0, 0, 0, 0
    local score, spaceports, holds = 0, 0, 1
    pcall(function() score = p:GetScore() end)
    pcall(function() sciVP = st:GetScienceVictoryPoints() or 0 end)
    pcall(function() sciNeed = st:GetScienceVictoryPointsTotalNeeded() or 50 end)
    pcall(function() diploVP = st:GetDiplomaticVictoryPoints() or 0 end)
    pcall(function() tourism = st:GetTourism() or 0 end)
    pcall(function() milStr = st:GetMilitaryStrength() or 0 end)
    pcall(function() techs = st:GetNumTechsResearched() or 0 end)
    pcall(function() civics = st:GetNumCivicsCompleted() or 0 end)
    pcall(function() relCities = st:GetNumCitiesFollowingReligion() or 0 end)
    pcall(function() stay = p:GetCulture():GetStaycationers() or 0 end)
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
      .. "|" .. tourism .. "|" .. milStr .. "|" .. techs .. "|" .. civics
      .. "|" .. relCities .. "|" .. spaceports .. "|" .. holds .. "|" .. stay)
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
  local mil, techs, civics, faith = 0, 0, 0, 0
  pcall(function()
    local st = p:GetStats()
    mil = st:GetMilitaryStrength()
    techs = st:GetNumTechsResearched()
    civics = st:GetNumCivicsCompleted()
  end)
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
  local hist = {{}}
  if leaderType and leaderType ~= "" then
    for ha in GameInfo.HistoricalAgendas() do
      if ha.LeaderType == leaderType then
        local aDef = GameInfo.Agendas[ha.AgendaType]
        if aDef then hist[aDef.Index] = true end
      end
    end
  end
  local okAg, agendas = pcall(function() return Players[vid]:GetAgendaTypes() end)
  if okAg and agendas then
    for _, agIdx in ipairs(agendas) do
      if hist[agIdx] then
        local aDef = GameInfo.Agendas[agIdx]
        if aDef then
          print("AGENDA|" .. vid .. "|" .. safeLookup(aDef.Name) .. "|" .. safeLookup(aDef.Description))
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
    print("VIEWER|" .. vid .. "|" .. civName .. "|" .. leaderName
      .. "|" .. score .. "|" .. cities .. "|" .. pop
      .. "|" .. string.format("%.1f", sci) .. "|" .. string.format("%.1f", cul) .. "|" .. string.format("%.1f", gold)
      .. "|" .. mil .. "|" .. techs .. "|" .. civics .. "|" .. string.format("%.1f", faith)
      .. "|" .. research .. "|" .. civic)
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
          pcall(function()
            if pDiplo:IsAtWarWith(tid) then war = 1 end
          end)
          pcall(function() griev = pDiplo:GetGrievancesAgainst(tid) or 0 end)
          pcall(function()
            local ai = Players[tid]:GetDiplomaticAI()
            local stateIdx = ai:GetDiplomaticStateIndex(vid)
            stateName = states[stateIdx + 1] or tostring(stateIdx)
            local mods = ai:GetDiplomaticModifiers(vid)
            if mods then
              for _, mod in ipairs(mods) do
                relScore = relScore + (mod.Score or 0)
              end
            end
          end)
          print("MET|" .. vid .. "|" .. tid .. "|" .. tciv .. "|" .. tleader
            .. "|" .. tscore .. "|" .. tcities .. "|" .. tpop
            .. "|" .. string.format("%.1f", tsci) .. "|" .. string.format("%.1f", tcul) .. "|" .. string.format("%.1f", tgold)
            .. "|" .. tmil .. "|" .. ttechs .. "|" .. tcivics .. "|" .. string.format("%.1f", tfaith)
            .. "|" .. stateName .. "|" .. relScore .. "|" .. war .. "|" .. griev)
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
          if pid ~= 63 then
            local ocfg = PlayerConfigurations[pid]
            if ocfg then ownerName = safeLookup(ocfg:GetCivilizationShortDescription()) end
            if ownerName == "" then ownerName = "Player" .. tostring(pid) end
          end
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
                    agg = {{name=ownerName, count=0, dist=999}}
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
      print("THREAT|" .. vid .. "|" .. pid .. "|" .. agg.name .. "|" .. agg.count .. "|" .. agg.dist)
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
                )
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
                    )
                )
    return views, rst_available
