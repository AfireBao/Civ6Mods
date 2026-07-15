"""Load Haikesi LLM config and invoke chat models (OpenAI-compatible or Anthropic)."""

from __future__ import annotations

import json
import logging
import os
import re
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Protocol

from civ_mcp.connection import GameConnection, LuaError
from civ_mcp.game_state import GameState
from civ_mcp.lua import haikesi as haikesi_lua
from civ_mcp.lua.haikesi import (
    BELIEF_CLASS_LABELS,
    LeaderView,
    MetCivView,
    RST_STRATEGY_LABELS,
)
from civ_mcp.lua.models import GameOverview, WorldCongressStatus

log = logging.getLogger(__name__)

# Lua EXT_AI_REASON_MAX_LEN=200 counts bytes; ~66 CJK chars fit safely.
_REASON_MAX_CHARS = 66

# Repo root: .../civ6-mcp-haikesi (this file lives in src/civ_mcp/)
_PKG_ROOT = Path(__file__).resolve().parents[2]
_DEFAULT_PROMPT_DIR = _PKG_ROOT / "logs"
_LAST_PROMPT_FILE = "haikesi_last_prompt.txt"
_LAST_EXCHANGE_FILE = "haikesi_last_exchange.json"


def last_prompt_path() -> Path:
    """Directory/file where the latest LLM prompt is written (override via env)."""
    override = os.environ.get("HAIKESI_LAST_PROMPT_PATH", "").strip()
    if override:
        return Path(override)
    return _DEFAULT_PROMPT_DIR / _LAST_PROMPT_FILE


def save_last_llm_exchange(
    *,
    prompt: str,
    raw_response: str,
    request_id: str,
    model: str,
    choices: dict[str, Any],
    reasons: dict[str, str],
) -> Path:
    """Persist latest prompt (+ exchange metadata) under logs/ for inspection."""
    prompt_path = last_prompt_path()
    prompt_path.parent.mkdir(parents=True, exist_ok=True)
    prompt_path.write_text(prompt, encoding="utf-8")

    exchange_path = prompt_path.parent / _LAST_EXCHANGE_FILE
    if os.environ.get("HAIKESI_LAST_PROMPT_PATH", "").strip():
        # Custom prompt path: keep exchange next to it with a fixed sibling name.
        exchange_path = prompt_path.with_name(_LAST_EXCHANGE_FILE)
    exchange = {
        "saved_at": time.strftime("%Y-%m-%d %H:%M:%S"),
        "request_id": request_id,
        "model": model,
        "prompt_chars": len(prompt),
        "prompt_path": str(prompt_path),
        "choices": choices,
        "reasons": reasons,
        "raw_response": raw_response,
    }
    exchange_path.write_text(
        json.dumps(exchange, ensure_ascii=False, indent=2),
        encoding="utf-8",
    )
    return prompt_path


def sanitize_decision_reason(reason: str, *, max_chars: int = _REASON_MAX_CHARS) -> str:
    """Strip emoji/special chars and bound length before FireTuner → game UI."""
    if not reason:
        return ""
    text = reason.strip()
    text = re.sub(r"[\U00010000-\U0010ffff]", "", text)
    text = re.sub(r"[\x00-\x1f\x7f]", "", text)
    kept: list[str] = []
    for ch in text:
        code = ord(ch)
        if (
            0x4E00 <= code <= 0x9FFF
            or 0x3400 <= code <= 0x4DBF
            or ch.isascii()
            and (ch.isalnum() or ch in " +-/%.,，。、；：？！""''（）【】《》…—·")
        ):
            kept.append(ch)
    text = re.sub(r"\s+", " ", "".join(kept)).strip()
    if len(text) > max_chars:
        text = text[:max_chars].rstrip("，。、；： ")
    return text


class _ChatClient(Protocol):
    def complete(self, prompt: str) -> str: ...


@dataclass(frozen=True)
class HaikesiLLMConfig:
    api_key: str
    model: str
    base_url: str | None = None

    @property
    def provider_label(self) -> str:
        if self.base_url:
            return f"openai-compatible @ {self.base_url}"
        return "anthropic"


def _repo_root() -> Path:
    return Path(__file__).resolve().parents[2]


DEEPSEEK_BASE_URL = "https://api.deepseek.com"
DEEPSEEK_DEFAULT_MODEL = "deepseek-chat"


def load_dotenv_file(path: Path | None = None) -> None:
    env_path = path or (_repo_root() / ".env")
    if not env_path.is_file():
        return
    for raw_line in env_path.read_text(encoding="utf-8").splitlines():
        line = raw_line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        value = value.strip().strip('"').strip("'")
        if key and key not in os.environ:
            os.environ[key] = value


