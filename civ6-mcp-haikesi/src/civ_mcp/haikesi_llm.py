"""Load Haikesi LLM config and invoke chat models (OpenAI-compatible or Anthropic)."""

from __future__ import annotations

import json
import logging
import os
import re
import time
from contextvars import ContextVar
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

# 绑定当前存档的多轮对话（仅 draft 主请求使用）
_active_chat_session: ContextVar[Any] = ContextVar("haikesi_llm_chat_session", default=None)

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
    tool_trace: list[dict[str, Any]] | None = None,
    tool_channel: str | None = None,
    style_meta: str | None = None,
    style_dice_json: str | None = None,
) -> str:
    prompt_md = markdownify_pipe_tables(prompt)
    meta_lines = [
        f"- **saved_at**: {time.strftime('%Y-%m-%d %H:%M:%S')}",
        f"- **request_id**: `{request_id}`",
        f"- **model**: `{model}`",
        f"- **pipeline**: `{llm_pipeline_mode()}` (`HAIKESI_LLM_PIPELINE`)",
        f"- **reason_mode**: `{reason_mode()}`",
        f"- **thinking**: `{'ON' if llm_thinking_enabled() else 'OFF'}` (`HAIKESI_LLM_THINKING`)",
        f"- **review_rounds**: `{llm_review_rounds()}` (`HAIKESI_LLM_REVIEW_ROUNDS`)",
        f"- **thinking_chars**: {len(reasoning or '')}",
        f"- **tools**: `{'ON' if tool_trace is not None else 'OFF'}` (`HAIKESI_LLM_TOOLS`)",
    ]
    if tool_channel:
        meta_lines.append(f"- **tool_channel**: `{tool_channel}`")
    if style_meta:
        meta_lines.append(f"- **styles**: `{style_meta}` (`HAIKESI_LLM_STYLES`)")
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
    ]
    if style_dice_json:
        parts.extend(
            [
                "## Style Dice（审计）",
                "",
                "每位有风格标签的领袖独立掷骰：`u < p` → cosplay，否则收益优先。",
                "",
                "```json",
                style_dice_json,
                "```",
                "",
            ]
        )
    parts.extend(
        [
        "## Prompt",
        "",
        prompt_md,
        "",
        "## Reasoning",
        "",
        "模型思考过程（不注入游戏）。",
        "",
        reasoning
        or (
            "*(empty — set `HAIKESI_LLM_THINKING=1` for prompt-dev thinking capture; "
            "set `0` when playing to save tokens)*"
        ),
        "",
        ]
    )
    if tool_trace is not None:
        from civ_mcp.haikesi_tools.runner import format_tool_trace_markdown

        parts.extend(
            [
                "## Tool Calls",
                "",
                format_tool_trace_markdown(tool_trace),
                "",
            ]
        )
    parts.extend(
        [
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
    )
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
    tool_trace: list[dict[str, Any]] | None = None,
    tool_channel: str | None = None,
    style_meta: str | None = None,
    style_dice_json: str | None = None,
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
                tool_trace=tool_trace,
                tool_channel=tool_channel,
                style_meta=style_meta,
                style_dice_json=style_dice_json,
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
        tool_trace=tool_trace,
        tool_channel=tool_channel,
        style_meta=style_meta,
        style_dice_json=style_dice_json,
    )
    path.write_text(text, encoding="utf-8")
    _prune_legacy_flat_decision_logs(log_dir)
    return archive_path or path


def save_draft_checkpoint_log(
    *,
    request_id: str,
    model: str,
    reasoning: str,
    raw_response: str,
    decision: dict[str, Any],
    payload: dict[str, Any] | None,
    review_model: str | None = None,
) -> Path | None:
    """审查开始前把初稿写入对局 decision 目录（``*__draft.md``）。"""
    if not decision_log_enabled() or payload is None:
        return None
    choices_map = _decision_choices_map(decision)
    reasons_map = {
        str(k): v
        for k, v in coerce_reasons_map(decision.get("reasons")).items()
        if not str(k).startswith("_")
    }
    await_line = (
        f"- **awaiting_review**: `{review_model}`"
        if review_model
        else "- **awaiting_review**: self-review"
    )
    raw_fence = "json" if (raw_response or "").strip().startswith("{") else ""
    body = "\n".join(
        [
            f"# Haikesi ExtAI Draft Checkpoint `{request_id}`",
            "",
            "## Meta",
            "",
            f"- **saved_at**: {time.strftime('%Y-%m-%d %H:%M:%S')}",
            f"- **request_id**: `{request_id}`",
            f"- **stage**: `draft`（审查前落盘；最终以同目录无 `__draft` 后缀的 md 为准）",
            f"- **draft_model**: `{model}`",
            await_line,
            f"- **pipeline**: `{llm_pipeline_mode()}`",
            "",
            "## Reasoning",
            "",
            reasoning or "*(no thinking text)*",
            "",
            "## Choices (draft)",
            "",
            "```json",
            json.dumps(choices_map, ensure_ascii=False, indent=2),
            "```",
            "",
            "## Reasons (draft)",
            "",
            "```json",
            json.dumps(reasons_map, ensure_ascii=False, indent=2),
            "```",
            "",
            "## Raw Response",
            "",
            f"```{raw_fence}".rstrip(),
            raw_response or "",
            "```",
            "",
        ]
    )
    try:
        from civ_mcp.decision_archive import get_decision_archive

        path = get_decision_archive().write_draft_checkpoint(
            payload,
            body=body,
            request_id=request_id,
            model=model,
        )
        return path
    except OSError as exc:
        log.warning("Failed to save draft checkpoint: %s", exc)
        return None


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
    def complete(
        self,
        prompt: str,
        *,
        required_ids: list[str] | None = None,
    ) -> str: ...

    # Optional: OpenAI-compatible clients may implement complete_with_tools.


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

# 智谱 GLM（OpenAI 兼容）
GLM_BASE_URL = "https://open.bigmodel.cn/api/paas/v4"
GLM_DEFAULT_MODEL = "glm-5.2"


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
    """Load DeepSeek API config (OpenAI-compatible).

    When ``DEEPSEEK_API_KEY`` is set, always use DeepSeek base/model defaults
    (do not inherit xAI ``HAIKESI_LLM_BASE_URL`` — dual pipeline needs both).

    If only ``HAIKESI_LLM_*`` is set (legacy deepseek_watch + Grok .env), fall
    back so a misconfigured single-provider run still reaches some gateway.
    """
    load_dotenv_file()
    ds_key = (os.environ.get("DEEPSEEK_API_KEY") or "").strip()
    if ds_key:
        model = (os.environ.get("DEEPSEEK_MODEL") or DEEPSEEK_DEFAULT_MODEL).strip()
        base_url = (os.environ.get("DEEPSEEK_BASE_URL") or DEEPSEEK_BASE_URL).strip()
        return HaikesiLLMConfig(api_key=ds_key, model=model, base_url=base_url)

    api_key = os.environ.get("HAIKESI_LLM_API_KEY")
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
    base_url = (
        os.environ.get("DEEPSEEK_BASE_URL")
        or os.environ.get("HAIKESI_LLM_BASE_URL")
        or DEEPSEEK_BASE_URL
    )
    return HaikesiLLMConfig(api_key=api_key, model=model, base_url=base_url)


def llm_pipeline_mode() -> str:
    """``single`` = 同一模型；``dual`` = 初稿/审查可分属不同 provider（由 env 指定）。"""
    load_dotenv_file()
    raw = (os.environ.get("HAIKESI_LLM_PIPELINE") or "").strip().lower()
    if raw in {"single", "solo", "one"}:
        return "single"
    if raw in {
        "dual",
        "complex",
        "ds+grok",
        "deepseek+grok",
        "deepseek_grok",
        "grok+deepseek",
        "grok_deepseek",
    }:
        return "dual"
    if _env_flag("HAIKESI_LLM_DUAL", False):
        return "dual"
    # 未写 PIPELINE 但显式指定了不同 draft/review → dual
    draft = (os.environ.get("HAIKESI_LLM_DRAFT") or "").strip()
    review = (os.environ.get("HAIKESI_LLM_REVIEW") or "").strip()
    if draft and review and draft.lower() != review.lower():
        return "dual"
    return "single"


def _normalize_provider_id(name: str) -> str:
    n = (name or "").strip().lower().replace("-", "_")
    aliases = {
        "ds": "deepseek",
        "xai": "grok",
        "haikesi": "grok",
        "haikesi_llm": "grok",
        "gpt": "openai",
        "claude": "anthropic",
        "ant": "anthropic",
        "zhipu": "glm",
        "bigmodel": "glm",
        "glm5": "glm",
        "glm_5": "glm",
        "glm_5_2": "glm",
        "glm52": "glm",
    }
    return aliases.get(n, n)


def llm_dual_roles() -> tuple[str, str]:
    """返回 (draft_provider_id, review_provider_id)。

    优先 ``HAIKESI_LLM_DRAFT`` / ``HAIKESI_LLM_REVIEW``；
    否则兼容 ``HAIKESI_LLM_DUAL_ORDER`` / ``HAIKESI_LLM_PIPELINE`` 别名；
    默认 ``grok`` → ``deepseek``。
    """
    load_dotenv_file()
    draft = _normalize_provider_id(os.environ.get("HAIKESI_LLM_DRAFT") or "")
    review = _normalize_provider_id(os.environ.get("HAIKESI_LLM_REVIEW") or "")
    if draft and review:
        return draft, review

    order = (os.environ.get("HAIKESI_LLM_DUAL_ORDER") or "").strip().lower()
    pipe = (os.environ.get("HAIKESI_LLM_PIPELINE") or "").strip().lower()
    if order in {
        "deepseek_draft",
        "deepseek+grok",
        "ds+grok",
        "deepseek_first",
        "ds_draft",
    } or pipe in {"deepseek+grok", "ds+grok", "deepseek_grok"}:
        return "deepseek", "grok"
    if order in {"grok_draft", "grok+deepseek", "grok_first"} or pipe in {
        "grok+deepseek",
        "grok_deepseek",
    }:
        return "grok", "deepseek"

    # 只写了一侧时补默认另一侧
    if draft and not review:
        return draft, "deepseek" if draft != "deepseek" else "grok"
    if review and not draft:
        return "grok" if review != "grok" else "deepseek", review
    return "grok", "deepseek"


def llm_dual_order() -> str:
    """兼容旧日志字段：由 draft/review provider 推导。"""
    draft, review = llm_dual_roles()
    if draft == "deepseek" and review in {"grok", "xai", "haikesi"}:
        return "deepseek_draft"
    if draft in {"grok", "xai", "haikesi"} and review == "deepseek":
        return "grok_draft"
    return f"{draft}_to_{review}"


def _env_first(*names: str) -> str:
    for name in names:
        val = (os.environ.get(name) or "").strip()
        if val:
            return val
    return ""


def load_glm_config() -> HaikesiLLMConfig:
    """智谱 GLM（OpenAI 兼容：open.bigmodel.cn）。"""
    load_dotenv_file()
    api_key = _env_first(
        "GLM_API_KEY",
        "ZHIPU_API_KEY",
        "BIGMODEL_API_KEY",
        "HAIKESI_PROVIDER_GLM_API_KEY",
    )
    if not api_key:
        raise RuntimeError(
            "provider=glm 需要 GLM_API_KEY（或 ZHIPU_API_KEY / BIGMODEL_API_KEY）"
        )
    model = (
        _env_first("GLM_MODEL", "ZHIPU_MODEL", "BIGMODEL_MODEL") or GLM_DEFAULT_MODEL
    )
    base_url = (
        _env_first("GLM_BASE_URL", "ZHIPU_BASE_URL", "BIGMODEL_BASE_URL")
        or GLM_BASE_URL
    )
    return HaikesiLLMConfig(api_key=api_key, model=model, base_url=base_url)


def load_provider_config(provider: str) -> HaikesiLLMConfig:
    """按 provider id 加载配置（只改 env 即可切换任意 OpenAI 兼容 / Anthropic 模型）。

    内置别名：
      - ``deepseek`` → ``DEEPSEEK_*``
      - ``grok`` / ``xai`` / ``haikesi`` → ``HAIKESI_LLM_*``
      - ``glm`` / ``zhipu`` / ``bigmodel`` → ``GLM_*``（智谱）
      - ``openai`` → ``OPENAI_*``
      - ``anthropic`` → ``ANTHROPIC_*``（无 base_url → 原生 Anthropic 客户端）
      - ``draft`` / ``review`` → ``HAIKESI_DRAFT_*`` / ``HAIKESI_REVIEW_*``

    自定义名 ``foo``：
      ``HAIKESI_PROVIDER_FOO_API_KEY`` / ``_BASE_URL`` / ``_MODEL``
      或简写 ``FOO_API_KEY`` / ``FOO_BASE_URL`` / ``FOO_MODEL``
    """
    load_dotenv_file()
    pid = _normalize_provider_id(provider)
    if not pid:
        raise RuntimeError("provider id 为空")

    if pid == "deepseek":
        return load_deepseek_config()
    if pid == "glm":
        return load_glm_config()
    if pid in {"grok", "haikesi"}:
        return load_haikesi_llm_config()
    if pid == "openai":
        api_key = _env_first("OPENAI_API_KEY", "HAIKESI_LLM_API_KEY")
        if not api_key:
            raise RuntimeError("provider=openai 需要 OPENAI_API_KEY")
        model = _env_first("OPENAI_MODEL", "HAIKESI_LLM_MODEL") or "gpt-4o"
        base_url = _env_first(
            "OPENAI_BASE_URL", "OPENAI_API_BASE", "HAIKESI_LLM_BASE_URL"
        ) or "https://api.openai.com/v1"
        return HaikesiLLMConfig(api_key=api_key, model=model, base_url=base_url)
    if pid == "anthropic":
        api_key = _env_first("ANTHROPIC_API_KEY", "HAIKESI_LLM_API_KEY")
        if not api_key:
            raise RuntimeError("provider=anthropic 需要 ANTHROPIC_API_KEY")
        model = _env_first(
            "ANTHROPIC_MODEL", "HAIKESI_LLM_MODEL"
        ) or "claude-sonnet-4-20250514"
        # base_url 空 → create_chat_client 走 Anthropic 原生
        base_url = _env_first("ANTHROPIC_BASE_URL") or None
        return HaikesiLLMConfig(api_key=api_key, model=model, base_url=base_url)

    if pid in {"draft", "review"}:
        prefix = "HAIKESI_DRAFT" if pid == "draft" else "HAIKESI_REVIEW"
        api_key = _env_first(f"{prefix}_API_KEY")
        if not api_key:
            raise RuntimeError(f"provider={pid} 需要 {prefix}_API_KEY")
        model = _env_first(f"{prefix}_MODEL") or "unknown-model"
        base_raw = _env_first(f"{prefix}_BASE_URL")
        base_url = base_raw or None
        return HaikesiLLMConfig(api_key=api_key, model=model, base_url=base_url)

    # 自定义：HAIKESI_PROVIDER_<ID>_* 或 <ID>_*
    tag = pid.upper()
    api_key = _env_first(
        f"HAIKESI_PROVIDER_{tag}_API_KEY",
        f"{tag}_API_KEY",
    )
    if not api_key:
        raise RuntimeError(
            f"未知 provider={provider!r}：请设 HAIKESI_PROVIDER_{tag}_API_KEY "
            f"（或使用内置 deepseek/grok/glm/openai/anthropic/draft/review）"
        )
    model = _env_first(
        f"HAIKESI_PROVIDER_{tag}_MODEL",
        f"{tag}_MODEL",
    ) or "unknown-model"
    base_raw = _env_first(
        f"HAIKESI_PROVIDER_{tag}_BASE_URL",
        f"{tag}_BASE_URL",
    )
    base_url = base_raw or None
    return HaikesiLLMConfig(api_key=api_key, model=model, base_url=base_url)


