"""ExtAI leader styles: local knowledge + Civ6-signal classification.

Styles bias hex picks only; they do not change in-game AI behavior.
Each styled leader rolls cosplay vs payoff (default 50/50); dice is audited.
"""

from __future__ import annotations

import json
import logging
import os
import random
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Literal

log = logging.getLogger(__name__)

_STYLES_DIR = Path(__file__).resolve().parents[2] / "knowledge" / "styles"

StyleMode = Literal["cosplay", "payoff", "none"]

_CHAOS_TYPES = frozenset(
    {
        "NW_AI_BARBARIAN_INVASION",
        "NW_AI_RIVER_FLOOD",
    }
)
_COMBAT_ECHO_PREFIX = "NW_AI_ECHO_"
_COMBAT_ECHO_OK = frozenset(
    {
        "NW_AI_ECHO_MELEE",
        "NW_AI_ECHO_RANGED",
        "NW_AI_ECHO_SIEGE",
        "NW_AI_ECHO_LIGHT_CAVALRY",
        "NW_AI_ECHO_HEAVY_CAVALRY",
        "NW_AI_ECHO_ANTI_CAVALRY",
    }
)
_CHAOS_SHORT = ("南蛮", "仇水")
_COMBAT_SHORT = (
    "近战翻倍",
    "远程翻倍",
    "攻城翻倍",
    "轻骑兵翻倍",
    "重骑兵翻倍",
    "抗骑兵翻倍",
)


def llm_styles_enabled() -> bool:
    raw = (os.environ.get("HAIKESI_LLM_STYLES") or "1").strip().lower()
    return raw in {"1", "true", "yes", "on"}


def style_cosplay_probability() -> float:
    """P(cosplay). Default 0.5; remainder is payoff-first."""
    try:
        p = float(os.environ.get("HAIKESI_LLM_STYLE_COSPLAY_P") or "0.5")
    except ValueError:
        p = 0.5
    return max(0.0, min(1.0, p))


def styles_dir() -> Path:
    override = (os.environ.get("HAIKESI_STYLES_DIR") or "").strip()
    return Path(override) if override else _STYLES_DIR


@dataclass
class StyleAssignment:
    player_id: int
    style_id: str | None
    display_name: str
    score: int = 0
    locked: bool = False
    reasons: list[str] = field(default_factory=list)
    # Dice audit: mode after roll; u in [0,1); p = cosplay threshold
    mode: StyleMode = "none"
    dice_u: float | None = None
    cosplay_p: float = 0.5

    @property
    def slim_line(self) -> str:
        if not self.style_id:
            return "风格:无（仅通用Skill）"
        lock = "锁定" if self.locked else "推断"
        why = "+".join(self.reasons[:3]) if self.reasons else ""
        suffix = f"·{why}" if why else ""
        if self.mode == "cosplay" and self.dice_u is not None:
            dice = f"·掷骰cosplay/u={self.dice_u:.3f}"
        elif self.mode == "payoff" and self.dice_u is not None:
            dice = f"·掷骰收益优先/u={self.dice_u:.3f}"
        else:
            dice = ""
        return f"风格:{self.display_name}({lock}{suffix}{dice})"

    def audit_token(self) -> str:
        """Compact token for decision Meta / logs."""
        if not self.style_id:
            return f"{self.player_id}=none"
        if self.dice_u is None:
            return f"{self.player_id}={self.style_id}/{self.mode}"
        return (
            f"{self.player_id}={self.style_id}/{self.mode}"
            f"/u={self.dice_u:.4f}/p={self.cosplay_p:.2f}"
        )


def load_index() -> dict[str, Any]:
    path = styles_dir() / "_index.json"
    if not path.is_file():
        return {"styles": [], "universal": "_universal.md"}
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        log.warning("styles index read failed: %s", exc)
        return {"styles": [], "universal": "_universal.md"}
    return data if isinstance(data, dict) else {"styles": [], "universal": "_universal.md"}


def load_markdown(filename: str) -> str:
    path = styles_dir() / filename
    if not path.is_file():
        return ""
    try:
        return path.read_text(encoding="utf-8").strip()
    except OSError as exc:
        log.warning("style md read failed (%s): %s", path, exc)
        return ""


def load_universal_skill() -> str:
    """Deprecated alias: payoff strategy body (compat for old callers/tests)."""
    return load_payoff_skill()


def load_legality_skill() -> str:
    idx = load_index()
    name = str(idx.get("legality") or "_legality.md")
    return load_markdown(name)


