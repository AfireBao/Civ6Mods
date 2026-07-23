"""Parse Haikesi ExtAI request dumps from Lua.log (MP / no FireTuner)."""

from __future__ import annotations

import os
import re
import time
from pathlib import Path
from typing import Any

from civ_mcp.lua import congress as congress_lua
from civ_mcp.lua import haikesi as haikesi_lua
from civ_mcp.lua import overview as overview_lua
from civ_mcp.lua.models import GameOverview

_BEGIN = "===HAIKESI_EXT_AI_REQ_BEGIN==="
_END = "===HAIKESI_EXT_AI_REQ_END==="
_CTX_BEGIN = "===HAIKESI_EXT_AI_CTX_BEGIN==="
_CTX_END = "===HAIKESI_EXT_AI_CTX_END==="

_DEFAULT_LOG_CANDIDATES = [
    # GS / 部分安装：写在 LocalAppData\Firaxis Games\...\Logs（本机实测）
    Path(os.environ.get("LOCALAPPDATA", ""))
    / "Firaxis Games"
    / "Sid Meier's Civilization VI"
    / "Logs"
    / "Lua.log",
    # 经典路径：Documents\My Games\...\Logs
    Path.home() / "Documents" / "My Games" / "Sid Meier's Civilization VI" / "Logs" / "Lua.log",
    Path.home() / "Documents" / "My Games" / "Sid Meier's Civilization VI" / "Logs" / "Lua.log.txt",
    # 中文 Windows「文档」
    Path.home() / "文档" / "My Games" / "Sid Meier's Civilization VI" / "Logs" / "Lua.log",
    Path.home() / "OneDrive" / "Documents" / "My Games" / "Sid Meier's Civilization VI" / "Logs" / "Lua.log",
]


def default_lua_log_path() -> Path:
    env = Path(os.environ.get("HAIKESI_LUA_LOG", "") or "")
    if env.is_file():
        return env
    existing: list[Path] = []
    for p in _DEFAULT_LOG_CANDIDATES:
        if str(p) and p.is_file():
            existing.append(p)
    if not existing:
        # Prefer LocalAppData candidate even if missing (common on this machine)
        return _DEFAULT_LOG_CANDIDATES[0]
    # 多个候选时取最近修改的（避免盯到空/旧路径）
    return max(existing, key=lambda p: p.stat().st_mtime)


def _strip_lua_prefix(line: str) -> str:
    """Lua.log lines look like: Haikesi_GamePlay_Script: REQUEST_ID=..."""
    text = line.strip()
    if ": " in text:
        left, right = text.split(": ", 1)
        if " " not in left and re.match(r"^[\w.\-]+$", left):
            return right.strip()
    return text


def _split_req_and_context(cleaned: list[str]) -> tuple[list[str], list[str]]:
    """Split request KV/AI lines from nested CTX dump lines."""
    req: list[str] = []
    ctx: list[str] = []
    in_ctx = False
    for ln in cleaned:
        if ln == _CTX_BEGIN:
            in_ctx = True
            continue
        if ln == _CTX_END:
            in_ctx = False
            continue
        if in_ctx:
            ctx.append(ln)
        else:
            req.append(ln)
    return req, ctx


def split_context_wire_lines(
    context_lines: list[str],
) -> tuple[list[str], list[str], list[str]]:
    """Split CTX body into overview / world-congress / leader-views wire lines."""
    wc_start: int | None = None
    views_start: int | None = None
    for i, ln in enumerate(context_lines):
        if wc_start is None and ln.startswith("WC_"):
            wc_start = i
        if views_start is None and (
            ln.startswith("RST_MOD|") or ln.startswith("VIEWER|")
        ):
            views_start = i
    if views_start is None:
        views_start = len(context_lines)
    if wc_start is None:
        wc_start = views_start
    if wc_start > views_start:
        # Malformed order — treat everything before views as overview
        wc_start = views_start
    return (
        context_lines[:wc_start],
        context_lines[wc_start:views_start],
        context_lines[views_start:],
    )


def parse_extai_log_block(lines: list[str]) -> dict[str, Any]:
    cleaned = [_strip_lua_prefix(ln) for ln in lines]
    cleaned = [ln for ln in cleaned if ln and ln not in (_BEGIN, _END)]
    req_lines, ctx_lines = _split_req_and_context(cleaned)
    filtered: list[str] = []
    for ln in req_lines:
        if ln.startswith("DUMP_REASON=") or ln.startswith("CHANNEL="):
            continue
        filtered.append(ln)
    result = haikesi_lua.parse_ai_request_lines(filtered)
    if ctx_lines:
        result["context_lines"] = ctx_lines
    return result