@dataclass(frozen=True)
class DecisionPipeline:
    """Draft/review clients for ExtAI decisions."""

    mode: str
    draft_client: Any
    draft_model: str
    review_client: Any
    review_model: str
    draft_provider: str = "single"
    review_provider: str = "single"
    dual_order: str = "single"  # 兼容旧日志/打印

    @property
    def model_label(self) -> str:
        if self.mode == "dual":
            return (
                f"{self.draft_provider}:{self.draft_model} → "
                f"{self.review_provider}:{self.review_model}"
            )
        return self.draft_model


def resolve_decision_pipeline(
    *,
    prefer: str = "haikesi",
) -> DecisionPipeline:
    """Build draft/review clients from env.

    ``prefer``: for single mode, ``haikesi`` → ``load_haikesi_llm_config``,
    ``deepseek`` → ``load_deepseek_config``.
    """
    load_dotenv_file()
    mode = llm_pipeline_mode()
    if mode == "dual":
        draft_id, review_id = llm_dual_roles()
        draft_cfg = load_provider_config(draft_id)
        review_cfg = load_provider_config(review_id)
        return DecisionPipeline(
            mode="dual",
            draft_client=create_chat_client(draft_cfg),
            draft_model=draft_cfg.model,
            review_client=create_chat_client(review_cfg),
            review_model=review_cfg.model,
            draft_provider=draft_id,
            review_provider=review_id,
            dual_order=llm_dual_order(),
        )

    if prefer == "deepseek":
        cfg = load_deepseek_config()
        pid = "deepseek"
    else:
        # single 也可用 HAIKESI_LLM_DRAFT 指定唯一模型
        single_id = _normalize_provider_id(
            os.environ.get("HAIKESI_LLM_DRAFT")
            or os.environ.get("HAIKESI_LLM_PROVIDER")
            or ""
        )
        if single_id:
            cfg = load_provider_config(single_id)
            pid = single_id
        else:
            cfg = load_haikesi_llm_config()
            pid = "grok"
    client = create_chat_client(cfg)
    return DecisionPipeline(
        mode="single",
        draft_client=client,
        draft_model=cfg.model,
        review_client=client,
        review_model=cfg.model,
        draft_provider=pid,
        review_provider=pid,
        dual_order="single",
    )


def llm_effective_review_rounds(*, dual: bool = False) -> int:
    """dual 且 REVIEW_ROUNDS=0 时至少审查 1 次（否则第二模型不会上场）。"""
    n = llm_review_rounds()
    if dual and n <= 0:
        return 1
    return n


def _client_looks_deepseek(client: Any) -> bool:
    base = str(getattr(client, "_base_url", "") or "").lower()
    return "deepseek" in base or bool(getattr(client, "_is_deepseek", False))


def _env_int(name: str, default: int) -> int:
    raw = os.environ.get(name)
    if raw is None or str(raw).strip() == "":
        return default
    try:
        return int(str(raw).strip())
    except ValueError:
        return default


def _llm_max_tokens(*, thinking: bool) -> int:
    """每次请求时读 env（须先 load_dotenv）；勿在 import 时固化。"""
    base = _env_int("HAIKESI_LLM_MAX_TOKENS", 4096)
    if not thinking:
        return max(256, base)
    # 默认抬到 16384：grok-4.5 内部 reasoning + 可见推演 + JSON 很吃额度
    thinking_cap = _env_int("HAIKESI_LLM_MAX_TOKENS_THINKING", max(base, 16384))
    return max(base, thinking_cap)


def _env_flag(name: str, default: bool) -> bool:
    raw = os.environ.get(name)
    if raw is None or raw.strip() == "":
        return default
    return raw.strip().lower() in {"1", "true", "yes", "on"}


def llm_thinking_enabled() -> bool:
    """开发开：捕获思考过程写 decision 日志；正常游玩关：省 output/reasoning token。"""
    return _env_flag("HAIKESI_LLM_THINKING", False)


def _is_deepseek_base(base_url: str) -> bool:
    return "deepseek" in (base_url or "").lower()


def _is_glm_base(base_url: str) -> bool:
    u = (base_url or "").lower()
    return "bigmodel.cn" in u or "zhipuai" in u or "/paas/v4" in u


def _is_xai_base(base_url: str) -> bool:
    u = (base_url or "").lower()
    return "x.ai" in u or "xai" in u


def _glm_model_supports_reasoning_effort(model: str) -> bool:
    """reasoning_effort 仅 GLM-5.2 及以上支持（官方文档）。"""
    m = (model or "").lower().replace("_", "-")
    # glm-5.2 / glm-5.1 / glm-5 / glm-5-turbo …
    if "glm-5.2" in m or "glm-5-2" in m:
        return True
    if "glm-5.1" in m or "glm-5-1" in m:
        return True
    if re.search(r"\bglm-5\b", m) or m.startswith("glm-5"):
        # glm-5、glm-5-turbo、glm-5v-turbo 等；排除误伤已覆盖的 5.x
        return True
    return False


def _glm_reasoning_effort(*, thinking: bool) -> str | None:
    """智谱 reasoning_effort（仅 GLM-5.2+）。

    官方可选：max | xhigh | high | medium | low | minimal | none
    服务端映射：none/minimal→放弃思考；low/medium→high；xhigh→max。
    """
    if not thinking:
        return None
    effort = (os.environ.get("HAIKESI_LLM_REASONING_EFFORT") or "high").strip().lower()
    # 兼容旧误写 light、以及 xAI 档位名
    aliases = {
        "light": "low",
        "none": "none",
        "minimal": "minimal",
        "low": "low",
        "medium": "medium",
        "high": "high",
        "xhigh": "xhigh",
        "max": "max",
    }
    return aliases.get(effort, "high")


def _xai_supports_reasoning_none(model: str) -> bool:
    """grok-4.5 等不能 reasoning_effort=none；grok-4.3 可以。"""
    m = (model or "").lower()
    if "4.5" in m or "grok-4-5" in m:
        return False
    if "4.3" in m or "grok-4-3" in m:
        return True
    # 未知新模型：保守不用 none，避免 400
    return False


def _xai_reasoning_effort(*, model: str, thinking: bool) -> str:
    supports_none = _xai_supports_reasoning_none(model)
    if thinking:
        effort = (os.environ.get("HAIKESI_LLM_REASONING_EFFORT") or "high").strip().lower()
        if effort not in {"none", "low", "medium", "high"}:
            effort = "high"
        if effort == "none" and not supports_none:
            effort = "low"
        return effort
    return "none" if supports_none else "low"


def _cleanup_thinking_text(text: str) -> str:
    """去掉半截草稿、未闭合标签，保留最后一套完整『### 领袖』推演。"""
    t = (text or "").strip()
    if not t:
        return ""
    t = re.sub(r"</?thinking>", "", t, flags=re.IGNORECASE)
    t = re.sub(r"</?think>", "", t, flags=re.IGNORECASE)
    # 若模型先写了一截再重写：保留从最后一个「完整领袖1块」或最密的连续 ### 领袖 段
    markers = list(re.finditer(r"(?m)^###\s*领袖\s+\d+", t))
    if len(markers) >= 2:
        # 若同一领袖编号重复出现，从最后一次「领袖 1」或最小编号的最后一轮开始
        last_starts: dict[str, int] = {}
        for m in markers:
            key = m.group(0)
            last_starts[key] = m.start()
        # 取所有领袖标题最后一次出现位置的最小值（一轮完整重写的起点）
        # 更稳：若「### 领袖 1」出现多次，从最后一次领袖1起切
        m1 = list(re.finditer(r"(?m)^###\s*领袖\s+1\b", t))
        if len(m1) >= 2:
            t = t[m1[-1].start() :].strip()
        elif markers:
            # 否则从最后一个「看似新一轮」的最小编号标题起
            t = t[markers[-min(5, len(markers))].start() :].strip()
    return t.strip()


_THINK_TAG_RE = re.compile(
    r"<thinking>(.*?)</thinking>|<think>(.*?)</think>",
    re.DOTALL | re.IGNORECASE,
)


def _split_visible_thinking(text: str) -> tuple[str, str]:
    """从回复中拆出可见推演与最终正文（JSON 仍可夹杂在正文里）。"""
    parts: list[str] = []

    def _keep(m: re.Match[str]) -> str:
        chunk = (m.group(1) or m.group(2) or "").strip()
        if chunk:
            parts.append(chunk)
        return ""

    rest = _THINK_TAG_RE.sub(_keep, text).strip()
    reasoning = "\n\n".join(parts)
    if reasoning:
        return _cleanup_thinking_text(reasoning), rest or text

    # 未闭合 <thinking>：剥掉标签后按前言处理
    raw = re.sub(r"</?thinking>|</?think>", "", text, flags=re.IGNORECASE)
    extracted = _extract_json_object(raw)
    if extracted:
        idx = raw.find(extracted)
        if idx > 0:
            preamble = raw[:idx].strip()
            if preamble and not preamble.startswith("{"):
                cleaned = _strip_code_fences(preamble).strip()
                if cleaned and cleaned.lower() not in {"json", "```", "```json"}:
                    return _cleanup_thinking_text(cleaned), extracted
    return "", rest or text