def load_payoff_skill() -> str:
    idx = load_index()
    name = str(idx.get("payoff") or "_payoff.md")
    text = load_markdown(name)
    if text:
        return text
    # Legacy fallback
    return load_markdown(str(idx.get("universal") or "_universal.md"))


def load_style_skill(style_id: str) -> str:
    if not style_id:
        return ""
    for row in load_index().get("styles") or []:
        if not isinstance(row, dict):
            continue
        if str(row.get("id") or "") == style_id:
            return load_markdown(str(row.get("file") or f"{style_id}.md"))
    return load_markdown(f"{style_id}.md")


def style_display_name(style_id: str) -> str:
    for row in load_index().get("styles") or []:
        if isinstance(row, dict) and str(row.get("id") or "") == style_id:
            return str(row.get("name") or style_id)
    return style_id


def _inventory_tokens(selected: list[Any]) -> list[str]:
    return [str(x).strip() for x in (selected or []) if str(x).strip()]


def _has_chaos_inventory(tokens: list[str]) -> bool:
    for t in tokens:
        if t in _CHAOS_TYPES:
            return True
        if any(s in t for s in _CHAOS_SHORT):
            return True
    return False


def _has_combat_echo_inventory(tokens: list[str]) -> bool:
    for t in tokens:
        if t in _COMBAT_ECHO_OK:
            return True
        if t.startswith(_COMBAT_ECHO_PREFIX) and "SETTLER" not in t and "BUILDER" not in t:
            if "WORKER" in t:
                continue
            return True
        if any(s in t for s in _COMBAT_SHORT):
            return True
    return False


def _rst(view: Any | None) -> str:
    if view is not None and getattr(view, "rst", None) is not None:
        return str(view.rst.active_strategy or "NONE")
    return "-"


def _at_war(view: Any | None) -> bool:
    if view is None:
        return False
    return any(getattr(m, "is_at_war", False) for m in (view.met or []))


def _trade_busy(view: Any | None) -> bool:
    if view is None or getattr(view, "trade", None) is None:
        return False
    t = view.trade
    return (
        int(t.capacity or 0) >= 2
        or int(t.active or 0) >= 2
        or int(t.intl_in or 0) + int(t.intl_out or 0) >= 1
    )


def _trade_sparse(view: Any | None) -> bool:
    if view is None:
        return True
    if getattr(view, "trade", None) is None:
        return True
    t = view.trade
    return int(t.active or 0) <= 1 and int(t.intl_in or 0) + int(t.intl_out or 0) == 0


def _inv_has(tokens: list[str], *needles: str) -> bool:
    for t in tokens:
        for n in needles:
            if n in t:
                return True
    return False


def _peaceful_relation_score(view: Any | None) -> tuple[int, int]:
    """Return (good_count, war_count) among met majors."""
    if view is None:
        return 0, 0
    good, war = 0, 0
    for m in view.met or []:
        if getattr(m, "is_at_war", False):
            war += 1
            continue
        rel = int(getattr(m, "relationship_score", 0) or 0)
        g_against = int(getattr(m, "grievances_against_me", 0) or 0)
        if rel >= 0 and g_against < 50:
            good += 1
    return good, war


def _bad_relation_count(view: Any | None) -> int:
    if view is None:
        return 0
    bad = 0
    for m in view.met or []:
        if getattr(m, "is_minor", False):
            continue
        g_against = int(getattr(m, "grievances_against_me", 0) or 0)
        rel = int(getattr(m, "relationship_score", 0) or 0)
        if g_against >= 50 or rel <= -20 or getattr(m, "is_at_war", False):
            bad += 1
    return bad


def _enemy_near_count(view: Any | None) -> int:
    if view is None:
        return 0
    threats = getattr(view, "threats", None) or []
    return sum(
        1
        for t in threats
        if int(getattr(t, "count", 0) or 0) > 0
        and (
            getattr(t, "is_at_war", False)
            or int(getattr(t, "nearest_dist", 99) or 99) <= 3
        )
    )


def _mil_advantage(view: Any | None) -> bool:
    if view is None:
        return False
    my = int(getattr(view, "mil", 0) or 0)
    if my <= 0:
        return False
    for m in view.met or []:
        if not getattr(m, "is_at_war", False):
            continue
        their = int(getattr(m, "mil", 0) or 0)
        if their <= 0 or my >= int(their * 1.2):
            return True
    return False


def _city_count(view: Any | None) -> int:
    if view is None:
        return 0
    return int(getattr(view, "cities", 0) or 0)


