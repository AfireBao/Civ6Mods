"""Offline Civilopedia + Haikesi dictionary for ExtAI tool lookup.

Index artifact: knowledge/civilopedia/index.json
Regenerate: uv run python scripts/export_civilopedia_index.py
"""

from __future__ import annotations

import json
import threading
from functools import lru_cache
from pathlib import Path
from typing import Any

_INDEX_PATH = Path(__file__).resolve().parents[2] / "knowledge" / "civilopedia" / "index.json"
_LOCK = threading.Lock()
_CACHE: dict[str, Any] | None = None


def index_path() -> Path:
    return _INDEX_PATH


def load_index(*, force: bool = False) -> dict[str, Any]:
    global _CACHE
    with _LOCK:
        if _CACHE is not None and not force:
            return _CACHE
        if not _INDEX_PATH.is_file():
            _CACHE = {"version": 0, "entries": [], "chapters": {}}
            return _CACHE
        _CACHE = json.loads(_INDEX_PATH.read_text(encoding="utf-8"))
        return _CACHE


def _norm(s: str) -> str:
    return (s or "").strip().casefold()


def _score_entry(entry: dict[str, Any], q: str, q_norm: str) -> int:
    """Higher = better. 0 = no match."""
    eid = str(entry.get("id") or "")
    name = str(entry.get("name") or "")
    desc = str(entry.get("description") or "")
    aliases = [str(a) for a in (entry.get("aliases") or [])]

    eid_n = _norm(eid)
    name_n = _norm(name)
    if eid_n == q_norm or name_n == q_norm:
        return 100
    if q_norm in aliases or any(_norm(a) == q_norm for a in aliases):
        return 95
    # TYPE id without LOC prefix variants
    if eid_n.endswith(q_norm) or q_norm.endswith(eid_n):
        return 90
    if name_n.startswith(q_norm) or q_norm.startswith(name_n):
        return 80
    if q_norm in eid_n:
        return 70
    if q_norm in name_n:
        return 60
    if q_norm in _norm(desc):
        return 40
    # Chinese / raw substring (case-sensitive for CJK)
    if q in name or q in eid:
        return 55
    if q in desc:
        return 35
    for a in aliases:
        if q_norm in _norm(a) or q in a:
            return 50
    return 0


def search(
    query: str,
    *,
    chapter: str | None = None,
    kind: str | None = None,
    limit: int = 5,
) -> list[dict[str, Any]]:
    q = (query or "").strip()
    if not q:
        return []
    q_norm = _norm(q)
    data = load_index()
    scored: list[tuple[int, dict[str, Any]]] = []
    for entry in data.get("entries") or []:
        if chapter and entry.get("chapter") != chapter:
            continue
        if kind and entry.get("kind") != kind:
            continue
        sc = _score_entry(entry, q, q_norm)
        if sc > 0:
            scored.append((sc, entry))
    scored.sort(key=lambda t: (-t[0], str(t[1].get("id") or "")))
    return [e for _, e in scored[: max(1, min(limit, 12))]]


def format_entry(entry: dict[str, Any], *, max_desc: int = 600) -> str:
    lines = [
        f"{entry.get('name') or '?'}（{entry.get('id')}）"
        f" [{entry.get('chapter')}/{entry.get('kind')}]"
    ]
    desc = str(entry.get("description") or "").strip()
    if desc:
        if len(desc) > max_desc:
            desc = desc[:max_desc].rstrip() + "…"
        lines.append(desc)
    flavor = str(entry.get("flavor") or "").strip()
    if flavor:
        lines.append(f"风味：{flavor}")
    stats = entry.get("stats")
    if isinstance(stats, dict) and stats:
        bits = [f"{k}={v}" for k, v in stats.items()]
        lines.append("数值：" + "；".join(bits))
    aliases = entry.get("aliases")
    if aliases:
        lines.append("别名：" + "、".join(str(a) for a in aliases))
    return "\n".join(lines)


def format_search_result(
    query: str,
    hits: list[dict[str, Any]],
    *,
    empty_hint: str = "",
) -> str:
    if not hits:
        hint = empty_hint or "无匹配词条"
        return f"{hint}（query={query!r}）"
    parts = [f"词典命中 {len(hits)} 条（query={query!r}）："]
    for i, e in enumerate(hits, 1):
        parts.append(f"--- [{i}] ---")
        parts.append(format_entry(e))
    return "\n".join(parts)


@lru_cache(maxsize=1)
def chapter_counts() -> tuple[int, int]:
    data = load_index()
    ch = data.get("chapters") or {}
    civ = int((ch.get("civilopedia") or {}).get("count") or 0)
    hk = int((ch.get("haikesi") or {}).get("count") or 0)
    return civ, hk
