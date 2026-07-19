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
_LAST_DECISION_FILE = "haikesi_last_decision.md"


def last_prompt_path() -> Path:
    """Directory/file where the latest LLM prompt is written (override via env)."""
    override = os.environ.get("HAIKESI_LAST_PROMPT_PATH", "").strip()
    if override:
        return Path(override)
    return _DEFAULT_PROMPT_DIR / _LAST_PROMPT_FILE


def last_exchange_path() -> Path:
    """File holding the latest ExtAIApply wire (plain text, for copy-paste)."""
    prompt_path = last_prompt_path()
    if os.environ.get("HAIKESI_LAST_PROMPT_PATH", "").strip():
        return prompt_path.with_name(_LAST_EXCHANGE_FILE)
    return prompt_path.parent / _LAST_EXCHANGE_FILE


def save_last_prompt(prompt: str) -> Path:
    """Persist latest LLM prompt under logs/ for inspection."""
    prompt_path = last_prompt_path()
    prompt_path.parent.mkdir(parents=True, exist_ok=True)
    prompt_path.write_text(prompt, encoding="utf-8")
    return prompt_path


def save_last_wire(wire: str) -> Path:
    """Persist latest ExtAIApply wire (same string as clipboard / apply.txt)."""
    exchange_path = last_exchange_path()
    exchange_path.parent.mkdir(parents=True, exist_ok=True)
    exchange_path.write_text(wire.strip(), encoding="utf-8")
    return exchange_path


def reason_mode() -> str:
    """off=JSON 不写 reasons；short/full=reasons 仅写入 decision 日志，永不注入游戏。"""
    raw = (os.environ.get("HAIKESI_REASON_MODE") or "short").strip().lower()
    if raw in {"off", "0", "none", "false", "no"}:
        return "off"
    if raw in {"full", "long", "verbose"}:
        return "full"
    return "short"


def decision_log_enabled() -> bool:
    """开发分析：把思考过程写入独立 md（与注入游戏的 wire 隔离）。"""
    return _env_flag("HAIKESI_DECISION_LOG", False)


def last_decision_path() -> Path:
    """Fixed path for the single retained decision analysis log."""
    return last_prompt_path().parent / _LAST_DECISION_FILE


def _prune_legacy_flat_decision_logs(log_dir: Path) -> None:
    """Remove obsolete flat / txt decision mirrors (pre-md layout)."""
    for pattern in (
        "haikesi_decision_*.txt",
        "haikesi_decision_*.md",
        "haikesi_last_decision.txt",
    ):
        for stale in log_dir.glob(pattern):
            try:
                stale.unlink()
            except OSError:
                pass


_TABLE_SEP_RE = re.compile(r"^\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)+\|?\s*$")


def _is_table_separator(line: str) -> bool:
    s = line.strip()
    return bool(s) and _TABLE_SEP_RE.fullmatch(s) is not None


def _is_pipe_table_row(line: str) -> bool:
    s = line.strip()
    if not s or s.startswith(("```", "#", "-", "*", "【", ">")):
        return False
    if _is_table_separator(s):
        return False
    # 已是 GFM 数据/表头行
    if s.startswith("|") and s.count("|") >= 3:
        return True
    # 明文表：至少 3 列；排除「国力/战略」等散文里的 a | b
    if " | " not in s:
        return False
    cells = [c.strip() for c in s.split(" | ")]
    if len(cells) < 3:
        return False
    head = cells[0]
    if re.match(r"^分数\d", head):
        return False
    if ":" in head or "：" in head:
        return False
    if head.startswith(("主战略", "时代", "难度", "速度")):
        return False
    return True


def _table_cells(row: str) -> list[str]:
    return [c.strip().replace("\n", " ") for c in row.strip().strip("|").split("|")]


def _emit_gfm_table(out: list[str], header_row: str, body_rows: list[str], *, more_after: bool) -> None:
    """Append one GFM table with mandatory blank lines (Cursor/GFM preview)."""
    header_cells = _table_cells(header_row)
    ncols = max(len(header_cells), 1)
    if out and out[-1].strip() != "":
        out.append("")
    out.append("| " + " | ".join(header_cells) + " |")
    out.append("| " + " | ".join("---" for _ in range(ncols)) + " |")
    for row in body_rows:
        cells = _table_cells(row)
        if len(cells) < ncols:
            cells = cells + [""] * (ncols - len(cells))
        elif len(cells) > ncols:
            cells = cells[:ncols]
        out.append("| " + " | ".join(cells) + " |")
    if more_after:
        out.append("")