def classify_demonic_warlord(
    *,
    view: Any | None,
    selected: list[Any],
) -> tuple[int, list[str], bool]:
    """Return (score, reason tags, excluded). Threshold for assign: score >= 3."""
    reasons: list[str] = []
    tokens = _inventory_tokens(selected)
    score = 0
    rst = _rst(view)
    war = _at_war(view)

    if rst in {"SCIENCE", "CULTURE"} and not war:
        peaceful_inv = not _has_chaos_inventory(tokens) and not _has_combat_echo_inventory(
            tokens
        )
        if peaceful_inv:
            return 0, ["排除:科文和平"], True

    # Clean combat wars → militant_warlord (chaos is demonic's signature)
    if (
        war
        and _has_combat_echo_inventory(tokens)
        and not _has_chaos_inventory(tokens)
    ):
        return 0, ["排除:无混乱→好战督军"], True

    if rst == "CONQUEST":
        score += 2
        reasons.append("RST=CONQUEST")

    if war:
        score += 2
        reasons.append("交战")

    bad = _bad_relation_count(view)
    if bad >= 2:
        score += 2
        reasons.append(f"关系差×{bad}")
    elif bad == 1:
        score += 1
        reasons.append("关系差")

    if _enemy_near_count(view) >= 1 and war:
        score += 1
        reasons.append("贴脸敌军")

    if _has_chaos_inventory(tokens):
        score += 2
        reasons.append("库存混乱")
    if _has_combat_echo_inventory(tokens):
        score += 1
        reasons.append("库存战斗echo")

    return score, reasons, False


def classify_militant_warlord(
    *,
    view: Any | None,
    selected: list[Any],
) -> tuple[int, list[str], bool]:
    reasons: list[str] = []
    tokens = _inventory_tokens(selected)
    score = 0
    rst = _rst(view)
    war = _at_war(view)

    if _has_chaos_inventory(tokens):
        return 0, ["排除:混乱→恶魔督军"], True
    if rst in {"SCIENCE", "CULTURE"} and not war:
        return 0, ["排除:科文和平"], True

    if rst == "CONQUEST":
        score += 2
        reasons.append("RST=CONQUEST")
    if war:
        score += 2
        reasons.append("交战")
    if _has_combat_echo_inventory(tokens):
        score += 2
        reasons.append("库存战斗echo")
    if _mil_advantage(view):
        score += 1
        reasons.append("军力优势")
    if _enemy_near_count(view) >= 1 and war:
        score += 1
        reasons.append("贴脸敌军")

    return score, reasons, False


def classify_imperial_warlord(
    *,
    view: Any | None,
    selected: list[Any],
) -> tuple[int, list[str], bool]:
    reasons: list[str] = []
    tokens = _inventory_tokens(selected)
    score = 0
    rst = _rst(view)

    if _has_chaos_inventory(tokens):
        return 0, ["排除:混乱"], True
    war = _at_war(view)
    if war and _has_combat_echo_inventory(tokens) and not _inv_has(
        tokens, "NW_AI_STATS_3", "生产力", "NW_AI_ECHO_BUILDER", "工人"
    ):
        if _city_count(view) < 4:
            return 0, ["排除:纯战斗督军"], True

    if rst == "CONQUEST":
        score += 2
        reasons.append("RST=CONQUEST")
    cities = _city_count(view)
    if cities >= 6:
        score += 2
        reasons.append(f"城={cities}")
    elif cities >= 4:
        score += 1
        reasons.append(f"城={cities}")
    if _inv_has(tokens, "NW_AI_STATS_3", "生产力", "NW_AI_ECHO_BUILDER", "工人"):
        score += 2
        reasons.append("库存产/工人")
    if war:
        score += 1
        reasons.append("交战扩张")

    return score, reasons, False


def classify_economic_warlord(
    *,
    view: Any | None,
    selected: list[Any],
) -> tuple[int, list[str], bool]:
    reasons: list[str] = []
    tokens = _inventory_tokens(selected)
    score = 0
    rst = _rst(view)
    war = _at_war(view)
    gold = float(getattr(view, "gold", 0) or 0) if view is not None else 0.0
    faith = float(getattr(view, "faith", 0) or 0) if view is not None else 0.0

    if _has_chaos_inventory(tokens):
        return 0, ["排除:混乱"], True
    if faith >= 25 and not war:
        return 0, ["排除:信仰隐士"], True
    if rst in {"SCIENCE", "CULTURE"} and not war and gold < 20:
        return 0, ["排除:科文和平"], True

    if gold >= 25:
        score += 2
        reasons.append(f"金={gold:.0f}")
    elif gold >= 15:
        score += 1
        reasons.append("金中等")
    if rst == "CONQUEST" or war:
        score += 2
        reasons.append("征服或交战")
    if _inv_has(tokens, "NW_AI_STATS_6", "金币"):
        score += 2
        reasons.append("库存金币%")
    elif _has_combat_echo_inventory(tokens) and gold >= 15:
        score += 1
        reasons.append("金+战斗echo")

    return score, reasons, False


