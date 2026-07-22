"""Native function-calling tool schemas for Haikesi ExtAI."""

from __future__ import annotations

from dataclasses import dataclass
from typing import Any


@dataclass(frozen=True)
class ToolDefinition:
    name: str
    description: str
    parameters: dict[str, Any]


_PID = {
    "type": "integer",
    "description": "本轮待决策领袖的 player_id（与 ### 领袖 N 的 N 相同）",
}

TOOL_DEFINITIONS: list[ToolDefinition] = [
    ToolDefinition(
        name="leader_snapshot",
        description=(
            "领袖概览（国力、RST、商路、宜居粗览）。极短况已有城数/军力/交战时勿重复调用；"
            "仅当需要商路容量或宜居细节时使用。在建/贴脸请改用 city_pressure / border_threats。"
        ),
        parameters={
            "type": "object",
            "properties": {"player_id": _PID},
            "required": ["player_id"],
        },
    ),
    ToolDefinition(
        name="city_pressure",
        description=(
            "读取缓存中的本国城市：人口、在建项目与剩余回合、宜居赤字。"
            "军事 echo / 产线协同前应调用（石弩=攻城≠远程）。只读本轮 gather 缓存。"
        ),
        parameters={
            "type": "object",
            "properties": {"player_id": _PID},
            "required": ["player_id"],
        },
    ),
    ToolDefinition(
        name="border_threats",
        description=(
            "读取缓存中的边境可见单位聚合：势力、可见数、最近距离、关系。"
            "交战或贴脸压力评估时使用。只读本轮 gather 缓存。"
        ),
        parameters={
            "type": "object",
            "properties": {"player_id": _PID},
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
            "查阅海克斯本地词条（中文名+效果）。仅用于历史库存或候选以外的对照；"
            "本轮候选全文已在首包——禁止对本轮候选 ID 再查一遍。"
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
            "properties": {"player_id": _PID},
            "required": ["player_id"],
        },
    ),
    ToolDefinition(
        name="check_echo_feasibility",
        description=(
            "评估某词条对该领袖是否可立即兑现、延迟或空放"
            "（0 城资源创建、军事 echo、商路条件等）。"
            "军事 echo 建议先 city_pressure 核对在建兵种。"
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
            "本地策略短篇：amenity / district / victory / trade。"
            "不要用来查单位/建筑专名（用 civilopedia_lookup）；"
            "不要用来查海克斯（用 lookup_relic）。不联网。"
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
    ToolDefinition(
        name="civilopedia_lookup",
        description=(
            "本地 Civilopedia/海克斯词典：中文名或类型 ID（UNIT_/TECH_/BUILDING_ 等）。"
            "用于兵种分类、科技解锁等原版专名；chapter=haikesi 可查海克斯章节。"
            "本轮候选海克斯效果已在首包，勿重复查询。不联网。"
        ),
        parameters={
            "type": "object",
            "properties": {
                "query": {
                    "type": "string",
                    "description": "中文名、类型 ID 或关键词",
                },
                "chapter": {
                    "type": "string",
                    "description": "可选：civilopedia | haikesi",
                },
                "limit": {
                    "type": "integer",
                    "description": "返回条数，默认 3，最大 8",
                },
            },
            "required": ["query"],
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