def context_from_log_payload(payload: dict[str, Any]):
    """Build HaikesiGameContext from Lua.log CTX lines (same parsers as SP)."""
    # Imported lazily to avoid circular import with haikesi_llm
    from civ_mcp.haikesi_llm import HaikesiGameContext

    notes: list[str] = []
    turn = int(payload.get("turn") or 0)
    requester = int(payload.get("requester") or 0)
    overview = GameOverview(
        turn=turn,
        player_id=requester,
        civ_name="",
        leader_name="",
        gold=0.0,
        gold_per_turn=0.0,
        science_yield=0.0,
        culture_yield=0.0,
        faith=0.0,
        current_research="",
        current_civic="",
        num_cities=0,
        num_units=0,
    )
    leader_views: dict[int, Any] = {}
    world_congress = None
    ctx_lines = list(payload.get("context_lines") or [])
    if not ctx_lines:
        notes.append(
            "联机 CTX 缺失：未找到 overview/领袖视图 dump（请确认已加载 Haikesi_ExtAI_Context.lua）"
        )
        return HaikesiGameContext(
            overview=overview,
            leader_views={},
            human_player_id=requester,
            fetch_notes=notes,
            world_congress=None,
        )

    ov_lines, wc_lines, view_lines = split_context_wire_lines(ctx_lines)
    if not ov_lines:
        ov_lines = haikesi_lua.recover_overview_lines(ctx_lines)
    wire_meta = haikesi_lua.scrape_ctx_wire_meta(ctx_lines)
    if ov_lines:
        try:
            overview = overview_lua.parse_overview_response(ov_lines)
        except Exception as exc:  # noqa: BLE001 — soft-fail like SP gather
            notes.append(f"overview: unavailable ({exc})")
            overview.turn = turn
            overview.player_id = requester
    else:
        notes.append("overview: missing from CTX dump")

    if wire_meta.get("era_name") and not overview.era_name:
        overview.era_name = wire_meta["era_name"]
    if wire_meta.get("game_speed") and not overview.game_speed:
        overview.game_speed = wire_meta["game_speed"]
    if wire_meta.get("game_speed_name") and not overview.game_speed_name:
        overview.game_speed_name = wire_meta["game_speed_name"]
    if wire_meta.get("speed_cost_multiplier"):
        try:
            overview.speed_cost_multiplier = int(wire_meta["speed_cost_multiplier"])
        except ValueError:
            pass

    if wc_lines:
        try:
            world_congress = congress_lua.parse_world_congress_response(wc_lines)
        except Exception as exc:  # noqa: BLE001
            notes.append(f"world_congress: unavailable ({exc})")
            world_congress = None
    else:
        notes.append("world_congress: missing from CTX dump")

    rst_available: bool | None = None
    if view_lines:
        try:
            leader_views, rst_available = haikesi_lua.parse_leader_views(view_lines)
        except Exception as exc:  # noqa: BLE001
            notes.append(f"leader_views: unavailable ({exc})")
            leader_views = {}
    else:
        notes.append("leader_views: missing from CTX dump")

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
        lean_n = haikesi_lua.apply_victory_lean(leader_views)
        if lean_n:
            notes.append(f"VictoryLean: 无 RST 探针，已估计 {lean_n} 位")

    notes.append("联机 LOG 通道：局势来自 Gameplay Lua.log CTX（与单机 FireTuner 线格式对齐）")
    return HaikesiGameContext(
        overview=overview,
        leader_views=leader_views,
        human_player_id=int(overview.player_id if overview.player_id is not None else requester),
        fetch_notes=notes,
        world_congress=world_congress,
    )


def _iter_complete_blocks(text: str) -> list[tuple[str, list[str], int]]:
    """Return list of (request_id_guess, block_lines, end_offset) for each complete dump."""
    blocks: list[tuple[str, list[str], int]] = []
    in_block = False
    partial: list[str] = []
    # Track character offset approximately via cumulative
    offset = 0
    for raw_line in text.splitlines(keepends=True):
        offset += len(raw_line)
        line = _strip_lua_prefix(raw_line.rstrip("\r\n"))
        if line == _BEGIN:
            in_block = True
            partial = []
            continue
        if line == _END and in_block:
            in_block = False
            parsed = parse_extai_log_block(partial)
            rid = str(parsed.get("request_id") or "")
            blocks.append((rid, list(partial), offset))
            partial = []
            continue
        if in_block:
            partial.append(raw_line.rstrip("\r\n"))
    return blocks


def recover_latest_unapplied_request(
    path: Path, *, lookback_bytes: int = 2_000_000
) -> dict[str, Any] | None:
    """On watch startup: if last dump has no ExtAIApply applied after it, return that pending."""
    if not path.is_file():
        return None
    size = path.stat().st_size
    start = max(0, size - lookback_bytes)
    with path.open("r", encoding="utf-8", errors="replace") as fh:
        fh.seek(start)
        text = fh.read()
    blocks = _iter_complete_blocks(text)
    if not blocks:
        return None
    rid, block_lines, end_off = blocks[-1]
    if not rid:
        return None
    # Text after this block within the lookback window
    after = text[end_off:]
    applied_marker = f"ExtAIApply applied request_id={rid}"
    # Also accept older wording
    if applied_marker in after or f"ExtAIApply applied request_id={rid}" in after:
        return None
    # Fallback flush / clear may also mean no longer pending
    if "External AI fallback" in after or "External AI request already pending" in after:
        # still might be pending; only skip if clear applied for this id
        pass
    parsed = parse_extai_log_block(block_lines)
    if parsed.get("status") == "pending" and parsed.get("request_id"):
        return parsed
    return None