def classify_strategist_warlord(
    *,
    view: Any | None,
    selected: list[Any],
) -> tuple[int, list[str], bool]:
    reasons: list[str] = []
    tokens = _inventory_tokens(selected)
    score = 0
    rst = _rst(view)
    war = _at_war(view)
    sci = float(getattr(view, "sci", 0) or 0) if view is not None else 0.0

    if _has_chaos_inventory(tokens):
        return 0, ["排除:混乱"], True
    if not war and _enemy_near_count(view) == 0:
        return 0, ["排除:无战事→贤者"], True
    if rst == "RELIGION" and float(getattr(view, "faith", 0) or 0) >= 25:
        return 0, ["排除:信仰主建"], True

    if rst == "SCIENCE":
        score += 2
        reasons.append("RST=SCIENCE")
    elif sci >= 35:
        score += 2
        reasons.append(f"科={sci:.0f}")
    elif sci >= 20:
        score += 1
        reasons.append("科中等")
    if war:
        score += 2
        reasons.append("交战")
    if _inv_has(tokens, "NW_AI_STATS_2", "科技"):
        score += 1
        reasons.append("库存科技%")
    if _has_combat_echo_inventory(tokens):
        score += 1
        reasons.append("库存战斗echo")

    return score, reasons, False


def classify_artisan_merchant(
    *,
    view: Any | None,
    selected: list[Any],
) -> tuple[int, list[str], bool]:
    reasons: list[str] = []
    tokens = _inventory_tokens(selected)
    score = 0
    rst = _rst(view)
    war = _at_war(view)

    if rst == "CONQUEST" and war and (
        _has_chaos_inventory(tokens) or _has_combat_echo_inventory(tokens)
    ):
        return 0, ["排除:征服交战"], True

    if rst in {"SCIENCE", "CULTURE"}:
        score += 2
        reasons.append(f"RST={rst}")

    if _trade_busy(view):
        score += 2
        reasons.append("商路活跃")

    if _inv_has(
        tokens,
        "NW_AI_STATS_3",
        "NW_AI_STATS_6",
        "金币",
        "生产力",
        "NW_AI_FERTILE_CRESCENT",
        "NW_AI_CELESTIAL_EMPIRE",
        "两河",
        "天朝",
        "NW_AI_ECHO_BUILDER",
        "工人",
    ):
        score += 1
        reasons.append("库存产金/商路")

    if view is not None:
        if float(view.gold or 0) >= 15 or float(getattr(view, "sci", 0) or 0) >= 30:
            score += 1
            reasons.append("产金或科突出")
        if not war:
            score += 1
            reasons.append("和平")

    return score, reasons, False


def classify_competitive_merchant(
    *,
    view: Any | None,
    selected: list[Any],
) -> tuple[int, list[str], bool]:
    reasons: list[str] = []
    tokens = _inventory_tokens(selected)
    score = 0
    rst = _rst(view)
    war = _at_war(view)
    gold = float(getattr(view, "gold", 0) or 0) if view is not None else 0.0
    favor = int(getattr(view, "favor", 0) or 0) if view is not None else 0

    if rst == "CONQUEST" and war and (
        _has_chaos_inventory(tokens) or _has_combat_echo_inventory(tokens)
    ):
        return 0, ["排除:征服交战"], True
    if favor >= 20:
        return 0, ["排除:外交favor"], True
    if float(getattr(view, "faith", 0) or 0) >= 25:
        return 0, ["排除:信仰"], True
    if rst in {"SCIENCE", "CULTURE"} and _inv_has(
        tokens, "NW_AI_STATS_3", "生产力", "NW_AI_ECHO_BUILDER", "工人"
    ):
        return 0, ["排除:工匠向"], True

    if _trade_busy(view):
        score += 2
        reasons.append("商路活跃")
    if gold >= 25:
        score += 2
        reasons.append(f"金={gold:.0f}")
    elif gold >= 15:
        score += 1
        reasons.append("金中等")
    if _inv_has(tokens, "NW_AI_STATS_6", "金币"):
        score += 2
        reasons.append("库存金币%")
    elif _inv_has(tokens, "两河", "天朝", "NW_AI_FERTILE_CRESCENT", "NW_AI_CELESTIAL_EMPIRE"):
        score += 1
        reasons.append("库存商路")
    if not war:
        score += 1
        reasons.append("和平")
    # Artisan lane: sci/culture + builder without extreme gold
    if (
        rst in {"SCIENCE", "CULTURE"}
        and _inv_has(tokens, "NW_AI_ECHO_BUILDER", "工人", "NW_AI_STATS_3", "生产力")
        and gold < 30
        and not _inv_has(tokens, "NW_AI_STATS_6", "金币")
    ):
        score = max(0, score - 2)
        reasons.append("工匠向减分")

    return score, reasons, False