def load_haikesi_llm_config() -> HaikesiLLMConfig:
    load_dotenv_file()
    api_key = (
        os.environ.get("HAIKESI_LLM_API_KEY")
        or os.environ.get("OPENAI_API_KEY")
        or os.environ.get("ANTHROPIC_API_KEY")
    )
    if not api_key:
        raise RuntimeError(
            "Missing API key. Set HAIKESI_LLM_API_KEY (or OPENAI_API_KEY) in .env or environment."
        )

    base_url = (
        os.environ.get("HAIKESI_LLM_BASE_URL")
        or os.environ.get("OPENAI_BASE_URL")
        or os.environ.get("OPENAI_API_BASE")
    )
    default_model = "gpt-5.5" if base_url else "claude-sonnet-4-20250514"
    model = os.environ.get("HAIKESI_LLM_MODEL") or os.environ.get("OPENAI_MODEL") or default_model
    return HaikesiLLMConfig(api_key=api_key, model=model, base_url=base_url)


def load_deepseek_config() -> HaikesiLLMConfig:
    """Load DeepSeek API config (OpenAI-compatible)."""
    load_dotenv_file()
    api_key = os.environ.get("DEEPSEEK_API_KEY") or os.environ.get("HAIKESI_LLM_API_KEY")
    if not api_key:
        raise RuntimeError(
            "Missing DeepSeek API key. Set DEEPSEEK_API_KEY in .env "
            "(get one at https://platform.deepseek.com/api_keys)."
        )
    model = (
        os.environ.get("DEEPSEEK_MODEL")
        or os.environ.get("HAIKESI_LLM_MODEL")
        or DEEPSEEK_DEFAULT_MODEL
    )
    base_url = os.environ.get("DEEPSEEK_BASE_URL") or DEEPSEEK_BASE_URL
    return HaikesiLLMConfig(api_key=api_key, model=model, base_url=base_url)


_LLM_MAX_TOKENS = int(os.environ.get("HAIKESI_LLM_MAX_TOKENS", "4096"))


def _env_flag(name: str, default: bool) -> bool:
    raw = os.environ.get(name)
    if raw is None or raw.strip() == "":
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


class _OpenAICompatibleClient:
    def __init__(self, config: HaikesiLLMConfig) -> None:
        from openai import OpenAI

        self._client = OpenAI(api_key=config.api_key, base_url=config.base_url)
        self._model = config.model
        # DeepSeek 官方：JSON Output 会偶发空 content；默认关闭，靠 prompt + 解析容错。
        self._json_mode = _env_flag("HAIKESI_LLM_JSON_MODE", False)
        # DeepSeek V4 thinking 默认 enabled，推理会吃掉 max_tokens 导致 content 为空。
        self._thinking_enabled = _env_flag("HAIKESI_LLM_THINKING", False)

    def _build_kwargs(self, prompt: str) -> dict[str, Any]:
        kwargs: dict[str, Any] = {
            "model": self._model,
            "messages": [{"role": "user", "content": prompt}],
            "max_tokens": _LLM_MAX_TOKENS,
        }
        if self._json_mode:
            kwargs["response_format"] = {"type": "json_object"}
        # OpenAI SDK：thinking 走 extra_body（DeepSeek V4）
        kwargs["extra_body"] = {
            "thinking": {"type": "enabled" if self._thinking_enabled else "disabled"}
        }
        return kwargs

    def _extract_content(self, response: Any) -> tuple[str, str]:
        choice = response.choices[0]
        msg = choice.message
        content = (msg.content or "").strip()
        finish = getattr(choice, "finish_reason", None) or ""
        reasoning = getattr(msg, "reasoning_content", None) or ""
        if not content and reasoning:
            # 极少数网关把最终答案只放在 reasoning；尝试抽取 JSON
            extracted = _extract_json_object(str(reasoning))
            if extracted:
                log.warning(
                    "message.content empty; recovered JSON from reasoning_content "
                    "(finish_reason=%s)",
                    finish,
                )
                return extracted, finish
        return content, finish

    def complete(self, prompt: str) -> str:
        last_detail = ""
        # 空 content 时逐步降级：关 json → 关 thinking 已是默认 → 再重试
        attempts = (
            (self._json_mode, self._thinking_enabled),
            (False, self._thinking_enabled),
            (False, False),
        )
        seen: set[tuple[bool, bool]] = set()
        for json_mode, thinking in attempts:
            key = (json_mode, thinking)
            if key in seen:
                continue
            seen.add(key)
            self._json_mode = json_mode
            self._thinking_enabled = thinking
            kwargs = self._build_kwargs(prompt)
            try:
                response = self._client.chat.completions.create(**kwargs)
            except Exception as exc:
                last_detail = str(exc)
                # 不支持 json_object / thinking 时换下一档
                log.warning(
                    "LLM create failed (json=%s thinking=%s): %s",
                    json_mode,
                    thinking,
                    exc,
                )
                continue
            content, finish = self._extract_content(response)
            if content:
                return content
            reasoning_len = len(
                getattr(response.choices[0].message, "reasoning_content", None) or ""
            )
            last_detail = (
                f"empty content finish_reason={finish!r} "
                f"reasoning_chars={reasoning_len} json={json_mode} thinking={thinking}"
            )
            log.warning("LLM empty content; retrying (%s)", last_detail)
        raise RuntimeError(f"LLM returned empty content ({last_detail})")


