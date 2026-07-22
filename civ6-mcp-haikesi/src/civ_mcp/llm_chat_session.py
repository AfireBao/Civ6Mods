"""Per-save LLM chat session (client-side multi-turn history).

智谱/OpenAI 兼容 Chat Completions 无服务端 session id；本模块按存档
``GameSessionKey`` 在决策归档目录持久化 ``messages``，实现「一局一个对话」。
丢失/损坏时新建；上下文过长时截断旧轮，必要时整段重建。
"""

from __future__ import annotations

import json
import os
import time
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Literal

from civ_mcp.decision_archive import (
    GameSessionKey,
    get_decision_archive,
)

_SESSION_FILE = "llm_chat_session.json"
_STATUS = Literal["resumed", "created", "recovered"]

_SYSTEM_PROMPT = (
    "你是文明6资深玩家，为多位 AI 领袖选海克斯。"
    "同一存档对局中多轮选卡可参考此前 choices 与局面变化；"
    "每轮仍须只根据**本轮用户消息**中的候选列表原样选 ID，禁止编造类型。"
    "输出格式以当轮用户消息末尾的规则为准。"
)


def chat_session_enabled() -> bool:
    raw = (os.environ.get("HAIKESI_LLM_CHAT_SESSION") or "1").strip().lower()
    return raw in {"1", "true", "yes", "on"}


def _env_int(name: str, default: int) -> int:
    raw = os.environ.get(name)
    if raw is None or str(raw).strip() == "":
        return default
    try:
        return int(str(raw).strip())
    except ValueError:
        return default


def max_history_turns() -> int:
    """保留最近 N 轮完整对（user+assistant）；不含当前轮。默认 6。"""
    return max(0, _env_int("HAIKESI_LLM_CHAT_HISTORY_TURNS", 6))


def max_history_chars() -> int:
    """历史消息总字符上限（不含当前 user prompt）。默认 ~120k。"""
    return max(8000, _env_int("HAIKESI_LLM_CHAT_HISTORY_CHARS", 120_000))


@dataclass
class LlmChatSession:
    session_id: str
    game_key: str
    path: Path
    status: _STATUS
    messages: list[dict[str, str]] = field(default_factory=list)
    turn_count: int = 0
    created_at: str = ""
    updated_at: str = ""
    model: str = ""
    # ExtAI leader styles (player_id str → style_id); inferred lock across picks
    styles: dict[str, str] = field(default_factory=dict)

    @property
    def short_id(self) -> str:
        return (self.session_id or "")[:12]

    def label(self) -> str:
        return (
            f"ChatSessionID={self.session_id} "
            f"status={self.status} turns={self.turn_count} "
            f"dir={self.path.parent.name}"
        )

    def build_api_messages(self, user_prompt: str) -> list[dict[str, str]]:
        """历史（已截断）+ 本轮完整局面 prompt。"""
        hist = list(self.messages)
        # 确保有 system
        if not hist or hist[0].get("role") != "system":
            hist = [{"role": "system", "content": _SYSTEM_PROMPT}] + [
                m for m in hist if m.get("role") != "system"
            ]
        hist = _trim_history(hist)
        return hist + [{"role": "user", "content": user_prompt}]

    def commit_decision_turn(
        self,
        *,
        request_id: str,
        turn: Any,
        human_relic: Any,
        assistant_json: str,
        model: str = "",
    ) -> None:
        """把本轮终稿写入历史：user 用短摘要，assistant 只留 JSON（控上下文）。"""
        now = time.strftime("%Y-%m-%d %H:%M:%S")
        if not self.messages or self.messages[0].get("role") != "system":
            self.messages = [{"role": "system", "content": _SYSTEM_PROMPT}] + [
                m for m in self.messages if m.get("role") != "system"
            ]
        user_summary = (
            f"[本轮选卡已结束] request_id={request_id} turn={turn} "
            f"human_relic={human_relic}。"
            f"下一轮请根据新局面重新选卡；勿照抄本轮 choices。"
        )
        asst = (assistant_json or "").strip()
        if len(asst) > 12000:
            asst = asst[:12000] + "\n…(截断)"
        self.messages.append({"role": "user", "content": user_summary})
        self.messages.append({"role": "assistant", "content": asst or "{}"})
        self.turn_count = int(self.turn_count or 0) + 1
        self.updated_at = now
        if model:
            self.model = model
        self.messages = _trim_history(self.messages)
        self.save()

    def reset(self, *, reason: str = "recovered") -> None:
        now = time.strftime("%Y-%m-%d %H:%M:%S")
        self.session_id = str(uuid.uuid4())
        self.status = "recovered" if reason == "recovered" else "created"
        self.messages = [{"role": "system", "content": _SYSTEM_PROMPT}]
        self.turn_count = 0
        self.created_at = now
        self.updated_at = now
        self.save()

    def set_styles(self, styles: dict[str, str]) -> None:
        """Merge style locks (empty style_id removes key)."""
        for k, v in (styles or {}).items():
            pid = str(k)
            sid = (v or "").strip()
            if sid:
                self.styles[pid] = sid
            elif pid in self.styles:
                del self.styles[pid]
        self.updated_at = time.strftime("%Y-%m-%d %H:%M:%S")
        self.save()

    def save(self) -> None:
        data = {
            "session_id": self.session_id,
            "game_key": self.game_key,
            "turn_count": self.turn_count,
            "created_at": self.created_at,
            "updated_at": self.updated_at or time.strftime("%Y-%m-%d %H:%M:%S"),
            "model": self.model,
            "messages": self.messages,
            "styles": self.styles,
        }
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.path.write_text(
            json.dumps(data, ensure_ascii=False, indent=2),
            encoding="utf-8",
        )