def classify_authoritarian_diplomat(
    *,
    view: Any | None,
    selected: list[Any],
) -> tuple[int, list[str], bool]:
    reasons: list[str] = []
    tokens = _inventory_tokens(selected)
    score = 0
    rst = _rst(view)
    war = _at_war(view)
    good, war_n = _peaceful_relation_score(view)

    if (rst == "CONQUEST" and war) or (
        war_n >= 2 and _has_chaos_inventory(tokens)
    ):
        return 0, ["排除:多线开战/征服"], True

    if rst in {"DIPLO", "CULTURE"}:
        score += 2
        reasons.append(f"RST={rst}")

    favor = int(getattr(view, "favor", 0) or 0) if view is not None else 0
    if favor < 15:
        return 0, ["排除:favor不足→侠义/间谍"], True
    if favor >= 20:
        score += 2
        reasons.append(f"favor={favor}")
    else:
        score += 1
        reasons.append("favor中等")

    if good >= 2 and war_n == 0:
        score += 2
        reasons.append(f"友好网×{good}")
    elif good >= 1 and not war:
        score += 1
        reasons.append("有友好")

    if _inv_has(
        tokens,
        "NW_AI_STATS_1",
        "文化",
        "NW_AI_FERTILE_CRESCENT",
        "NW_AI_CELESTIAL_EMPIRE",
        "两河",
        "天朝",
    ) and not _has_chaos_inventory(tokens):
        score += 1
        reasons.append("库存文/商路")

    return score, reasons, False


def classify_chivalrous_diplomat(
    *,
    view: Any | None,
    selected: list[Any],
) -> tuple[int, list[str], bool]:
    reasons: list[str] = []
    tokens = _inventory_tokens(selected)
    score = 0
    rst = _rst(view)
    war = _at_war(view)
    good, war_n = _peaceful_relation_score(view)
    favor = int(getattr(view, "favor", 0) or 0) if view is not None else 0

    if war or war_n >= 1:
        return 0, ["排除:交战"], True
    if _has_chaos_inventory(tokens) or _has_combat_echo_inventory(tokens):
        return 0, ["排除:混乱/开战echo"], True
    if favor >= 20:
        return 0, ["排除:高favor→威权"], True

    if rst in {"DIPLO", "CULTURE"}:
        score += 2
        reasons.append(f"RST={rst}")
    if good >= 2:
        score += 2
        reasons.append(f"友好网×{good}")
    elif good >= 1:
        score += 1
        reasons.append("有友好")
    if favor >= 5:
        score += 1
        reasons.append("favor温和")
    if _inv_has(tokens, "NW_AI_STATS_1", "文化", "两河", "天朝"):
        score += 1
        reasons.append("库存文/商路")

    return score, reasons, False


def classify_fanatic_isolationist(
    *,
    view: Any | None,
    selected: list[Any],
) -> tuple[int, list[str], bool]:
    reasons: list[str] = []
    tokens = _inventory_tokens(selected)
    score = 0
    rst = _rst(view)

    if rst == "DIPLO" and (view is not None and int(getattr(view, "favor", 0) or 0) >= 20):
        return 0, ["排除:外交高favor"], True
    if _trade_busy(view) and _inv_has(tokens, "金币", "生产力", "NW_AI_STATS_3", "NW_AI_STATS_6"):
        if not _inv_has(tokens, "信仰", "NW_AI_STATS_4") and float(
            getattr(view, "faith", 0) or 0
        ) < 10:
            return 0, ["排除:商人向"], True

    if rst in {"RELIGION", "CONQUEST"}:
        score += 2
        reasons.append(f"RST={rst}")

    faith = float(getattr(view, "faith", 0) or 0) if view is not None else 0.0
    if faith >= 20:
        score += 2
        reasons.append(f"信仰={faith:.0f}")
    elif faith >= 8:
        score += 1
        reasons.append("信仰中等")

    if _inv_has(tokens, "NW_AI_STATS_4", "信仰"):
        score += 1
        reasons.append("库存信仰%")

    if _trade_sparse(view):
        score += 1
        reasons.append("商路少")

    if rst == "CONQUEST" and _has_combat_echo_inventory(tokens):
        score += 1
        reasons.append("征服+战斗echo")

    return score, reasons, False


