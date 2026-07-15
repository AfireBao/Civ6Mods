#!/usr/bin/env python3
"""Sync civ-mcp JSONL files to Convex.

Three modes, different roles:

  --watch  (default, local file watching)
    Long-running process. Uses watchfiles.awatch on ~/.civ6-mcp/ and streams
    diary/log updates incrementally as the MCP server writes them. Tracks
    per-file line counts in .sync_state.json so re-runs are idempotent. Runs
    check_idle_games every 5 min to auto-complete stalled games. This is
    what the orchestrator runs in a persistent tmux session per machine so
    live games stream to Convex in real time.

  --upload DIR  (one-shot batch)
    Scans a directory for game files, applies should_sync_game() quality
    gate (skip <10 turn micro-runs), ingests each game, and calls
    completeGame to set outcome + admissibility. Called by the orchestrator
    at post-game as a "finalisation" step — runs in 10-30s and is mostly a
    no-op for files the watcher has already streamed.

  --cloud BUCKET  (one-shot batch from cloud)
    Reads game files from Azure/GCS/S3 instead of a local dir. Used for
    historical backfill and cross-machine recovery, not live operation.

  --backfill-outcomes --cloud BUCKET
    Scans completed games with missing outcomes, fetches their log.jsonl
    from cloud storage, parses game_over events (or falls back to tool_call
    regex), and patches completeGame. For recovering outcomes from games
    that completed before the scumming/game-over detection fixes landed.

Usage:
    python scripts/convex_sync.py --prod                       # live watch (prod)
    python scripts/convex_sync.py --upload ~/.civ6-mcp --prod  # post-game batch
    python scripts/convex_sync.py --cloud az://telemetry --prod
    python scripts/convex_sync.py --backfill-outcomes --cloud az://telemetry --prod

Env files are loaded from web/ relative to this script. Environment variables
CONVEX_URL and CONVEX_DEPLOY_KEY override file values if set.

Optional:
    CIV6_DIARY_DIR=~/.civ6-mcp   (default, for local watch mode)
"""

from __future__ import annotations

import argparse
import asyncio
import hashlib
import json
import logging
import os
import re
import signal
import sys
import time
from glob import glob
from pathlib import Path
from typing import Any

import httpx
import watchfiles

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger("convex_sync")

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

SCRIPT_DIR = Path(__file__).resolve().parent
WEB_DIR = SCRIPT_DIR.parent / "web"


def _load_env_file(path: Path) -> dict[str, str]:
    """Parse a .env file into a dict. Ignores comments and blank lines."""
    env: dict[str, str] = {}
    if not path.exists():
        return env
    for line in path.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            continue
        key, _, value = line.partition("=")
        key = key.strip()
        value = value.strip().split("#")[0].strip()  # strip inline comments
        env[key] = value
    return env


def _resolve_config(prod: bool) -> tuple[str, str]:
    """Resolve CONVEX_URL and CONVEX_DEPLOY_KEY from env file + environment.

    Environment variables take precedence over file values.
    """
    env_file = WEB_DIR / (".env.prod" if prod else ".env.dev")
    file_env = _load_env_file(env_file)

    convex_url = os.environ.get("CONVEX_URL") or file_env.get("CONVEX_URL", "")
    deploy_key = os.environ.get("CONVEX_DEPLOY_KEY") or file_env.get(
        "CONVEX_DEPLOY_KEY", ""
    )

    # .env.local uses NEXT_PUBLIC_CONVEX_URL, .env.prod uses CONVEX_URL
    if not convex_url:
        convex_url = file_env.get("NEXT_PUBLIC_CONVEX_URL", "")

    return convex_url, deploy_key


DIARY_DIR = Path(os.environ.get("CIV6_DIARY_DIR", Path.home() / ".civ6-mcp"))
STATE_FILE = DIARY_DIR / ".sync_state.json"

# How many recent diary lines to re-check for reflection merges
DIARY_LOOKBACK = 12
# Batch size for Convex mutations
BATCH_SIZE = 50
# Idle timeout before marking a game as completed (seconds)
IDLE_TIMEOUT = 30 * 60
# Retry config
MAX_RETRIES = 3
RETRY_BACKOFF = [1, 3, 10]

# ---------------------------------------------------------------------------
# State management
# ---------------------------------------------------------------------------


def load_state() -> dict[str, Any]:
    if STATE_FILE.exists():
        try:
            return json.loads(STATE_FILE.read_text())
        except (json.JSONDecodeError, OSError):
            log.warning("Corrupt state file, starting fresh")
    return {"files": {}, "game_last_seen": {}}


def save_state(state: dict[str, Any]) -> None:
    STATE_FILE.parent.mkdir(parents=True, exist_ok=True)
    tmp = STATE_FILE.with_suffix(".tmp")
    try:
        tmp.write_text(json.dumps(state, indent=2))
        tmp.rename(STATE_FILE)
    except OSError:
        # Atomic rename can fail on some FS configs; fall back to direct write
        STATE_FILE.write_text(json.dumps(state, indent=2))
        tmp.unlink(missing_ok=True)


# ---------------------------------------------------------------------------
# File classification
# ---------------------------------------------------------------------------


def classify_file(name: str) -> str | None:
    """Return file type: 'diary', 'cities', 'spatial', 'mapturns', or None."""
    if name.startswith("diary_") and name.endswith("_cities.jsonl"):
        return "cities"
    if name.startswith("diary_") and name.endswith(".jsonl"):
        return "diary"
    if name.startswith("spatial_") and name.endswith(".jsonl"):
        return "spatial"
    if name.startswith("mapturns_") and name.endswith(".jsonl"):
        return "mapturns"
    return None


def extract_game_id(name: str) -> str:
    """Extract game ID from filename: diary_india_123.jsonl → india_123"""
    name = (
        name.removesuffix("_cities.jsonl").removesuffix(".jsonl").removesuffix(".json")
    )
    for prefix in ("diary_", "spatial_", "mapstatic_", "mapturns_"):
        if name.startswith(prefix):
            name = name[len(prefix) :]
    return name


def hash_lines(lines: list[str]) -> str:
    """Content hash for a set of lines."""
    return hashlib.md5("".join(lines).encode()).hexdigest()


MIN_TURNS_TO_SYNC = 10


