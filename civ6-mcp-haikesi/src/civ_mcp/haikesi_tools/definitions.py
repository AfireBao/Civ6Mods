"""Native function-calling tool schemas for Haikesi ExtAI."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any


@dataclass(frozen=True)
class ToolDefinition:
    name: str
    description: str
    parameters: dict[str, Any]


TOOL_DEFINITIONS: list[ToolDefinition] = [
    ToolDefinition(
        name="leader_snapshot",
        description=(
            "按需读取某位本轮待决策领袖的可见概况：国力、主战略、宗教摘要、城市短板、"
            "边境威胁粗览。参数 player_id 必须是该领袖自己的 id；禁止查其他领袖。"
        ),
        parameters={
            "type": "object",
            "properties": {
                "player_id": {
                    "type": "integer",
                    "description": "本轮待决策领袖的 player_id（与 ### 领袖 N 的 N 相同）",
                }
            },
            "required": ["player_id"],
        },
    ),
    ToolDefinition(
        name="met_civ_detail",
        description=(
            "读取某领袖已相遇文明的外交/军力/不满明细。"
            "可指定 other_id；省略则返回该领袖全部已遇主要文明摘要。"
        ),
        parameters={
            "type": "object",
            "properties": {
                "player_id": {
                    "type": "integer",
                    "description": "观察者领袖 id（迷雾主体）",
                },
                "other_id": {
                    "type": "integer",
                    "description": "可选：已遇文明的 player_id",
                },
            },
            "required": ["player_id"],
        },
    ),
    ToolDefinition(
        name="lookup_relic",
        description=(
            "查阅海克斯模组本地权威词条：类型 ID 的中文名与效果说明。"
            "用于历史库存或候选以外的对照；本轮候选效果已在首包给出。"
        ),
        parameters={
            "type": "object",
            "properties": {
                "relic_type": {
                    "type": "string",
                    "description": "完整类型 ID，如 NW_AI_ECHO_MELEE",
                }
            },
            "required": ["relic_type"],
        },
    ),
    ToolDefinition(
        name="inventory_brief",
        description="列出某文明历史已持有海克斯的类型 ID 与短名（不含全文效果）。",
        parameters={
            "type": "object",
            "properties": {
                "player_id": {
                    "type": "integer",
                    "description": "文明/领袖 player_id",
                }
            },
            "required": ["player_id"],
        },
    ),
    ToolDefinition(
        name="check_echo_feasibility",
        description=(
            "评估某词条对该领袖是否可立即兑现、延迟或空放"
            "（0 城资源创建、军事 echo、商路条件等）。"
        ),
        parameters={
            "type": "object",
            "properties": {
                "player_id": {"type": "integer"},
                "relic_type": {"type": "string"},
            },
            "required": ["player_id", "relic_type"],
        },
    ),
    ToolDefinition(
        name="civ6_kb",
        description=(
            "查阅本地离线文明6规则摘要（宜居、区域、胜利条件等）。"
            "不联网；海克斯词条请用 lookup_relic。"
        ),
        parameters={
            "type": "object",
            "properties": {
                "topic": {
                    "type": "string",
                    "description": "主题关键词，如 amenity / district / victory / trade",
                }
            },
            "required": ["topic"],
        },
    ),
]


def openai_tools_schema() -> list[dict[str, Any]]:
    """OpenAI / OpenAI-compatible tools= payload."""
    out: list[dict[str, Any]] = []
    for t in TOOL_DEFINITIONS:
        out.append(
            {
                "type": "function",
                "function": {
                    "name": t.name,
                    "description": t.description,
                    "parameters": t.parameters,
                },
            }
        )
    return out