class _AnthropicClient:
    def __init__(self, config: HaikesiLLMConfig) -> None:
        from anthropic import Anthropic

        self._client = Anthropic(api_key=config.api_key)
        self._model = config.model

    def complete(self, prompt: str) -> str:
        response = self._client.messages.create(
            model=self._model,
            max_tokens=_LLM_MAX_TOKENS,
            messages=[{"role": "user", "content": prompt}],
        )
        return response.content[0].text


def create_chat_client(config: HaikesiLLMConfig) -> _ChatClient:
    if config.base_url:
        return _OpenAICompatibleClient(config)
    return _AnthropicClient(config)


@dataclass
class HaikesiGameContext:
    """Game state for Haikesi AI relic decisions (per-leader fog views)."""

    overview: GameOverview
    leader_views: dict[int, LeaderView] = field(default_factory=dict)
    human_player_id: int = 0
    fetch_notes: list[str] = field(default_factory=list)
    world_congress: WorldCongressStatus | None = None


async def _safe_fetch(label: str, coro, notes: list[str]):
    try:
        return await coro
    except Exception as exc:
        notes.append(f"{label}: unavailable ({exc})")
        log.debug("Haikesi context fetch failed: %s", label, exc_info=True)
        return None


async def gather_haikesi_game_context(
    gs: GameState,
    viewer_ids: list[int] | None = None,
) -> HaikesiGameContext:
    """Pull public overview + per-AI diplo/fog views (not human god-view dumps)."""
    notes: list[str] = []
    overview = await gs.get_game_overview()
    human_id = overview.player_id

    leader_views: dict[int, LeaderView] = {}
    ids = [int(i) for i in (viewer_ids or []) if int(i) >= 0]
    if ids:

        async def _fetch_views():
            lines = await gs.conn.execute_write(
                haikesi_lua.build_leader_views_query(ids)
            )
            return haikesi_lua.parse_leader_views(lines)

        fetched = await _safe_fetch("leader_views", _fetch_views(), notes)
        rst_available: bool | None = None
        if isinstance(fetched, tuple):
            leader_views = fetched[0] or {}
            rst_available = fetched[1]
        elif isinstance(fetched, dict):
            leader_views = fetched

        missing = [i for i in ids if i not in leader_views]
        if missing:
            notes.append(f"leader_views: missing viewers {missing}")

        if rst_available is False:
            # InGame 可能看不到 GamePlay ExposedMembers；用海克斯 GamePlay 状态回退探测
            async def _fetch_rst_fallback():
                lines = await gs.conn.execute_haikesi(
                    haikesi_lua.build_rst_strategies_query(ids)
                )
                return haikesi_lua.parse_rst_strategies(lines)

            fb = await _safe_fetch("real_strategy_fallback", _fetch_rst_fallback(), notes)
            if isinstance(fb, tuple):
                rst_map, rst_available = fb[0] or {}, fb[1]
                for vid, rst_view in rst_map.items():
                    if vid in leader_views:
                        leader_views[vid].rst = rst_view

        if rst_available is False:
            notes.append("Real Strategy: 未加载（软依赖跳过）")
        elif rst_available is True:
            with_rst = sum(1 for v in leader_views.values() if v.rst is not None)
            if with_rst == 0:
                notes.append("Real Strategy: 已加载但尚无 ActiveStrategy 数据")
            elif with_rst < len(leader_views):
                notes.append(
                    f"Real Strategy: {with_rst}/{len(leader_views)} 位领袖有战略意图"
                )

    async def _fetch_wc():
        return await gs.get_world_congress(soft_missing=True)

    world_congress = await _safe_fetch("world_congress", _fetch_wc(), notes)

    return HaikesiGameContext(
        overview=overview,
        leader_views=leader_views,
        human_player_id=human_id,
        fetch_notes=notes,
        world_congress=world_congress,
    )


def _met_table(met: list[MetCivView]) -> str:
    if not met:
        return "(尚未与其他主要文明建立接触)"
    header = (
        "id | 文明 | 领袖 | 分数 | 城 | 人口 | 科/回合 | 文/回合 | 金/回合 | "
        "军力 | 科技数 | 市政数 | 信仰 | 关系 | 交战 | 我对彼不满 | 彼对我不满"
    )
    rows = [header]
    for m in sorted(met, key=lambda x: -x.score):
        rows.append(
            f"{m.player_id} | {m.civ_name} | {m.leader_name} | {m.score} | {m.cities} | {m.pop} | "
            f"{m.sci} | {m.cul} | {m.gold} | {m.mil} | {m.techs} | {m.civics} | {m.faith} | "
            f"{m.diplomatic_state}({m.relationship_score}) | "
            f"{'是' if m.is_at_war else '否'} | {m.grievances} | {m.grievances_against_me}"
        )
    return "\n".join(rows)