def should_sync_game(
    files: dict[str, Path],
) -> tuple[bool, str | None]:
    """Check if a game has enough data to be worth syncing.

    Returns (should_sync, exclude_reason).
    - (True, None) = sync normally
    - (True, "reason") = sync but mark as excluded
    - (False, "reason") = skip entirely
    """
    diary_path = files.get("diary")
    if not diary_path or not diary_path.exists():
        return False, "no_diary"

    # Count diary lines (each line = one player-turn observation)
    try:
        with open(diary_path) as f:
            line_count = sum(1 for _ in f)
    except Exception:
        return False, "unreadable_diary"

    if line_count < MIN_TURNS_TO_SYNC:
        return False, f"micro_run ({line_count} lines)"

    # Check max turn from last diary entry
    try:
        with open(diary_path, "rb") as f:
            # Read last non-empty line efficiently
            f.seek(0, 2)
            pos = f.tell()
            while pos > 0:
                pos -= 1
                f.seek(pos)
                if f.read(1) == b"\n" and pos < f.tell() - 1:
                    break
            last_line = f.readline().decode().strip()
            if last_line:
                last = json.loads(last_line)
                max_turn = last.get("turn", 0)
                if max_turn < MIN_TURNS_TO_SYNC:
                    return False, f"early_abort (max turn {max_turn})"
    except Exception:
        pass  # non-fatal — line count check above is sufficient

    return True, None


def discover_games(directory: Path) -> dict[str, dict[str, Path]]:
    """Scan directory for JSONL/JSON game files, grouped by game_id.

    Returns {game_id: {file_type: path, ...}, ...}
    """
    games: dict[str, dict[str, Path]] = {}
    for f in sorted(directory.iterdir()):
        if f.is_dir():
            continue
        name = f.name
        ftype = classify_file(name)
        if ftype is None:
            # Also pick up mapstatic JSON files (consumed by sync_map_data)
            if name.startswith("mapstatic_") and name.endswith(".json"):
                ftype = "mapstatic"
            else:
                continue
        game_id = extract_game_id(name)
        games.setdefault(game_id, {})[ftype] = f
    return games


# ---------------------------------------------------------------------------
# Cloud source (via fsspec)
# ---------------------------------------------------------------------------


def _get_cloud_fs(bucket_url: str) -> tuple[Any, str]:
    """Create fsspec filesystem from bucket URL.

    Returns (fs, prefix) where prefix is the path portion without scheme.
    E.g. "az://civbench" → (AzureBlobFileSystem, "civbench").

    Loads Azure credentials from evals/.env if present, then falls back
    to environment variables, then DefaultAzureCredential.
    """
    import fsspec

    scheme = bucket_url.split("://")[0]
    prefix = bucket_url[len(scheme) + 3 :]

    # Load credentials from evals/.env if available
    evals_env = SCRIPT_DIR.parent / "evals" / ".env"
    env = _load_env_file(evals_env)

    conn_str = env.get("AZURE_STORAGE_CONNECTION_STRING", "") or os.environ.get(
        "AZURE_STORAGE_CONNECTION_STRING", ""
    )
    if conn_str:
        fs = fsspec.filesystem(scheme, connection_string=conn_str)
        return fs, prefix

    account = env.get("AZURE_STORAGE_ACCOUNT_NAME", "") or os.environ.get(
        "AZURE_STORAGE_ACCOUNT_NAME", ""
    )
    key = env.get("AZURE_STORAGE_ACCOUNT_KEY", "") or os.environ.get(
        "AZURE_STORAGE_ACCOUNT_KEY", ""
    )
    if account and key:
        fs = fsspec.filesystem(scheme, account_name=account, account_key=key)
        return fs, prefix

    # Fallback: no explicit credentials (relies on DefaultAzureCredential / az login)
    if account:
        try:
            from azure.identity import DefaultAzureCredential

            fs = fsspec.filesystem(
                scheme, account_name=account, credential=DefaultAzureCredential()
            )
            return fs, prefix
        except Exception:
            pass

    fs = fsspec.filesystem(scheme)
    return fs, prefix


def discover_cloud_runs(bucket_url: str) -> list[dict[str, Any]]:
    """List all runs in a cloud bucket by reading their manifest.json files."""
    fs, prefix = _get_cloud_fs(bucket_url)
    try:
        manifest_paths = fs.glob(f"{prefix}/runs/*/manifest.json")
    except Exception:
        log.exception("Failed to list cloud manifests at %s", bucket_url)
        return []

    manifests = []
    for mp in manifest_paths:
        try:
            data = json.loads(fs.cat_file(mp))
            manifests.append(data)
        except Exception:
            log.warning("Failed to read manifest: %s", mp)
    return manifests


def discover_eval_files(run_id: str) -> list[str]:
    """Discover .eval filenames for a run from cloud or local storage.

    Returns just the filenames (not full paths) — these are stored in Convex
    and combined with the blob base URL + run_id to construct download links.
    """
    # Try cloud storage first
    bucket_url = os.environ.get("CIV_MCP_TELEMETRY_BUCKET", "")
    if bucket_url:
        try:
            fs, prefix = _get_cloud_fs(bucket_url)
            paths = fs.glob(f"{prefix}/runs/{run_id}/*.eval")
            names = [p.rsplit("/", 1)[-1] for p in paths]
            if names:
                log.debug(
                    "Found %d .eval file(s) in cloud for run %s", len(names), run_id
                )
                return names
        except Exception:
            log.debug("Could not list .eval files in cloud for run %s", run_id)

    # Fall back to local logs/ directory
    local_logs = SCRIPT_DIR.parent / "logs"
    if local_logs.exists():
        names = [f.name for f in local_logs.glob("*.eval")]
        if names:
            log.debug("Found %d .eval file(s) in local logs/", len(names))
            return names

    return []


def _extract_outcome(log_lines: list[str]) -> dict[str, Any] | None:
    """Extract game outcome from log JSONL lines.

    Returns patchGameOutcome-shaped dict or None if no game_over found.
    """
    outcome = None
    for line in log_lines:
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue
        if entry.get("type") == "game_over":
            o = entry.get("outcome", {})
            outcome = {
                "result": "defeat" if o.get("is_defeat") else "victory",
                "winnerCiv": o.get("winner_civ", ""),
                "winnerLeader": o.get("winner_leader", ""),
                "victoryType": o.get("victory_type", ""),
                "turn": entry.get("turn", 0),
                "playerAlive": o.get("player_alive", True),
            }
    return outcome