def classify_solitary_isolationist(
    *,
    view: Any | None,
    selected: list[Any],
) -> tuple[int, list[str], bool]:
    reasons: list[str] = []
    tokens = _inventory_tokens(selected)
    score = 0
    rst = _rst(view)
    faith = float(getattr(view, "faith", 0) or 0) if view is not None else 0.0
    favor = int(getattr(view, "favor", 0) or 0) if view is not None else 0

    if _trade_busy(view):
        return 0, ["排除:商路忙"], True
    if faith >= 20:
        return 0, ["排除:高信仰→狂热"], True
    if favor >= 20 or rst == "DIPLO":
        return 0, ["排除:外交向"], True

    if _trade_sparse(view):
        score += 2
        reasons.append("商路少")
    near = _enemy_near_count(view)
    if near >= 1:
        score += 2
        reasons.append("边境压力")
    elif _at_war(view):
        score += 1
        reasons.append("防守交战")
    if _inv_has(tokens, "NW_AI_STATS_3", "生产力", "NW_AI_STATS_5", "食物"):
        score += 1
        reasons.append("库存内政")
    if _has_combat_echo_inventory(tokens) and not _has_chaos_inventory(tokens):
        score += 1
        reasons.append("防御echo")
    if rst not in {"DIPLO", "SCIENCE"}:
        score += 1
        reasons.append(f"RST={rst}")

    return score, reasons, False


def classify_erudite_sage(
    *,
    view: Any | None,
    selected: list[Any],
) -> tuple[int, list[str], bool]:
    reasons: list[str] = []
    tokens = _inventory_tokens(selected)
    score = 0
    rst = _rst(view)
    war = _at_war(view)

    if rst == "CONQUEST" and war and (
        _has_chaos_inventory(tokens) or _has_combat_echo_inventory(tokens)
    ):
        return 0, ["排除:征服进攻"], True
    if rst == "RELIGION" and float(getattr(view, "faith", 0) or 0) >= 25:
        return 0, ["排除:信仰主建"], True
    # Hand war+science combat to strategist
    if war and (rst == "SCIENCE" or float(getattr(view, "sci", 0) or 0) >= 35):
        if _has_combat_echo_inventory(tokens):
            return 0, ["排除:交战科→谋略督军"], True

    if rst == "SCIENCE":
        score += 2
        reasons.append("RST=SCIENCE")

    sci = float(getattr(view, "sci", 0) or 0) if view is not None else 0.0
    if sci >= 40:
        score += 2
        reasons.append(f"科={sci:.0f}")
    elif sci >= 20:
        score += 1
        reasons.append("科中等")

    if _inv_has(tokens, "NW_AI_STATS_2", "科技"):
        score += 1
        reasons.append("库存科技%")

    if not war:
        score += 2
        reasons.append("和平")
    elif war and not _has_chaos_inventory(tokens):
        score += 1
        reasons.append("被动交战无混乱")

    return score, reasons, False


def classify_deceptive_spy(
    *,
    view: Any | None,
    selected: list[Any],
) -> tuple[int, list[str], bool]:
    reasons: list[str] = []
    tokens = _inventory_tokens(selected)
    score = 0
    rst = _rst(view)
    war = _at_war(view)
    favor = int(getattr(view, "favor", 0) or 0) if view is not None else 0
    cul = float(getattr(view, "cul", 0) or 0) if view is not None else 0.0
    gold = float(getattr(view, "gold", 0) or 0) if view is not None else 0.0
    faith = float(getattr(view, "faith", 0) or 0) if view is not None else 0.0

    if rst == "CONQUEST" and war and (
        _has_chaos_inventory(tokens) or _has_combat_echo_inventory(tokens)
    ):
        return 0, ["排除:正面开战"], True
    if faith >= 25:
        return 0, ["排除:信仰"], True
    if _trade_busy(view) and gold >= 25 and favor < 8 and cul < 20:
        return 0, ["排除:纯商人"], True
    good, war_n = _peaceful_relation_score(view)
    if good >= 2 and war_n == 0 and favor < 15:
        return 0, ["排除:侠义友好网"], True

    if rst in {"DIPLO", "CULTURE"}:
        score += 2
        reasons.append(f"RST={rst}")
    if 8 <= favor < 25:
        score += 2
        reasons.append(f"favor代理={favor}")
    elif favor >= 5:
        score += 1
        reasons.append("favor轻")
    if cul >= 25:
        score += 1
        reasons.append(f"文={cul:.0f}")
    if _inv_has(tokens, "NW_AI_STATS_1", "文化") and not _has_chaos_inventory(tokens):
        score += 1
        reasons.append("库存文化%")
    if not war:
        score += 1
        reasons.append("非正面开战")

    return score, reasons, False