def _diplo_attitude_block(met: list[MetCivView]) -> str:
    """Summarize grievances + top opinion modifiers for met civs."""
    if not met:
        return ""
    lines: list[str] = [
        "【对已遇文明的不满与观感】（不满=外交不满值；修饰语=对方对你的好感/恶感原因）"
    ]
    any_row = False
    for m in sorted(
        met,
        key=lambda x: -(abs(x.grievances) + abs(x.grievances_against_me) + abs(x.relationship_score)),
    ):
        if (
            m.grievances == 0
            and m.grievances_against_me == 0
            and not m.modifiers
            and abs(m.relationship_score) < 5
        ):
            continue
        any_row = True
        lines.append(
            f"- {m.civ_name}（{m.leader_name}）: 关系 {m.diplomatic_state}"
            f"（{m.relationship_score}）；我对彼不满 {m.grievances}；"
            f"彼对我不满 {m.grievances_against_me}"
        )
        # Prefer largest absolute modifiers; keep prompt short
        top = sorted(m.modifiers, key=lambda x: -abs(x.score))[:4]
        for mod in top:
            sign = f"+{mod.score}" if mod.score >= 0 else str(mod.score)
            lines.append(f"  · [{sign}] {mod.text}")
    if not any_row:
        return ""
    return "\n".join(lines)


def _format_world_congress(status: WorldCongressStatus | None) -> str:
    """Public World Congress block for Haikesi prompts (Chinese)."""
    if status is None:
        return "世界会议: 尚未解锁或当前不可用"

    imminent = not status.is_in_session and status.turns_until_next <= 0
    lines: list[str] = []
    if status.is_in_session:
        lines.append("状态: 开会中（本局正在表决）")
    elif imminent:
        lines.append("状态: 本回合即将开会")
    elif status.turns_until_next >= 0:
        lines.append(f"状态: 距下次会议还有 {status.turns_until_next} 回合")
    else:
        lines.append("状态: 尚未召开")

    if status.resolutions:
        lines.append("决议/议程:")
        for i, r in enumerate(status.resolutions, 1):
            if status.is_in_session or imminent:
                lines.append(f"  {i}. {r.name}（{r.resolution_type}）")
                if r.effect_a:
                    lines.append(f"     选项A: {r.effect_a}")
                if r.effect_b:
                    lines.append(f"     选项B: {r.effect_b}")
                if r.possible_targets:
                    tgt_strs = []
                    for t in r.possible_targets[:8]:
                        if ":" in t:
                            _tid, tname = t.split(":", 1)
                            tgt_strs.append(tname)
                        else:
                            tgt_strs.append(t)
                    more = "…" if len(r.possible_targets) > 8 else ""
                    lines.append(f"     可选目标: {', '.join(tgt_strs)}{more}")
            else:
                outcome = "A" if r.winner == 0 else "B" if r.winner == 1 else "?"
                effect = (
                    r.effect_a
                    if r.winner == 0
                    else r.effect_b
                    if r.winner == 1
                    else ""
                )
                chosen = f"（{r.chosen_thing}）" if r.chosen_thing else ""
                lines.append(
                    f"  {i}. {r.name} — 已通过选项{outcome}{chosen}"
                    + (f": {effect}" if effect else "")
                )
    else:
        lines.append("决议/议程: （无）")

    if status.is_in_session and status.proposals:
        lines.append("讨论提案:")
        for p in status.proposals[:6]:
            desc = f" — {p.description}" if p.description else ""
            lines.append(
                f"  · {p.sender_name} → {p.target_name}{desc}"
            )

    return "\n".join(lines)


def _threat_table(view: LeaderView) -> str:
    if not view.threats:
        return "(视野内未见敌对军事单位)"
    rows = ["势力 | 可见单位数 | 最近距离(格)"]
    for t in sorted(view.threats, key=lambda x: (x.nearest_dist, -x.count)):
        name = "蛮族" if t.owner_name == "Barbarian" else t.owner_name
        rows.append(f"{name} | {t.count} | {t.nearest_dist}")
    return "\n".join(rows)


def _traits_block(view: LeaderView) -> str:
    lines: list[str] = []
    for name, desc in view.leader_traits[:4]:
        lines.append(f"- 领袖能力「{name}」: {desc}")
    for name, desc in view.civ_traits[:4]:
        lines.append(f"- 文明特性「{name}」: {desc}")
    for name, desc in view.agendas[:2]:
        lines.append(f"- 历史议程「{name}」: {desc}")
    if not lines:
        return "(无可用能力/议程文本)"
    return "\n".join(lines)


def _cities_table(view: LeaderView) -> str:
    if not view.own_cities:
        return "(无城市数据)"
    rows = [
        "城名 | 人口 | 粮/产/金/科/文/信 | 住房 | 宜居 | 区划 | 在建(回合) | 忠诚"
    ]
    for c in sorted(view.own_cities, key=lambda x: -x.pop):
        districts = c.districts or "-"
        prod = c.producing
        if prod != "空闲" and c.turns_left > 0:
            prod = f"{prod}({c.turns_left})"
        rows.append(
            f"{c.name} | {c.pop} | "
            f"{c.food:.0f}/{c.prod:.0f}/{c.gold:.0f}/{c.sci:.0f}/{c.cul:.0f}/{c.faith:.0f} | "
            f"{c.housing:.0f} | {c.amenities}/{c.amenities_needed} | {districts} | "
            f"{prod} | {c.loyalty:.0f}"
        )
    return "\n".join(rows)