# Patterns for parsing game-over from end_turn tool_call result strings
_DEFEAT_RE = re.compile(
    r"GAME OVER — DEFEAT\. (.+?) of (.+?) won a (.+?) victory", re.IGNORECASE
)
_VICTORY_RE = re.compile(r"GAME OVER — VICTORY! You won a (.+?) victory", re.IGNORECASE)


def _extract_outcome_from_tool_calls(
    log_lines: list[str], civ: str = "", leader: str = ""
) -> dict[str, Any] | None:
    """Parse outcome from end_turn tool_call results when game_over event is missing.

    The _logged() wrapper writes every tool result to log.jsonl. Even when
    log_game_over() fails, the "GAME OVER" result string is captured.
    """
    for line in reversed(log_lines):
        try:
            entry = json.loads(line)
        except json.JSONDecodeError:
            continue
        if entry.get("type") != "tool_call":
            continue
        result = entry.get("result", "")
        if "GAME OVER" not in result:
            continue

        m = _DEFEAT_RE.search(result)
        if m:
            return {
                "result": "defeat",
                "winnerLeader": m.group(1),
                "winnerCiv": m.group(2),
                "victoryType": m.group(3),
                "turn": entry.get("turn", 0),
                "playerAlive": "eliminated" not in result.lower(),
            }
        m = _VICTORY_RE.search(result)
        if m:
            return {
                "result": "victory",
                "winnerCiv": civ,
                "winnerLeader": leader,
                "victoryType": m.group(1),
                "turn": entry.get("turn", 0),
                "playerAlive": True,
            }
    return None


async def _complete_game(
    game_id: str,
    client: "ConvexClient",
    log_lines: list[str] | None = None,
    civ: str = "",
    leader: str = "",
    agent_model: str = "",
) -> None:
    """Mark a game as completed via completeGame mutation.

    Sets outcome (if found), agent model, snapshots eloPlayers, and computes
    admissibility atomically.
    """
    outcome = _extract_outcome(log_lines) if log_lines else None
    if outcome is None and log_lines:
        outcome = _extract_outcome_from_tool_calls(log_lines, civ, leader)
        if outcome:
            log.info("Recovered outcome from tool_call result for %s", game_id)

    args: dict[str, Any] = {"gameId": game_id}
    if outcome:
        args["outcome"] = outcome
    if agent_model:
        args["agentModel"] = agent_model

    await client.mutation("ingest:completeGame", args)

    if outcome:
        log.info(
            "Completed %s: %s — %s (%s)",
            game_id,
            outcome["result"],
            outcome["winnerCiv"],
            outcome["victoryType"],
        )
    else:
        log.info("Completed %s (no outcome found)", game_id)

    # Compute 8-dimension scores and patch onto game doc
    try:
        from analyze import cloud_diary, cloud_log, score_game

        run_id = game_id.rsplit("_", 1)[-1] if "_" in game_id else game_id
        diary = cloud_diary(run_id)
        log_data = cloud_log(run_id)
        if diary:
            scores = score_game(diary, log_data)
            dim = {
                "overall": float(scores["Overall Score"]["score"]),
                "economic": float(scores["Economic Management"]["score"]),
                "military": float(scores["Military Competence"]["score"]),
                "scientific": float(scores["Scientific Progress"]["score"]),
                "diplomatic": float(scores["Diplomatic Skill"]["score"]),
                "spatial": float(scores["Spatial Reasoning"]["score"]),
                "toolFluency": float(scores["Tool-Use Fluency"]["score"]),
                "coherence": float(scores["Long-Horizon Coherence"]["score"]),
            }
            await client.mutation(
                "ingest:patchGameFields",
                {"gameId": game_id, "patch": {"dimensionScores": dim}},
            )
            avg = sum(dim.values()) / 8
            log.info("Scored %s: avg=%.0f", game_id, avg)
    except Exception:
        log.debug("Dimension scoring failed for %s", game_id, exc_info=True)


def _cloud_run_outcome(
    fs: Any, prefix: str, run_id: str, civ: str = "", leader: str = ""
) -> dict[str, Any] | None:
    """Extract game outcome from a cloud run's log file."""
    log_path = f"{prefix}/runs/{run_id}/log.jsonl"
    try:
        content = fs.cat_file(log_path).decode("utf-8")
        lines = content.splitlines()
        outcome = _extract_outcome(lines)
        if outcome is None:
            outcome = _extract_outcome_from_tool_calls(lines, civ, leader)
        return outcome
    except FileNotFoundError:
        return None
    except Exception:
        log.warning("Failed to read log for run %s", run_id)
        return None


def _download_cloud_run(
    fs: Any, prefix: str, run_id: str, manifest: dict[str, Any], dest_dir: Path
) -> str | None:
    """Download a cloud run's files to dest_dir with local naming conventions.

    Returns the game_id (e.g. "babylon_-1498189056_abc12345") or None.
    """
    civ = manifest.get("civ", "")
    seed = manifest.get("seed", "")

    if not civ or seed == "":
        log.warning("Run %s: incomplete manifest (no civ/seed) — skipping", run_id)
        return None

    game_id = f"{civ}_{seed}_{run_id}"

    # Cloud filename → local filename (matches LocalSink naming)
    file_map = {
        "diary.jsonl": f"diary_{game_id}.jsonl",
        "cities.jsonl": f"diary_{game_id}_cities.jsonl",
        "spatial.jsonl": f"spatial_{game_id}.jsonl",
        "map_static.json": f"mapstatic_{game_id}.json",
        "map_turns.jsonl": f"mapturns_{game_id}.jsonl",
    }

    downloaded = 0
    for cloud_name, local_name in file_map.items():
        cloud_path = f"{prefix}/runs/{run_id}/{cloud_name}"
        local_path = dest_dir / local_name
        try:
            data = fs.cat_file(cloud_path)
            local_path.write_bytes(data)
            downloaded += 1
        except FileNotFoundError:
            pass  # Not all file types exist for every run
        except Exception:
            log.warning("Failed to download %s", cloud_path)

    if downloaded == 0:
        log.warning("Run %s: no data files found in cloud", run_id)
        return None

    log.debug("Downloaded run %s → %s (%d files)", run_id, game_id, downloaded)
    return game_id


