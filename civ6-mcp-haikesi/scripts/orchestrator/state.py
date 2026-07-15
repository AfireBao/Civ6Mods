"""Job state machine + persistence."""

from __future__ import annotations

import json
import logging
import time
from dataclasses import asdict, dataclass, field
from typing import Any

from pathlib import Path

from .config import CONFIG_DIR, STATE_PATH

log = logging.getLogger("orchestrator")

# Valid state transitions
TRANSITIONS = {
    "pending": {"launching", "failed", "running"},  # running = adopted from discovery
    "launching": {"booting", "failed", "pending"},  # pending = retry
    "booting": {"running", "failed", "pending", "needs_attention"},
    "running": {"completing", "failed", "pending", "needs_attention"},
    "completing": {"done", "failed"},
    "needs_attention": {"pending", "failed"},  # human decides: retry or abandon
    "done": set(),
    "failed": {"pending"},  # retry
}


@dataclass
class JobState:
    """State for a single benchmark job."""

    id: str
    machine: str
    model: str
    scenario: str
    run_num: int
    state: str = "pending"
    run_id: str | None = None
    turn: int = 0
    started_at: float = 0
    finished_at: float = 0
    boot_retries: int = 0
    game_retries: int = 0
    fail_reason: str = ""
    synced: bool = False
    score: int = 0
    outcome: str = ""
    # Heartbeat tracking
    last_heartbeat_ts: float = 0
    last_heartbeat_phase: str = ""
    boot_started_at: float = 0
    last_turn_change: float = 0
    # Transition log
    transitions: list[tuple[float, str, str]] = field(default_factory=list)

    def transition(self, new_state: str, reason: str = "") -> bool:
        """Attempt a state transition. Returns True if valid."""
        if new_state not in TRANSITIONS.get(self.state, set()):
            log.warning(
                "Invalid transition %s → %s for %s", self.state, new_state, self.id
            )
            return False
        old = self.state
        self.state = new_state
        self.transitions.append((time.time(), old, new_state))
        if reason:
            log.info("Job %s: %s → %s (%s)", self.id, old, new_state, reason)
        else:
            log.info("Job %s: %s → %s", self.id, old, new_state)
        return True

    def to_dict(self) -> dict:
        return asdict(self)

    @classmethod
    def from_dict(cls, d: dict) -> JobState:
        # Handle transitions as list of lists (JSON doesn't have tuples)
        transitions = [tuple(t) for t in d.pop("transitions", [])]
        known = {f.name for f in cls.__dataclass_fields__.values()}
        filtered = {k: v for k, v in d.items() if k in known}
        filtered["transitions"] = transitions
        return cls(**filtered)


@dataclass
class BatchState:
    """Persistent state for the entire benchmark batch."""

    started_at: float = 0
    jobs: dict[str, JobState] = field(default_factory=dict)
    config_snapshot: dict[str, Any] = field(default_factory=dict)
    _path: Path = field(default=STATE_PATH, repr=False)

    @staticmethod
    def path_for_machines(machine_names: set[str] | list[str]) -> Path:
        """Derive a state file path from machine names.

        Each orchestrator instance gets its own state file so multiple
        orchestrators can run concurrently without overwriting each other.
        """
        tag = "_".join(sorted(machine_names))
        return CONFIG_DIR / f"state_{tag}.json"

    def save(self) -> None:
        """Atomic write to state file."""
        self._path.parent.mkdir(parents=True, exist_ok=True)
        data = {
            "started_at": self.started_at,
            "config_snapshot": self.config_snapshot,
            "jobs": {jid: j.to_dict() for jid, j in self.jobs.items()},
        }
        # Atomic: write to tmp then rename
        tmp = self._path.with_suffix(".tmp")
        tmp.write_text(json.dumps(data, indent=2))
        tmp.replace(self._path)

    @classmethod
    def load(cls, path: Path | None = None) -> BatchState:
        """Load from state file, or return empty state."""
        p = path or STATE_PATH
        if not p.exists():
            return cls(_path=p)
        try:
            raw = json.loads(p.read_text())
            jobs = {
                jid: JobState.from_dict(jdata)
                for jid, jdata in raw.get("jobs", {}).items()
            }
            return cls(
                started_at=raw.get("started_at", 0),
                jobs=jobs,
                config_snapshot=raw.get("config_snapshot", {}),
                _path=p,
            )
        except Exception:
            log.warning(
                "Failed to load state file %s, starting fresh", p, exc_info=True
            )
            return cls(_path=p)

    def active_jobs(self) -> list[JobState]:
        """Jobs that are in-flight (not done/failed/pending)."""
        return [
            j
            for j in self.jobs.values()
            if j.state in ("launching", "booting", "running", "completing")
        ]

    def pending_for_machine(self, machine: str) -> list[JobState]:
        """Pending jobs assigned to a specific machine."""
        return [
            j
            for j in self.jobs.values()
            if j.state == "pending" and j.machine == machine
        ]

    def machine_busy(self, machine: str) -> bool:
        """Is a machine currently running a job (or awaiting human intervention)?"""
        return any(
            j.machine == machine
            and j.state
            in ("launching", "booting", "running", "completing", "needs_attention")
            for j in self.jobs.values()
        )

    def all_terminal(self) -> bool:
        """Are all jobs in a terminal state (done or failed)?"""
        return all(j.state in ("done", "failed") for j in self.jobs.values())

    def summary(self) -> dict[str, int]:
        """Count jobs by state."""
        counts: dict[str, int] = {}
        for j in self.jobs.values():
            counts[j.state] = counts.get(j.state, 0) + 1
        return counts
