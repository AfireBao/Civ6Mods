"""Per-game decision log archive (one folder per save / new game)."""

from __future__ import annotations

import json
import os
import re
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

_PKG_ROOT = Path(__file__).resolve().parents[2]
_DEFAULT_ARCHIVE_DIR = _PKG_ROOT / "logs" / "decisions"
_ACTIVE_SESSION_FILE = ".active_session.json"


def decision_archive_base_dir() -> Path:
    override = os.environ.get("HAIKESI_DECISION_ARCHIVE_DIR", "").strip()
    if override:
        return Path(override)
    return _DEFAULT_ARCHIVE_DIR


@dataclass(frozen=True)
class GameSessionKey:
    seed: str
    map_script: str
    map_size: str
    requester: int
    requester_civ: str = ""

    @classmethod
    def from_payload(cls, payload: dict[str, Any]) -> GameSessionKey:
        raw = payload.get("game_session")
        if isinstance(raw, dict) and raw.get("seed") is not None:
            return cls(
                seed=str(raw.get("seed", "")),
                map_script=str(raw.get("map_script", "Unknown")),
                map_size=str(raw.get("map_size", "Unknown")),
                requester=int(raw.get("requester", payload.get("requester") or 0)),
                requester_civ=str(raw.get("requester_civ", "")),
            )
        # Fallback before mod reload / missing GAME_SESSION line (single legacy bucket)
        requester = int(payload.get("requester") or 0)
        return cls(
            seed="legacy",
            map_script="Unknown",
            map_size="Unknown",
            requester=requester,
            requester_civ="",
        )

    def stable_id(self) -> str:
        civ = self.requester_civ or "Unknown"
        return "|".join(
            [
                str(self.seed),
                self.map_script,
                self.map_size,
                str(self.requester),
                civ,
            ]
        )


def _slug(text: str, *, max_len: int = 24) -> str:
    cleaned = re.sub(r'[<>:"/\\|?*\s]+', "_", (text or "").strip())
    cleaned = cleaned.strip("_")
    return (cleaned[:max_len] if cleaned else "civ")


def _safe_request_filename(request_id: str) -> str:
    name = re.sub(r"[^\w.\-]+", "_", request_id.strip())
    return name or "unknown_request"


class DecisionArchive:
    """Append decision logs under logs/decisions/<session>/; reset on new GAME_SESSION."""

    def __init__(self, base_dir: Path) -> None:
        self.base_dir = base_dir
        self.base_dir.mkdir(parents=True, exist_ok=True)
        self._active_path = self.base_dir / _ACTIVE_SESSION_FILE
        self._session_key: str | None = None
        self._session_dir: Path | None = None
        self._load_active_session()

    def _load_active_session(self) -> None:
        if not self._active_path.is_file():
            return
        try:
            data = json.loads(self._active_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return
        session_dir = data.get("session_dir")
        session_key = data.get("session_key")
        if not session_key or not session_dir:
            return
        path = self.base_dir / str(session_dir)
        if path.is_dir():
            self._session_key = str(session_key)
            self._session_dir = path

    def _save_active_session(self, *, session_key: str, session_dir: Path, meta: dict[str, Any]) -> None:
        payload = {
            "session_key": session_key,
            "session_dir": session_dir.name,
            "updated_at": time.strftime("%Y-%m-%d %H:%M:%S"),
            **meta,
        }
        self._active_path.write_text(
            json.dumps(payload, ensure_ascii=False, indent=2),
            encoding="utf-8",
        )

    def _start_session(self, key: GameSessionKey, payload: dict[str, Any]) -> Path:
        stamp = time.strftime("%Y%m%d_%H%M%S")
        seed_slug = re.sub(r"[^\w.\-]+", "_", str(key.seed))[:32]
        folder = (
            f"{stamp}_seed{seed_slug}_P{key.requester}_"
            f"{_slug(key.requester_civ)}"
        )
        session_dir = self.base_dir / folder
        session_dir.mkdir(parents=True, exist_ok=False)
        session_meta = {
            "session_key": key.stable_id(),
            "seed": key.seed,
            "map_script": key.map_script,
            "map_size": key.map_size,
            "requester": key.requester,
            "requester_civ": key.requester_civ,
            "started_at": time.strftime("%Y-%m-%d %H:%M:%S"),
            "first_turn": int(payload.get("turn") or 0),
            "decision_count": 0,
        }
        (session_dir / "session.json").write_text(
            json.dumps(session_meta, ensure_ascii=False, indent=2),
            encoding="utf-8",
        )
        (session_dir / "index.jsonl").write_text("", encoding="utf-8")
        self._session_key = key.stable_id()
        self._session_dir = session_dir
        self._save_active_session(
            session_key=key.stable_id(),
            session_dir=session_dir,
            meta={"decision_count": 0},
        )
        return session_dir

    def resolve_session_dir(self, payload: dict[str, Any]) -> Path:
        key = GameSessionKey.from_payload(payload)
        stable = key.stable_id()
        if self._session_dir is not None and self._session_key == stable:
            return self._session_dir
        return self._start_session(key, payload)

    def append_decision(
        self,
        payload: dict[str, Any],
        *,
        body: str,
        request_id: str,
        model: str,
    ) -> Path:
        session_dir = self.resolve_session_dir(payload)
        base = _safe_request_filename(request_id)
        human = _safe_request_filename(str(payload.get("human_relic") or "norelic"))
        # 同 request_id / 同回合重选：文件名带 human_relic，避免覆盖；仍冲突再加时戳
        filename = f"{base}__{human}.md"
        path = session_dir / filename
        if path.exists():
            stamp = time.strftime("%H%M%S")
            filename = f"{base}__{human}__{stamp}.md"
            path = session_dir / filename
        path.write_text(body, encoding="utf-8")

        index_entry = {
            "saved_at": time.strftime("%Y-%m-%d %H:%M:%S"),
            "request_id": request_id,
            "turn": payload.get("turn"),
            "human_relic": payload.get("human_relic"),
            "model": model,
            "file": filename,
        }
        with (session_dir / "index.jsonl").open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(index_entry, ensure_ascii=False) + "\n")

        session_json = session_dir / "session.json"
        meta: dict[str, Any] = {}
        if session_json.is_file():
            try:
                meta = json.loads(session_json.read_text(encoding="utf-8"))
            except json.JSONDecodeError:
                meta = {}
        count = int(meta.get("decision_count") or 0) + 1
        meta["decision_count"] = count
        meta["last_decision_at"] = index_entry["saved_at"]
        meta["last_turn"] = payload.get("turn")
        meta["last_request_id"] = request_id
        session_json.write_text(
            json.dumps(meta, ensure_ascii=False, indent=2),
            encoding="utf-8",
        )
        self._save_active_session(
            session_key=self._session_key or GameSessionKey.from_payload(payload).stable_id(),
            session_dir=session_dir,
            meta={"decision_count": count},
        )
        return path


_archive: DecisionArchive | None = None


def get_decision_archive() -> DecisionArchive:
    global _archive
    if _archive is None:
        _archive = DecisionArchive(decision_archive_base_dir())
    return _archive


def reset_decision_archive_cache() -> None:
    """Tests: drop singleton so next call uses fresh state."""
    global _archive
    _archive = None