class _OpenAICompatibleClient:
    def __init__(self, config: HaikesiLLMConfig) -> None:
        from openai import OpenAI

        self._client = OpenAI(api_key=config.api_key, base_url=config.base_url)
        self._model = config.model
        self._base_url = (config.base_url or "").lower()
        self._is_deepseek = _is_deepseek_base(self._base_url)
        self._is_glm = _is_glm_base(self._base_url) or "glm" in (
            config.model or ""
        ).lower()
        self._is_xai = _is_xai_base(self._base_url)
        # DeepSeek 官方：JSON Output 会偶发空 content；默认关闭，靠 prompt + 解析容错。
        # 开发 thinking 模式要求 <thinking> 前言，与 response_format=json_object 冲突。
        self._json_mode = _env_flag("HAIKESI_LLM_JSON_MODE", False)
        self._thinking_requested = llm_thinking_enabled()
        if self._thinking_requested:
            self._json_mode = False
        self._thinking_enabled = self._thinking_requested
        self._last_reasoning = ""

    def _build_kwargs(
        self,
        prompt: str,
        *,
        messages: list[dict[str, str]] | None = None,
    ) -> dict[str, Any]:
        load_dotenv_file()
        max_tokens = _llm_max_tokens(thinking=self._thinking_enabled)
        kwargs: dict[str, Any] = {
            "model": self._model,
            "messages": messages
            if messages is not None
            else [{"role": "user", "content": prompt}],
            "max_tokens": max_tokens,
        }
        if self._json_mode:
            kwargs["response_format"] = {"type": "json_object"}
        extra: dict[str, Any] = {}
        if self._is_deepseek:
            # DeepSeek V4：thinking extra_body
            extra["thinking"] = {
                "type": "enabled" if self._thinking_enabled else "disabled"
            }
        elif self._is_glm:
            # 智谱：thinking.type = enabled|disabled（与官方一致）
            extra["thinking"] = {
                "type": "enabled" if self._thinking_enabled else "disabled"
            }
            # reasoning_effort 仅 GLM-5.2+；4.7 等发了也会被忽略
            if self._thinking_enabled and _glm_model_supports_reasoning_effort(
                self._model
            ):
                effort = _glm_reasoning_effort(thinking=True)
                if effort is not None:
                    extra["reasoning_effort"] = effort
        elif self._is_xai:
            # xAI：grok-4.5 禁止 none；关 thinking 时用 low
            extra["reasoning_effort"] = _xai_reasoning_effort(
                model=self._model, thinking=self._thinking_enabled
            )
        if extra:
            kwargs["extra_body"] = extra
        return kwargs

    def _session_messages_for_prompt(self, prompt: str) -> list[dict[str, str]] | None:
        sess = _active_chat_session.get()
        if sess is None:
            return None
        try:
            return sess.build_api_messages(prompt)
        except Exception as exc:  # noqa: BLE001
            log.warning("chat session build_api_messages failed: %s", exc)
            return None

    def _extract_content(self, response: Any) -> tuple[str, str, str]:
        """Returns (answer_content, finish_reason, api_reasoning)."""
        choice = response.choices[0]
        msg = choice.message
        content = (msg.content or "").strip()
        finish = getattr(choice, "finish_reason", None) or ""
        api_reasoning = ""
        rc = getattr(msg, "reasoning_content", None)
        if rc:
            api_reasoning = str(rc).strip()
        else:
            r = getattr(msg, "reasoning", None)
            if isinstance(r, dict):
                api_reasoning = str(
                    r.get("content") or r.get("text") or r.get("summary") or ""
                ).strip()
            elif r:
                api_reasoning = str(r).strip()
        # DeepSeek/部分模型：tool 轮 content 空、思考在 reasoning；勿把思考当正文，
        # 否则 ToolLoop 会把推演片段当成 spoken → JSON 解析失败再整轮重试。
        raw_calls = getattr(msg, "tool_calls", None) or []
        if raw_calls or str(finish).lower() in {"tool_calls", "tool_call"}:
            return content, finish, api_reasoning
        # 终局：优先用 content 里的 JSON；content 无 JSON 时从 reasoning 抠。
        # DeepSeek tools+thinking 常见：content 是中文推演、JSON 只在 reasoning_content。
        content_json = _extract_json_object(content) if content else None
        if content_json:
            return content_json, finish, api_reasoning
        if api_reasoning:
            extracted = _extract_json_object(api_reasoning)
            if extracted:
                log.warning(
                    "message.content missing JSON; recovered from reasoning_content "
                    "(content_chars=%s finish_reason=%s)",
                    len(content),
                    finish,
                )
                return extracted, finish, api_reasoning
            if not content:
                # grok-4.5 常见：可见正文在 reasoning，content 为空 → 整段当正文继续解析
                log.warning(
                    "message.content empty; using reasoning_content as body "
                    "(chars=%s finish_reason=%s)",
                    len(api_reasoning),
                    finish,
                )
                return api_reasoning, finish, api_reasoning
        return content, finish, api_reasoning

    def _json_only_followup(
        self,
        *,
        draft_text: str,
        required_ids: list[str] | None = None,
        partial_choices: dict[str, Any] | None = None,
        payload: dict[str, Any] | None = None,
        violations: list[str] | None = None,
    ) -> str | None:
        """content/reasoning 有推演但无 JSON / JSON 缺人/越池时，再要一次仅 JSON。"""
        snippet = (draft_text or "").strip()
        if len(snippet) < 20 and not partial_choices and not payload:
            return None
        if len(snippet) > 8000:
            snippet = snippet[:8000] + "\n…(截断)"
        req = ",".join(required_ids or [])
        partial = ""
        if partial_choices:
            partial = (
                "\n已有不完整/可疑 choices（可保留仍合法的项，其余必须改正）：\n"
                + json.dumps(partial_choices, ensure_ascii=False)
                + "\n"
            )
        viol_block = ""
        if violations:
            viol_block = (
                "\n上一版违规（必须消除）：\n- "
                + "\n- ".join(violations[:12])
                + "\n"
            )
        pool_block = ""
        if payload:
            pool_block = (
                "\n【硬约束·每人独立】禁止把 A 领袖的候选填到 B 领袖；"
                "禁止编造未列出的 NW_AI_*；"
                "GOLDEN/英雄 picks≥2 必须数组满员，NORMAL/DARK 选1 必须是字符串。\n"
                f"{format_options_constraint(payload)}\n"
            )
        id_rule = ""
        if required_ids:
            id_rule = (
                f"\nchoices 必须包含且仅需包含这些键（缺一不可）：{req}\n"
            )
        follow = (
            "根据以下策略推演（及已有不完整结果），输出唯一合法 JSON 对象。\n"
            "格式必须是对象（不是数组）：\n"
        )
        if reason_mode() == "off":
            follow += (
                '{"choices": {"1": "NW_AI_...", "5": ["NW_AI_A", "NW_AI_B"]}}\n'
                "不要输出 reasons（或给 {}）。\n"
            )
        else:
            follow += (
                '{"choices": {"1": "NW_AI_...", "5": ["NW_AI_A", "NW_AI_B"]}, '
                '"reasons": {"1": "...", "5": "..."}}\n'
                "reasons 各 1 句中文，禁止英文双引号。\n"
            )
        follow += (
            f"{id_rule}{pool_block}{viol_block}{partial}"
            "禁止 markdown，禁止再写 <thinking>，禁止解释。\n\n"
            f"{snippet or '（推演原文过短；请严格按上方每位领袖候选 ID 与 picks 补全）'}"
        )
        # 跟随时用较低 effort，把额度留给 JSON
        prev_think = self._thinking_enabled
        prev_json = self._json_mode
        try:
            self._thinking_enabled = False
            self._json_mode = False
            kwargs = self._build_kwargs(follow)
            # 强制给足 JSON 空间
            kwargs["max_tokens"] = max(1024, min(4096, int(kwargs.get("max_tokens") or 4096)))
            if self._is_xai:
                kwargs.setdefault("extra_body", {})
                kwargs["extra_body"]["reasoning_effort"] = (
                    "low" if not _xai_supports_reasoning_none(self._model) else "none"
                )
            response = self._client.chat.completions.create(**kwargs)
            content, _finish, api_reasoning = self._extract_content(response)
            body = content or api_reasoning
            if not body:
                return None
            extracted = _extract_json_object(body)
            return extracted or body
        except Exception as exc:  # noqa: BLE001
            log.warning("JSON-only followup failed: %s", exc)
            return None
        finally:
            self._thinking_enabled = prev_think
            self._json_mode = prev_json

    def complete_with_tools(
        self,
        messages: list[dict[str, Any]],
        tools: list[dict[str, Any]],
        *,
        allow_tool_use: bool = True,
    ) -> Any:
        """One chat turn that may return native tool_calls (OpenAI-compatible)."""
        from civ_mcp.haikesi_tools.runner import ChatResult, ToolCallSpec

        load_dotenv_file()
        prev_json = self._json_mode
        prev_think = self._thinking_enabled
        # Tool rounds: no json_object; keep thinking if user requested
        self._json_mode = False
        try:
            kwargs = self._build_kwargs("", messages=messages)
            kwargs["tools"] = tools
            if allow_tool_use:
                kwargs["tool_choice"] = "auto"
            else:
                kwargs["tool_choice"] = "none"
            response = self._client.chat.completions.create(**kwargs)
            content, _finish, api_reasoning = self._extract_content(response)
            if api_reasoning:
                self._last_reasoning = api_reasoning
            msg = response.choices[0].message
            calls: list[ToolCallSpec] = []
            raw_calls = getattr(msg, "tool_calls", None) or []
            for i, tc in enumerate(raw_calls):
                fn = getattr(tc, "function", None)
                name = getattr(fn, "name", None) if fn is not None else None
                args = getattr(fn, "arguments", None) if fn is not None else None
                if not name:
                    continue
                calls.append(
                    ToolCallSpec(
                        id=str(getattr(tc, "id", None) or f"call_{i}"),
                        name=str(name),
                        arguments_json=str(args or "{}"),
                    )
                )
            return ChatResult(
                text=content or "",
                tool_calls=calls,
                reasoning=api_reasoning or self._last_reasoning or "",
            )
        finally:
            self._json_mode = prev_json
            self._thinking_enabled = prev_think

    def complete(
        self,
        prompt: str,
        *,
        required_ids: list[str] | None = None,
    ) -> str:
        load_dotenv_file()
        last_detail = ""
        last_reasoning = ""
        # 空 content 时逐步降级：关 json → 保持 thinking 再试 → 最后降 effort
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
            session_msgs = self._session_messages_for_prompt(prompt)
            kwargs = self._build_kwargs(prompt, messages=session_msgs)
            try:
                response = self._client.chat.completions.create(**kwargs)
            except Exception as exc:
                err = str(exc).lower()
                # 上下文过长：丢弃历史、新建 session 后重试一次
                sess = _active_chat_session.get()
                if (
                    sess is not None
                    and session_msgs is not None
                    and any(
                        k in err
                        for k in (
                            "context",
                            "maximum",
                            "too long",
                            "token",
                            "131072",
                            "overflow",
                        )
                    )
                ):
                    log.warning(
                        "Context overflow with chat session; resetting session %s",
                        getattr(sess, "short_id", "?"),
                    )
                    try:
                        sess.reset(reason="recovered")
                    except Exception:  # noqa: BLE001
                        pass
                    kwargs = self._build_kwargs(prompt, messages=None)
                    try:
                        response = self._client.chat.completions.create(**kwargs)
                    except Exception as exc2:
                        last_detail = str(exc2)
                        log.warning(
                            "LLM create failed after session reset: %s",
                            exc2,
                        )
                        continue
                else:
                    last_detail = str(exc)
                    log.warning(
                        "LLM create failed (json=%s thinking=%s max_tokens=%s): %s",
                        json_mode,
                        thinking,
                        kwargs.get("max_tokens"),
                        exc,
                    )
                    continue
            content, finish, api_reasoning = self._extract_content(response)
            if api_reasoning:
                last_reasoning = api_reasoning
            if content:
                if want_think and not thinking:
                    log.warning("LLM fell back to thinking=disabled after empty content")
                visible, answer = _split_visible_thinking(content)
                merged = "\n\n".join(
                    p for p in (api_reasoning, visible) if p and p.strip()
                )
                self._last_reasoning = merged
                # 推演有了但 JSON 被吃掉 → 追一次仅 JSON
                if _extract_json_object(answer) is None and (merged or answer):
                    recovered = self._json_only_followup(
                        draft_text=merged or answer or content,
                        required_ids=required_ids,
                    )
                    if recovered and _extract_json_object(recovered):
                        log.warning("Recovered JSON via followup after thinking-only body")
                        return recovered
                return answer
            last_detail = (
                f"empty content finish_reason={finish!r} "
                f"reasoning_chars={len(api_reasoning)} json={json_mode} "
                f"thinking={thinking} max_tokens={kwargs.get('max_tokens')}"
            )
            log.warning("LLM empty content; retrying (%s)", last_detail)

        if last_reasoning:
            self._last_reasoning = last_reasoning
            recovered = self._json_only_followup(
                draft_text=last_reasoning,
                required_ids=required_ids,
            )
            if recovered and _extract_json_object(recovered):
                log.warning("Recovered JSON via followup after all empty-content attempts")
                return recovered
        raise RuntimeError(f"LLM returned empty content ({last_detail})")