def _religion_block(view: LeaderView) -> str:
    """Format own pantheon / religion tenets for one leader (with effect text)."""
    rel = view.religion
    if rel is None:
        return ""

    def _effect(text: str, *, limit: int = 120) -> str:
        desc = haikesi_lua._strip_civ_icons(text or "").strip()
        desc = desc.replace("\n", " ")
        if len(desc) > limit:
            desc = desc[:limit].rstrip() + "…"
        return desc

    lines = ["【本国宗教】"]
    pan_belief = next(
        (b for b in rel.beliefs if b.belief_class == "BELIEF_CLASS_PANTHEON"),
        None,
    )
    if rel.pantheon_name or pan_belief:
        name = rel.pantheon_name or (pan_belief.name if pan_belief else "")
        typ = rel.pantheon_type or (pan_belief.belief_type if pan_belief else "")
        desc = _effect(pan_belief.description) if pan_belief else ""
        if desc:
            lines.append(f"万神殿: {name}（{typ}）— {desc}")
        else:
            lines.append(f"万神殿: {name}（{typ}）")
    else:
        lines.append("万神殿: 尚未选择")

    if rel.religion_name:
        lines.append(f"创立宗教: {rel.religion_name}（{rel.religion_type}）")
    else:
        lines.append("创立宗教: 尚未创立")

    tenets = [
        b for b in rel.beliefs if b.belief_class != "BELIEF_CLASS_PANTHEON"
    ]
    if tenets:
        lines.append("教义词条:")
        for b in tenets:
            cls = BELIEF_CLASS_LABELS.get(
                b.belief_class, b.belief_class.replace("BELIEF_CLASS_", "")
            )
            desc = _effect(b.description)
            if desc:
                lines.append(f"- [{cls}] {b.name}（{b.belief_type}）— {desc}")
            else:
                lines.append(f"- [{cls}] {b.name}（{b.belief_type}）")
    return "\n".join(lines)


def _rst_block(view: LeaderView) -> str:
    """Format Real Strategy soft snapshot for one leader (or hide if absent)."""
    rst = view.rst
    if rst is None:
        return ""
    label = RST_STRATEGY_LABELS.get(rst.active_strategy, rst.active_strategy)
    pri = rst.priorities
    order = ("CONQUEST", "SCIENCE", "CULTURE", "RELIGION", "DIPLO")
    ranked = sorted(order, key=lambda k: -float(pri.get(k, 0.0)))
    pri_txt = " / ".join(
        f"{RST_STRATEGY_LABELS.get(k, k)}{pri.get(k, 0.0):.0f}" for k in ranked
    )
    flags: list[str] = []
    if rst.active_defense is True:
        flags.append("防御态势开启")
    if rst.active_catching is True:
        flags.append("军力追赶态势开启")
    flag_txt = f"；{'、'.join(flags)}" if flags else ""
    return "\n".join(
        [
            "【Real Strategy 战略意图】（仅作选卡倾向参考，非强制）",
            f"主战略: {label}（{rst.active_strategy}） | 优先级: {pri_txt}{flag_txt}",
        ]
    )


def _victory_rank_block(view: LeaderView) -> str:
    """Per-viewer fog: rank self + met civs on victory-relevant metrics."""
    peers = view.victory_peers
    if not peers:
        return ""
    me = view.player_id
    n = len(peers)

    def _label(p: haikesi_lua.VictoryPeerStat) -> str:
        return "我" if p.player_id == me else p.civ_name

    def _rank_line(title: str, key_fn, fmt_fn, *, top: int = 4) -> str:
        ordered = sorted(peers, key=key_fn, reverse=True)
        my_rank = next(
            (i + 1 for i, p in enumerate(ordered) if p.player_id == me), n
        )
        bits = [
            f"{i + 1}.{_label(p)}{fmt_fn(p)}"
            for i, p in enumerate(ordered[:top])
        ]
        more = f"…共{n}家" if n > top else f"共{n}家"
        return f"{title}: {' · '.join(bits)}（我#{my_rank}/{n}；{more}）"

    return "\n".join(
        [
            "【已知文明胜利进度排名】（仅自己与已相遇；未相遇者不在榜）",
            _rank_line(
                "分数",
                lambda p: (p.score, p.mil),
                lambda p: f"{p.score}",
            ),
            _rank_line(
                "科技",
                lambda p: (p.science_vp, p.techs, p.spaceports),
                lambda p: f"{p.science_vp}/{p.science_needed}VP·科{p.techs}"
                + (f"·港{p.spaceports}" if p.spaceports else ""),
            ),
            _rank_line(
                "外交",
                lambda p: (p.diplo_vp, p.score),
                lambda p: f"{p.diplo_vp}分",
            ),
            _rank_line(
                "文化",
                lambda p: (p.tourism, p.civics),
                lambda p: f"旅{p.tourism}·内游{p.staycationers}",
            ),
            _rank_line(
                "宗教",
                lambda p: (p.rel_cities, p.score),
                lambda p: f"{p.rel_cities}城追随",
            ),
            _rank_line(
                "征服(军力)",
                lambda p: (p.mil, 0 if p.holds_own_capital else 1, p.score),
                lambda p: f"军{p.mil}"
                + ("·非原都" if not p.holds_own_capital else ""),
            ),
        ]
    )