# ---------------------------------------------------------------------------
# Convex HTTP client
# ---------------------------------------------------------------------------


class ConvexClient:
    def __init__(self, url: str, deploy_key: str) -> None:
        self.base_url = url.rstrip("/")
        self.client = httpx.AsyncClient(
            timeout=30,
            headers={
                "Content-Type": "application/json",
                "Authorization": f"Convex {deploy_key}",
            },
        )

    async def mutation(self, path: str, args: dict[str, Any]) -> Any:
        """Call a Convex mutation with retries. Raises on persistent failure."""
        url = f"{self.base_url}/api/mutation"
        payload = {"path": path, "args": args, "format": "json"}
        last_error: Exception | None = None
        for attempt in range(MAX_RETRIES):
            try:
                resp = await self.client.post(url, json=payload)
                data = resp.json()
                if data.get("status") == "success":
                    return data.get("value")
                last_error = RuntimeError(
                    f"Mutation {path} failed: {data.get('errorMessage')}"
                )
                log.error("Mutation %s failed: %s", path, data.get("errorMessage"))
                if attempt < MAX_RETRIES - 1:
                    await asyncio.sleep(RETRY_BACKOFF[attempt])
            except (httpx.HTTPError, json.JSONDecodeError) as e:
                last_error = e
                log.exception("HTTP error calling %s", path)
                if attempt < MAX_RETRIES - 1:
                    await asyncio.sleep(RETRY_BACKOFF[attempt])
        raise last_error or RuntimeError(
            f"Mutation {path} failed after {MAX_RETRIES} retries"
        )

    async def close(self) -> None:
        await self.client.aclose()


# ---------------------------------------------------------------------------
# Sync logic per file type
# ---------------------------------------------------------------------------


async def sync_diary(
    path: Path, game_id: str, state: dict, client: ConvexClient
) -> None:
    """Sync a diary JSONL file (player rows). Handles reflection merges."""
    name = path.name
    file_state = state["files"].get(name, {"line_count": 0, "tail_hash": ""})

    lines = path.read_text().strip().splitlines()
    total = len(lines)

    if total == 0:
        return

    # Determine what to check: new lines + lookback window for merges
    old_count = file_state.get("line_count", 0)
    lookback_start = max(0, old_count - DIARY_LOOKBACK)
    tail_lines = lines[lookback_start:]
    new_hash = hash_lines(tail_lines)

    if old_count == total and new_hash == file_state.get("tail_hash"):
        return  # No changes

    # Parse rows that may be new or changed
    rows_to_upsert = []
    for line in tail_lines:
        try:
            rows_to_upsert.append(json.loads(line))
        except json.JSONDecodeError:
            continue

    if not rows_to_upsert:
        return

    # Extract civ/leader from first agent row
    agent_row = next(
        (r for r in rows_to_upsert if r.get("is_agent")), rows_to_upsert[0]
    )
    civ = agent_row.get("civ", "")
    leader = agent_row.get("leader", "")
    # Read seed from row data's "game" field (= "civ_seed"), not from
    # the filename-based game_id which now includes the run_id suffix.
    game_field = agent_row.get("game", "")
    seed = game_field.rsplit("_", 1)[-1] if "_" in game_field else ""

    # Extract run_id from game_id (format: civ_seed_runid)
    # Run IDs are hex/alphanumeric; seeds are numeric (possibly negative)
    parts = game_id.rsplit("_", 1)
    candidate = parts[-1] if len(parts) > 1 else ""
    run_id = candidate if candidate and not candidate.lstrip("-").isdigit() else None

    # Discover .eval files associated with this run
    eval_files = discover_eval_files(run_id) if run_id else []

    # Batch and send
    for i in range(0, len(rows_to_upsert), BATCH_SIZE):
        batch = rows_to_upsert[i : i + BATCH_SIZE]
        args: dict[str, Any] = {
            "gameId": game_id,
            "civ": civ,
            "leader": leader,
            "seed": seed,
            "rows": batch,
        }
        if run_id:
            args["runId"] = run_id
        if eval_files:
            args["evalFiles"] = eval_files
        await client.mutation("ingest:ingestPlayerRows", args)

    log.info(
        "diary %s: synced %d rows (total %d lines)", game_id, len(rows_to_upsert), total
    )
    file_state["line_count"] = total
    file_state["tail_hash"] = new_hash
    state["files"][name] = file_state
    state["game_last_seen"][game_id] = time.time()


async def sync_cities(
    path: Path, game_id: str, state: dict, client: ConvexClient
) -> None:
    """Sync a cities diary JSONL file. Append-only — use line count."""
    name = path.name
    file_state = state["files"].get(name, {"line_count": 0})

    lines = path.read_text().strip().splitlines()
    total = len(lines)
    old_count = file_state.get("line_count", 0)

    if total <= old_count:
        return

    new_lines = lines[old_count:]
    rows = []
    for line in new_lines:
        try:
            rows.append(json.loads(line))
        except json.JSONDecodeError:
            continue

    if not rows:
        return

    for i in range(0, len(rows), BATCH_SIZE * 2):
        batch = rows[i : i + BATCH_SIZE * 2]
        await client.mutation(
            "ingest:ingestCityRows", {"gameId": game_id, "rows": batch}
        )

    log.info("cities %s: synced %d new rows", game_id, len(rows))
    file_state["line_count"] = total
    state["files"][name] = file_state
    state["game_last_seen"][game_id] = time.time()