def markdownify_pipe_tables(text: str) -> str:
    """Turn plain/GFM pipe blocks into spaced GFM tables (blank line + header + ---).

    无表前空行时，CommonMark 会把 `|...|` 并入上一段落，预览里就变成 `||` 粘连。
    已带 `| --- |` 分隔行的块也必须再走一遍，补空行并规范化。
    """
    lines = text.splitlines()
    out: list[str] = []
    i = 0
    n = len(lines)
    while i < n:
        line = lines[i]
        # 已是 GFM：表头 + 分隔行 + 数据行
        if (
            _is_pipe_table_row(line)
            and i + 1 < n
            and _is_table_separator(lines[i + 1])
        ):
            body: list[str] = []
            j = i + 2
            while j < n and _is_pipe_table_row(lines[j]):
                body.append(lines[j])
                j += 1
            _emit_gfm_table(out, line, body, more_after=(j < n and lines[j].strip() != ""))
            i = j
            continue
        # 纯文本 pipe 表：连续 ≥2 行 a | b
        if _is_pipe_table_row(line) and i + 1 < n and _is_pipe_table_row(lines[i + 1]):
            block = [line]
            j = i + 1
            while j < n and _is_pipe_table_row(lines[j]):
                block.append(lines[j])
                j += 1
            _emit_gfm_table(
                out, block[0], block[1:], more_after=(j < n and lines[j].strip() != "")
            )
            i = j
            continue
        out.append(line)
        i += 1
    return "\n".join(out)


def _build_decision_log_body(
    *,
    request_id: str,
    model: str,
    prompt: str,
    raw_response: str,
    reasoning: str,
    choices: dict[str, Any],
    reasons: dict[str, str],
    wire: str,
    archive_path: Path | None = None,
) -> str:
    prompt_md = markdownify_pipe_tables(prompt)
    meta_lines = [
        f"- **saved_at**: {time.strftime('%Y-%m-%d %H:%M:%S')}",
        f"- **request_id**: `{request_id}`",
        f"- **model**: `{model}`",
        f"- **reason_mode**: `{reason_mode()}`",
        f"- **thinking_chars**: {len(reasoning or '')}",
    ]
    if archive_path is not None:
        meta_lines.append(f"- **archive_file**: `{archive_path}`")
    raw_fence = "json" if raw_response.strip().startswith("{") else ""
    parts = [
        f"# Haikesi ExtAI Decision `{request_id}`",
        "",
        "## Meta",
        "",
        *meta_lines,
        "",
        "## Prompt",
        "",
        prompt_md,
        "",
        "## Reasoning",
        "",
        "模型思考过程（不注入游戏）。",
        "",
        reasoning or "*(empty — enable `HAIKESI_LLM_THINKING=1` to capture)*",
        "",
        "## Raw Response",
        "",
        f"```{raw_fence}".rstrip(),
        raw_response,
        "```",
        "",
        "## Choices",
        "",
        "```json",
        json.dumps(choices, ensure_ascii=False, indent=2),
        "```",
        "",
        "## Reasons",
        "",
        "仅开发日志；永不注入游戏。",
        "",
        "```json",
        json.dumps(reasons, ensure_ascii=False, indent=2),
        "```",
        "",
        "## Wire Injected",
        "",
        "```",
        wire,
        "```",
        "",
    ]
    return "\n".join(parts)