class LuaLogExtAITailer:
    """Tail Lua.log for ===HAIKESI_EXT_AI_REQ_*=== blocks."""

    def __init__(self, path: Path | None = None, *, recover_pending: bool = True) -> None:
        self.path = path or default_lua_log_path()
        self._pos = 0
        self._partial: list[str] = []
        self._in_block = False
        self._dump_seq = 0
        self._recovered: dict[str, Any] | None = None
        if self.path.is_file():
            self._pos = self.path.stat().st_size
            if recover_pending:
                self._recovered = recover_latest_unapplied_request(self.path)
                if self._recovered is not None:
                    self._dump_seq += 1
                    self._recovered["_log_pos"] = self._pos
                    self._recovered["_dump_seq"] = self._dump_seq
        else:
            self._recovered = None

    def poll_new_request(self) -> dict[str, Any] | None:
        # Re-resolve if file appeared / newer sibling path
        if not self.path.is_file():
            refreshed = default_lua_log_path()
            if refreshed.is_file() and refreshed != self.path:
                self.path = refreshed
                self._pos = self.path.stat().st_size
                self._partial = []
                self._in_block = False
            else:
                return None

        if self._recovered is not None:
            pending = self._recovered
            self._recovered = None
            return pending

        size = self.path.stat().st_size
        if size < self._pos:
            self._pos = 0
            self._partial = []
            self._in_block = False
        if size == self._pos:
            return None

        with self.path.open("r", encoding="utf-8", errors="replace") as fh:
            fh.seek(self._pos)
            chunk = fh.read()
            self._pos = fh.tell()

        found: dict[str, Any] | None = None
        for raw_line in chunk.splitlines():
            line = _strip_lua_prefix(raw_line)
            if line == _BEGIN:
                self._in_block = True
                self._partial = []
                continue
            if line == _END and self._in_block:
                self._in_block = False
                parsed = parse_extai_log_block(self._partial)
                self._partial = []
                if parsed.get("status") == "pending" and parsed.get("request_id"):
                    self._dump_seq += 1
                    parsed["_log_pos"] = self._pos
                    parsed["_dump_seq"] = self._dump_seq
                    found = parsed
                continue
            if self._in_block:
                self._partial.append(raw_line)
        return found


def encode_extai_apply_payload(
    request_id: str,
    choices: dict[str, str],
    reasons: dict[str, str] | None = None,
    *,
    max_reason_chars: int = 80,
    max_wire_len: int | None = None,
) -> str:
    """Match Lua Haikesi_EncodeExtAIApply (reason as utf-8 hex, strip #|=*).

    For MP EditBox/chat inject, pass max_reason_chars≈12 and max_wire_len≈505
    (Civ6 EditBox GetText truncates ~511; longer wires drop leaders mid-payload).
    If reasons make the wire too long, shrink per-reason length to fit — do not
    drop all reasons at once (that made UI show blank labels).
    """

    def _wire_reason(reason: str, limit: int) -> str:
        text = (reason or "").strip()
        text = re.sub(r"[\x00-\x1f]", "", text)
        text = text.replace("#", "").replace("|", "").replace("=", "").replace("*", "")
        text = text.replace('"', "").replace("“", "").replace("”", "")
        if len(text) > limit:
            text = text[:limit].rstrip("，。、；： ")
        return text

    def _build(limit: int, include_reasons: bool) -> str:
        ids = sorted(choices.keys(), key=lambda x: int(x) if str(x).isdigit() else str(x))
        parts: list[str] = []
        src = reasons or {}
        for ai_id in ids:
            relic = choices[ai_id]
            reason_hex = ""
            if include_reasons:
                cleaned = _wire_reason(str(src.get(ai_id) or src.get(str(ai_id)) or ""), limit)
                reason_hex = cleaned.encode("utf-8").hex() if cleaned else ""
            parts.append(f"{ai_id}={relic}*{reason_hex}")
        return f"{request_id}#{'|'.join(parts)}"

    include = bool(reasons)
    wire = _build(max_reason_chars, include)
    if max_wire_len is not None and len(wire) > max_wire_len and include:
        # Binary-search the largest per-reason char budget that still fits.
        lo, hi = 0, max_reason_chars
        best = _build(0, False)
        while lo <= hi:
            mid = (lo + hi) // 2
            candidate = _build(mid, True)
            if len(candidate) <= max_wire_len:
                best = candidate
                lo = mid + 1
            else:
                hi = mid - 1
        wire = best
    if max_wire_len is not None and len(wire) > max_wire_len:
        raise ValueError(
            f"ExtAIApply wire too long ({len(wire)}>{max_wire_len}) even without reasons"
        )
    return wire


def wait_for_log_path(timeout_sec: float = 120.0) -> Path:
    path = default_lua_log_path()
    deadline = time.time() + timeout_sec
    while time.time() < deadline:
        if path.is_file():
            return path
        path = default_lua_log_path()
        time.sleep(2.0)
    return path