def _format_leader_block(
    ai: dict[str, Any],
    view: LeaderView | None,
    human_player_id: int,
) -> str:
    pid = int(ai["player_id"])
    if view is None:
        label = ai.get("player_name") or ai.get("civ_label") or str(pid)
        return (
            f"### 领袖 {pid}（{label}）\n"
            "可见情报不足（未能读取该领袖外交/视野数据）。\n"
            "仅根据候选海克斯与已选海克斯，从自身发展需求选卡。\n"
            "候选海克斯:\n"
            + "\n".join(haikesi_lua.format_option_lines(ai.get("options", [])))
            + f"\n已选海克斯: {haikesi_lua.format_relic_type_list(ai.get('selected', []))}"
        )

    title = f"### 领袖 {pid}：{view.civ_name}（{view.leader_name}）"
    human_met = next((m for m in view.met if m.player_id == human_player_id), None)
    if human_met:
        human_line = (
            f"已接触人类玩家 {human_met.civ_name}（{human_met.leader_name}）："
            f"关系 {human_met.diplomatic_state}({human_met.relationship_score})，"
            f"{'交战' if human_met.is_at_war else '和平'}，"
            f"科{human_met.sci}/文{human_met.cul}/金{human_met.gold}，军力{human_met.mil}，"
            f"我对彼不满{human_met.grievances}，彼对我不满{human_met.grievances_against_me}"
        )
    else:
        human_line = "尚未与人类玩家建立接触（不知其详细国力与位置）"

    parts = [
        title,
        "【你的身份】",
        _traits_block(view),
        "【本国国力】",
        (
            f"分数{view.score} | {view.cities}城 | 人口{view.pop} | "
            f"科{view.sci}/回合 文{view.cul}/回合 金{view.gold}/回合 | "
            f"军力{view.mil} | 科技{view.techs} 市政{view.civics} | 信仰{view.faith}/回合 | "
            f"外交支持度{view.favor} | "
            f"在研:{view.current_research} | 市政:{view.current_civic}"
        ),
    ]
    rst_txt = _rst_block(view)
    if rst_txt:
        parts.append(rst_txt)
    rel_txt = _religion_block(view)
    if rel_txt:
        parts.append(rel_txt)
    vic_txt = _victory_rank_block(view)
    if vic_txt:
        parts.append(vic_txt)
    parts.extend(
        [
            "【本国城市】",
            _cities_table(view),
            "【与人类】",
            human_line,
            "【已相遇文明（外交可见数值；未相遇者不出现）】",
            _met_table(view.met),
        ]
    )
    attitude = _diplo_attitude_block(view.met)
    if attitude:
        parts.append(attitude)
    parts.extend(
        [
            "【视野内可见敌对军事单位（战争迷雾外不可见）】",
            _threat_table(view),
            "【候选海克斯】",
            "\n".join(haikesi_lua.format_option_lines(ai.get("options", []))),
            f"【已选海克斯】{haikesi_lua.format_relic_type_list(ai.get('selected', []))}",
        ]
    )
    return "\n".join(parts)


def format_context_summary(context: HaikesiGameContext) -> str:
    """One-line summary of fetched civ6-mcp context for watch script logs."""
    ov = context.overview
    met_total = sum(len(v.met) for v in context.leader_views.values())
    threat_total = sum(len(v.threats) for v in context.leader_views.values())
    city_total = sum(len(v.own_cities) for v in context.leader_views.values())
    trait_total = sum(
        len(v.leader_traits) + len(v.civ_traits) + len(v.agendas)
        for v in context.leader_views.values()
    )
    rst_total = sum(1 for v in context.leader_views.values() if v.rst is not None)
    faith_total = sum(
        1
        for v in context.leader_views.values()
        if v.religion is not None
        and (v.religion.pantheon_type or v.religion.religion_type)
    )
    victory_peers = sum(len(v.victory_peers) for v in context.leader_views.values())
    mod_total = sum(len(m.modifiers) for v in context.leader_views.values() for m in v.met)
    wc = context.world_congress
    if wc is None:
        wc_tag = "none"
    elif wc.is_in_session:
        wc_tag = f"session:{len(wc.resolutions)}res"
    else:
        wc_tag = f"next={wc.turns_until_next}:{len(wc.resolutions)}res"
    parts = [
        f"turn={ov.turn}",
        f"human={ov.civ_name or '未知'}(id={context.human_player_id})",
        f"leader_views={len(context.leader_views)}",
        f"traits_agendas={trait_total}",
        f"own_cities={city_total}",
        f"met_edges={met_total}",
        f"diplo_modifiers={mod_total}",
        f"visible_threat_groups={threat_total}",
        f"rst_strategies={rst_total}",
        f"religion_intel={faith_total}",
        f"victory_peer_rows={victory_peers}",
        f"world_congress={wc_tag}",
    ]
    if context.fetch_notes:
        parts.append(f"fetch_warnings={len(context.fetch_notes)}")
    return "Context OK: " + ", ".join(parts)


