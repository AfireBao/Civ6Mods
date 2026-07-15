"""Stage 2 — build curated parquet tables from the staged raw data.

Output: <staging>/tables/{games,player_rows,city_rows,tool_calls,spatial_turns}.parquet

Per-row tables are derived directly from the raw JSONL streams in
<staging>/raw/runs/. The `games` summary table is enriched from a Convex
snapshot at <staging>/_convex/games.jsonl (produced separately via
`npx convex export --table games --format jsonl`); if absent, we fall
back to a minimal summary built from manifest.json.
"""

from __future__ import annotations

import json
import logging
from pathlib import Path
from typing import Any, Iterator

import pyarrow as pa
import pyarrow.parquet as pq

log = logging.getLogger("publish_hf.export_tables")

JSON_FAMILIES = {
    "diary.jsonl": "player_rows",
    "cities.jsonl": "city_rows",
    "log.jsonl": "tool_calls",
    "spatial.jsonl": "spatial_turns",
}


def _iter_jsonl(path: Path) -> Iterator[dict]:
    with path.open() as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            try:
                yield json.loads(line)
            except json.JSONDecodeError:
                log.warning("Skipping malformed line in %s", path)


def _read_manifest(run_dir: Path) -> dict | None:
    p = run_dir / "manifest.json"
    if not p.exists():
        return None
    raw = p.read_text().strip()
    if not raw:
        return None
    try:
        return json.loads(raw.split("\n")[0])
    except json.JSONDecodeError:
        return None


# Fields that could deanonymize the submission (git SHAs link to the repo,
# agent_client* identifies the MCP server package name).
_REDACT_FIELDS = {
    "mcp_git_sha",
    "mcp_git_describe",
    "mcp_version",
    "agent_client",
    "agent_client_ver",
}


def _redact_row(row: dict) -> dict:
    """Remove fields that could deanonymize the submission."""
    return {k: v for k, v in row.items() if k not in _REDACT_FIELDS}


def _stringify_complex(rows: list[dict]) -> list[dict]:
    """Coerce nested dict/list values to JSON strings for stable parquet schema.

    Keeps scalars as-is; serializes dict/list to text so heterogeneous
    nested shapes (e.g. unit_composition, reflections) don't cause
    schema unification failures.
    """
    out = []
    for r in rows:
        flat = {}
        for k, v in r.items():
            if isinstance(v, (dict, list)):
                flat[k] = json.dumps(v, separators=(",", ":"))
            else:
                flat[k] = v
        out.append(flat)
    return out


def _write_parquet(rows: list[dict], path: Path) -> None:
    if not rows:
        log.warning("No rows to write for %s", path.name)
        return
    table = pa.Table.from_pylist(_stringify_complex(rows))
    path.parent.mkdir(parents=True, exist_ok=True)
    pq.write_table(table, path, compression="zstd")
    log.info("Wrote %s (%d rows, %d cols)", path, table.num_rows, table.num_columns)


def _build_per_row_tables(raw_runs_dir: Path, out_dir: Path) -> dict[str, int]:
    counts: dict[str, list[dict]] = {v: [] for v in JSON_FAMILIES.values()}
    for run_dir in sorted(raw_runs_dir.iterdir()):
        if not run_dir.is_dir():
            continue
        manifest = _read_manifest(run_dir)
        game_id = (manifest or {}).get("game_id") or run_dir.name
        run_id = (manifest or {}).get("run_id") or run_dir.name
        for filename, table_name in JSON_FAMILIES.items():
            path = run_dir / filename
            if not path.exists():
                continue
            for row in _iter_jsonl(path):
                row.setdefault("gameId", game_id)
                row.setdefault("runId", run_id)
                counts[table_name].append(_redact_row(row))

    for table_name, rows in counts.items():
        _write_parquet(rows, out_dir / f"{table_name}.parquet")
    return {k: len(v) for k, v in counts.items()}


def _build_games_table(staging: Path, out_dir: Path, raw_runs_dir: Path) -> int:
    convex_snapshot = staging / "_convex" / "games.jsonl"
    if convex_snapshot.exists():
        log.info("Loading games summary from Convex snapshot at %s", convex_snapshot)
        rows = list(_iter_jsonl(convex_snapshot))
    else:
        log.warning(
            "No %s — building minimal games table from manifest.json. "
            "Run `npx convex export --table games --format jsonl --path %s` "
            "to include admissibility/ELO/dimensionScores.",
            convex_snapshot,
            convex_snapshot.parent,
        )
        rows = []
        for run_dir in sorted(raw_runs_dir.iterdir()):
            if not run_dir.is_dir():
                continue
            m = _read_manifest(run_dir)
            if not m:
                continue
            meta = m.get("metadata", {})
            rows.append(
                {
                    "gameId": m.get("game_id"),
                    "runId": m.get("run_id"),
                    "civ": m.get("civ"),
                    "seed": str(m.get("seed")),
                    "startTs": m.get("start_ts"),
                    # mcpVersion and mcpGitSha redacted for anonymous submission
                    "agentModel": meta.get("model_id"),
                    "scenarioId": meta.get("scenario_id"),
                    "difficulty": meta.get("difficulty"),
                    "mapType": meta.get("map_type"),
                    "mapSize": meta.get("map_size"),
                    "gameSpeed": meta.get("game_speed"),
                    "evalTrack": meta.get("eval_track"),
                    "admissible": None,
                }
            )
    _write_parquet(rows, out_dir / "games.parquet")
    return len(rows)


def run(staging: Path, prod: bool = True) -> int:
    raw_runs = staging / "raw" / "runs"
    if not raw_runs.exists():
        log.error("Missing %s — run the download stage first.", raw_runs)
        return 1
    out_dir = staging / "tables"
    out_dir.mkdir(parents=True, exist_ok=True)

    counts = _build_per_row_tables(raw_runs, out_dir)
    games_n = _build_games_table(staging, out_dir, raw_runs)
    counts["games"] = games_n
    log.info("Per-table row counts: %s", counts)
    return 0
