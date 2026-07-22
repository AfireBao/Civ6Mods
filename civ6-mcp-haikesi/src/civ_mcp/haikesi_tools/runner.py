"""ToolLoop runner — Immersive-style complete → resolve → repeat."""

from __future__ import annotations

import json
import logging
import os
from dataclasses import dataclass, field
from typing import Any, Protocol

from civ_mcp.haikesi_tools.context_cache import DecisionToolContext
from civ_mcp.haikesi_tools.definitions import openai_tools_schema
from civ_mcp.haikesi_tools.handlers import NOTHING_SURFACES, resolve_tool

log = logging.getLogger(__name__)


def llm_tools_enabled() -> bool:
    raw = (os.environ.get("HAIKESI_LLM_TOOLS") or "0").strip().lower()
    return raw in {"1", "true", "yes", "on"}


def llm_tool_rounds() -> int:
    try:
        n = int(os.environ.get("HAIKESI_LLM_TOOL_ROUNDS") or "3")
    except ValueError:
        n = 3
    return max(1, min(n, 6))


@dataclass
class ToolCallSpec:
    id: str
    name: str
    arguments_json: str


@dataclass
class ChatResult:
    text: str = ""
    tool_calls: list[ToolCallSpec] = field(default_factory=list)
    reasoning: str = ""

    @property
    def wants_tools(self) -> bool:
        return bool(self.tool_calls)


@dataclass
class ToolLoopResult:
    text: str
    reasoning: str = ""
    tool_trace: list[dict[str, Any]] = field(default_factory=list)


class ToolCapableClient(Protocol):
    def complete_with_tools(
        self,
        messages: list[dict[str, Any]],
        tools: list[dict[str, Any]],
        *,
        allow_tool_use: bool = True,
    ) -> ChatResult: ...


class ToolLoopRunner:
    @staticmethod
    def run(
        client: ToolCapableClient,
        *,
        user_prompt: str,
        tool_ctx: DecisionToolContext,
        max_rounds: int | None = None,
        system_prompt: str | None = None,
    ) -> ToolLoopResult:
        rounds = max_rounds if max_rounds is not None else llm_tool_rounds()
        tools = openai_tools_schema()
        messages: list[dict[str, Any]] = []
        if system_prompt:
            messages.append({"role": "system", "content": system_prompt})
        messages.append({"role": "user", "content": user_prompt})

        spoken = ""
        reasoning = ""
        for round_i in range(rounds + 1):
            allow = round_i < rounds
            result = client.complete_with_tools(
                messages, tools, allow_tool_use=allow
            )
            if result.reasoning:
                reasoning = result.reasoning
            if result.text and result.text.strip():
                spoken = result.text

            if not result.wants_tools or not allow:
                return ToolLoopResult(
                    text=spoken or result.text or "",
                    reasoning=reasoning,
                    tool_trace=list(tool_ctx.tool_trace),
                )

            # Assistant turn with tool_calls (OpenAI shape)
            assistant_msg: dict[str, Any] = {
                "role": "assistant",
                "content": result.text or None,
                "tool_calls": [
                    {
                        "id": tc.id,
                        "type": "function",
                        "function": {
                            "name": tc.name,
                            "arguments": tc.arguments_json or "{}",
                        },
                    }
                    for tc in result.tool_calls
                ],
            }
            messages.append(assistant_msg)

            for tc in result.tool_calls:
                answer = resolve_tool(tool_ctx, tc.name, tc.arguments_json or "{}")
                if not (answer or "").strip():
                    answer = NOTHING_SURFACES
                messages.append(
                    {
                        "role": "tool",
                        "tool_call_id": tc.id,
                        "content": answer,
                    }
                )

        return ToolLoopResult(
            text=spoken,
            reasoning=reasoning,
            tool_trace=list(tool_ctx.tool_trace),
        )


def format_tool_trace_markdown(trace: list[dict[str, Any]]) -> str:
    if not trace:
        return "*(no tool calls)*"
    lines: list[str] = []
    for i, row in enumerate(trace, 1):
        args = json.dumps(row.get("arguments") or {}, ensure_ascii=False)
        lines.append(
            f"{i}. `{row.get('name')}` args={args} "
            f"→ {row.get('result_chars', 0)} chars\n"
            f"   > {row.get('result_preview', '')}"
        )
    return "\n".join(lines)