# Tie-break order when scores equal (lower index wins)
_STYLE_PRIORITY: list[str] = [
    "demonic_warlord",
    "militant_warlord",
    "strategist_warlord",
    "economic_warlord",
    "imperial_warlord",
    "fanatic_isolationist",
    "solitary_isolationist",
    "erudite_sage",
    "competitive_merchant",
    "artisan_merchant",
    "authoritarian_diplomat",
    "chivalrous_diplomat",
    "deceptive_spy",
]

_STYLE_CLASSIFIERS: list[tuple[str, Any]] = [
    ("demonic_warlord", classify_demonic_warlord),
    ("militant_warlord", classify_militant_warlord),
    ("imperial_warlord", classify_imperial_warlord),
    ("economic_warlord", classify_economic_warlord),
    ("strategist_warlord", classify_strategist_warlord),
    ("artisan_merchant", classify_artisan_merchant),
    ("competitive_merchant", classify_competitive_merchant),
    ("authoritarian_diplomat", classify_authoritarian_diplomat),
    ("chivalrous_diplomat", classify_chivalrous_diplomat),
    ("fanatic_isolationist", classify_fanatic_isolationist),
    ("solitary_isolationist", classify_solitary_isolationist),
    ("erudite_sage", classify_erudite_sage),
    ("deceptive_spy", classify_deceptive_spy),
]


def classify_style_for_leader(
    *,
    player_id: int,
    view: Any | None,
    selected: list[Any],
    locked_id: str | None = None,
) -> StyleAssignment:
    """Score all known styles; pick best with score >= 3 (Session lock honored)."""
    scored: list[tuple[int, str, list[str]]] = []
    by_id: dict[str, tuple[int, list[str], bool]] = {}
    for style_id, fn in _STYLE_CLASSIFIERS:
        score, reasons, excluded = fn(view=view, selected=selected)
        by_id[style_id] = (score, reasons, excluded)
        if not excluded and score >= 3:
            scored.append((score, style_id, reasons))

    if locked_id and locked_id in by_id:
        sc, reasons, excluded = by_id[locked_id]
        if not excluded and sc >= 2:
            return StyleAssignment(
                player_id=player_id,
                style_id=locked_id,
                display_name=style_display_name(locked_id),
                score=max(sc, 3),
                locked=True,
                reasons=reasons or ["Session锁定"],
            )

    if not scored:
        # Best effort reasons from top raw score for debug
        best_raw = max(by_id.items(), key=lambda kv: kv[1][0], default=None)
        reasons = best_raw[1][1] if best_raw else []
        return StyleAssignment(
            player_id=player_id,
            style_id=None,
            display_name="",
            score=best_raw[1][0] if best_raw else 0,
            locked=False,
            reasons=reasons,
            mode="none",
        )

    def _key(item: tuple[int, str, list[str]]) -> tuple[int, int]:
        sc, sid, _ = item
        try:
            pri = _STYLE_PRIORITY.index(sid)
        except ValueError:
            pri = 99
        return (-sc, pri)

    scored.sort(key=_key)
    score, style_id, reasons = scored[0]
    return StyleAssignment(
        player_id=player_id,
        style_id=style_id,
        display_name=style_display_name(style_id),
        score=score,
        locked=False,
        reasons=reasons,
    )


def _dice_rng(request_id: str) -> random.Random:
    """Fixed seed → reproducible per request_id; else OS entropy."""
    seed_raw = (os.environ.get("HAIKESI_LLM_STYLE_DICE_SEED") or "").strip()
    if seed_raw:
        return random.Random(f"{seed_raw}:{request_id}")
    return random.Random()


def apply_style_dice(
    assignments: dict[int, StyleAssignment],
    *,
    request_id: str = "",
    rng: random.Random | None = None,
    cosplay_p: float | None = None,
) -> dict[int, StyleAssignment]:
    """Per styled leader: roll cosplay vs payoff. Mutates and returns assignments."""
    p = style_cosplay_probability() if cosplay_p is None else max(0.0, min(1.0, cosplay_p))
    r = rng if rng is not None else _dice_rng(request_id)
    for pid in sorted(assignments):
        asn = assignments[pid]
        asn.cosplay_p = p
        if not asn.style_id:
            asn.mode = "none"
            asn.dice_u = None
            continue
        u = r.random()
        asn.dice_u = u
        asn.mode = "cosplay" if u < p else "payoff"
    return assignments