def build_decision_prompt(payload: dict[str, Any], context: HaikesiGameContext) -> str:
    ai_blocks = [
        _format_leader_block(
            ai,
            context.leader_views.get(int(ai["player_id"])),
            context.human_player_id,
        )
        for ai in payload.get("ai_players", [])
    ]

    invasion_note = (
        "本轮 NW_AI_BARBARIAN_INVASION 互斥：全场最多一名领袖可选。"
        if payload.get("invasion_mutex")
        else "本轮无南蛮入侵互斥限制。"
    )
    human_relic = haikesi_lua.format_relic_display(str(payload.get("human_relic") or ""))

    notes_block = ""
    if context.fetch_notes:
        notes_block = (
            "## 数据说明（系统）\n"
            + "\n".join(f"- {n}" for n in context.fetch_notes)
            + "\n\n"
        )

    return f"""你同时代入下列多位文明领袖，为各自选择本轮海克斯。数据来自真实对局（FireTuner）。

情报规则（必须遵守）：
- 每位领袖只能使用**自己区块**内的情报做决策；禁止引用其他领袖区块，也禁止臆造未给出的单位/文明。
- 未相遇文明、战争迷雾外的敌军对本领袖不存在，不得当作已知信息。
- 人类本轮海克斯、全局时代/难度、世界会议决议是本局公开机制信息，各位领袖都可以参考。
- 已相遇文明的科/文/金/军力、双向不满值、对方对你的外交修饰语等为外交界面可见信息，可以比较。
- 若区块含「已知文明胜利进度排名」：仅可比较榜内文明；未上榜者对本领袖不可见。
- 若区块含「Real Strategy 战略意图」：将其作为该领袖当前胜利路线倾向；选卡应优先契合主战略（征服→军事/扩张，科技→科研，文化→文化/伟人，宗教→信仰，外交→使者/外交），但若候选与短板/可见威胁明显冲突，可偏离。

## 当前回合
Turn {payload.get("turn")}

## 全局公开设定
难度: {context.overview.difficulty or '未知'} | 速度: {context.overview.game_speed_name or '未知'} | 时代: {context.overview.era_name}

## 世界会议（公开）
{_format_world_congress(context.world_congress)}

## 人类玩家本轮海克斯（公开）
{human_relic}

{notes_block}## 待决策领袖（逐位以该领袖身份选卡）
{chr(10).join(ai_blocks)}

## 规则
- 每位领袖只能从其「候选海克斯」中选 1 个 relic type
- {invasion_note}
- 决策结合：自身能力与议程、Real Strategy 主战略（若有）、本国万神殿/教义、已知胜利进度排名、对已遇文明的不满与观感、世界会议决议、本国城市与产出短板、已相遇文明对比、可见威胁、人类公开海克斯、候选效果
- reason 用 1 句规范简体中文（常用汉字，20-40 字），第一人称「我」；禁止 emoji、英文双引号 "、生僻字，不要复述效果全文
- 必须输出完整合法 JSON（所有字符串已闭合）；禁止 markdown 代码块

## 输出格式（仅 JSON，无 markdown）
{{
  "choices": {{"1": "NW_AI_...", "...": "NW_AI_..."}},
  "reasons": {{"1": "...", "...": "..."}}
}}
"""


def _strip_code_fences(text: str) -> str:
    text = text.strip()
    if text.startswith("```"):
        text = text.split("\n", 1)[-1]
        if text.endswith("```"):
            text = text.rsplit("```", 1)[0]
        text = text.strip()
        if text.lower().startswith("json"):
            text = text[4:].lstrip()
    return text


def _extract_json_object(text: str) -> str | None:
    start = text.find("{")
    if start < 0:
        return None
    depth = 0
    in_str = False
    escape = False
    for i in range(start, len(text)):
        ch = text[i]
        if in_str:
            if escape:
                escape = False
            elif ch == "\\":
                escape = True
            elif ch == '"':
                in_str = False
            continue
        if ch == '"':
            in_str = True
        elif ch == "{":
            depth += 1
        elif ch == "}":
            depth -= 1
            if depth == 0:
                return text[start : i + 1]
    # 截断时返回从首 { 到末尾，交给上层再试/失败
    return text[start:] if depth > 0 else None


