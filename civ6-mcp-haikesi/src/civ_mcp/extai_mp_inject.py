"""Multiplayer ExtAI: publish wire to clipboard + disk archive (no SendInput).

联机落地：玩家在 HUD EditBox 内 Ctrl+V → OnChange → ExtAIApply。
watch 不阻塞、不抢前台。

持久化（Ctrl+C 不丢决策）：
  Logs/haikesi_extai_apply.txt
  logs/haikesi_last_exchange.json（wire 单行）
  logs/haikesi_last_decision.txt
  系统剪贴板（直到被其它程序覆盖）
"""

from __future__ import annotations

import ctypes
import time
from ctypes import wintypes
from pathlib import Path

from civ_mcp.extai_log_channel import default_lua_log_path

kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
user32 = ctypes.WinDLL("user32", use_last_error=True)

kernel32.GlobalAlloc.argtypes = (wintypes.UINT, ctypes.c_size_t)
kernel32.GlobalAlloc.restype = wintypes.HGLOBAL
kernel32.GlobalLock.argtypes = (wintypes.HGLOBAL,)
kernel32.GlobalLock.restype = wintypes.LPVOID
kernel32.GlobalUnlock.argtypes = (wintypes.HGLOBAL,)
kernel32.GlobalUnlock.restype = wintypes.BOOL
kernel32.GlobalFree.argtypes = (wintypes.HGLOBAL,)
kernel32.GlobalFree.restype = wintypes.HGLOBAL

user32.OpenClipboard.argtypes = (wintypes.HWND,)
user32.OpenClipboard.restype = wintypes.BOOL
user32.CloseClipboard.argtypes = ()
user32.CloseClipboard.restype = wintypes.BOOL
user32.EmptyClipboard.argtypes = ()
user32.EmptyClipboard.restype = wintypes.BOOL
user32.SetClipboardData.argtypes = (wintypes.UINT, wintypes.HANDLE)
user32.SetClipboardData.restype = wintypes.HANDLE

CF_UNICODETEXT = 13
GMEM_MOVEABLE = 0x0002

_INJECT_NAME = "haikesi_extai_apply.txt"


def set_clipboard_text(text: str) -> None:
    raw = text.encode("utf-16-le") + b"\x00\x00"
    size = len(raw)
    if not user32.OpenClipboard(None):
        raise RuntimeError(f"OpenClipboard failed (winerr={ctypes.get_last_error()})")
    try:
        user32.EmptyClipboard()
        h_global = kernel32.GlobalAlloc(GMEM_MOVEABLE, size)
        if not h_global:
            raise RuntimeError(f"GlobalAlloc failed (winerr={ctypes.get_last_error()})")
        locked = kernel32.GlobalLock(h_global)
        if not locked:
            kernel32.GlobalFree(h_global)
            raise RuntimeError(f"GlobalLock failed (winerr={ctypes.get_last_error()})")
        try:
            ctypes.memmove(locked, raw, size)
        finally:
            kernel32.GlobalUnlock(h_global)
        if not user32.SetClipboardData(CF_UNICODETEXT, h_global):
            kernel32.GlobalFree(h_global)
            raise RuntimeError(f"SetClipboardData failed (winerr={ctypes.get_last_error()})")
    finally:
        user32.CloseClipboard()


def _log_contains(marker: str, *, lookback: int = 512_000) -> bool:
    log_path = default_lua_log_path()
    if not log_path.is_file():
        return False
    size = log_path.stat().st_size
    start = max(0, size - lookback)
    with log_path.open("r", encoding="utf-8", errors="replace") as fh:
        fh.seek(start)
        return marker in fh.read()


def write_extai_apply_file(payload: str) -> Path | None:
    try:
        path = default_lua_log_path().parent / _INJECT_NAME
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(payload, encoding="utf-8")
        return path
    except OSError:
        return None


def publish_extai_decision(
    wire: str,
    *,
    request_id: str | None = None,
) -> dict[str, Path | None]:
    """Publish LLM wire: clipboard (Ctrl+V) + disk archive."""
    if not wire or "#" not in wire:
        raise ValueError("invalid ExtAIApply wire")
    wire = wire.strip().replace("\r", "").replace("\n", "")
    rid = (request_id or wire.split("#", 1)[0]).strip()

    apply_path = write_extai_apply_file(wire)

    try:
        set_clipboard_text(wire)
    except Exception as exc:  # noqa: BLE001
        print(f"  clipboard failed: {exc}", flush=True)
        print(f"  copy from: {apply_path}", flush=True)

    print(f"  ★ 决策已发布 request_id={rid!r} wireLen={len(wire)}", flush=True)
    if apply_path is not None:
        print(f"  archive: {apply_path}", flush=True)
    print(
        "  → 游戏内：下方输入框 Ctrl+V（或 apply.txt / exchange.json）",
        flush=True,
    )
    print(
        "  → Ctrl+C 停止 watch 不会删除已发布内容（剪贴板/apply.txt/decision 日志仍在）",
        flush=True,
    )

    return {"apply": apply_path}


def wait_extai_applied(request_id: str, *, timeout_sec: float = 75.0) -> str:
    """Optional dev wait."""
    deadline = time.time() + timeout_sec
    while time.time() < deadline:
        if _log_contains(f"ExtAIApply applied request_id={request_id}"):
            return f"ExtAIApply applied request_id={request_id}"
        time.sleep(0.25)
    raise RuntimeError(f"apply not confirmed within {timeout_sec:.0f}s for {request_id!r}")


def inject_extai_apply_payload(
    payload: str,
    *,
    settle_sec: float = 0.35,  # noqa: ARG001 — compat
    timeout_sec: float = 75.0,  # noqa: ARG001
    prefer_chat: bool | None = None,  # noqa: ARG001
) -> None:
    publish_extai_decision(payload)