def assign_styles_for_payload(
    payload: dict[str, Any],
    context: Any,
    *,
    locked: dict[str, str] | None = None,
    rng: random.Random | None = None,
) -> dict[int, StyleAssignment]:
    """Map player_id → StyleAssignment for AIs with non-empty options (+ dice)."""
    locked = locked or {}
    leader_views = getattr(context, "leader_views", None) or {}
    out: dict[int, StyleAssignment] = {}
    for ai in payload.get("ai_players") or []:
        opts = ai.get("options") or []
        picks = int(ai.get("picks") or 0)
        if not opts or picks < 1:
            continue
        try:
            pid = int(ai["player_id"])
        except (KeyError, TypeError, ValueError):
            continue
        view = leader_views.get(pid)
        lock = locked.get(str(pid)) or locked.get(pid)  # type: ignore[arg-type]
        if isinstance(lock, str) and lock.strip():
            lock_s = lock.strip()
        else:
            lock_s = None
        out[pid] = classify_style_for_leader(
            player_id=pid,
            view=view,
            selected=list(ai.get("selected") or []),
            locked_id=lock_s,
        )
    rid = str(payload.get("request_id") or "")
    return apply_style_dice(out, request_id=rid, rng=rng)


def build_style_injection(assignments: dict[int, StyleAssignment]) -> str:
    """Inject legality always; payoff only for payoff/none; style only for cosplay."""
    if not llm_styles_enabled():
        return ""
    parts: list[str] = [
        "【系统注入·选卡Skill】合法性底线始终生效。"
        "掷骰 cosplay → 只跟风格偏好（不受收益策略管理）；"
        "掷骰收益优先 / 无风格 → 使用收益优先策略，须用工具算账。",
    ]
    legality = load_legality_skill()
    if legality:
        parts.append("### 合法性底线（始终）\n" + legality)

    dice_lines = [
        f"- 领袖 {a.player_id}：{a.audit_token()}"
        for a in sorted(assignments.values(), key=lambda x: x.player_id)
    ]
    if dice_lines:
        parts.append("### 本轮风格掷骰\n" + "\n".join(dice_lines))

    # Cosplay: style skills only
    cosplay_by_style: dict[str, list[StyleAssignment]] = {}
    for asn in assignments.values():
        if asn.mode != "cosplay" or not asn.style_id:
            continue
        cosplay_by_style.setdefault(asn.style_id, []).append(asn)

    for style_id, group in sorted(cosplay_by_style.items()):
        body = load_style_skill(style_id)
        if not body:
            continue
        name = group[0].display_name
        leaders = ", ".join(
            str(a.player_id) for a in sorted(group, key=lambda x: x.player_id)
        )
        parts.append(
            f"### 风格 Skill（cosplay）：{name}（`{style_id}`）"
            f" · 适用领袖 {leaders}\n"
            + body
        )

    # Payoff: styled+payoff OR no style (none)
    payoff_ids = [
        str(a.player_id)
        for a in sorted(assignments.values(), key=lambda x: x.player_id)
        if a.mode in {"payoff", "none"}
    ]
    if payoff_ids:
        payoff = load_payoff_skill()
        if payoff:
            parts.append(
                "### 收益优先策略（payoff）\n"
                f"适用领袖 {', '.join(payoff_ids)}："
                "忽略风格偏好序；按下列策略用工具评估后再选。\n\n"
                + payoff
            )

    return "\n\n".join(parts)


def styles_for_session_lock(
    assignments: dict[int, StyleAssignment],
) -> dict[str, str]:
    """Persistable map player_id → style_id (only confident hits)."""
    out: dict[str, str] = {}
    for pid, asn in assignments.items():
        if asn.style_id and (asn.locked or asn.score >= 3):
            out[str(pid)] = asn.style_id
    return out


def format_styles_meta(assignments: dict[int, StyleAssignment]) -> str:
    if not assignments:
        return ""
    return ", ".join(assignments[pid].audit_token() for pid in sorted(assignments))


def format_styles_dice_json(assignments: dict[int, StyleAssignment]) -> str:
    """JSON array for decision log audit section."""
    rows = []
    for pid in sorted(assignments):
        asn = assignments[pid]
        rows.append(
            {
                "player_id": pid,
                "style_id": asn.style_id,
                "mode": asn.mode,
                "dice_u": asn.dice_u,
                "cosplay_p": asn.cosplay_p,
                "score": asn.score,
                "locked": asn.locked,
                "reasons": list(asn.reasons),
            }
        )
    return json.dumps(rows, ensure_ascii=False)
