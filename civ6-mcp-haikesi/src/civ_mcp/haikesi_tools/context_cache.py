"""Per-decision read-only cache shared by SP (Tuner) and MP (Lua.log CTX)."""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Literal

Channel = Literal["tuner", "log"]


@dataclass
class DecisionToolContext:
    """Filled once before ToolLoop; handlers must not call GameConnection.

    ``context`` is a HaikesiGameContext instance (avoid importing haikesi_llm here
    to prevent circular imports).
    """

    context: Any
    payload: dict[str, Any]
    channel: Channel = "tuner"
    allowed_player_ids: set[int] = field(default_factory=set)
    tool_trace: list[dict[str, Any]] = field(default_factory=list)

    def __post_init__(self) -> None:
        if not self.allowed_player_ids:
            ids: set[int] = set()
            for ai in self.payload.get("ai_players") or []:
                try:
                    ids.add(int(ai["player_id"]))
                except (KeyError, TypeError, ValueError):
                    continue
            self.allowed_player_ids = ids

    def record(self, name: str, arguments: dict[str, Any], result: str) -> None:
        self.tool_trace.append(
            {
                "name": name,
                "arguments": arguments,
                "result_chars": len(result or ""),
                "result_preview": (result or "")[:240],
            }
        )