async def sync_spatial(
    path: Path, game_id: str, state: dict, client: ConvexClient
) -> None:
    """Sync a spatial JSONL file. Aggregates per-turn and pushes to Convex."""
    name = path.name
    file_state = state["files"].get(name, {"line_count": 0})

    lines = path.read_text().strip().splitlines()
    total = len(lines)
    old_count = file_state.get("line_count", 0)

    if total <= old_count:
        return

    # Parse all entries (re-process from start for cumulative tracking)
    entries: list[dict[str, Any]] = []
    for line in lines:
        try:
            entries.append(json.loads(line))
        except json.JSONDecodeError:
            continue

    if not entries:
        return

    # Group by turn and compute aggregates
    by_turn: dict[int, list[dict[str, Any]]] = {}
    for entry in entries:
        turn = entry.get("turn")
        if turn is None:
            continue
        by_turn.setdefault(turn, []).append(entry)

    cumulative_tiles: set[tuple[int, int]] = set()
    rows: list[dict[str, Any]] = []

    for turn in sorted(by_turn.keys()):
        turn_entries = by_turn[turn]
        turn_tiles: set[tuple[int, int]] = set()
        by_type: dict[str, int] = {
            "deliberate_scan": 0,
            "deliberate_action": 0,
            "survey": 0,
            "peripheral": 0,
            "reactive": 0,
        }
        total_ms = 0

        for entry in turn_entries:
            for tile in entry.get("tiles", []):
                if isinstance(tile, list) and len(tile) == 2:
                    turn_tiles.add((tile[0], tile[1]))
            atype = entry.get("type", "")
            if atype in by_type:
                by_type[atype] += 1
            total_ms += entry.get("ms", 0)

        cumulative_tiles |= turn_tiles
        rows.append(
            {
                "turn": turn,
                "tiles_observed": len(turn_tiles),
                "tool_calls": len(turn_entries),
                "cumulative_tiles": len(cumulative_tiles),
                "total_ms": total_ms,
                "by_type": by_type,
            }
        )

    if not rows:
        return

    # Only push rows for turns we haven't synced yet
    last_synced_turn = file_state.get("last_turn", -1)
    new_rows = [r for r in rows if r["turn"] > last_synced_turn]
    if not new_rows:
        file_state["line_count"] = total
        state["files"][name] = file_state
        return

    for i in range(0, len(new_rows), BATCH_SIZE):
        batch = new_rows[i : i + BATCH_SIZE]
        await client.mutation(
            "ingest:ingestSpatialTurns",
            {"gameId": game_id, "rows": batch},
        )

    log.info(
        "spatial %s: synced %d new turn aggregates (%d total)",
        game_id,
        len(new_rows),
        len(rows),
    )
    file_state["line_count"] = total
    file_state["last_turn"] = max(r["turn"] for r in new_rows)
    state["files"][name] = file_state
    state["game_last_seen"][game_id] = time.time()

    # Also push tile-level heatmap blob
    await sync_spatial_map(entries, game_id, client)


async def sync_spatial_map(
    entries: list[dict[str, Any]], game_id: str, client: ConvexClient
) -> None:
    """Compute per-tile aggregates from spatial entries and push as one blob."""
    TYPE_MAP = {
        "deliberate_scan": "ds",
        "deliberate_action": "da",
        "survey": "sv",
        "peripheral": "pe",
        "reactive": "re",
    }

    tile_data: dict[tuple[int, int], dict[str, int]] = {}

    for entry in entries:
        turn = entry.get("turn")
        short = TYPE_MAP.get(entry.get("type", ""), "")
        if turn is None:
            continue
        for tile in entry.get("tiles", []):
            if not isinstance(tile, list) or len(tile) != 2:
                continue
            key = (tile[0], tile[1])
            if key not in tile_data:
                tile_data[key] = {
                    "ds": 0,
                    "da": 0,
                    "sv": 0,
                    "pe": 0,
                    "re": 0,
                    "ft": turn,
                    "lt": turn,
                }
            td = tile_data[key]
            if short:
                td[short] += 1
            td["ft"] = min(td["ft"], turn)
            td["lt"] = max(td["lt"], turn)

    if not tile_data:
        return

    xs = [k[0] for k in tile_data]
    ys = [k[1] for k in tile_data]
    min_x, max_x = min(xs), max(xs)
    min_y, max_y = min(ys), max(ys)

    # Pack: [x, y, total, ds, da, sv, pe, re, firstTurn, lastTurn] per tile
    flat: list[int] = []
    for (x, y), td in tile_data.items():
        total = td["ds"] + td["da"] + td["sv"] + td["pe"] + td["re"]
        flat.extend(
            [
                x,
                y,
                total,
                td["ds"],
                td["da"],
                td["sv"],
                td["pe"],
                td["re"],
                td["ft"],
                td["lt"],
            ]
        )

    await client.mutation(
        "ingest:ingestSpatialMap",
        {
            "gameId": game_id,
            "minX": min_x,
            "maxX": max_x,
            "minY": min_y,
            "maxY": max_y,
            "tileCount": len(tile_data),
            "tiles": flat,
        },
    )
    log.info(
        "spatial map %s: %d tiles, bounds (%d,%d)-(%d,%d)",
        game_id,
        len(tile_data),
        min_x,
        min_y,
        max_x,
        max_y,
    )


_FRAME_CHUNK_LIMIT = 700_000  # bytes per chunk, well under 1MB with overhead