def save_decision_analysis_log(
    *,
    request_id: str,
    model: str,
    prompt: str,
    raw_response: str,
    reasoning: str,
    choices: dict[str, Any],
    reasons: dict[str, str],
    wire: str,
    payload: dict[str, Any] | None = None,
) -> Path | None:
    """Append per-game decision log + mirror latest to haikesi_last_decision.md."""
    if not decision_log_enabled():
        return None
    log_dir = last_prompt_path().parent
    log_dir.mkdir(parents=True, exist_ok=True)

    archive_path: Path | None = None
    if payload is not None:
        try:
            from civ_mcp.decision_archive import get_decision_archive

            body = _build_decision_log_body(
                request_id=request_id,
                model=model,
                prompt=prompt,
                raw_response=raw_response,
                reasoning=reasoning,
                choices=choices,
                reasons=reasons,
                wire=wire,
            )
            archive_path = get_decision_archive().append_decision(
                payload,
                body=body,
                request_id=request_id,
                model=model,
            )
        except OSError as exc:
            log.warning("Failed to append decision archive: %s", exc)

    path = last_decision_path()
    text = _build_decision_log_body(
        request_id=request_id,
        model=model,
        prompt=prompt,
        raw_response=raw_response,
        reasoning=reasoning,
        choices=choices,
        reasons=reasons,
        wire=wire,
        archive_path=archive_path,
    )
    path.write_text(text, encoding="utf-8")
    _prune_legacy_flat_decision_logs(log_dir)
    return archive_path or path


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
# thinking 开启时推理占用大量 tokens；未显式设置时抬到 8192，降低 content 被截空概率
_LLM_MAX_TOKENS_THINKING = int(
    os.environ.get("HAIKESI_LLM_MAX_TOKENS_THINKING")
    or max(_LLM_MAX_TOKENS, 8192)
)


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
        # DeepSeek V4 thinking：默认关（省延迟/费用）。开 HAIKESI_LLM_THINKING=1 可提升策略深度。
        self._thinking_enabled = _env_flag("HAIKESI_LLM_THINKING", False)
        self._thinking_requested = self._thinking_enabled
        self._last_reasoning = ""

    def _build_kwargs(self, prompt: str) -> dict[str, Any]:
        max_tokens = (
            _LLM_MAX_TOKENS_THINKING if self._thinking_enabled else _LLM_MAX_TOKENS
        )
        kwargs: dict[str, Any] = {
            "model": self._model,
            "messages": [{"role": "user", "content": prompt}],
            "max_tokens": max_tokens,
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
        # 空 content 时逐步降级：关 json → 保持 thinking 再试 → 最后关 thinking
        want_think = self._thinking_requested
        attempts = (
            (self._json_mode, want_think),
            (False, want_think),
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
                log.warning(
                    "LLM create failed (json=%s thinking=%s max_tokens=%s): %s",
                    json_mode,
                    thinking,
                    kwargs.get("max_tokens"),
                    exc,
                )
                continue
            content, finish = self._extract_content(response)
            if content:
                if want_think and not thinking:
                    log.warning("LLM fell back to thinking=disabled after empty content")
                try:
                    self._last_reasoning = str(
                        getattr(response.choices[0].message, "reasoning_content", None) or ""
                    )
                except Exception:  # noqa: BLE001
                    self._last_reasoning = ""
                return content
            reasoning_len = len(
                getattr(response.choices[0].message, "reasoning_content", None) or ""
            )
            last_detail = (
                f"empty content finish_reason={finish!r} "
                f"reasoning_chars={reasoning_len} json={json_mode} thinking={thinking} "
                f"max_tokens={kwargs.get('max_tokens')}"
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
    """列表而非宽表：17 列表格在 Cursor 预览里会挤成「分 数」按字换行、形似坏表。"""
    if not met:
        return "(尚未与其他主要文明建立接触)"
    lines: list[str] = []
    for m in sorted(met, key=lambda x: -x.score):
        war = "交战" if m.is_at_war else "和平"
        lines.append(
            f"- {m.civ_name}（{m.leader_name}，id{m.player_id}）："
            f"分数{m.score}，{m.cities}城/人口{m.pop}，"
            f"科{m.sci}/文{m.cul}/金{m.gold}，军力{_fmt_mil(m.mil)}，"
            f"科技{_fmt_count(m.techs)}/市政{_fmt_count(m.civics)}，信仰{m.faith}，"
            f"{m.diplomatic_state}({m.relationship_score})，{war}，"
            f"不满我→彼{m.grievances}/彼→我{m.grievances_against_me}"
        )
    return "\n".join(lines)


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


def _fmt_mil(value: int | float | None) -> str:
    """军力：-1/缺失 → 未知（勿当成无军队）。"""
    if value is None:
        return "未知"
    try:
        n = int(value)
    except (TypeError, ValueError):
        return "未知"
    if n < 0:
        return "未知"
    return str(n)


def _fmt_count(value: int | float | None, *, suffix: str = "") -> str:
    if value is None:
        return "未知"
    try:
        n = int(value)
    except (TypeError, ValueError):
        return "未知"
    if n < 0:
        return "未知"
    return f"{n}{suffix}"


def _threat_table(view: LeaderView) -> str:
    if not view.threats:
        return "(视野内未见边境军事单位)"
    rows = [
        "| 势力 | 可见单位数 | 最近距离(格) | 关系 |",
        "| --- | --- | --- | --- |",
    ]
    for t in sorted(view.threats, key=lambda x: (x.nearest_dist, -x.count)):
        name = "蛮族" if t.owner_name == "Barbarian" else t.owner_name
        if t.owner_name == "Barbarian":
            rel = "敌对"
        elif t.is_minor:
            rel = "城邦可见"
        elif t.is_at_war:
            rel = "交战"
        else:
            rel = "可见·未交战"
        rows.append(f"| {name} | {t.count} | {t.nearest_dist} | {rel} |")
    return "\n".join(rows)


def _power_table(view: LeaderView) -> str:
    """窄两列表：避免散文里的 `|` 被预览当成坏表，也避免并入上方能力列表。"""
    rows = [
        ("分数", str(view.score)),
        ("城市/人口", f"{view.cities}城 / {view.pop}"),
        ("科/文/金/回合", f"{view.sci}/{view.cul}/{view.gold}"),
        ("军力", _fmt_mil(view.mil)),
        ("科技/市政", f"{_fmt_count(view.techs)} / {_fmt_count(view.civics)}"),
        ("信仰/回合", str(view.faith)),
        ("外交支持度", str(view.favor)),
        ("在研", view.current_research or "-"),
        ("市政", view.current_civic or "-"),
    ]
    lines = ["| 项 | 值 |", "| --- | --- |"]
    for key, val in rows:
        lines.append(f"| {key} | {val} |")
    return "\n".join(lines)


def _traits_block(view: LeaderView) -> str:
    lines: list[str] = []
    for name, desc in view.leader_traits[:4]:
        d = haikesi_lua._strip_civ_icons(desc).replace("[NEWLINE]", " ")
        lines.append(f"- 领袖能力「{name}」: {d}")
    for name, desc in view.civ_traits[:4]:
        d = haikesi_lua._strip_civ_icons(desc).replace("[NEWLINE]", " ")
        lines.append(f"- 文明特性「{name}」: {d}")
    for name, desc in view.agendas[:2]:
        d = haikesi_lua._strip_civ_icons(desc).replace("[NEWLINE]", " ")
        lines.append(f"- 历史议程「{name}」: {d}")
    if not lines:
        return "(无可用能力/议程文本)"
    return "\n".join(lines)


def _cities_table(view: LeaderView) -> str:
    if not view.own_cities:
        return "(无城市数据)"
    # 直接输出 GFM（列少，预览稳定）；markdownify 会再补表前后空行
    rows = [
        "| 城名 | 人口 | 粮/产/金/科/文/信 | 住房 | 宜居 | 区划 | 在建(回合) | 忠诚 |",
        "| --- | --- | --- | --- | --- | --- | --- | --- |",
    ]
    for c in sorted(view.own_cities, key=lambda x: -x.pop):
        districts = c.districts or "-"
        prod = c.producing
        if prod != "空闲" and c.turns_left > 0:
            prod = f"{prod}({c.turns_left})"
        rows.append(
            f"| {c.name} | {c.pop} | "
            f"{c.food:.0f}/{c.prod:.0f}/{c.gold:.0f}/{c.sci:.0f}/{c.cul:.0f}/{c.faith:.0f} | "
            f"{c.housing:.0f} | {c.amenities}/{c.amenities_needed} | {districts} | "
            f"{prod} | {c.loyalty:.0f} |"
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
            f"主战略: {label}（{rst.active_strategy}） · 优先级: {pri_txt}{flag_txt}",
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

    def _culture_required(p: haikesi_lua.VictoryPeerStat) -> int:
        # WorldRankings：需求 = 其他文明国内游客最大值 + 1
        best = 0
        for o in peers:
            if o.player_id != p.player_id and o.staycationers > best:
                best = o.staycationers
        return best + 1 if best > 0 or n > 1 else 1

    def _tech_key(p: haikesi_lua.VictoryPeerStat) -> tuple:
        # 太空竞赛未启动时 VP 全 0：改按已研究科技数排序，避免假并列
        if p.science_vp > 0 or p.spaceports > 0:
            return (1, p.science_vp, max(p.techs, 0), p.spaceports)
        return (0, max(p.techs, 0), p.score)

    def _tech_fmt(p: haikesi_lua.VictoryPeerStat) -> str:
        techs = _fmt_count(p.techs, suffix="项")
        if p.science_vp > 0 or p.spaceports > 0:
            return (
                f"{p.science_vp}/{p.science_needed}VP·{techs}"
                + (f"·港{p.spaceports}" if p.spaceports else "")
            )
        if p.techs < 0:
            return "科技胜利VP未计·科技数未知"
        return f"胜利VP未启动·{techs}"

    def _mil_key(p: haikesi_lua.VictoryPeerStat) -> tuple:
        mil = p.mil if p.mil is not None and p.mil >= 0 else -1
        return (mil, 0 if p.holds_own_capital else 1, p.score)

    def _mil_fmt(p: haikesi_lua.VictoryPeerStat) -> str:
        return f"军{_fmt_mil(p.mil)}" + (
            "·非原都" if not p.holds_own_capital else ""
        )

    return "\n".join(
        [
            "【已知文明胜利进度排名】（仅自己与已相遇；未相遇者不在榜；"
            "若军力/科技数为「未知」勿当作 0）",
            _rank_line(
                "分数",
                lambda p: (p.score, p.mil if p.mil >= 0 else -1),
                lambda p: f"{p.score}",
            ),
            _rank_line("科技", _tech_key, _tech_fmt),
            _rank_line(
                "外交",
                lambda p: (p.diplo_vp, p.score),
                # diplo_vp=外交胜利点数（世界会议累积）；与外交条 Favor（支持度）不是同一指标
                lambda p: f"{p.diplo_vp}VP",
            ),
            # 与世界排名·文化页一致：旅=每回合旅游业绩；游客=国际/需求（非「内游」）
            _rank_line(
                "文化",
                lambda p: (
                    p.visiting_tourists / max(_culture_required(p), 1),
                    p.tourism,
                    p.visiting_tourists,
                ),
                lambda p: (
                    f"旅{p.tourism}·游客{p.visiting_tourists}/{_culture_required(p)}"
                    f"（国内{p.staycationers}）"
                ),
            ),
            _rank_line(
                "宗教",
                lambda p: (p.rel_cities, p.score),
                lambda p: f"{p.rel_cities}城追随",
            ),
            _rank_line("征服(军力)", _mil_key, _mil_fmt),
        ]
    )


def _format_leader_block(
    ai: dict[str, Any],
    view: LeaderView | None,
    human_player_id: int,
) -> str:
    pid = int(ai["player_id"])
    selected = haikesi_lua.dedupe_preserve_order(list(ai.get("selected") or []))
    # 效果全文见全局「各文明历史已选」；领袖侧只留摘要，避免双份膨胀与南蛮误读
    if selected:
        hist_block = (
            f"【历史库存摘要】共{len(selected)}张："
            f"{haikesi_lua.format_relic_type_list(selected)}\n"
            "（完整效果见上文全局列表；不是本轮选项。"
            "其中若含南蛮入侵，仅表示过去某轮已触发，与本轮候选能否再选无关）"
        )
    else:
        hist_block = "【历史库存摘要】（无）"
    if view is None:
        label = ai.get("player_name") or ai.get("civ_label") or str(pid)
        return "\n\n".join(
            [
                f"### 领袖 {pid}（{label}）",
                "可见情报不足（未能读取该领袖外交/视野数据）。\n"
                "仅根据候选海克斯与历史库存，从自身发展需求选卡。",
                "候选海克斯:\n"
                + "\n".join(haikesi_lua.format_option_lines(ai.get("options", []))),
                hist_block,
            ]
        )

    title = f"### 领袖 {pid}：{view.civ_name}（{view.leader_name}）"
    human_met = next((m for m in view.met if m.player_id == human_player_id), None)
    if human_met:
        human_line = (
            f"已接触人类玩家 {human_met.civ_name}（{human_met.leader_name}）："
            f"关系 {human_met.diplomatic_state}({human_met.relationship_score})，"
            f"{'交战' if human_met.is_at_war else '和平'}，"
            f"科{human_met.sci}/文{human_met.cul}/金{human_met.gold}，"
            f"军力{_fmt_mil(human_met.mil)}，"
            f"我对彼不满{human_met.grievances}，彼对我不满{human_met.grievances_against_me}"
        )
    else:
        human_line = "尚未与人类玩家建立接触（不知其详细国力与位置）"

    # 段间空行：避免 CommonMark 把【国力】/城表并入「你的身份」最后一个 bullet
    parts: list[str] = [
        title,
        "【你的身份】\n" + _traits_block(view),
        "【本国国力】\n" + _power_table(view),
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
    parts.append("【本国城市】\n" + _cities_table(view))
    parts.append("【与人类】\n" + human_line)
    parts.append(
        "【已相遇文明（外交可见数值；未相遇者不出现）】\n" + _met_table(view.met)
    )
    attitude = _diplo_attitude_block(view.met)
    if attitude:
        parts.append(attitude)
    synergy = haikesi_lua.build_trait_option_synergy_hints(
        view, list(ai.get("options") or [])
    )
    if synergy:
        parts.append(synergy)
    parts.append(
        "【边境可见军事单位】（战争迷雾外；含中立邻国/城邦/蛮族；"
        "「可见·未交战」≠正在交战，勿一律当敌军）\n" + _threat_table(view)
    )
    parts.append(
        "【候选海克斯】（本轮三选一，必须从这里选）\n"
        + "\n".join(
            haikesi_lua.format_option_lines(
                ai.get("options", []), cities=int(view.cities or 0)
            )
        )
    )
    parts.append(hist_block)
    return "\n\n".join(parts)


def _format_historical_hexes_public(payload: dict[str, Any]) -> str:
    """持有名单 + 去重效果词典（同词条全文只出现一次）。"""
    ownership: list[str] = []
    ordered_types: list[str] = []
    for ai in payload.get("ai_players", []) or []:
        pid = int(ai.get("player_id", -1))
        label = (
            ai.get("civ_label")
            or ai.get("player_name")
            or f"领袖{pid}"
        )
        selected = haikesi_lua.dedupe_preserve_order(list(ai.get("selected") or []))
        if not selected:
            ownership.append(f"- {label}：无")
            continue
        ownership.append(
            f"- {label}：{haikesi_lua.format_relic_type_list(selected)}"
        )
        ordered_types.extend(selected)
    if not ownership:
        return "- （尚无历史海克斯）"
    unique = haikesi_lua.dedupe_preserve_order(ordered_types)
    if not unique:
        return "持有（仅名称）：\n" + "\n".join(ownership)
    glossary = [
        f"- {haikesi_lua.format_relic_display(relic)}" for relic in unique
    ]
    return (
        "持有（仅名称）：\n"
        + "\n".join(ownership)
        + "\n\n"
        + "效果说明（同词条只列一次）：\n"
        + "\n".join(glossary)
    )


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


def _resolve_game_speed(
    context: HaikesiGameContext,
    payload: dict[str, Any] | None = None,
) -> tuple[int, str, bool]:
    """Return (cost_multiplier, display_name, used_default)."""
    payload = payload or {}
    gs = payload.get("game_speed")
    if isinstance(gs, dict):
        mult = int(gs.get("cost_multiplier") or 0)
        name = str(gs.get("name") or "").strip()
        if mult > 0 and name and name not in ("Unknown", "未知"):
            return mult, name, False

    ov = context.overview
    name = (ov.game_speed_name or "").strip()
    mult = int(getattr(ov, "speed_cost_multiplier", 0) or 0)
    if name and name not in ("Unknown", "未知") and mult > 0:
        return mult, name, False

    is_mp = bool(payload.get("mp")) or any(
        "联机 LOG 通道" in n or "联机无 FireTuner" in n for n in context.fetch_notes
    )
    if is_mp:
        return (
            haikesi_lua.DEFAULT_SPEED_MULTIPLIER_ONLINE,
            "联机",
            True,
        )
    return haikesi_lua.DEFAULT_SPEED_MULTIPLIER_STANDARD, "标准", True


def _format_global_setting(
    context: HaikesiGameContext,
    *,
    turn: int,
    payload: dict[str, Any] | None = None,
) -> str:
    ov = context.overview
    mult, speed, speed_default = _resolve_game_speed(context, payload)
    era = haikesi_lua.infer_era_label(
        turn=turn, era_name=ov.era_name or "", cost_multiplier=mult
    )
    if speed_default:
        speed = f"{speed}（默认 Cost×{mult}；CTX 未提供速度）"
    elif mult != 100:
        speed = f"{speed}（Cost×{mult}，相对标准速度）"
    is_mp = any(
        "联机 LOG 通道" in n or "联机无 FireTuner" in n for n in context.fetch_notes
    )
    if is_mp or not ov.difficulty or ov.difficulty in ("Unknown", "未知"):
        return (
            f"时代: {era} | 速度: {speed}\n"
            "（联机/CTX 通常不提供难度；以文明6老玩家常识决策，"
            "并受所扮演领袖历史性格与议程影响。）"
        )
    return f"难度: {ov.difficulty} | 速度: {speed} | 时代: {era}"


def _format_human_relic_section(payload: dict[str, Any]) -> str:
    relic_type = str(payload.get("human_relic") or "")
    display = haikesi_lua.format_relic_display(relic_type)
    hint = haikesi_lua.human_relic_strategy_hint(relic_type)
    if hint:
        return f"{display}\n策略参考：{hint}"
    return display


def _early_game_rules(
    turn: int,
    *,
    cost_multiplier: int = 100,
    speed_name: str = "",
) -> tuple[str, str]:
    """Return (early_phase_rule, barbarian_turn_window) scaled by game speed."""
    thresholds = haikesi_lua.early_game_phase_thresholds(cost_multiplier=cost_multiplier)
    ancient_end = thresholds["ancient_end"]
    echo_horizon = thresholds["echo_horizon"]
    barb_end = thresholds["barbarian_caution_end"]
    barbarian_window = f"T2–T{barb_end}"
    if turn > ancient_end:
        return "", barbarian_window
    speed_hint = ""
    if speed_name and speed_name != "未知" and cost_multiplier != 100:
        speed_hint = f"（{speed_name}；阈值按 Cost×{cost_multiplier}/100 相对标准速度缩放）"
    rule = (
        f"- 远古早期（约 T1–T{ancient_end}{speed_hint}、单城且已知军力≤2）："
        "优先真正即时的百分比产出；"
        "有城时才优先资源创建（落在最新城 3 环）；"
        "**0 城时资源创建会空放，禁止选择**，改选开拓者/工人 echo 或百分比；"
        f"军事 echo 需 {echo_horizon} 回合内可造对应单位才优先，否则视为延迟收益\n"
    )
    return rule, barbarian_window


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

    notes_block = ""
    if context.fetch_notes:
        notes_block = (
            "## 数据说明（系统）\n"
            + "\n".join(f"- {n}" for n in context.fetch_notes)
            + "\n\n"
        )

    channel_note = (
        "数据来自联机 Lua.log CTX dump（与单机 FireTuner 同线格式）。"
        if any("联机 LOG 通道" in n or "联机无 FireTuner" in n for n in context.fetch_notes)
        else "数据来自真实对局（FireTuner）。"
    )

    mode = reason_mode()
    if mode == "off":
        reason_rule = (
            "- 不要输出 reasons（或给空对象 {}）；只需 choices。"
            "内心推演即可，勿把分析写进 JSON，以节省输出 token。"
        )
        output_fmt = '{\n  "choices": {"2": "NW_AI_...", "3": "NW_AI_..."}\n}'
    elif mode == "full":
        reason_rule = (
            "- reasons 仅供开发日志，不会显示在游戏内；可用 1～2 句带领袖风味的简体中文"
            "（常用汉字，约 40 字内），第一人称；禁止 emoji、英文双引号 \"、生僻字；"
            "详细推演过程不必复述（另有 thinking 日志）。"
        )
        output_fmt = (
            '{\n  "choices": {"2": "NW_AI_...", "3": "NW_AI_..."},\n'
            '  "reasons": {"2": "...", "3": "..."}\n}'
        )
    else:
        reason_rule = (
            "- reasons 仅供开发日志，不会显示在游戏内；用 1 句带领袖风味的简体中文"
            "（常用汉字，约 20 字内），第一人称；禁止 emoji、英文双引号 \"、生僻字；"
            "不要复述效果全文"
        )
        output_fmt = (
            '{\n  "choices": {"2": "NW_AI_...", "3": "NW_AI_..."},\n'
            '  "reasons": {"2": "...", "3": "..."}\n}'
        )

    human_relic = _format_human_relic_section(payload)
    turn = int(payload.get("turn") or 0)
    speed_mult, speed_name, _ = _resolve_game_speed(context, payload)
    global_setting = _format_global_setting(context, turn=turn, payload=payload)
    early_rules, barbarian_window = _early_game_rules(
        turn, cost_multiplier=speed_mult, speed_name=speed_name
    )

    return f"""你是文明6资深玩家，同时代入下列多位文明领袖，为各自选择本轮海克斯。{channel_note}
决策以老玩家常识与当前局面数据为主；仅在收益接近时用历史人物性格/议程破平（勿为角色表演而违背明显最优）。

情报规则（必须遵守）：
- 每位领袖只能使用**自己区块**内的情报做决策；禁止引用其他领袖区块，也禁止臆造未给出的单位/文明。
- 未相遇文明、战争迷雾外的敌军对本领袖不存在，不得当作已知信息。
- 人类本轮海克斯、各文明历史已选海克斯（含效果说明）、全局时代/速度、世界会议决议是本局公开机制信息，各位领袖都可以参考。
- 「历史已选 / 历史库存」不是本轮选择：不得据此认定某领袖本轮已选完，也不得照抄历史词条作为本轮 choices；历史中的南蛮入侵只表示过去触发过，与本轮候选是否再出现无关。
- 已相遇文明的科/文/金/军力、双向不满值、对方对你的外交修饰语等为外交界面可见信息，可以比较；军力/科技数为「未知」时勿当成 0 或「无军队/零科技」。
- 若区块含「已知文明胜利进度排名」：仅可比较榜内文明；未上榜者对本领袖不可见；「胜利VP未启动」时用科技项数等替代指标，勿被全员 0/50VP 误导。
- 优先级：交战或边境可见单位最近距离≤2 的生存/军事压力 > Real Strategy 主战略 > 协同弱提示。主战略仅作倾向（征服→军事/扩张，科技→科研，文化→文化/伟人，宗教→信仰，外交→使者/外交）。
- 「能力与候选协同提示」为弱提示，可完全忽略；勿当作必须跟风的硬规则。

## 当前回合
Turn {turn}

## 全局公开设定
{global_setting}

## 世界会议（公开）
{_format_world_congress(context.world_congress)}

## 人类玩家本轮海克斯（公开）
{human_relic}

## 各文明历史已选海克斯（公开，含效果说明）
以下为过往回合已获得的词条库存，供理解局面；与本轮选卡无关，禁止当作「本轮已选定」。
{_format_historical_hexes_public(payload)}

{notes_block}## 待决策领袖（逐位以该领袖身份选卡）
{"\n\n".join(ai_blocks)}

## 规则
- 每位领袖只能从其「候选海克斯」中选 1 个 relic type；必须重新决策，禁止因「历史已选」而照抄、跳过或认定本轮已选完
- 「历史已选海克斯 / 各文明历史已选」仅为库存说明（名称+效果），不是本轮选项，也不是自动选卡结果
- {invasion_note}
- NW_AI_BARBARIAN_INVASION 分配：同一 JSON 内至多 1 名领袖；优先分配给触发后净收益最高者（清蛮/军事/干扰领先人类）；{barbarian_window} 且已知军力≤2 时，除非明确以干扰人类为目标且接受连带干扰其他 AI，否则优先即时产出或扩张类；历史库存里出现过南蛮≠本轮不能选
- 候选前缀标注生效时机：【即时】立刻生效；【条件即时·需已有城市】无城则空放；【空放·当前0城】禁止选择；【延迟】须先满足生产/商路等条件；勿在远古早期盲选尚无法使用的军事 echo
- 资源创建类（奶龙/丝绸/烟草/茶/棉花等）依赖「最新建立的城市」：国力显示 0 城或「无城市数据」时选择=效果跳过，应改选开拓者 echo 或百分比产出
{early_rules}- 先在内心做策略推演再选卡（不必写出推演过程）：生存威胁、胜利路线、时代与扩张节奏、产出短板、外交、与人类海克斯的对抗/跟风
- 文明6常识（用于解释上下文，勿复述）：早期扩张与基础设施常优先于奇观；战略资源与特色单位窗口很关键；忠诚度差的新城易叛；宗教胜利靠信仰传播与神学战斗；科技靠学院链+航天；文化靠旅游压过对手国内游客；外交靠好感/宗主/世界会议；军事窗口常在特色单位与时代领先时；奢侈品种类比重复拷贝更重要；贸易路线容量是免费产出
- 决策结合：局面威胁与交战状态、自身能力与议程、Real Strategy（可偏离）、本国宗教、胜利进度（注意未知/未启动）、不满与观感、世界会议、城市短板、人类公开海克斯、候选效果；历史库存仅作能力背景
- 尽量避免多名领袖无差别抄同一张牌；只有局面高度相似时才可同选
- 领袖皆有历史原型：仅在收益接近时用议程/不满表达风味
{reason_rule}
- choices 的键必须等于上文「### 领袖 N」中的 N（本局可能从 2 起，勿强行从 1 编号）
- 必须输出完整合法 JSON（所有字符串已闭合）；禁止 markdown 代码块

## 输出格式（仅 JSON，无 markdown）
{output_fmt}
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
        save_last_prompt(prompt)
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
    mode = reason_mode()
    if mode != "off":
        max_chars = 80 if mode == "full" else 40
        for ai_id, raw_reason in raw_reasons.items():
            if str(ai_id).startswith("_"):
                continue
            cleaned = sanitize_decision_reason(str(raw_reason), max_chars=max_chars)
            if cleaned:
                reasons[ai_id] = cleaned
    if not choices:
        raise RuntimeError("LLM returned empty choices")

    from civ_mcp.extai_log_channel import encode_extai_apply_payload

    wire = encode_extai_apply_payload(request_id, choices, None)
    try:
        save_last_prompt(prompt)
        save_last_wire(wire)
    except OSError as exc:
        log.warning("Failed to save last prompt/wire: %s", exc)

    if verbose:
        print(f"Submitting {request_id!r} ({len(choices)} choices, no reasons) ...", flush=True)

    # 游戏内不注入理由；reasons 仅保留在 decision 日志
    submit_lines = await conn.execute_haikesi(
        haikesi_lua.build_submit_ai_choices_lua(request_id, choices, None)
    )
    result = haikesi_lua.summarize_submit_result(submit_lines)
    parsed = json.loads(result)
    if not parsed.get("ok"):
        raise RuntimeError(parsed.get("message", "submit failed"))
    reasoning = ""
    if hasattr(client, "_last_reasoning"):
        reasoning = str(getattr(client, "_last_reasoning") or "")
    try:
        save_decision_analysis_log(
            request_id=request_id,
            model=model,
            prompt=prompt,
            raw_response=raw,
            reasoning=reasoning,
            choices=choices,
            reasons=reasons,
            wire=wire,
            payload=payload,
        )
    except OSError as exc:
        log.warning("Failed to save decision analysis log: %s", exc)
    if verbose:
        print(f"Submit OK: {request_id!r}", flush=True)
    return True


def build_log_channel_context(payload: dict[str, Any]) -> HaikesiGameContext:
    """MP path: parse Lua.log CTX dump with the same parsers as FireTuner gathers."""
    from civ_mcp.extai_log_channel import context_from_log_payload

    return context_from_log_payload(payload)


async def decide_and_inject_log_channel(
    client: _ChatClient,
    model: str,
    payload: dict[str, Any],
    *,
    verbose: bool = True,
) -> bool:
    """MP path: Lua.log request → LLM → publish wire (clipboard); Ctrl+V in game."""
    from civ_mcp.extai_log_channel import encode_extai_apply_payload
    from civ_mcp.extai_mp_inject import inject_extai_apply_payload

    request_id = str(payload.get("request_id", ""))
    ctx_n = len(payload.get("context_lines") or [])
    if verbose:
        print(
            f"Pending {request_id!r} (LOG channel); "
            f"CTX lines={ctx_n} ...",
            flush=True,
        )

    context = build_log_channel_context(payload)
    if verbose:
        print(format_context_summary(context), flush=True)

    # Reuse the same LLM path as decide_and_submit_once (inline subset)
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
            print(f"LLM JSON parse failed ({exc}); retrying once ...", flush=True)
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
            raise RuntimeError(f"LLM returned invalid JSON after retry: {exc2}") from exc2

    choices = {str(k): v for k, v in decision.get("choices", {}).items()}
    raw_reasons = {str(k): v for k, v in decision.get("reasons", {}).items()}
    reasons: dict[str, str] = {}
    mode = reason_mode()
    if mode != "off":
        # 仅写入 decision 日志，不再受联机 wire 字数限制
        max_chars = 80 if mode == "full" else 40
        for ai_id, raw_reason in raw_reasons.items():
            if str(ai_id).startswith("_"):
                continue
            cleaned = sanitize_decision_reason(str(raw_reason), max_chars=max_chars)
            if cleaned:
                reasons[ai_id] = cleaned
    if not choices:
        raise RuntimeError("LLM returned empty choices")

    reasoning = ""
    if hasattr(client, "_last_reasoning"):
        reasoning = str(getattr(client, "_last_reasoning") or "")

    # 游戏内只注入选卡；理由仅留在 decision 日志
    wire = encode_extai_apply_payload(
        request_id,
        choices,
        None,
        max_wire_len=505,
    )
    try:
        save_last_prompt(prompt)
        save_last_wire(wire)
    except OSError as exc:
        log.warning("Failed to save last prompt/wire: %s", exc)

    try:
        analysis_path = save_decision_analysis_log(
            request_id=request_id,
            model=model,
            prompt=prompt,
            raw_response=raw,
            reasoning=reasoning,
            choices=choices,
            reasons=reasons,
            wire=wire,
            payload=payload,
        )
        if verbose and analysis_path is not None:
            print(f"Decision analysis log: {analysis_path}", flush=True)
    except OSError as exc:
        log.warning("Failed to save decision analysis log: %s", exc)

    from civ_mcp.extai_mp_inject import publish_extai_decision

    if verbose:
        print(
            f"Publishing ExtAIApply choices-only wire (len={len(wire)}; "
            f"reasons→decision log only, mode={mode}) ...",
            flush=True,
        )
    publish_extai_decision(wire, request_id=request_id)
    if verbose:
        print(
            f"Publish OK: {request_id!r} — Ctrl+V in game; "
            f"Ctrl+C safe (clipboard + apply.txt + decision log)",
            flush=True,
        )
    return True
