"""Heartbeat file for orchestrator observability.

Writes ``~/.civ6-mcp/heartbeat.json`` atomically so the orchestrator
can read phase and turn via SSH without process-detection hacks.
"""

import json
import logging
import os
import time
from pathlib import Path

log = logging.getLogger(__name__)

HEARTBEAT_PATH = Path.home() / ".civ6-mcp" / "heartbeat.json"

# Module-level state — set once, reused on every write
_run_id: str = ""
_civ: str = ""
_seed: int = 0
_model_id: str = ""
_scenario_id: str = ""


def init(run_id: str) -> None:
    """Set run_id at MCP server startup."""
    global _run_id
    _run_id = run_id


def bind_game(civ: str, seed: int) -> None:
    """Set civ/seed once game identity is discovered."""
    global _civ, _seed
    _civ = civ
    _seed = seed


def bind_eval(model_id: str, scenario_id: str) -> None:
    """Set model/scenario so the orchestrator can identify this game."""
    global _model_id, _scenario_id
    _model_id = model_id
    _scenario_id = scenario_id


def write(phase: str, turn: int = 0) -> None:
    """Write heartbeat.json atomically (tmp + rename)."""
    try:
        HEARTBEAT_PATH.parent.mkdir(parents=True, exist_ok=True)
        data = {
            "phase": phase,
            "turn": turn,
            "ts": time.time(),
            "pid": os.getpid(),
            "run_id": _run_id,
            "civ": _civ,
            "seed": _seed,
            "model_id": _model_id,
            "scenario_id": _scenario_id,
        }
        tmp = HEARTBEAT_PATH.with_suffix(".tmp")
        tmp.write_text(json.dumps(data))
        tmp.replace(HEARTBEAT_PATH)
    except Exception:
        log.debug("Failed to write heartbeat", exc_info=True)
