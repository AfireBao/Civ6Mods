"""Health monitoring — heartbeat, stall detection, boot validation."""

from __future__ import annotations

import logging
import time

from .config import Defaults
from .machine import Machine
from .state import JobState

log = logging.getLogger("orchestrator")


def check_heartbeat(machine: Machine, job: JobState, defaults: Defaults) -> dict | None:
    """Read heartbeat and update job state. Returns heartbeat dict or None."""
    hb = machine.read_heartbeat()
    if hb is None:
        return None

    phase = hb.get("phase", "")
    try:
        hb_turn = int(hb.get("turn", 0))
    except (ValueError, TypeError):
        hb_turn = 0
    hb_ts = hb.get("ts", 0)
    age = time.time() - hb_ts

    # Update job tracking
    job.last_heartbeat_ts = hb_ts
    job.last_heartbeat_phase = phase

    # Bind run_id if discovered
    if not job.run_id and hb.get("run_id"):
        job.run_id = hb["run_id"]

    # Update turn
    if hb_turn > 0 and hb_turn != job.turn:
        old = job.turn
        job.turn = hb_turn
        job.last_turn_change = time.time()
        if old > 0:
            log.info("Turn advance: %s T%d->T%d", job.id, old, hb_turn)

    return {"phase": phase, "turn": hb_turn, "ts": hb_ts, "age": age}


def is_heartbeat_stale(hb_info: dict, job: JobState, defaults: Defaults) -> bool:
    """Check if heartbeat is stale (agent/game may be dead)."""
    age = hb_info["age"]
    phase = hb_info["phase"]

    if phase in ("error", "finished"):
        return False  # Terminal states are not stale

    # Use boot_timeout for boot phases, playing_timeout for gameplay
    if phase in ("starting", "launching", "connecting", "loading"):
        threshold = defaults.boot_timeout
    else:
        threshold = defaults.playing_timeout

    return age > threshold


def is_stalled(job: JobState, defaults: Defaults) -> bool:
    """Check if turn hasn't advanced for too long (game may be stuck)."""
    if job.turn == 0:
        return False  # Still booting
    if job.last_turn_change == 0:
        return False  # No turn data yet
    stall_min = (time.time() - job.last_turn_change) / 60
    return stall_min > defaults.stall_kill_minutes


def is_stall_warning(job: JobState, defaults: Defaults) -> bool:
    """Check if turn stall is approaching kill threshold."""
    if job.turn == 0 or job.last_turn_change == 0:
        return False
    stall_min = (time.time() - job.last_turn_change) / 60
    return stall_min > defaults.stall_alert_minutes


def classify_failure(job: JobState, defaults: Defaults) -> tuple[str, bool]:
    """Classify failure type. Returns (reason, is_boot_failure).

    Boot failures don't count against game retry budget.
    """
    phase = job.last_heartbeat_phase
    if phase in ("", "starting", "launching", "connecting", "loading"):
        return "boot failure", True
    if phase == "error":
        return "MCP error", True  # Usually boot-related
    return "game failure", False