def parse_llm_json(raw: str) -> dict[str, Any]:
    """Parse LLM JSON; tolerate markdown fences and surrounding prose."""
    text = _strip_code_fences(raw)
    candidates = [text]
    extracted = _extract_json_object(text)
    if extracted and extracted not in candidates:
        candidates.append(extracted)
    # 常见：尾逗号
    for cand in list(candidates):
        fixed = re.sub(r",\s*([}\]])", r"\1", cand)
        if fixed not in candidates:
            candidates.append(fixed)

    errors: list[Exception] = []
    for cand in candidates:
        try:
            data = json.loads(cand)
            if isinstance(data, dict):
                return data
        except json.JSONDecodeError as exc:
            errors.append(exc)
    raise errors[-1] if errors else json.JSONDecodeError("no json object", text, 0)


def _save_failed_llm_raw(
    *,
    prompt: str,
    raw_response: str,
    request_id: str,
    model: str,
    error: str,
) -> None:
    try:
        save_last_llm_exchange(
            prompt=prompt,
            raw_response=raw_response,
            request_id=request_id,
            model=model,
            choices={},
            reasons={"_parse_error": error[:200]},
        )
    except OSError as exc:
        log.warning("Failed to save broken LLM response: %s", exc)


async def poll_pending_request(conn: GameConnection) -> dict[str, Any]:
    try:
        lines = await conn.execute_haikesi(haikesi_lua.build_get_ai_request_lua())
        return haikesi_lua.parse_ai_request_lines(lines)
    except LuaError as exc:
        msg = str(exc)
        if "Haikesi_GetExternalAIRequest" in msg or "function expected instead of nil" in msg:
            return {
                "status": "not_ready",
                "message": "Haikesi API unavailable (not on map or mod not loaded)",
            }
        raise


async def decide_and_submit_once(
    conn: GameConnection,
    gs: GameState,
    client: _ChatClient,
    model: str,
    *,
    verbose: bool = True,
) -> bool:
    """Poll once; if pending, call LLM and submit. Returns True if a request was handled."""
    payload = await poll_pending_request(conn)
    if payload.get("status") == "not_ready":
        if verbose:
            print(f"(game not ready: {payload.get('message', 'not in map')})")
        return False
    if payload.get("status") != "pending":
        if verbose:
            print("(no pending request)")
        return False

    request_id = str(payload.get("request_id", ""))
    if verbose:
        print(f"Pending {request_id!r}; gathering context...", flush=True)

    viewer_ids = [int(ai['player_id']) for ai in payload.get('ai_players', [])]
    context = await gather_haikesi_game_context(gs, viewer_ids)
    if verbose:
        print(format_context_summary(context), flush=True)

    prompt = build_decision_prompt(payload, context)

    if verbose:
        print(f"Calling {model} (prompt ~{len(prompt)} chars) ...", flush=True)
    raw = client.complete(prompt)
    try:
        decision = parse_llm_json(raw)
    except json.JSONDecodeError as exc:
        _save_failed_llm_raw(
            prompt=prompt,
            raw_response=raw,
            request_id=request_id,
            model=model,
            error=str(exc),
        )
        if verbose:
            print(
                f"LLM JSON parse failed ({exc}); retrying once ...",
                flush=True,
            )
        repair_prompt = (
            prompt
            + "\n\n【重试】你上次输出的 JSON 不合法（字符串未闭合或被截断）。"
            "请重新输出一个完整合法的 JSON 对象，不要 markdown；"
            "reasons 内只用中文逗号/句号，禁止英文双引号。"
        )
        raw = client.complete(repair_prompt)
        try:
            decision = parse_llm_json(raw)
        except json.JSONDecodeError as exc2:
            _save_failed_llm_raw(
                prompt=repair_prompt,
                raw_response=raw,
                request_id=request_id,
                model=model,
                error=str(exc2),
            )
            raise RuntimeError(
                f"LLM returned invalid JSON after retry: {exc2}"
            ) from exc2

    choices = {str(k): v for k, v in decision.get("choices", {}).items()}
    raw_reasons = {str(k): v for k, v in decision.get("reasons", {}).items()}
    reasons: dict[str, str] = {}
    for ai_id, raw_reason in raw_reasons.items():
        if str(ai_id).startswith("_"):
            continue
        cleaned = sanitize_decision_reason(str(raw_reason))
        if cleaned:
            reasons[ai_id] = cleaned
    if not choices:
        raise RuntimeError("LLM returned empty choices")

    try:
        save_last_llm_exchange(
            prompt=prompt,
            raw_response=raw,
            request_id=request_id,
            model=model,
            choices=choices,
            reasons=reasons,
        )
    except OSError as exc:
        log.warning("Failed to save last prompt/exchange: %s", exc)

    if verbose:
        print(f"Submitting {request_id!r} ({len(choices)} choices) ...", flush=True)

    submit_lines = await conn.execute_haikesi(
        haikesi_lua.build_submit_ai_choices_lua(request_id, choices, reasons)
    )
    result = haikesi_lua.summarize_submit_result(submit_lines)
    parsed = json.loads(result)
    if not parsed.get("ok"):
        raise RuntimeError(parsed.get("message", "submit failed"))
    if verbose:
        print(f"Submit OK: {request_id!r}", flush=True)
    return True