class _AnthropicClient:
    def __init__(self, config: HaikesiLLMConfig) -> None:
        from anthropic import Anthropic

        self._client = Anthropic(api_key=config.api_key)
        self._model = config.model
        self._last_reasoning = ""

    def complete_with_tools(
        self,
        messages: list[dict[str, Any]],
        tools: list[dict[str, Any]],
        *,
        allow_tool_use: bool = True,
    ) -> Any:
        """Native Anthropic tools not wired yet — return plain completion."""
        from civ_mcp.haikesi_tools.runner import ChatResult

        del tools, allow_tool_use
        user_text = ""
        for m in reversed(messages):
            if m.get("role") == "user" and isinstance(m.get("content"), str):
                user_text = m["content"]
                break
        return ChatResult(text=self.complete(user_text or ""), tool_calls=[], reasoning="")

    def complete(
        self,
        prompt: str,
        *,
        required_ids: list[str] | None = None,
    ) -> str:
        del required_ids  # Anthropic path unused
        load_dotenv_file()
        response = self._client.messages.create(
            model=self._model,
            max_tokens=_llm_max_tokens(thinking=False),
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
    # 人类也进 FAITH 转储：公开万神殿名册 + 创造万神殿组合效果（civilopedia 查不到）
    if human_id is not None and int(human_id) >= 0 and int(human_id) not in ids:
        ids.append(int(human_id))
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
            lean_n = haikesi_lua.apply_victory_lean(leader_views)
            if lean_n:
                notes.append(
                    f"VictoryLean: 已为 {lean_n}/{len(leader_views)} 位领袖估计胜线路"
                )
        elif rst_available is True:
            with_rst = sum(1 for v in leader_views.values() if v.rst is not None)
            if with_rst == 0:
                notes.append("Real Strategy: 已加载但尚无 ActiveStrategy 数据")
                lean_n = haikesi_lua.apply_victory_lean(leader_views)
                if lean_n:
                    notes.append(
                        f"VictoryLean: RST 无数据，已估计 {lean_n} 位领袖胜线路"
                    )
            elif with_rst < len(leader_views):
                notes.append(
                    f"Real Strategy: {with_rst}/{len(leader_views)} 位领袖有战略意图"
                )
                lean_n = haikesi_lua.apply_victory_lean(leader_views)
                if lean_n:
                    notes.append(f"VictoryLean: 补全其余 {lean_n} 位领袖")
        elif rst_available is None and leader_views:
            # Older dump without RST_MOD line
            lean_n = haikesi_lua.apply_victory_lean(leader_views)
            if lean_n:
                notes.append(f"VictoryLean: 无 RST 探针，已估计 {lean_n} 位")

        # 仇水预见：InGame 常无 RiverManager；缺 FLOOD_API 时用 GamePlay 回退写入同一缓存
        need_flood_fb = any(
            v.flood_api_ok is False or v.flood_api_ok is None
            for v in leader_views.values()
        )
        if need_flood_fb and leader_views:

            async def _fetch_flood_fallback():
                lines = await gs.conn.execute_haikesi(
                    haikesi_lua.build_flood_foresight_query(ids)
                )
                haikesi_lua.merge_flood_foresight_lines(leader_views, lines)
                return True

            await _safe_fetch(
                "flood_foresight_fallback", _fetch_flood_fallback(), notes
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


def _trade_block(view: LeaderView) -> str:
    """本国商路：容量/出站/入向；两河等吃的是国际入向。"""
    t = view.trade
    if t is None or t.capacity < 0:
        return (
            "【本国商路】\n"
            "本轮未同步到 UI 商路缓存（勿臆造商路条数；和平互利类按延迟收益评估）"
        )
    free = max(0, int(t.capacity) - int(t.active))
    lines = [
        "【本国商路】（两河/天朝/罗马和平吃「国际入向」；出站国际线不触发该加成）",
        (
            f"容量 {t.capacity} · 已用 {t.active}"
            f"（国内 {t.domestic} / 国际出 {t.intl_out}）"
            f" · 空位 {free} · 国际入向 {t.intl_in}"
        ),
    ]
    outs: list[str] = []
    inns: list[str] = []
    for leg in t.routes:
        if leg.direction == "OUT":
            if leg.kind == "dom":
                outs.append(f"{leg.a}→{leg.c}（国内）")
            else:
                outs.append(f"{leg.a}→{leg.b}·{leg.c}（国际）")
        elif leg.direction == "IN":
            inns.append(f"{leg.a}·{leg.b}→{leg.c}")
    if outs:
        lines.append("出站: " + "；".join(outs[:8]))
    else:
        lines.append("出站: （无）")
    if inns:
        lines.append("国际入向: " + "；".join(inns[:8]))
    else:
        lines.append("国际入向: （无）— 和平互利类选后需他国向你开商路才生效")
    return "\n".join(lines)


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
    # 创造万神殿组合词条可能不是 BELIEF_CLASS_PANTHEON；仍以 FAITH 主档 + 首条 FBELIEF 为准
    if pan_belief is None and rel.pantheon_type:
        pan_belief = next(
            (b for b in rel.beliefs if b.belief_type == rel.pantheon_type),
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
        b
        for b in rel.beliefs
        if b.belief_class != "BELIEF_CLASS_PANTHEON"
        and b.belief_type != (rel.pantheon_type or "")
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


def _pantheon_brief(view: LeaderView | None, *, desc_limit: int = 100) -> str:
    """One-line pantheon for slim prompt (live GameInfo text; covers CreatePantheon)."""
    if view is None or view.religion is None:
        return "万神殿: （未知）"
    rel = view.religion
    pan_belief = next(
        (b for b in rel.beliefs if b.belief_class == "BELIEF_CLASS_PANTHEON"),
        None,
    )
    if pan_belief is None and rel.pantheon_type:
        pan_belief = next(
            (b for b in rel.beliefs if b.belief_type == rel.pantheon_type),
            None,
        )
    if not (rel.pantheon_name or pan_belief):
        return "万神殿: 尚未选择"
    name = haikesi_lua._strip_civ_icons(
        rel.pantheon_name or (pan_belief.name if pan_belief else "") or ""
    ).strip()
    desc = ""
    if pan_belief and pan_belief.description:
        desc = haikesi_lua._strip_civ_icons(pan_belief.description).replace("\n", " ").strip()
        if len(desc) > desc_limit:
            desc = desc[:desc_limit].rstrip() + "…"
    if desc:
        return f"万神殿: {name} — {desc}"
    typ = rel.pantheon_type or ""
    return f"万神殿: {name}" + (f"（{typ}）" if typ else "")


def _format_pantheon_public_section(
    payload: dict[str, Any],
    context: HaikesiGameContext,
) -> str:
    """Public pantheon roster — Create Your Pantheon combos are not in civilopedia KB."""
    lines: list[str] = []
    seen: set[int] = set()
    human_id = int(context.human_player_id)
    hv = context.leader_views.get(human_id)
    if hv is not None:
        label = f"{hv.civ_name or '人类'}（人类）"
        lines.append(f"- {label}：{_pantheon_brief(hv, desc_limit=140)}")
        seen.add(human_id)
    for ai in payload.get("ai_players", []) or []:
        pid = int(ai.get("player_id", -1))
        if pid < 0 or pid in seen:
            continue
        seen.add(pid)
        view = context.leader_views.get(pid)
        label = (
            (f"{view.civ_name}（{view.leader_name}）" if view is not None else None)
            or ai.get("player_name")
            or ai.get("civ_label")
            or f"领袖{pid}"
        )
        lines.append(f"- {label}：{_pantheon_brief(view, desc_limit=140)}")
    if not lines:
        return "- （尚无万神殿情报）"
    return "\n".join(lines)


def _rst_block(view: LeaderView) -> str:
    """Format Real Strategy / VictoryLean soft snapshot for one leader."""
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
    src = (rst.source or "rst").lower()
    title = (
        "【VictoryLean 胜线路估计】（RST 未加载；仅作选卡倾向参考，非强制）"
        if src == "lean"
        else "【Real Strategy 战略意图】（仅作选卡倾向参考，非强制）"
    )
    return "\n".join(
        [
            title,
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


def _format_pick_rule(picks: int, n_options: int = 0, *, short: bool = False) -> str:
    """选几张 vs 候选池张数分开写，避免「三选一/六选二」在池扩到 6 后误导。"""
    picks = max(1, int(picks or 1))
    n = max(0, int(n_options or 0))
    pool = f"候选{n}" if n > 0 else "下列候选"
    if short:
        if picks >= 2:
            return f"选{picks}/{pool}" if n else f"选{picks}"
        return f"选1/{pool}" if n else "选1"
    if picks >= 2:
        return f"本轮选{picks}（黄金/英雄双选·{pool}；候选张数≠可选张数）"
    return f"本轮选1（{pool}；勿把候选张数当成可选张数）"


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
            "（完整效果见上文全局列表；不是本轮选项）"
        )
    else:
        hist_block = "【历史库存摘要】（无）"
    if view is None:
        label = ai.get("player_name") or ai.get("civ_label") or str(pid)
        picks = int(ai.get("picks") or 1)
        age = str(ai.get("age") or "NORMAL")
        opts = list(ai.get("options") or [])
        pick_rule = _format_pick_rule(picks, len(opts))
        return "\n\n".join(
            [
                f"### 领袖 {pid}（{label}）",
                "可见情报不足（未能读取该领袖外交/视野数据）。\n"
                "仅根据候选海克斯与历史库存，从自身发展需求选卡。",
                f"年龄状态: {age} · {pick_rule}",
                "候选海克斯:\n"
                + "\n".join(haikesi_lua.format_option_lines(opts)),
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
    trade_txt = _trade_block(view)
    if trade_txt:
        parts.append(trade_txt)
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
    picks = int(ai.get("picks") or 1)
    age = str(ai.get("age") or "NORMAL")
    n_opts = len(list(ai.get("options") or []))
    if picks >= 2:
        cand_header = (
            f"【候选海克斯】（{age}：{_format_pick_rule(picks, n_opts)}；"
            "不重复类型；JSON 可用数组或 A+B 字符串）\n"
        )
    else:
        cand_header = (
            f"【候选海克斯】（{_format_pick_rule(picks, n_opts)}；"
            "必须从这里选 1 个完整类型 ID）\n"
        )
    parts.append(
        cand_header
        + "\n".join(
            haikesi_lua.format_option_lines(
                ai.get("options", []),
                cities=int(view.cities or 0),
                intl_inbound=(
                    int(view.trade.intl_in)
                    if view.trade is not None
                    else None
                ),
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
    flood_total = sum(len(v.flood_targets) for v in context.leader_views.values())
    flood_rivers = sum(
        f.floodable_rivers
        for v in context.leader_views.values()
        for f in v.flood_targets
    )
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
        f"flood_visible_cities={flood_total}",
        f"floodable_rivers={flood_rivers}",
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
        type_id = str(gs.get("type") or "").strip()
        if mult > 0 and (name not in ("", "Unknown", "未知") or type_id.startswith("GAMESPEED_")):
            if name in ("", "Unknown", "未知") and type_id:
                name = haikesi_lua.game_speed_display_name(type_id)
            return mult, name or type_id or "未知", False

    ov = context.overview
    name = (ov.game_speed_name or "").strip()
    type_id = (ov.game_speed or "").strip()
    mult = int(getattr(ov, "speed_cost_multiplier", 0) or 0)
    # Prefer typed SPEED| wire (proves dump succeeded). Bare mult=100 with empty
    # name is the GameOverview default and must NOT count as Standard.
    if type_id.startswith("GAMESPEED_") and mult > 0:
        if name in ("", "Unknown", "未知"):
            name = haikesi_lua.game_speed_display_name(type_id)
        return mult, name, False
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
) -> str:
    """Return early-phase rule text scaled by game speed (empty if past ancient)."""
    thresholds = haikesi_lua.early_game_phase_thresholds(cost_multiplier=cost_multiplier)
    ancient_end = thresholds["ancient_end"]
    echo_horizon = thresholds["echo_horizon"]
    if turn > ancient_end:
        return ""
    speed_hint = ""
    if speed_name and speed_name != "未知" and cost_multiplier != 100:
        speed_hint = f"（{speed_name}；阈值按 Cost×{cost_multiplier}/100 相对标准速度缩放）"
    return (
        f"- 远古早期（约 T1–T{ancient_end}{speed_hint}、单城且已知军力≤2）："
        "优先真正即时的百分比产出；"
        "有城时才优先资源创建（落在最新城 3 环）；"
        "**0 城时资源创建会空放，禁止选择**，改选开拓者/工人 echo 或百分比；"
        f"军事 echo：{echo_horizon} 回合内可造则抬权；无同系在建≠禁止，可当延迟收益"
        f"（计划改队列仍可选）；仅长期造不出才近似空放\n"
    )


def build_decision_prompt(payload: dict[str, Any], context: HaikesiGameContext) -> str:
    ai_blocks = [
        _format_leader_block(
            ai,
            context.leader_views.get(int(ai["player_id"])),
            context.human_player_id,
        )
        for ai in payload.get("ai_players", [])
    ]

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
    think_on = llm_thinking_enabled()
    if mode == "off":
        reason_rule = (
            "- 不要输出 reasons（或给空对象 {}）；只需 choices。"
            "内心推演即可，勿把分析写进 JSON，以节省输出 token。"
        )
        output_fmt = (
            '{\n  "choices": {"2": "NW_AI_...", "3": ["NW_AI_A", "NW_AI_B"]}\n}'
        )
    elif mode == "full":
        reason_rule = (
            "- reasons 仅供开发日志，不会显示在游戏内；可用 1～2 句带领袖风味的简体中文"
            "（常用汉字，约 40 字内），第一人称；禁止 emoji、英文双引号 \"、生僻字；"
            "详细推演写在 thinking 区（若已开启），勿塞进 reasons。"
        )
        output_fmt = (
            '{\n  "choices": {"2": "NW_AI_...", "3": ["NW_AI_A", "NW_AI_B"]},\n'
            '  "reasons": {"2": "...", "3": "..."}\n}'
        )
    else:
        reason_rule = (
            "- reasons 仅供开发日志，不会显示在游戏内；用 1 句带领袖风味的简体中文"
            "（常用汉字，约 20 字内），第一人称；禁止 emoji、英文双引号 \"、生僻字；"
            "不要复述效果全文"
        )
        output_fmt = (
            '{\n  "choices": {"2": "NW_AI_...", "3": ["NW_AI_A", "NW_AI_B"]},\n'
            '  "reasons": {"2": "...", "3": "..."}\n}'
        )

    if think_on:
        strategy_rule = (
            "- 先做**详细**策略推演再选卡：推演写在 <thinking>…</thinking> 内，"
            "**推演结束后再输出 JSON**（JSON 的 reasons 仍只保留短句）。"
            "每位领袖必须写清：局面压力、主战略、对该领袖【每一张候选】的取/弃及理由、"
            "最终选定与一句因果；涉及 echo 须核对在建兵种类型"
            "（石弩/投石机=攻城≠远程）。禁止复述规则原文与元叙述；允许较长，勿注水。"
        )
        output_section = f"""## 输出格式（开发模式：详细推演 → 再 JSON）
1) 先在 <thinking>…</thinking> 写**完整详细**策略推演（写入决策日志，不注入游戏）。
   - 简体中文；必须按「### 领袖 N」覆盖**每一位**待决策领袖（禁止只写一人）。
   - 每位领袖建议包含（可自由组织，但信息不能缺）：
     · 局面：交战/贴脸/蛮族/军力对比/主战略/商路入向等关键事实
     · 候选逐张：对列表中**每一张**写「取/弃 + 具体理由」（即时/延迟/空放、兑现）
     · 选定：类型（picks≥2 写两张）+ 为何优于被弃选项
   - 篇幅：每位领袖约 150–350 字；总推演可到约 1500–3500 字。密度优先，禁止复读 Prompt。
2) </thinking> 之后只输出一个合法 JSON（禁止 markdown）。reasons 仍短句风味，详细理由只放 thinking。

<thinking>
### 领袖 1
……
### 领袖 2
……
</thinking>
{output_fmt}"""
    else:
        strategy_rule = (
            "- 先在内心做策略推演再选卡（不必写出推演过程）：生存威胁、胜利路线、"
            "时代与扩张节奏、产出短板、外交、与人类海克斯的对抗/跟风"
        )
        output_section = f"""## 输出格式（仅 JSON，无 markdown）
{output_fmt}"""

    human_relic = _format_human_relic_section(payload)
    turn = int(payload.get("turn") or 0)
    speed_mult, speed_name, _ = _resolve_game_speed(context, payload)
    global_setting = _format_global_setting(context, turn=turn, payload=payload)
    early_rules = _early_game_rules(
        turn, cost_multiplier=speed_mult, speed_name=speed_name
    )

    return f"""你是文明6资深玩家，同时代入下列多位文明领袖，为各自选择本轮海克斯。{channel_note}
决策以老玩家常识与当前局面数据为主；仅在收益接近时用历史人物性格/议程破平（勿为角色表演而违背明显最优）。

情报规则（必须遵守）：
- 每位领袖只能使用**自己区块**内的情报做决策；禁止引用其他领袖区块，也禁止臆造未给出的单位/文明。
- 未相遇文明、战争迷雾外的敌军对本领袖不存在，不得当作已知信息。
- 人类本轮海克斯、各文明历史已选海克斯（含效果说明）、各文明万神殿（含创造万神殿组合效果）、全局时代/速度、世界会议决议是本局公开机制信息，各位领袖都可以参考。
- 「创造万神殿」组合词条不在 civilopedia 离线词典；效果以公开万神殿名册 / 各领袖【本国宗教】为准，禁止臆造。
- 「历史已选 / 历史库存」不是本轮选择：不得据此认定某领袖本轮已选完，也不得照抄历史词条作为本轮 choices。
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

## 各文明万神殿（公开·含创造万神殿组合效果）
以下为局内 Locale 实时效果；「创造万神殿」组合词条不在离线 civilopedia。
{_format_pantheon_public_section(payload, context)}

## 各文明历史已选海克斯（公开，含效果说明）
以下为过往回合已获得的词条库存，供理解局面；与本轮选卡无关，禁止当作「本轮已选定」。
{_format_historical_hexes_public(payload)}

{notes_block}## 待决策领袖（逐位以该领袖身份选卡）
{"\n\n".join(ai_blocks)}

## 规则
- 每位领袖从其「候选海克斯」中选择：普通时代选 1 个（字符串）；区块标注选2/picks=2（黄金或英雄时代）时选 2 个不重复类型（JSON 数组或 "A+B"）。候选池张数（常为 6）≠可选张数，禁止因「有 6 张候选」就选 2 张；必须重新决策，禁止因「历史已选」而照抄、跳过或认定本轮已选完
- 「历史已选海克斯 / 各文明历史已选」仅为库存说明（名称+效果），不是本轮选项，也不是自动选卡结果
- 只从该领袖区块列出的候选中选择；未列出的类型不可选
- choices 的值必须是候选行里的**完整类型 ID**（如 NW_AI_ECHO_MELEE），禁止编造/改写/缩写（禁止 NW_AI_BALANCED、NW_AI_CONQUEST_* 等不存在的名字）；可从候选文本中原样复制
- NW_AI_BARBARIAN_INVASION：对除触发者外各文明最新城附近刷蛮；远古早期且已知军力≤2 时慎选（除非以干扰人类为主）
- NW_AI_LIGHTNING_STORM：下回合起多回合全图风暴；评估对本国与对手的净收益后再选
- NW_AI_RIVER_FLOOD：对关系最差最多 3 名文明（未接触=中立默认分）城市附近可泛滥河，下回合起连续 5 回合洪水；无河则空放。选前用 flood_targets 核对观察者可见城的可泛滥河数
- 候选前缀标注生效时机：【即时】立刻生效；【条件即时·需已有城市】无城则空放；【空放·当前0城】禁止选择；【延迟】须先满足生产/商路等条件；勿在远古早期盲选尚无法使用的军事 echo
- 资源创建类（奶龙/丝绸/烟草/茶/棉花等）依赖「最新建立的城市」：国力显示 0 城或「无城市数据」时选择=效果跳过，应改选开拓者 echo 或百分比产出
{early_rules}{strategy_rule}
- 文明6常识（用于解释上下文，勿复述）：早期扩张与基础设施常优先于奇观；战略资源与特色单位窗口很关键；忠诚度差的新城易叛；宗教胜利靠信仰传播与神学战斗；科技靠学院链+航天；文化靠旅游压过对手国内游客；外交靠好感/宗主/世界会议；军事窗口常在特色单位与时代领先时；贸易路线容量是免费产出；宜居度：人口每2人需1宜居；每种独有奢侈品改良后为最多4城各+1宜居，同种多余拷贝无额外宜居（种类>重复）；宜居赤字惩罚产出与忠诚（严重时可叛乱），盈余则加成产出；娱乐区/奇观/政策/总督亦可提供宜居
- 决策结合：局面威胁与交战状态、自身能力与议程、Real Strategy（可偏离）、本国宗教、胜利进度（注意未知/未启动）、不满与观感、世界会议、城市短板、人类公开海克斯、候选效果；历史库存仅作能力背景
- 尽量避免多名领袖无差别抄同一张牌；只有局面高度相似时才可同选
- 领袖皆有历史原型：仅在收益接近时用议程/不满表达风味
{reason_rule}
- choices 的键必须等于上文「### 领袖 N」中的 N（本局可能从 2 起，勿强行从 1 编号）
- 必须输出完整合法 JSON（所有字符串已闭合）；禁止 markdown 代码块

{output_section}
"""


def _format_leader_block_slim(
    ai: dict[str, Any],
    view: LeaderView | None,
    human_player_id: int,
    style: Any | None = None,
) -> str:
    """Slim leader block: age/picks + candidates; details via tools."""
    pid = int(ai["player_id"])
    picks = int(ai.get("picks") or 1)
    age = str(ai.get("age") or "NORMAL")
    opts = list(ai.get("options") or [])
    style_line = ""
    if style is not None and getattr(style, "slim_line", None):
        style_line = f"{style.slim_line}\n"
    if not opts or picks < 1:
        label = (
            (view.civ_name if view else None)
            or ai.get("player_name")
            or ai.get("civ_label")
            or str(pid)
        )
        return (
            f"### 领袖 {pid}：{label}\n"
            f"本轮无候选（池空，已跳过 ExtAI 选卡）。\n"
        )

    selected = haikesi_lua.dedupe_preserve_order(list(ai.get("selected") or []))
    hist = (
        f"历史库存短名：{haikesi_lua.format_relic_type_list(selected)}"
        if selected
        else "历史库存：（无）"
    )
    cities = int(view.cities or 0) if view is not None else 0
    mil = int(view.mil or 0) if view is not None else 0
    war = any(m.is_at_war for m in view.met) if view is not None else False
    rst = (
        view.rst.active_strategy
        if view is not None and view.rst is not None
        else "-"
    )
    if view is None:
        label = ai.get("player_name") or ai.get("civ_label") or str(pid)
        cand = "\n".join(haikesi_lua.format_option_lines(opts))
        return (
            f"### 领袖 {pid}（{label}）\n"
            f"极短况：视图缺失 · {age} · picks={picks}\n"
            f"{style_line}"
            f"万神殿: （未知）\n"
            f"{hist}\n"
            f"候选：\n{cand}"
        )

    human_met = next((m for m in view.met if m.player_id == human_player_id), None)
    human_bit = (
        f"人类:{human_met.civ_name}/{'战' if human_met.is_at_war else '和'}"
        if human_met
        else "未接触人类"
    )
    cand = "\n".join(
        haikesi_lua.format_option_lines(
            opts,
            cities=cities,
            intl_inbound=(
                int(view.trade.intl_in) if view.trade is not None else None
            ),
        )
    )
    pick_rule = _format_pick_rule(picks, len(opts), short=True)
    pantheon_line = _pantheon_brief(view)
    return (
        f"### 领袖 {pid}：{view.civ_name}（{view.leader_name}）\n"
        f"极短况：{cities}城 军{mil} RST={rst} 交战={'是' if war else '否'} "
        f"· {age}/{pick_rule} · {human_bit}\n"
        f"{style_line}"
        f"{pantheon_line}\n"
        f"{hist}\n"
        f"候选（必须从这里选）：\n{cand}"
    )


def _format_historical_hexes_names_only(payload: dict[str, Any]) -> str:
    lines: list[str] = []
    for ai in payload.get("ai_players", []) or []:
        pid = int(ai.get("player_id", -1))
        label = ai.get("civ_label") or ai.get("player_name") or f"领袖{pid}"
        selected = haikesi_lua.dedupe_preserve_order(list(ai.get("selected") or []))
        if not selected:
            lines.append(f"- {label}：无")
        else:
            lines.append(
                f"- {label}：{haikesi_lua.format_relic_type_list(selected)}"
            )
    return "\n".join(lines) if lines else "- （尚无历史海克斯）"


def build_decision_prompt_slim(
    payload: dict[str, Any],
    context: HaikesiGameContext,
    *,
    style_by_pid: dict[int, Any] | None = None,
) -> str:
    """Thin prompt for ToolLoop: candidates + short status; details via tools."""
    style_by_pid = style_by_pid or {}
    ai_blocks = [
        _format_leader_block_slim(
            ai,
            context.leader_views.get(int(ai["player_id"])),
            context.human_player_id,
            style=style_by_pid.get(int(ai["player_id"])),
        )
        for ai in payload.get("ai_players", [])
        if (ai.get("options") or []) and int(ai.get("picks") or 0) > 0
    ]
    if not ai_blocks:
        ai_blocks = ["（本轮无待决策领袖：全部 AI 海克斯池已空）"]
    notes_block = ""
    if context.fetch_notes:
        notes_block = (
            "## 数据说明（系统）\n"
            + "\n".join(f"- {n}" for n in context.fetch_notes)
            + "\n\n"
        )
    channel_note = (
        "局势缓存来自联机 Lua.log CTX（工具只读缓存，无法中途补查游戏）。"
        if any(
            "联机 LOG 通道" in n or "联机无 FireTuner" in n
            for n in context.fetch_notes
        )
        else "局势缓存来自单机 FireTuner 一次 gather（工具只读缓存，不二次查询）。"
    )
    mode = reason_mode()
    if mode == "off":
        reason_rule = "- 不要输出 reasons（或 {}）；只需 choices。"
        output_fmt = (
            '{\n  "choices": {"2": "NW_AI_...", "3": ["NW_AI_A", "NW_AI_B"]}\n}'
        )
    else:
        reason_rule = (
            "- reasons 仅开发日志用 1 句简体中文风味（约 20 字）；禁止英文双引号。"
        )
        output_fmt = (
            '{\n  "choices": {"2": "NW_AI_...", "3": ["NW_AI_A", "NW_AI_B"]},\n'
            '  "reasons": {"2": "...", "3": "..."}\n}'
        )

    turn = int(payload.get("turn") or 0)
    speed_mult, speed_name, _ = _resolve_game_speed(context, payload)
    global_setting = _format_global_setting(context, turn=turn, payload=payload)
    early_rules = _early_game_rules(
        turn, cost_multiplier=speed_mult, speed_name=speed_name
    )
    human_relic = _format_human_relic_section(payload)

    return f"""你是文明6资深玩家，代入下列领袖为本轮选择海克斯。{channel_note}

你可以使用工具按需索取：leader_snapshot / city_pressure / border_threats /
met_civ_detail / lookup_relic / inventory_brief / check_echo_feasibility /
flood_targets / civ6_kb / civilopedia_lookup。
对局工具必须带正确的 player_id（迷雾主体=该领袖自己）；禁止跨领袖偷看。
查完后输出最终 JSON（不要 markdown）。

情报规则：
- 每位领袖只用自己区块与自己 player_id 的工具结果。
- 候选全文已在下方；choices 值必须是候选里的完整类型 ID。禁止 NW_AI_NONE / 数字占位。
- 极短况已含城数/军力/RST/交战：勿再 leader_snapshot，除非要商路或宜居细节。
- 要看在建队列/人口短板 → city_pressure；贴脸可见单位 → border_threats。
- 若极短况有「风格:…」：系统已注入对应选卡 Skill；勿再编造人格。
- 历史库存仅短名；仅当需要**非本轮候选**的历史词条效果时用 lookup_relic（禁止复读下方候选全文）。
- civilopedia_lookup：优先用类型 ID（如 UNIT_SPY、CIVIC_DIPLOMATIC_SERVICE、UNIT_MISSIONARY、TECH_*），
  中文名易串条（「间谍」会命中政策/海克斯，「城堡」可能命中改良而非 TECH_CASTLES）。
  候选含间谍署/传教浪/特殊单位时，不确定解锁或分类应查 ID，勿凭印象臆造；本轮候选海克斯效果勿重复查。
- 万神殿（含「创造万神殿」组合词条）效果已在下方公开名册/各领袖行；**勿**用 civilopedia_lookup 查万神殿。
- civ6_kb：宜居/区域/胜利/商路等策略短篇；专名优先 civilopedia_lookup。
- 候选含仇水连汛（NW_AI_RIVER_FLOOD）时 → flood_targets 核对可见城可泛滥河；河合计=0 则强烈降权（易空放）。

## 当前回合
Turn {turn}

## 全局公开设定
{global_setting}

## 世界会议（公开）
{_format_world_congress(context.world_congress)}

## 人类玩家本轮海克斯（公开）
{human_relic}

## 各文明万神殿（公开·含创造万神殿组合效果）
{_format_pantheon_public_section(payload, context)}

## 各文明历史已选（仅短名）
{_format_historical_hexes_names_only(payload)}

{notes_block}## 待决策领袖
{"\n\n".join(ai_blocks)}

## 规则
- 普通时代选 1；黄金/英雄 picks=2 选 2 个不重复类型；候选池张数≠可选张数（有 6 张仍可能只选 1）；picks 已按候选数量夹紧
- 各领袖 picks 可能不同（有人 GOLDEN 选2、有人 NORMAL/DARK 选1）：按该领袖极短况 `选N` 填写，禁止把一人的选择抄给另一人
- 只从该领袖候选中选；禁止编造 NW_AI_*
{early_rules}- 0 城勿选资源创建；军事 echo：核对能否生产该系（石弩=攻城≠远程）→ city_pressure；无同系在建≠禁止（可改队列兑现），勿当成空放禁选
{reason_rule}
- choices 键=「### 领袖 N」的 N；无候选的领袖不要出现在 choices
- 最终只输出一个合法 JSON：
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


def _salvage_choices_dict(text: str) -> dict[str, Any] | None:
    """从损坏 JSON 中尽量抠出 choices（reasons 常因未转义引号炸掉整段）。"""
    m = re.search(r'"choices"\s*:\s*\{', text)
    if not m:
        return None
    start = m.end() - 1  # '{'
    depth = 0
    in_str = False
    escape = False
    end = None
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
                end = i + 1
                break
    if end is None:
        return None
    blob = text[start:end]
    try:
        choices = json.loads(blob)
    except json.JSONDecodeError:
        # 再试：去掉尾逗号
        try:
            choices = json.loads(re.sub(r",\s*}", "}", blob))
        except json.JSONDecodeError:
            return None
    if isinstance(choices, dict) and choices:
        return {"choices": choices, "reasons": {}}
    return None


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
            # 偶发：根是 [ {choices:...} ] 或直接是 choices 列表
            if isinstance(data, list) and data:
                if isinstance(data[0], dict) and (
                    "choices" in data[0] or "1" in data[0] or "2" in data[0]
                ):
                    return data[0] if "choices" in data[0] else {"choices": data}
                if all(isinstance(x, dict) for x in data):
                    return {"choices": data}
        except json.JSONDecodeError as exc:
            errors.append(exc)
    salvaged = _salvage_choices_dict(text)
    if salvaged is not None:
        return salvaged
    if extracted:
        salvaged = _salvage_choices_dict(extracted)
        if salvaged is not None:
            return salvaged
    raise errors[-1] if errors else json.JSONDecodeError("no json object", text, 0)


def coerce_choices_map(raw: Any) -> dict[str, Any]:
    """把 LLM 各种 choices 形态收成 dict[player_id -> relic|list]."""
    if raw is None:
        return {}
    if isinstance(raw, dict):
        # 有时套一层 {"choices": {...}}
        if "choices" in raw and len(raw) <= 2 and isinstance(raw.get("choices"), (dict, list)):
            return coerce_choices_map(raw.get("choices"))
        return {str(k): v for k, v in raw.items() if not str(k).startswith("_")}
    if isinstance(raw, list):
        out: dict[str, Any] = {}
        for item in raw:
            if isinstance(item, dict):
                if "player_id" in item or "id" in item or "leader" in item:
                    key = str(
                        item.get("player_id")
                        or item.get("id")
                        or item.get("leader")
                        or ""
                    )
                    val = (
                        item.get("relic")
                        or item.get("choice")
                        or item.get("relics")
                        or item.get("pick")
                    )
                    if key and val is not None:
                        out[key] = val
                        continue
                # {"1": "NW_..."} 或 {"1": ["A","B"]}
                for k, v in item.items():
                    if str(k).startswith("_"):
                        continue
                    out[str(k)] = v
            elif isinstance(item, (list, tuple)) and len(item) >= 2:
                out[str(item[0])] = item[1]
            elif isinstance(item, str) and "=" in item:
                k, _, v = item.partition("=")
                if k.strip():
                    out[k.strip()] = v.strip()
        return out
    return {}


def coerce_reasons_map(raw: Any) -> dict[str, Any]:
    if raw is None:
        return {}
    if isinstance(raw, dict):
        if "reasons" in raw and isinstance(raw.get("reasons"), (dict, list)):
            return coerce_reasons_map(raw.get("reasons"))
        return {str(k): v for k, v in raw.items() if not str(k).startswith("_")}
    if isinstance(raw, list):
        return coerce_choices_map(raw)  # 同构：[{ "1": "..." }, ...]
    return {}


def expected_choice_ids(payload: dict[str, Any]) -> list[str]:
    """AIs that must choose this round (non-empty options only)."""
    ids: list[str] = []
    for ai in payload.get("ai_players") or []:
        pid = str(ai.get("player_id") or "")
        if not pid or pid == "None":
            continue
        opts = [str(x).strip() for x in (ai.get("options") or []) if str(x).strip()]
        if not opts:
            continue
        ids.append(pid)
    return ids


def missing_choice_ids(choices: dict[str, Any], expected: list[str]) -> list[str]:
    have = {str(k) for k, v in choices.items() if v not in (None, "", [], {})}
    return [i for i in expected if i not in have]


def _flatten_choice_relics(value: Any) -> list[str]:
    if isinstance(value, list):
        return [str(x).strip() for x in value if str(x).strip()]
    text = str(value or "").strip()
    if not text:
        return []
    if "+" in text:
        return [x.strip() for x in text.split("+") if x.strip()]
    return [text]


def is_legal_ai_relic_id(relic: str) -> bool:
    """Reject placeholders like NW_AI_NONE / bare numbers from empty-pool hallucinations."""
    r = (relic or "").strip()
    if not r or r.upper() in {"NW_AI_NONE", "NONE", "NULL", "NIL"}:
        return False
    if r.isdigit():
        return False
    return r.startswith("NW_AI_")


def options_by_player(payload: dict[str, Any]) -> dict[str, list[str]]:
    out: dict[str, list[str]] = {}
    for ai in payload.get("ai_players") or []:
        pid = str(ai.get("player_id") or "")
        if not pid or pid == "None":
            continue
        opts = [str(x).strip() for x in (ai.get("options") or []) if str(x).strip()]
        out[pid] = opts
    return out


def picks_needed_by_player(payload: dict[str, Any]) -> dict[str, int]:
    out: dict[str, int] = {}
    for ai in payload.get("ai_players") or []:
        pid = str(ai.get("player_id") or "")
        if not pid or pid == "None":
            continue
        opts = [str(x).strip() for x in (ai.get("options") or []) if str(x).strip()]
        if not opts:
            continue
        want = max(1, int(ai.get("picks") or 1))
        out[pid] = min(want, len(opts))
    return out


def validate_choices_against_options(
    choices: dict[str, Any],
    payload: dict[str, Any],
) -> list[str]:
    """返回违规说明；空列表=全部合法。"""
    opts_map = options_by_player(payload)
    need_map = picks_needed_by_player(payload)
    errors: list[str] = []
    for pid, opts in opts_map.items():
        if not opts:
            continue
        opt_set = set(opts)
        relics = _flatten_choice_relics(choices.get(pid))
        need = need_map.get(pid, 1)
        if not relics:
            errors.append(f"AI {pid}: empty choice")
            continue
        if len(relics) != len(set(relics)):
            errors.append(f"AI {pid}: duplicate picks {relics}")
        if len(relics) > need:
            errors.append(f"AI {pid}: too many picks {relics} (need <={need})")
        if len(opts) >= need and len(relics) < need:
            errors.append(f"AI {pid}: under-picked {relics} (need {need})")
        for r in relics:
            if not is_legal_ai_relic_id(r):
                errors.append(f"AI {pid}: illegal relic id {r!r}")
            elif r not in opt_set:
                errors.append(
                    f"AI {pid}: {r} not in options "
                    f"[{', '.join(opts)}]"
                )
    # ExtAI / 大模型选卡：不再校验混乱互斥（多 AI 可同轮选混乱）
    return errors


_CHAOS_INTERFERENCE_RELICS: frozenset[str] = frozenset(
    {
        "NW_AI_BARBARIAN_INVASION",
        "NW_AI_LIGHTNING_STORM",
        "NW_AI_RIVER_FLOOD",
    }
)


def is_chaos_interference_relic(relic_type: str) -> bool:
    return (relic_type or "") in _CHAOS_INTERFERENCE_RELICS


def list_chaos_assignments(choices: dict[str, Any]) -> list[tuple[str, str]]:
    """[(player_id, relic_type), ...] 本轮所有混乱干扰选定（审计用，不再互斥）。"""
    hits: list[tuple[str, str]] = []
    for pid, packed in choices.items():
        if str(pid).startswith("_"):
            continue
        for r in _flatten_choice_relics(packed):
            if is_chaos_interference_relic(r):
                hits.append((str(pid), r))
    return hits


def enforce_chaos_mutex_choices(
    choices: dict[str, Any],
    payload: dict[str, Any],
) -> tuple[dict[str, Any], list[str]]:
    """已废弃：大模型选卡不再互斥混乱。保留函数以免旧调用崩溃。"""
    return choices, []


def coerce_choices_to_options(
    choices: dict[str, Any],
    payload: dict[str, Any],
) -> dict[str, Any]:
    """非法/缺失选卡时，用该领袖候选池前 N 张补齐（保证可提交）。"""
    opts_map = options_by_player(payload)
    need_map = picks_needed_by_player(payload)
    out: dict[str, Any] = {}
    for pid, opts in opts_map.items():
        need = need_map.get(pid, 1)
        if not opts:
            continue
        relics = _flatten_choice_relics(choices.get(pid))
        opt_set = set(opts)
        kept = [r for r in relics if r in opt_set]
        # de-dupe
        seen: set[str] = set()
        uniq: list[str] = []
        for r in kept:
            if r in seen:
                continue
            seen.add(r)
            uniq.append(r)
        for opt in opts:
            if len(uniq) >= need:
                break
            if opt not in seen:
                seen.add(opt)
                uniq.append(opt)
        if not uniq:
            uniq = opts[:need]
        out[pid] = uniq[0] if need == 1 and len(uniq) == 1 else uniq[:need]
    return out


def revert_invalid_picks_to_draft(
    choices: dict[str, Any],
    draft_choices: dict[str, Any],
    payload: dict[str, Any],
) -> tuple[dict[str, Any], list[str]]:
    """审查改坏时：该领袖若初稿合法则整份回退初稿；返回 (新 choices, 回退的领袖 id)。"""
    if not draft_choices:
        return dict(choices), []
    opts_map = options_by_player(payload)
    need_map = picks_needed_by_player(payload)
    out = dict(choices)
    reverted: list[str] = []
    for pid, opts in opts_map.items():
        opt_set = set(opts)
        need = need_map.get(pid, 1)
        cur = _flatten_choice_relics(out.get(pid))
        cur_bad = (
            not cur
            or any(r not in opt_set for r in cur)
            or len(cur) != len(set(cur))
            or (len(opts) >= need and len(cur) < need)
            or len(cur) > need
        )
        if not cur_bad:
            continue
        draft = _flatten_choice_relics(draft_choices.get(pid))
        draft_ok = (
            bool(draft)
            and all(r in opt_set for r in draft)
            and len(draft) == len(set(draft))
            and not (len(opts) >= need and len(draft) < need)
            and len(draft) <= need
        )
        if draft_ok:
            out[pid] = draft[0] if need == 1 and len(draft) == 1 else draft
            reverted.append(pid)
    return out, reverted


def format_options_constraint(payload: dict[str, Any]) -> str:
    """每人 picks + 合法 ID 列表（供 followup / 池修复强制约束）。"""
    lines: list[str] = []
    need_map = picks_needed_by_player(payload)
    for ai in payload.get("ai_players") or []:
        pid = str(ai.get("player_id") or "")
        opts = [str(x).strip() for x in (ai.get("options") or []) if str(x).strip()]
        if not pid or not opts:
            continue
        need = need_map.get(pid, max(1, int(ai.get("picks") or 1)))
        age = str(ai.get("age") or "NORMAL")
        if need >= 2:
            shape = f"必须选 {need} 张（JSON 数组，不重复）"
        else:
            shape = "必须选 1 张（JSON 字符串，禁止数组）"
        lines.append(
            f"- 领袖 {pid}（{age}）：{shape}；仅可从下列 ID 原样复制：\n"
            f"  {' | '.join(opts)}"
        )
    return "\n".join(lines) if lines else "(无候选)"


def merge_choice_dicts(*parts: dict[str, Any]) -> dict[str, Any]:
    out: dict[str, Any] = {}
    for part in parts:
        for k, v in (part or {}).items():
            if v in (None, "", [], {}):
                continue
            out[str(k)] = v
    return out


def llm_review_rounds() -> int:
    """自审轮数：0=一次出牌；1–5=初稿后再 Review N 次（更贵更慢，开发用）。"""
    raw = (os.environ.get("HAIKESI_LLM_REVIEW_ROUNDS") or "0").strip()
    try:
        return max(0, min(5, int(raw)))
    except ValueError:
        return 0


def _client_last_reasoning(client: _ChatClient) -> str:
    if hasattr(client, "_last_reasoning"):
        return str(getattr(client, "_last_reasoning") or "")
    return ""


def build_self_review_prompt(
    base_prompt: str,
    *,
    previous_reasoning: str,
    previous_raw: str,
    round_index: int,
    total_rounds: int,
) -> str:
    """在原局面 Prompt 后追加自审指令（API 无无状态，须重带局面）。"""
    prev_json = _extract_json_object(previous_raw) or previous_raw.strip()
    think_on = llm_thinking_enabled()
    if think_on:
        out_rule = (
            "先输出完整 <thinking>…</thinking>（必须覆盖每一位领袖），再输出唯一合法 JSON。"
            "禁止 markdown。禁止只复述一人或只写「全部维持」而不逐人说明。"
        )
    else:
        out_rule = "只输出唯一合法 JSON（禁止 markdown）；内心完成审查即可。"
    return (
        f"{base_prompt}\n\n"
        f"---\n"
        f"## 自审第 {round_index}/{total_rounds} 轮（提交游戏前）\n"
        f"你是严格审稿人。对照局面数据，审查上一轮选卡与推演；有错必改，无错也要写清为何维持。\n\n"
        f"### 上一轮推演\n{previous_reasoning or '（无独立 thinking，见下方原文）'}\n\n"
        f"### 上一轮 JSON\n{prev_json}\n\n"
        f"### 审查清单（逐项对照真实数据）\n"
        f"1. 兵种：石弩/投石机=攻城≠远程；echo 优先同系在建，无在建可改队列仍可选（勿一律禁选）\n"
        f"2. 和平互利是否已有国际入向商路，否则近似空放\n"
        f"3. 战时军力劣势是否仍优先开拓者/奇观等长线\n"
        f"4. 即时/延迟/空放是否说错；资源创建是否有城\n"
        f"5. 是否跨领袖偷看、编造未给出情报\n"
        f"6. GOLDEN/英雄时代是否选满 2 张且不重复\n"
        f"7. choices 是否均为该领袖候选列表中的完整类型 ID（禁止幻觉类型）\n\n"
        f"### <thinking> 强制结构（每位领袖都要有，禁止省略）\n"
        f"对每一位「### 领袖 N」按下列三行写（可加细节，不可合并多人）：\n"
        f"- 上轮选择：…\n"
        f"- 审稿结论：维持 / 改选为 XXX（必须二选一写明）\n"
        f"- 详细原因：至少 2～4 句，说明核对了哪些数据；若改选，写清旧选错在哪、新选为何更好；"
        f"若维持，写清为何审查项全部通过（勿空喊「没问题」）\n"
        f"全部领袖写完后，可加一小节「本轮改动摘要」：列出所有改选的领袖与旧→新。\n\n"
        f"{out_rule}"
    )


def _decision_choices_map(decision: dict[str, Any]) -> dict[str, Any]:
    if "choices" in decision:
        return coerce_choices_map(decision.get("choices"))
    return coerce_choices_map(
        {k: v for k, v in decision.items() if re.fullmatch(r"-?\d+", str(k))}
    )


def _complete_and_parse_decision(
    client: _ChatClient,
    prompt: str,
    *,
    request_id: str,
    model: str,
    verbose: bool,
    label: str,
    required_ids: list[str] | None = None,
    tool_ctx: Any | None = None,
    style_injection: str | None = None,
    payload: dict[str, Any] | None = None,
) -> tuple[str, str, dict[str, Any]]:
    """One LLM call (or ToolLoop draft) → (raw, reasoning, decision_dict)."""
    from civ_mcp.haikesi_tools.runner import ToolLoopRunner, llm_tools_enabled

    if verbose:
        mode = "tools" if tool_ctx is not None and llm_tools_enabled() else "plain"
        print(
            f"Calling {model} [{label}/{mode}] (prompt ~{len(prompt)} chars) ...",
            flush=True,
        )

    if (
        tool_ctx is not None
        and llm_tools_enabled()
        and label == "draft"
        and hasattr(client, "complete_with_tools")
    ):
        try:
            loop_result = ToolLoopRunner.run(
                client,  # type: ignore[arg-type]
                user_prompt=prompt,
                tool_ctx=tool_ctx,
                style_injection=style_injection,
            )
            raw = loop_result.text
            reasoning = loop_result.reasoning or _client_last_reasoning(client)
            if not reasoning:
                reasoning, _ = _split_visible_thinking(raw)
            # ToolLoop 终局：DeepSeek 常把 JSON 只放在 reasoning；先抠再跟进，避免整轮 repair。
            if _extract_json_object(raw) is None:
                from_reasoning = (
                    _extract_json_object(reasoning) if reasoning else None
                )
                if from_reasoning and '"choices"' in from_reasoning:
                    log.warning(
                        "ToolLoop text missing JSON; using reasoning extract "
                        "(text_chars=%s)",
                        len(raw or ""),
                    )
                    raw = from_reasoning
                elif hasattr(client, "_json_only_followup"):
                    recovered = client._json_only_followup(  # type: ignore[attr-defined]
                        draft_text=reasoning or raw or "",
                        required_ids=required_ids,
                        payload=payload,
                    )
                    if recovered and _extract_json_object(recovered):
                        log.warning(
                            "ToolLoop recovered JSON via followup "
                            "(text_chars=%s reasoning_chars=%s)",
                            len(raw or ""),
                            len(reasoning or ""),
                        )
                        if verbose:
                            print(
                                "ToolLoop: JSON followup recovered "
                                f"[{label}] ...",
                                flush=True,
                            )
                        raw = recovered
            # 跟进 JSON 常串领袖/漏双选：有 payload 时立刻按池再跟一次
            raw = _maybe_pool_repair_followup(
                client,
                raw=raw,
                reasoning=reasoning,
                required_ids=required_ids,
                payload=payload,
                verbose=verbose,
                label=label,
            )
        except Exception as exc:  # noqa: BLE001
            log.warning("ToolLoop failed (%s); falling back to plain complete", exc)
            if verbose:
                print(f"ToolLoop failed ({exc}); plain fallback...", flush=True)
            raw = client.complete(prompt, required_ids=required_ids)
            reasoning = _client_last_reasoning(client)
            if not reasoning:
                reasoning, _ = _split_visible_thinking(raw)
    else:
        raw = client.complete(prompt, required_ids=required_ids)
        reasoning = _client_last_reasoning(client)
        if not reasoning:
            reasoning, _ = _split_visible_thinking(raw)
        raw = _maybe_pool_repair_followup(
            client,
            raw=raw,
            reasoning=reasoning,
            required_ids=required_ids,
            payload=payload,
            verbose=verbose,
            label=label,
        )

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
            print(f"LLM JSON parse failed ({exc}); retrying once [{label}] ...", flush=True)
        repair_prompt = (
            prompt
            + "\n\n【重试】你上次输出的 JSON 不合法（字符串未闭合或被截断）。"
            "请先完成推演（若开启 thinking），再输出一个完整合法的 JSON 对象，不要 markdown；"
            "reasons 内只用中文逗号/句号，禁止英文双引号。"
        )
        if required_ids:
            repair_prompt += (
                f"\nchoices 必须包含全部键：{','.join(required_ids)}（缺一不可）。"
            )
        if payload:
            repair_prompt += (
                "\n每位领袖只能从下列 ID 原样复制（注意 picks 数量）：\n"
                f"{format_options_constraint(payload)}\n"
            )
        raw = client.complete(repair_prompt, required_ids=required_ids)
        reasoning = _client_last_reasoning(client) or reasoning
        if not reasoning:
            reasoning, _ = _split_visible_thinking(raw)
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
                f"LLM returned invalid JSON after retry ({label}): {exc2}"
            ) from exc2
    return raw, reasoning, decision


def _maybe_pool_repair_followup(
    client: _ChatClient,
    *,
    raw: str,
    reasoning: str,
    required_ids: list[str] | None,
    payload: dict[str, Any] | None,
    verbose: bool,
    label: str,
) -> str:
    """若已解析 JSON 但越池/少选，立刻用带候选表的短 followup 改正（避免盲 coerce）。"""
    if not payload or not hasattr(client, "_json_only_followup"):
        return raw
    try:
        probe = parse_llm_json(raw)
    except (json.JSONDecodeError, TypeError, ValueError):
        return raw
    cmap = _decision_choices_map(probe)
    viol = validate_choices_against_options(cmap, payload)
    if required_ids:
        miss = missing_choice_ids(cmap, required_ids)
        if miss:
            viol = list(viol) + [f"missing keys: {','.join(miss)}"]
    if not viol:
        return raw
    if verbose:
        print(
            f"Pool check early [{label}]: "
            + "; ".join(viol[:4])
            + (" ..." if len(viol) > 4 else "")
            + "; JSON followup ...",
            flush=True,
        )
    recovered = client._json_only_followup(  # type: ignore[attr-defined]
        draft_text=reasoning or raw or "",
        required_ids=required_ids,
        partial_choices=cmap,
        payload=payload,
        violations=viol,
    )
    if recovered and _extract_json_object(recovered):
        try:
            fixed = parse_llm_json(recovered)
            fixed_map = _decision_choices_map(fixed)
            still = validate_choices_against_options(fixed_map, payload)
            if required_ids:
                miss2 = missing_choice_ids(fixed_map, required_ids)
                if miss2:
                    still = list(still) + [f"missing keys: {','.join(miss2)}"]
            if not still:
                log.warning("Pool followup fixed choices after ToolLoop/parse")
                if verbose:
                    print(f"Pool followup OK [{label}].", flush=True)
                return recovered
            log.warning(
                "Pool followup still invalid (%s); keep for later repair",
                "; ".join(still[:4]),
            )
            # 仍用改进版（通常比串台版好）
            return recovered
        except (json.JSONDecodeError, TypeError, ValueError):
            pass
    return raw


def _ensure_all_choices(
    client: _ChatClient,
    *,
    base_prompt: str,
    decision: dict[str, Any],
    reasoning: str,
    required_ids: list[str],
    request_id: str,
    model: str,
    verbose: bool,
) -> dict[str, Any]:
    """若 choices 缺领袖，带着完整局面再补全（最多 2 次）。"""
    choices_map = _decision_choices_map(decision)
    missing = missing_choice_ids(choices_map, required_ids)
    if not missing:
        decision["choices"] = choices_map
        return decision

    for attempt in range(1, 3):
        if verbose:
            print(
                f"Incomplete choices got {len(choices_map)}/{len(required_ids)} "
                f"missing={missing}; fill attempt {attempt}/2 ...",
                flush=True,
            )
        fill_prompt = (
            f"{base_prompt}\n\n"
            f"---\n"
            f"## 补全缺失 choices（第 {attempt} 次）\n"
            f"上一轮 choices 不完整：\n"
            f"{json.dumps(choices_map, ensure_ascii=False)}\n"
            f"缺少领袖编号：{', '.join(missing)}\n"
            f"必须输出完整 JSON，choices 键必须全部包含："
            f"{', '.join(required_ids)}\n"
            f"可保留已有合理选择并补全缺失项。禁止 markdown。"
            f"禁止把 A 领袖候选填到 B；每人 picks 与合法 ID 见局面各领袖区块。\n"
        )
        if reasoning:
            fill_prompt += f"\n参考推演摘要：\n{reasoning[:8000]}\n"
        raw = client.complete(fill_prompt, required_ids=required_ids)
        try:
            filled = parse_llm_json(raw)
        except json.JSONDecodeError:
            # 尝试仅 JSON followup 路径已在 complete 内；再失败则继续
            if verbose:
                print("Fill parse failed; retrying ...", flush=True)
            continue
        new_map = merge_choice_dicts(choices_map, _decision_choices_map(filled))
        # 合并 reasons
        old_r = coerce_reasons_map(decision.get("reasons"))
        new_r = coerce_reasons_map(filled.get("reasons"))
        decision = {
            "choices": new_map,
            "reasons": merge_choice_dicts(old_r, new_r),
        }
        choices_map = new_map
        missing = missing_choice_ids(choices_map, required_ids)
        if not missing:
            if verbose:
                print(f"Choices complete after fill ({len(choices_map)}/{len(required_ids)}).", flush=True)
            return decision
    raise RuntimeError(
        f"incomplete choices after fill: got {len(choices_map)} expected {len(required_ids)} "
        f"missing={missing} (request {request_id})"
    )


def _ensure_valid_pool_choices(
    client: _ChatClient,
    *,
    base_prompt: str,
    decision: dict[str, Any],
    payload: dict[str, Any],
    required_ids: list[str],
    request_id: str,
    model: str,
    verbose: bool,
    draft_choices: dict[str, Any] | None = None,
) -> dict[str, Any]:
    """拒绝幻觉/越池类型。优先回退合法初稿 → 再 LLM 重修 → 再候选池前 N 张。"""
    choices_map = _decision_choices_map(decision)
    choices_map, chaos_changed = enforce_chaos_mutex_choices(choices_map, payload)
    if chaos_changed:
        decision["choices"] = choices_map
        if verbose:
            print(
                "Chaos mutex: max 1 interference/round; replaced for AI "
                + ", ".join(chaos_changed),
                flush=True,
            )
    violations = validate_choices_against_options(choices_map, payload)
    if not violations:
        decision["choices"] = choices_map
        return decision

    if verbose:
        print(
            "Invalid pool choices: "
            + "; ".join(violations[:6])
            + (" ..." if len(violations) > 6 else ""),
            flush=True,
        )

    if draft_choices:
        restored, reverted = revert_invalid_picks_to_draft(
            choices_map, draft_choices, payload
        )
        if reverted:
            choices_map = restored
            if verbose:
                print(
                    f"Reverted illegal review picks to draft for AI: "
                    f"{', '.join(reverted)}",
                    flush=True,
                )
            violations = validate_choices_against_options(choices_map, payload)
            if not violations:
                decision["choices"] = choices_map
                decision["_reverted_to_draft"] = reverted
                if verbose:
                    print("Pool OK after draft revert (skip LLM repair).", flush=True)
                return decision

    if verbose:
        print("Repairing against candidate pools ...", flush=True)

    # 先短 followup（带每人候选表），比整份 prompt 重修便宜且更贴约束
    if hasattr(client, "_json_only_followup"):
        recovered = client._json_only_followup(  # type: ignore[attr-defined]
            draft_text=json.dumps(
                {"choices": choices_map, "violations": violations},
                ensure_ascii=False,
            ),
            required_ids=required_ids or None,
            partial_choices=choices_map,
            payload=payload,
            violations=violations,
        )
        if recovered and _extract_json_object(recovered):
            try:
                repaired = parse_llm_json(recovered)
                new_map = dict(choices_map)
                new_map.update(_decision_choices_map(repaired))
                old_r = coerce_reasons_map(decision.get("reasons"))
                new_r = coerce_reasons_map(repaired.get("reasons"))
                trial = {
                    "choices": new_map,
                    "reasons": merge_choice_dicts(old_r, new_r),
                }
                trial_viol = validate_choices_against_options(new_map, payload)
                if not trial_viol:
                    if verbose:
                        print("Pool repair OK (compact followup).", flush=True)
                    return trial
                choices_map = new_map
                decision = trial
                violations = trial_viol
                if verbose:
                    print(
                        "Compact pool followup still invalid; full repair ...",
                        flush=True,
                    )
            except (json.JSONDecodeError, TypeError, ValueError):
                pass

    constraint = format_options_constraint(payload)
    repair_prompt = (
        f"{base_prompt}\n\n"
        f"---\n"
        f"## 候选池校验失败（必须重修）\n"
        f"上一轮 choices 含有**不在该领袖本轮候选列表**中的类型，或 picks 数量不对"
        f"（禁止编造如 NW_AI_BALANCED / NW_AI_CONQUEST_*；禁止把 A 的候选填给 B）：\n"
        f"{json.dumps(choices_map, ensure_ascii=False)}\n\n"
        f"违规：\n- " + "\n- ".join(violations) + "\n\n"
        f"每位领袖只能从下列**完整类型字符串**中原样复制（注意选几张）：\n"
        f"{constraint}\n\n"
        f"输出合法 JSON：choices 键必须全部包含 {', '.join(required_ids)}；"
        f"{'不要 reasons；' if reason_mode() == 'off' else 'reasons 禁止英文双引号；'}"
        f"禁止 markdown。\n"
    )
    try:
        raw = client.complete(repair_prompt, required_ids=required_ids or None)
        repaired = parse_llm_json(raw)
        new_map = dict(choices_map)
        new_map.update(_decision_choices_map(repaired))
        old_r = coerce_reasons_map(decision.get("reasons"))
        new_r = coerce_reasons_map(repaired.get("reasons"))
        decision = {
            "choices": new_map,
            "reasons": merge_choice_dicts(old_r, new_r),
        }
        choices_map = new_map
        violations = validate_choices_against_options(choices_map, payload)
    except (json.JSONDecodeError, RuntimeError, OSError) as exc:
        if verbose:
            print(f"Pool repair LLM failed ({exc}); coercing to options.", flush=True)
        violations = ["repair failed"]

    if violations:
        coerced = coerce_choices_to_options(choices_map, payload)
        coerced, chaos_changed2 = enforce_chaos_mutex_choices(coerced, payload)
        if verbose:
            print(
                f"Coerced invalid picks to pool fallback: "
                f"{json.dumps(coerced, ensure_ascii=False)}",
                flush=True,
            )
            if chaos_changed2:
                print(
                    "Chaos mutex after coerce; replaced for AI "
                    + ", ".join(chaos_changed2),
                    flush=True,
                )
        decision = {
            "choices": coerced,
            "reasons": coerce_reasons_map(decision.get("reasons")),
            "_pool_coerced": True,
            "_pool_violations": violations,
        }
        still = validate_choices_against_options(coerced, payload)
        if still:
            raise RuntimeError(
                f"pool coerce still invalid (request {request_id}): "
                + "; ".join(still)
            )
        return decision

    if verbose:
        print("Pool repair OK.", flush=True)
    decision["choices"] = choices_map
    return decision


def run_llm_decision_with_reviews(
    client: _ChatClient,
    model: str,
    prompt: str,
    *,
    request_id: str,
    required_ids: list[str] | None = None,
    payload: dict[str, Any] | None = None,
    review_client: _ChatClient | None = None,
    review_model: str | None = None,
    verbose: bool = True,
    tool_ctx: Any | None = None,
    style_injection: str | None = None,
) -> tuple[str, str, dict[str, Any]]:
    """初稿 + 可选多轮审查。

    ``review_client`` 若给定且不同于 draft，则为双模型（DeepSeek 初稿 / Grok 审查）。
    缺人补全与候选池修复优先用初稿客户端（DeepSeek 更稳跟格式约束）。
    ``tool_ctx`` 仅用于 draft ToolLoop（SP/MP 只读缓存）；审查轮不用 tools。
    ``style_injection`` 仅 draft ToolLoop 追加（通用+风格 Skill）。
    """
    from civ_mcp.llm_chat_session import (
        chat_session_enabled,
        load_or_create_chat_session,
    )

    dual = review_client is not None and review_client is not client
    rounds = llm_effective_review_rounds(dual=dual or llm_pipeline_mode() == "dual")
    rev_client = review_client or client
    rev_model = review_model or model
    req = required_ids or []

    chat_sess = None
    chat_token = None
    if payload is not None and chat_session_enabled():
        try:
            chat_sess = load_or_create_chat_session(payload, model=model)
            chat_token = _active_chat_session.set(chat_sess)
            if verbose:
                # 每轮都打完整 UUID，便于对照是否同一存档会话
                print(chat_sess.label(), flush=True)
                if chat_sess.status != "resumed":
                    print(
                        f"ChatSession {chat_sess.status.upper()} "
                        f"(file was missing/corrupt or first pick this save)",
                        flush=True,
                    )
        except Exception as exc:  # noqa: BLE001
            log.warning("chat session load failed: %s", exc)
            chat_sess = None
            chat_token = None

    try:
        raw, reasoning, decision = _complete_and_parse_decision(
            client,
            prompt,
            request_id=request_id,
            model=model,
            verbose=verbose,
            label="draft",
            required_ids=req or None,
            tool_ctx=tool_ctx,
            style_injection=style_injection,
            payload=payload,
        )
    finally:
        # 审查/修复不用多轮历史，避免把 review prompt 叠进对局记忆
        if chat_token is not None:
            _active_chat_session.reset(chat_token)
            chat_token = None

    draft_tag = f"draft ({model})" if dual else "draft"
    log_parts = [f"### Round 0 — {draft_tag}\n\n{reasoning or '*(no thinking text)*'}"]
    draft_choices = _decision_choices_map(decision)
    if rounds >= 1 and payload is not None:
        draft_path = save_draft_checkpoint_log(
            request_id=request_id,
            model=model,
            reasoning=reasoning,
            raw_response=raw,
            decision=decision,
            payload=payload,
            review_model=rev_model if dual or rounds else None,
        )
        if verbose and draft_path is not None:
            print(f"Draft checkpoint saved: {draft_path.name}", flush=True)
    for i in range(1, rounds + 1):
        if verbose:
            who = f"{rev_model} " if dual else ""
            print(f"Review {i}/{rounds} ({who.strip() or 'self'}) ...", flush=True)
        review_prompt = build_self_review_prompt(
            prompt,
            previous_reasoning=reasoning,
            previous_raw=raw,
            round_index=i,
            total_rounds=rounds,
        )
        if dual:
            review_prompt += (
                "\n\n【双模型审查】上一轮由另一模型起草；你只负责纠错与改选。"
                "必须从每位领袖候选列表原样复制类型 ID，禁止编造 NW_AI_*"
                "（禁止 MOUNTAIN_PASS / DESERT_STORM / TRADE_ROUTE 等幻觉名）。\n"
                "若上轮选择合法且合理，可维持；非法类型必须改回候选列表内的 ID。\n"
                "禁止把「历史库存/效果说明」里的类型当成该领袖本轮候选；"
                "文化主战略也不代表本轮一定有 NW_AI_STATS_1。\n"
            )
        if req:
            review_prompt += (
                f"\n\n【强制】最终 choices 必须包含全部键：{','.join(req)}（缺一不可）。"
            )
        if payload:
            review_prompt += (
                "\n【强制】每位领袖 choices 只能从下列本轮合法 ID 中原样复制"
                "（历史库存中的类型若未出现在此表则不可选）：\n"
                f"{format_options_constraint(payload)}\n"
            )
        raw, reasoning, decision = _complete_and_parse_decision(
            rev_client,
            review_prompt,
            request_id=request_id,
            model=rev_model,
            verbose=verbose,
            label=f"review-{i}",
            required_ids=req or None,
            payload=payload,
        )
        rev_tag = f"review ({rev_model})" if dual else "self-review"
        log_parts.append(
            f"### Round {i} — {rev_tag}\n\n{reasoning or '*(no thinking text)*'}"
        )
    # 补全/池修复：dual 时优先 DeepSeek（跟格式更稳），不论它是初稿还是审查
    if dual:
        if _client_looks_deepseek(rev_client):
            fix_client, fix_model = rev_client, rev_model
        elif _client_looks_deepseek(client):
            fix_client, fix_model = client, model
        else:
            fix_client, fix_model = rev_client, rev_model
    else:
        fix_client, fix_model = rev_client, rev_model
    if req:
        decision = _ensure_all_choices(
            fix_client,
            base_prompt=prompt,
            decision=decision,
            reasoning=reasoning,
            required_ids=req,
            request_id=request_id,
            model=fix_model,
            verbose=verbose,
        )
    if payload:
        decision = _ensure_valid_pool_choices(
            fix_client,
            base_prompt=prompt,
            decision=decision,
            payload=payload,
            required_ids=req,
            request_id=request_id,
            model=fix_model,
            verbose=verbose,
            draft_choices=draft_choices,
        )
        raw = json.dumps(
            {
                "choices": decision.get("choices"),
                "reasons": decision.get("reasons"),
            },
            ensure_ascii=False,
            indent=2,
        )
    elif req:
        raw = json.dumps(decision, ensure_ascii=False, indent=2)

    combined = "\n\n---\n\n".join(log_parts)
    if rounds and verbose:
        print(f"Reviews done ({rounds}); using final choices.", flush=True)
    return raw, combined, decision


def commit_chat_session_after_success(
    payload: dict[str, Any],
    decision: dict[str, Any],
    *,
    request_id: str,
    model: str,
    verbose: bool = True,
) -> None:
    """Submit/publish 成功后再写入多轮会话，避免失败重试污染历史。"""
    from civ_mcp.llm_chat_session import chat_session_enabled, load_or_create_chat_session

    if not chat_session_enabled():
        return
    try:
        chat_sess = load_or_create_chat_session(payload, model=model)
        commit_body = json.dumps(
            {
                "choices": decision.get("choices"),
                "reasons": decision.get("reasons"),
            },
            ensure_ascii=False,
        )
        chat_sess.commit_decision_turn(
            request_id=request_id,
            turn=payload.get("turn"),
            human_relic=payload.get("human_relic"),
            assistant_json=commit_body,
            model=model,
        )
        if verbose:
            print(
                f"ChatSession committed: id={chat_sess.session_id} "
                f"turns={chat_sess.turn_count}",
                flush=True,
            )
    except Exception as exc:  # noqa: BLE001
        log.warning("chat session commit failed: %s", exc)


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
    review_client: _ChatClient | None = None,
    review_model: str | None = None,
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

    from civ_mcp.haikesi_tools import DecisionToolContext, llm_tools_enabled
    from civ_mcp.haikesi_styles import (
        assign_styles_for_payload,
        build_style_injection,
        format_styles_dice_json,
        format_styles_meta,
        llm_styles_enabled,
        styles_for_session_lock,
    )
    from civ_mcp.llm_chat_session import chat_session_enabled, load_or_create_chat_session

    tool_ctx = None
    style_by_pid: dict[int, Any] = {}
    style_injection: str | None = None
    style_meta: str | None = None
    style_dice_json: str | None = None
    if llm_tools_enabled():
        tool_ctx = DecisionToolContext(
            context=context, payload=payload, channel="tuner"
        )
        if llm_styles_enabled():
            locked: dict[str, str] = {}
            if chat_session_enabled():
                try:
                    sess = load_or_create_chat_session(payload, model=model)
                    locked = dict(sess.styles or {})
                except Exception as exc:  # noqa: BLE001
                    log.warning("style lock load failed: %s", exc)
            style_by_pid = assign_styles_for_payload(
                payload, context, locked=locked
            )
            style_injection = build_style_injection(style_by_pid) or None
            style_meta = format_styles_meta(style_by_pid) or None
            style_dice_json = format_styles_dice_json(style_by_pid) or None
            if chat_session_enabled() and style_by_pid:
                try:
                    sess = load_or_create_chat_session(payload, model=model)
                    sess.set_styles(styles_for_session_lock(style_by_pid))
                except Exception as exc:  # noqa: BLE001
                    log.warning("style lock save failed: %s", exc)
            if verbose and style_meta:
                print(f"Styles: {style_meta}", flush=True)
        prompt = build_decision_prompt_slim(
            payload, context, style_by_pid=style_by_pid
        )
        if verbose:
            print(
                f"Tools ON (tuner); slim prompt ~{len(prompt)} chars"
                + (
                    f"; style inject ~{len(style_injection)} chars"
                    if style_injection
                    else ""
                ),
                flush=True,
            )
    else:
        prompt = build_decision_prompt(payload, context)
    required_ids = expected_choice_ids(payload)

    if not required_ids:
        if verbose:
            print(
                f"All AI pools empty for {request_id!r}; cancelling ExtAI request.",
                flush=True,
            )
        cancel_lines = await conn.execute_haikesi(
            haikesi_lua.build_cancel_ai_request_lua(request_id)
        )
        result = haikesi_lua.summarize_submit_result(cancel_lines)
        # Cancel prints OK:cancelled — treat as handled
        if verbose:
            print(f"Cancel result: {result}", flush=True)
        return True

    model_label = model
    if review_client is not None and review_model and review_client is not client:
        model_label = f"{model} → {review_model}"

    raw, reasoning, decision = run_llm_decision_with_reviews(
        client,
        model,
        prompt,
        request_id=request_id,
        required_ids=required_ids,
        payload=payload,
        review_client=review_client,
        review_model=review_model,
        verbose=verbose,
        tool_ctx=tool_ctx,
        style_injection=style_injection,
    )

    choices_map = _decision_choices_map(decision)
    choices = haikesi_lua.normalize_extai_choices(
        choices_map,
        payload.get("ai_players") or [],
    )
    raw_reasons = {
        str(k): v for k, v in coerce_reasons_map(decision.get("reasons")).items()
    }
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
        raise RuntimeError(
            "LLM returned empty choices "
            f"(raw choices type={type(decision.get('choices')).__name__})"
        )

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
    commit_chat_session_after_success(
        payload,
        decision,
        request_id=request_id,
        model=model,
        verbose=verbose,
    )
    try:
        save_decision_analysis_log(
            request_id=request_id,
            model=model_label,
            prompt=prompt,
            raw_response=raw,
            reasoning=reasoning,
            choices=choices,
            reasons=reasons,
            wire=wire,
            payload=payload,
            tool_trace=(tool_ctx.tool_trace if tool_ctx is not None else None),
            tool_channel=(tool_ctx.channel if tool_ctx is not None else None),
            style_meta=style_meta,
            style_dice_json=style_dice_json,
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
    review_client: _ChatClient | None = None,
    review_model: str | None = None,
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

    from civ_mcp.haikesi_tools import DecisionToolContext, llm_tools_enabled
    from civ_mcp.haikesi_styles import (
        assign_styles_for_payload,
        build_style_injection,
        format_styles_dice_json,
        format_styles_meta,
        llm_styles_enabled,
        styles_for_session_lock,
    )
    from civ_mcp.llm_chat_session import chat_session_enabled, load_or_create_chat_session

    tool_ctx = None
    style_by_pid: dict[int, Any] = {}
    style_injection: str | None = None
    style_meta: str | None = None
    style_dice_json: str | None = None
    if llm_tools_enabled():
        tool_ctx = DecisionToolContext(
            context=context, payload=payload, channel="log"
        )
        if llm_styles_enabled():
            locked: dict[str, str] = {}
            if chat_session_enabled():
                try:
                    sess = load_or_create_chat_session(payload, model=model)
                    locked = dict(sess.styles or {})
                except Exception as exc:  # noqa: BLE001
                    log.warning("style lock load failed: %s", exc)
            style_by_pid = assign_styles_for_payload(
                payload, context, locked=locked
            )
            style_injection = build_style_injection(style_by_pid) or None
            style_meta = format_styles_meta(style_by_pid) or None
            style_dice_json = format_styles_dice_json(style_by_pid) or None
            if chat_session_enabled() and style_by_pid:
                try:
                    sess = load_or_create_chat_session(payload, model=model)
                    sess.set_styles(styles_for_session_lock(style_by_pid))
                except Exception as exc:  # noqa: BLE001
                    log.warning("style lock save failed: %s", exc)
            if verbose and style_meta:
                print(f"Styles: {style_meta}", flush=True)
        prompt = build_decision_prompt_slim(
            payload, context, style_by_pid=style_by_pid
        )
        if verbose:
            print(
                f"Tools ON (log/CTX); slim prompt ~{len(prompt)} chars"
                + (
                    f"; style inject ~{len(style_injection)} chars"
                    if style_injection
                    else ""
                ),
                flush=True,
            )
    else:
        prompt = build_decision_prompt(payload, context)
    required_ids = expected_choice_ids(payload)
    model_label = model
    if review_client is not None and review_model and review_client is not client:
        model_label = f"{model} → {review_model}"

    if not required_ids:
        if verbose:
            print(
                f"All AI pools empty for {request_id!r} (LOG); skip LLM "
                "(host should clear pending / no ExtAI cards).",
                flush=True,
            )
        return True

    raw, reasoning, decision = run_llm_decision_with_reviews(
        client,
        model,
        prompt,
        request_id=request_id,
        required_ids=required_ids,
        payload=payload,
        review_client=review_client,
        review_model=review_model,
        verbose=verbose,
        tool_ctx=tool_ctx,
        style_injection=style_injection,
    )

    choices_map = _decision_choices_map(decision)
    choices = haikesi_lua.normalize_extai_choices(
        choices_map,
        payload.get("ai_players") or [],
    )
    raw_reasons = {
        str(k): v for k, v in coerce_reasons_map(decision.get("reasons")).items()
    }
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
        raise RuntimeError(
            "LLM returned empty choices "
            f"(raw choices type={type(decision.get('choices')).__name__})"
        )

    # 游戏内只注入选卡；理由仅留在 decision 日志（金/英双选 wire 为 A+B）
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
            model=model_label,
            prompt=prompt,
            raw_response=raw,
            reasoning=reasoning,
            choices=choices,
            reasons=reasons,
            wire=wire,
            payload=payload,
            tool_trace=(tool_ctx.tool_trace if tool_ctx is not None else None),
            tool_channel=(tool_ctx.channel if tool_ctx is not None else None),
            style_meta=style_meta,
            style_dice_json=style_dice_json,
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
    commit_chat_session_after_success(
        payload,
        decision,
        request_id=request_id,
        model=model,
        verbose=verbose,
    )
    if verbose:
        print(
            f"Publish OK: {request_id!r} — Ctrl+V in game; "
            f"Ctrl+C safe (clipboard + apply.txt + decision log)",
            flush=True,
        )
    return True