def _trim_history(messages: list[dict[str, str]]) -> list[dict[str, str]]:
    if not messages:
        return [{"role": "system", "content": _SYSTEM_PROMPT}]
    system = [m for m in messages if m.get("role") == "system"][:1]
    if not system:
        system = [{"role": "system", "content": _SYSTEM_PROMPT}]
    rest = [m for m in messages if m.get("role") != "system"]
    # 按轮截断：一对 user+assistant
    max_turns = max_history_turns()
    pairs: list[list[dict[str, str]]] = []
    i = 0
    while i < len(rest):
        if (
            i + 1 < len(rest)
            and rest[i].get("role") == "user"
            and rest[i + 1].get("role") == "assistant"
        ):
            pairs.append([rest[i], rest[i + 1]])
            i += 2
        else:
            # 落单消息并入
            pairs.append([rest[i]])
            i += 1
    if max_turns >= 0 and len(pairs) > max_turns:
        pairs = pairs[-max_turns:]
    out = system + [m for pair in pairs for m in pair]
    # 字符上限：从最旧 pair 丢掉
    budget = max_history_chars()
    while True:
        total = sum(len(m.get("content") or "") for m in out)
        if total <= budget or len(out) <= 1:
            break
        # 删掉 system 后的前两条（最旧一轮）
        if len(out) >= 3:
            out = [out[0]] + out[3:]
        else:
            break
    return out


def _load_file(path: Path) -> dict[str, Any] | None:
    if not path.is_file():
        return None
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    if not isinstance(data, dict):
        return None
    sid = data.get("session_id")
    if not sid or not isinstance(sid, str):
        return None
    msgs = data.get("messages")
    if msgs is not None and not isinstance(msgs, list):
        return None
    return data


def load_or_create_chat_session(
    payload: dict[str, Any],
    *,
    model: str = "",
) -> LlmChatSession:
    """绑定当前存档对局的 LLM 对话；文件丢失/损坏则新建。"""
    archive = get_decision_archive()
    session_dir = archive.resolve_session_dir(payload)
    key = GameSessionKey.from_payload(payload).stable_id()
    path = session_dir / _SESSION_FILE
    now = time.strftime("%Y-%m-%d %H:%M:%S")

    data = _load_file(path)
    if data is not None:
        game_key = str(data.get("game_key") or "")
        if game_key and game_key != key:
            # 目录被复用但 key 变了 → 新建
            data = None
        else:
            msgs = data.get("messages") or []
            clean: list[dict[str, str]] = []
            for m in msgs:
                if not isinstance(m, dict):
                    continue
                role = str(m.get("role") or "")
                content = str(m.get("content") or "")
                if role in {"system", "user", "assistant"} and content:
                    clean.append({"role": role, "content": content})
            raw_styles = data.get("styles") or {}
            styles: dict[str, str] = {}
            if isinstance(raw_styles, dict):
                for sk, sv in raw_styles.items():
                    if str(sv).strip():
                        styles[str(sk)] = str(sv).strip()
            return LlmChatSession(
                session_id=str(data["session_id"]),
                game_key=key,
                path=path,
                status="resumed",
                messages=clean
                or [{"role": "system", "content": _SYSTEM_PROMPT}],
                turn_count=int(data.get("turn_count") or 0),
                created_at=str(data.get("created_at") or now),
                updated_at=str(data.get("updated_at") or now),
                model=str(data.get("model") or model or ""),
                styles=styles,
            )

    # created or recovered (file missing / corrupt)
    status: _STATUS = "recovered" if path.exists() else "created"
    sess = LlmChatSession(
        session_id=str(uuid.uuid4()),
        game_key=key,
        path=path,
        status=status,
        messages=[{"role": "system", "content": _SYSTEM_PROMPT}],
        turn_count=0,
        created_at=now,
        updated_at=now,
        model=model,
    )
    sess.save()
    return sess
