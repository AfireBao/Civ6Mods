"""CivBench data access library for notebooks and collaborator analysis.

Usage:
    import civbench_data as cb

    games = cb.list_games()              # DataFrame of all games
    diary = cb.load_diary("run-id")      # DataFrame of player rows per turn
    log = cb.load_log("run-id")          # DataFrame of tool calls
    cities = cb.load_cities("run-id")    # DataFrame of city snapshots
    agent = cb.agent_turns("run-id")     # Agent-only rows
    scores = cb.score_game("run-id")     # 8-dimension scoring dict
    card = cb.scorecard()                # Model × dimension comparison DataFrame

Setup: put AZURE_SAS_TOKEN=<token> in .env (or evals/.env) or set as env var.
"""

from __future__ import annotations

import json
import os
from pathlib import Path
from typing import Any

import pandas as pd

# ---------------------------------------------------------------------------
# Import reusable helpers from analyze.py
# ---------------------------------------------------------------------------

# Allow import from scripts/ when running from repo root or notebooks/
_scripts_dir = Path(__file__).resolve().parent
import sys

if str(_scripts_dir) not in sys.path:
    sys.path.insert(0, str(_scripts_dir))

from analyze import (  # noqa: E402
    CACHE_DIR,
    _agent_rows,
    _cloud_jsonl,
    _get_fs,
    _list_games,
    cloud_diary,
    cloud_log,
    convex_query,
    score_game as _score_game_raw,
)

# ---------------------------------------------------------------------------
# .env loader (checks cwd/.env, then evals/.env)
# ---------------------------------------------------------------------------


def _load_local_env() -> None:
    """Load .env from cwd into os.environ (SAS token for collaborators)."""
    for candidate in [Path(".env"), Path("evals/.env")]:
        if candidate.exists():
            for line in candidate.read_text().splitlines():
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    k, v = k.strip(), v.strip()
                    if k not in os.environ:
                        os.environ[k] = v


_load_local_env()

# ---------------------------------------------------------------------------
# Game list
# ---------------------------------------------------------------------------


def list_games(include_excluded: bool = False) -> pd.DataFrame:
    """Fetch all games from Convex as a DataFrame."""
    raw = _list_games()
    rows = []
    for g in raw:
        if not include_excluded and g.get("excludeReason"):
            continue
        o = g.get("outcome") or {}
        rows.append(
            {
                "run_id": g.get("runId", ""),
                "game_id": g.get("gameId", ""),
                "model": (g.get("agentModel") or "").rsplit("/", 1)[-1],
                "model_full": g.get("agentModel", ""),
                "scenario": g.get("scenarioId", ""),
                "turns": g.get("turnCount", 0),
                "score": g.get("lastScore", 0),
                "status": g.get("status", ""),
                "result": o.get("result", ""),
                "victory_type": o.get("victoryType", ""),
                "winner": o.get("winnerCiv", ""),
                "admissible": g.get("admissible", False),
                "exclude_reason": g.get("excludeReason", ""),
            }
        )
    df = pd.DataFrame(rows)
    if not df.empty:
        df["turns"] = df["turns"].astype("Int64")
        df["score"] = df["score"].astype("Int64")
        df["admissible"] = df["admissible"].map(
            lambda x: bool(x) if x is not None else False
        )
    return df


# ---------------------------------------------------------------------------
# JSONL loaders → DataFrame
# ---------------------------------------------------------------------------


def load_diary(run_id: str) -> pd.DataFrame:
    """Load diary JSONL (all players, all turns) as a DataFrame."""
    rows = _cloud_jsonl(run_id, "diary.jsonl")
    df = pd.DataFrame(rows)
    if not df.empty and "turn" in df.columns:
        df["turn"] = df["turn"].astype("Int64")
    return df


def load_cities(run_id: str) -> pd.DataFrame:
    """Load city snapshots JSONL as a DataFrame."""
    rows = _cloud_jsonl(run_id, "cities.jsonl")
    df = pd.DataFrame(rows)
    if not df.empty and "turn" in df.columns:
        df["turn"] = df["turn"].astype("Int64")
    return df


def load_log(run_id: str) -> pd.DataFrame:
    """Load tool-call log JSONL as a DataFrame."""
    rows = _cloud_jsonl(run_id, "log.jsonl")
    df = pd.DataFrame(rows)
    if not df.empty:
        if "turn" in df.columns:
            df["turn"] = df["turn"].astype("Int64")
        if "ts" in df.columns:
            df["timestamp"] = pd.to_datetime(df["ts"], unit="s", utc=True)
        if "duration_ms" in df.columns:
            df["duration_s"] = df["duration_ms"] / 1000
    return df


def load_spatial(run_id: str) -> pd.DataFrame:
    """Load spatial attention JSONL as a DataFrame."""
    rows = _cloud_jsonl(run_id, "spatial.jsonl")
    df = pd.DataFrame(rows)
    if not df.empty and "turn" in df.columns:
        df["turn"] = df["turn"].astype("Int64")
    return df


# ---------------------------------------------------------------------------
# Convenience
# ---------------------------------------------------------------------------


def agent_turns(run_id: str) -> pd.DataFrame:
    """Load agent-only rows (one per turn) as a DataFrame."""
    diary = cloud_diary(run_id)
    rows = _agent_rows(diary)
    df = pd.DataFrame(rows)
    if not df.empty and "turn" in df.columns:
        df["turn"] = df["turn"].astype("Int64")
    return df


# ---------------------------------------------------------------------------
# Scoring
# ---------------------------------------------------------------------------

DIMENSIONS = [
    "Overall Score",
    "Economic Management",
    "Military Competence",
    "Scientific Progress",
    "Diplomatic Skill",
    "Spatial Reasoning",
    "Tool-Use Fluency",
    "Long-Horizon Coherence",
]


def score_game(run_id: str) -> dict[str, dict]:
    """Score a game across all 8 dimensions. Returns {dim: {score, details}}."""
    diary = cloud_diary(run_id)
    log = cloud_log(run_id)
    if not diary:
        return {d: {"score": 0, "details": "No data"} for d in DIMENSIONS}
    return _score_game_raw(diary, log)


def scorecard(
    models: list[str] | None = None,
    scenario: str | None = None,
) -> pd.DataFrame:
    """Score all admissible games, return model × dimension DataFrame."""
    games_df = list_games()
    if games_df.empty:
        return pd.DataFrame()

    # Filter
    mask = games_df["admissible"] == True  # noqa: E712
    if scenario:
        mask &= games_df["scenario"] == scenario
    if models:
        mask &= games_df["model"].isin(models)
    subset = games_df[mask]

    rows = []
    for _, g in subset.iterrows():
        scores = score_game(g["run_id"])
        row = {
            "run_id": g["run_id"],
            "model": g["model"],
            "scenario": g["scenario"],
            "turns": g["turns"],
            "result": g["result"],
        }
        for dim in DIMENSIONS:
            row[dim] = scores[dim]["score"]
        row["aggregate"] = sum(scores[d]["score"] for d in DIMENSIONS) / len(DIMENSIONS)
        rows.append(row)

    df = pd.DataFrame(rows)
    return df


def scorecard_summary(
    models: list[str] | None = None,
    scenario: str | None = None,
) -> pd.DataFrame:
    """Mean scores per model across dimensions."""
    card = scorecard(models=models, scenario=scenario)
    if card.empty:
        return card
    score_cols = DIMENSIONS + ["aggregate"]
    return card.groupby("model")[score_cols].mean().round(1)
