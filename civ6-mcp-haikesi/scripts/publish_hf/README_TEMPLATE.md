---
license: cc-by-4.0
pretty_name: CivBench
size_categories:
  - 1K<n<10K
task_categories:
  - other
tags:
  - llm-agents
  - benchmarks
  - civilization-vi
  - tool-use
  - multi-turn
  - long-horizon
configs:
  - config_name: tables
    data_files:
      - split: games
        path: tables/games.parquet
      - split: player_rows
        path: tables/player_rows.parquet
      - split: city_rows
        path: tables/city_rows.parquet
      - split: tool_calls
        path: tables/tool_calls.parquet
      - split: spatial_turns
        path: tables/spatial_turns.parquet
  - config_name: raw
    data_files:
      - split: train
        path: raw/runs/*/diary.jsonl
---

# CivBench

A benchmark of LLM agents playing full games of Civilization VI through an
MCP (Model Context Protocol) server. Each run captures the full per-turn
game state, every tool call the agent issued, and the agent's own
structured reflections.

## Configs

- **`tables`** — curated parquet tables, one row per logical record. Use this
  for analysis: `datasets.load_dataset("<repo>", "tables", split="games")`.
- **`raw`** — byte-identical mirror of the on-disk telemetry JSONL streams.
  Use this for forensic replay or building new derived tables.
- **Inspect AI sidecar** — full LLM message traces in `inspect_logs/*.eval`,
  loadable via `inspect.log.read_eval_log()`.

## Schemas

The Croissant 1.1 file at `croissant.json` is the authoritative schema
declaration. Cross-table joins are on `gameId`; per-turn rows additionally
key on `(gameId, turn, pid)` for player rows and `(gameId, turn, city_id)`
for city rows.

Nested fields (`stockpiles`, `unit_composition`, `reflections`, etc.) are
JSON-encoded text in parquet — parse client-side.

## Admissibility

Each row in `games.parquet` carries an `admissible` flag indicating whether
the run passed the standard filters (≥10 turns, no save scumming, no failed
launch). Filter to `admissible == True` for the canonical leaderboard cut.

## Citation

```bibtex
@misc{civbench2026,
  title={CivBench: A Civilization VI benchmark for LLM agents},
  year={2026},
  url={https://huggingface.co/datasets/<repo>}
}
```

## License

CC BY 4.0. See `LICENSE`.