def _chunk_map_frames(
    turn_entries: list[dict[str, Any]],
) -> list[dict[str, str]]:
    """Split per-turn map deltas into chunks that fit under Convex's doc limit.

    Packs frames per-turn into flat arrays, then greedily groups turns into
    chunks by cumulative JSON byte size. Returns list of dicts with
    ownerFrames/cityFrames/roadFrames as JSON strings.
    """
    # Build per-turn packed segments
    per_turn: list[tuple[list[int], list[int], list[int]]] = []
    for entry in turn_entries:
        turn = entry.get("turn", 0)
        o: list[int] = []
        c: list[int] = []
        r: list[int] = []

        owners = entry.get("owners", [])
        if owners:
            o = [turn, len(owners) // 2, *owners]

        cities = entry.get("cities", [])
        if cities:
            c = [turn, len(cities)]
            for city in cities:
                c.extend([city["x"], city["y"], city["pid"], city["pop"]])

        roads = entry.get("roads", [])
        if roads:
            r = [turn, len(roads) // 2, *roads]

        per_turn.append((o, c, r))

    # Greedily pack turns into chunks
    chunks: list[dict[str, str]] = []
    cur_o: list[int] = []
    cur_c: list[int] = []
    cur_r: list[int] = []
    cur_size = 0

    def _flush() -> None:
        nonlocal cur_o, cur_c, cur_r, cur_size
        if cur_o or cur_c or cur_r:
            chunks.append(
                {
                    "ownerFrames": json.dumps(cur_o),
                    "cityFrames": json.dumps(cur_c),
                    "roadFrames": json.dumps(cur_r),
                }
            )
        cur_o, cur_c, cur_r, cur_size = [], [], [], 0

    for o, c, r in per_turn:
        # Estimate size of this turn's data (rough: ~4 chars per int + commas)
        turn_size = (len(o) + len(c) + len(r)) * 5
        if cur_size + turn_size > _FRAME_CHUNK_LIMIT and cur_size > 0:
            _flush()
        cur_o.extend(o)
        cur_c.extend(c)
        cur_r.extend(r)
        cur_size += turn_size

    _flush()
    return chunks


async def sync_map_data(
    path: Path, game_id: str, state: dict, client: ConvexClient
) -> None:
    """Sync strategic map data (static terrain + per-turn deltas) to Convex.

    Reads mapstatic_{id}.json for terrain grid + initial state, and
    mapturns_{id}.jsonl for per-turn ownership/road/city deltas.
    Packs everything into flat arrays and sends as a single mutation.
    """
    name = path.name
    file_state = state["files"].get(name, {"line_count": 0})

    lines = path.read_text().strip().splitlines()
    total = len(lines)
    old_count = file_state.get("line_count", 0)

    if total <= old_count:
        return

    # Find the corresponding mapstatic JSON file
    static_name = name.replace("mapturns_", "mapstatic_").replace(".jsonl", ".json")
    static_path = path.parent / static_name
    if not static_path.exists():
        log.debug("Map static file not found for %s", game_id)
        return

    # Read static data
    try:
        static_data = json.loads(static_path.read_text())
    except (json.JSONDecodeError, OSError):
        log.warning("Failed to read map static file for %s", game_id)
        return

    # Parse turn deltas
    turn_entries: list[dict[str, Any]] = []
    for line in lines:
        try:
            turn_entries.append(json.loads(line))
        except json.JSONDecodeError:
            continue

    # Pack frames into flat arrays matching Convex schema
    # ownerFrames: [turn, count, tileIdx, owner, ...]
    # cityFrames: [turn, count, x, y, pid, pop, ...]
    # roadFrames: [turn, count, tileIdx, routeType, ...]
    owner_frames: list[int] = []
    city_frames: list[int] = []
    road_frames: list[int] = []
    # city names: "x,y" → name (last seen name wins)
    city_names: dict[str, str] = {}
    max_turn = static_data.get("initialTurn", 0)

    # Seed city names from initial cities
    for c in static_data.get("initialCities", []):
        name = c.get("name", "")
        if name:
            city_names[f"{c['x']},{c['y']}"] = name

    for entry in turn_entries:
        turn = entry.get("turn", 0)
        max_turn = max(max_turn, turn)

        owners = entry.get("owners", [])
        if owners:
            owner_frames.append(turn)
            owner_frames.append(len(owners) // 2)
            owner_frames.extend(owners)

        cities = entry.get("cities", [])
        if cities:
            city_frames.append(turn)
            city_frames.append(len(cities))
            for c in cities:
                city_frames.extend([c["x"], c["y"], c["pid"], c["pop"]])
                name = c.get("name", "")
                if name:
                    city_names[f"{c['x']},{c['y']}"] = name

        roads = entry.get("roads", [])
        if roads:
            road_frames.append(turn)
            road_frames.append(len(roads) // 2)
            road_frames.extend(roads)

    # Check if frames fit in a single doc or need chunking
    frames_json = {
        "ownerFrames": json.dumps(owner_frames),
        "cityFrames": json.dumps(city_frames),
        "roadFrames": json.dumps(road_frames),
    }
    frames_bytes = sum(len(v.encode()) for v in frames_json.values())

    # Static payload (always fits — terrain is fixed size)
    static_payload = {
        "gameId": game_id,
        "gridW": static_data["gridW"],
        "gridH": static_data["gridH"],
        "terrain": json.dumps(static_data["terrain"]),
        "initialOwners": json.dumps(static_data["initialOwners"]),
        "initialRoutes": json.dumps(static_data.get("initialRoutes", [])),
        "initialTurn": static_data.get("initialTurn", 0),
        "cityNames": json.dumps(city_names) if city_names else None,
        "players": static_data.get("players", []),
        "maxTurn": max_turn,
    }

    # If frames fit in one doc (~700KB threshold), send inline (simpler)
    if frames_bytes < 700_000:
        static_payload.update(frames_json)
        await client.mutation("ingest:ingestMapData", static_payload)
    else:
        # Chunk frames into multiple docs
        chunks = _chunk_map_frames(turn_entries)
        static_payload["frameChunks"] = len(chunks)
        await client.mutation("ingest:ingestMapData", static_payload)
        for i, chunk in enumerate(chunks):
            await client.mutation(
                "ingest:ingestMapFrames",
                {
                    "gameId": game_id,
                    "chunk": i,
                    **chunk,
                },
            )
        log.info(
            "map %s: frames split into %d chunks (%dKB total)",
            game_id,
            len(chunks),
            frames_bytes // 1024,
        )

    log.info(
        "map %s: %dx%d grid, %d turn deltas, maxTurn=%d",
        game_id,
        static_data["gridW"],
        static_data["gridH"],
        len(turn_entries),
        max_turn,
    )
    file_state["line_count"] = total
    state["files"][name] = file_state
    state["game_last_seen"][game_id] = time.time()


# ---------------------------------------------------------------------------
# Dispatcher
# ---------------------------------------------------------------------------


async def sync_file(path: Path, state: dict, client: ConvexClient) -> None:
    """Route a file change to the appropriate sync handler."""
    name = path.name
    ftype = classify_file(name)
    if ftype is None:
        return

    game_id = extract_game_id(name)

    try:
        if ftype == "diary":
            await sync_diary(path, game_id, state, client)
        elif ftype == "cities":
            await sync_cities(path, game_id, state, client)
        elif ftype == "spatial":
            await sync_spatial(path, game_id, state, client)
        elif ftype == "mapturns":
            await sync_map_data(path, game_id, state, client)
    except Exception:
        log.exception("Error syncing %s", name)


async def check_idle_games(state: dict, client: ConvexClient) -> None:
    """Mark games as completed if no writes for IDLE_TIMEOUT."""
    now = time.time()
    for game_id, last_seen in list(state.get("game_last_seen", {}).items()):
        if now - last_seen > IDLE_TIMEOUT:
            log_path = DIARY_DIR / f"log_{game_id}.jsonl"
            log_lines = log_path.read_text().splitlines() if log_path.exists() else None
            # Extract civ/leader/agent_model from diary
            civ, leader, agent_model = "", "", ""
            diary_path = DIARY_DIR / f"diary_{game_id}.jsonl"
            if diary_path.exists():
                try:
                    for dl in diary_path.read_text().splitlines():
                        row = json.loads(dl)
                        if not civ:
                            civ = row.get("civ", "")
                            leader = row.get("leader", "")
                        if row.get("is_agent") and row.get("agent_model"):
                            agent_model = row["agent_model"]
                            break
                except Exception:
                    pass
            await _complete_game(
                game_id,
                client,
                log_lines,
                civ=civ,
                leader=leader,
                agent_model=agent_model,
            )
            del state["game_last_seen"][game_id]


# ---------------------------------------------------------------------------
# Batch upload
# ---------------------------------------------------------------------------


async def batch_upload(directory: Path, client: ConvexClient) -> None:
    """One-shot upload of all JSONL files in directory, then exit."""
    games = discover_games(directory)
    if not games:
        log.error("No game files found in %s", directory)
        return

    log.info("Found %d game(s) in %s:", len(games), directory)
    for gid, files in sorted(games.items()):
        types = ", ".join(sorted(files.keys()))
        log.info("  %s: %s", gid, types)

    # Stateless — never reads/writes .sync_state.json
    state: dict[str, Any] = {"files": {}, "game_last_seen": {}}
    total_start = time.time()
    games_uploaded = 0

    skipped = 0
    for gid, files in sorted(games.items()):
        # Quality gate: skip micro-runs and failed launches
        sync_ok, exclude_reason = should_sync_game(files)
        if not sync_ok:
            log.info("  SKIP %s — %s", gid, exclude_reason)
            skipped += 1
            continue

        game_start = time.time()
        log.info("--- %s ---", gid)

        # Process diary first (creates the games row in Convex)
        for ftype in ("diary", "cities", "spatial", "mapturns"):
            if ftype in files:
                await sync_file(files[ftype], state, client)

        log_path = directory / f"log_{gid}.jsonl"
        log_lines = log_path.read_text().splitlines() if log_path.exists() else None
        # Extract civ/leader/agent_model from diary
        civ, leader, agent_model = "", "", ""
        if "diary" in files:
            try:
                for dl in files["diary"].read_text().splitlines():
                    row = json.loads(dl)
                    if not civ:
                        civ = row.get("civ", "")
                        leader = row.get("leader", "")
                    if row.get("is_agent") and row.get("agent_model"):
                        agent_model = row["agent_model"]
                        break
            except Exception:
                pass
        await _complete_game(
            gid,
            client,
            log_lines,
            civ=civ,
            leader=leader,
            agent_model=agent_model,
        )

        elapsed = time.time() - game_start
        log.info("  %s done (%.1fs)", gid, elapsed)
        games_uploaded += 1

    if skipped:
        log.info("Skipped %d game(s) below quality threshold", skipped)

    total_elapsed = time.time() - total_start
    log.info(
        "=== Batch upload complete: %d game(s) in %.1fs ===",
        games_uploaded,
        total_elapsed,
    )


async def batch_upload_cloud(bucket_url: str, client: ConvexClient) -> None:
    """Batch sync all runs from cloud bucket to Convex.

    Downloads cloud files to a temp directory with local naming conventions,
    then delegates to the existing batch_upload() function.
    """
    import tempfile

    manifests = discover_cloud_runs(bucket_url)
    if not manifests:
        log.error("No runs found in %s", bucket_url)
        return

    fs, prefix = _get_cloud_fs(bucket_url)

    # Only sync runs that have a game identity (civ + seed from bind_game)
    valid = [m for m in manifests if m.get("civ") and m.get("seed") is not None]
    log.info(
        "Found %d run(s) in cloud (%d with game identity)",
        len(manifests),
        len(valid),
    )

    with tempfile.TemporaryDirectory(prefix="civbench_") as tmp:
        tmp_dir = Path(tmp)
        for manifest in valid:
            run_id = manifest.get("run_id", "")
            if not run_id:
                continue
            _download_cloud_run(fs, prefix, run_id, manifest, tmp_dir)

        # Reuse existing batch upload on the downloaded files
        await batch_upload(tmp_dir, client)


# ---------------------------------------------------------------------------
# Watch loop
# ---------------------------------------------------------------------------


async def watch_loop(diary_dir: Path, client: ConvexClient) -> None:
    """Watch directory and stream changes to Convex in real-time.

    NOTE: `should_sync_game()` quality gate is deliberately NOT applied here.
    The watcher streams everything as it arrives so the frontend can show
    games from turn 0 onward. Filtering happens at the display layer via
    `MIN_LIVE_TURNS` in web/src/lib/diary-types.ts. Early-abort games will
    accumulate as short-lived `status="live"` rows that get marked
    `completed` by `check_idle_games` after 30 min and then filtered out
    by the frontend because they fail the `admissible` threshold (T<50).
    """
    state = load_state()

    # Graceful shutdown
    shutdown = asyncio.Event()

    def on_signal(*_: Any) -> None:
        log.info("Shutting down...")
        shutdown.set()

    for sig in (signal.SIGINT, signal.SIGTERM):
        signal.signal(sig, on_signal)

    try:
        # Initial sync: process all existing files
        for pattern in (
            "diary_*.jsonl",
            "spatial_*.jsonl",
            "mapturns_*.jsonl",
        ):
            for filepath in sorted(glob(str(diary_dir / pattern))):
                await sync_file(Path(filepath), state, client)
        save_state(state)
        log.info("Initial sync complete")

        # Watch for changes
        idle_check_time = time.time()
        async for changes in watchfiles.awatch(
            diary_dir,
            watch_filter=lambda _, p: p.endswith(".jsonl"),
            stop_event=shutdown,
        ):
            for _, filepath in changes:
                await sync_file(Path(filepath), state, client)
            save_state(state)

            # Periodically check for idle games
            if time.time() - idle_check_time > 300:
                await check_idle_games(state, client)
                save_state(state)
                idle_check_time = time.time()

    finally:
        save_state(state)
        log.info("State saved, exiting")


# ---------------------------------------------------------------------------
# Backfill missing outcomes
# ---------------------------------------------------------------------------


async def backfill_outcomes(bucket_url: str, client: ConvexClient) -> None:
    """Backfill missing outcomes from cloud log files for completed games."""
    # 1. Fetch all games from Convex
    resp = await client.client.post(
        f"{client.base_url}/api/query",
        json={"path": "diary:listGames", "args": {}},
    )
    resp.raise_for_status()
    data = resp.json()
    all_games = data.get("value", [])

    missing = [
        g for g in all_games if g.get("status") == "completed" and not g.get("outcome")
    ]
    if not missing:
        log.info("All completed games have outcomes — nothing to backfill")
        return

    log.info("Found %d game(s) with missing outcomes:", len(missing))
    for g in missing:
        log.info(
            "  %s (model=%s, turns=%d)",
            g.get("gameId", "?"),
            g.get("agentModel", "?"),
            g.get("count", 0),
        )

    # 2. Connect to cloud storage
    fs, prefix = _get_cloud_fs(bucket_url)

    # 3. Discover all cloud runs
    manifests = discover_cloud_runs(bucket_url)
    run_map: dict[str, dict[str, Any]] = {}
    for m in manifests:
        rid = m.get("run_id", "")
        if rid:
            run_map[rid] = m

    # 4. For each missing game, try to extract outcome from cloud log
    patched = 0
    for g in missing:
        game_id = g.get("gameId", "")
        run_id = g.get("runId") or ""

        # Try to find run_id from game_id if not stored
        if not run_id:
            parts = game_id.rsplit("_", 1)
            candidate = parts[-1] if len(parts) > 1 else ""
            if candidate and not candidate.lstrip("-").isdigit():
                run_id = candidate

        if not run_id:
            log.warning("  %s: no run_id — cannot locate cloud log", game_id)
            continue

        log_path = f"{prefix}/runs/{run_id}/log.jsonl"
        try:
            content = fs.cat_file(log_path).decode("utf-8")
            lines = content.splitlines()
        except FileNotFoundError:
            log.warning("  %s: cloud log not found at %s", game_id, log_path)
            continue
        except Exception:
            log.warning("  %s: failed to read cloud log", game_id, exc_info=True)
            continue

        # Try game_over event first, then tool_call fallback
        outcome = _extract_outcome(lines)
        if outcome is None:
            civ = g.get("label", "")
            leader = g.get("leader", "")
            outcome = _extract_outcome_from_tool_calls(lines, civ, leader)
            if outcome:
                log.info("  %s: recovered from tool_call fallback", game_id)

        if outcome:
            args: dict[str, Any] = {
                "gameId": game_id,
                "outcome": outcome,
                "force": True,
            }
            model = g.get("agentModel", "")
            if model:
                args["agentModel"] = model
            await client.mutation("ingest:completeGame", args)
            log.info(
                "  %s: PATCHED %s — %s (%s) T%s",
                game_id,
                outcome["result"],
                outcome["winnerCiv"],
                outcome["victoryType"],
                outcome.get("turn", "?"),
            )
            patched += 1
        else:
            log.warning(
                "  %s: no outcome found in cloud log (%d lines)", game_id, len(lines)
            )

    log.info("=== Backfill complete: %d/%d outcomes patched ===", patched, len(missing))


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


async def main() -> None:
    parser = argparse.ArgumentParser(description="Sync civ-mcp JSONL files to Convex")
    parser.add_argument(
        "--prod",
        action="store_true",
        help="Target production deployment (reads web/.env.prod instead of web/.env.dev)",
    )
    mode = parser.add_mutually_exclusive_group()
    mode.add_argument(
        "--watch",
        action="store_true",
        help="Watch for changes and stream to Convex (default for local)",
    )
    mode.add_argument(
        "--upload",
        type=str,
        metavar="DIR",
        help="One-shot batch upload of all files in DIR, then exit",
    )
    mode.add_argument(
        "--backfill-outcomes",
        action="store_true",
        help="Backfill missing outcomes from cloud log files, then exit",
    )
    parser.add_argument(
        "--cloud",
        type=str,
        metavar="BUCKET",
        help="Cloud bucket URL (e.g. az://telemetry) for one-shot batch "
        "upload or --backfill-outcomes. Use local --watch on each machine "
        "for live streaming instead.",
    )
    args = parser.parse_args()

    convex_url, deploy_key = _resolve_config(prod=args.prod)
    env_label = "PROD" if args.prod else "DEV"

    if not convex_url:
        log.error(
            "CONVEX_URL not set — check web/.env.%s", "prod" if args.prod else "dev"
        )
        sys.exit(1)
    if not deploy_key:
        log.error(
            "CONVEX_DEPLOY_KEY not set — check web/.env.%s",
            "prod" if args.prod else "dev",
        )
        sys.exit(1)

    client = ConvexClient(convex_url, deploy_key)
    try:
        if args.backfill_outcomes:
            if not args.cloud:
                log.error("--backfill-outcomes requires --cloud BUCKET")
                sys.exit(1)
            log.info("[%s] Backfilling outcomes from %s", env_label, args.cloud)
            await backfill_outcomes(args.cloud, client)
        elif args.upload:
            upload_dir = Path(args.upload).expanduser().resolve()
            if not upload_dir.is_dir():
                log.error("Directory not found: %s", upload_dir)
                sys.exit(1)
            log.info("[%s] Batch upload %s → %s", env_label, upload_dir, convex_url)
            await batch_upload(upload_dir, client)
        elif args.cloud:
            if args.watch:
                log.error(
                    "--watch --cloud is no longer supported. Use --watch "
                    "(local file watching) on each machine, or --cloud alone "
                    "for one-shot batch historical backfill."
                )
                sys.exit(1)
            log.info("[%s] Batch cloud %s → %s", env_label, args.cloud, convex_url)
            await batch_upload_cloud(args.cloud, client)
        else:
            log.info("[%s] Watching %s → %s", env_label, DIARY_DIR, convex_url)
            await watch_loop(DIARY_DIR, client)
    finally:
        await client.close()


if __name__ == "__main__":
    asyncio.run(main())
