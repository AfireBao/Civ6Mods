#!/usr/bin/env -S .venv/bin/python
"""CivBench game analysis CLI — tool calling patterns and strategic planning."""

from __future__ import annotations

import argparse
import json
import os
import sys
from collections import Counter, defaultdict
from pathlib import Path
from typing import Any

# ---------------------------------------------------------------------------
# Data access helpers
# ---------------------------------------------------------------------------

CONVEX_URL = "https://precious-lion-600.eu-west-1.convex.cloud"
CACHE_DIR = Path("/tmp/civbench_cache")
EVALS_ENV = Path(__file__).resolve().parent.parent / "evals" / ".env"

# Strategic tools worth tracking separately
STRATEGIC_TOOLS = [
    "get_victory_progress",
    "get_diplomacy",
    "get_religion_spread",
    "get_great_people",
    "get_strategic_map",
    "get_global_settle_advisor",
    "get_trade_routes",
    "get_district_advisor",
    "get_tech_civics",
    "get_empire_resources",
    "get_builder_tasks",
]


def _load_env() -> dict[str, str]:
    """Read evals/.env for Azure credentials."""
    env: dict[str, str] = {}
    if EVALS_ENV.exists():
        for line in EVALS_ENV.read_text().splitlines():
            line = line.strip()
            if line and not line.startswith("#") and "=" in line:
                k, v = line.split("=", 1)
                env[k.strip()] = v.strip()
    return env


def convex_query(path: str, args: dict | None = None) -> Any:
    """HTTP POST to Convex query endpoint."""
    import requests

    resp = requests.post(
        f"{CONVEX_URL}/api/query",
        json={"path": path, "args": args or {}},
        timeout=30,
    )
    resp.raise_for_status()
    data = resp.json()
    if data.get("status") != "success":
        raise RuntimeError(f"Convex query failed: {data}")
    return data["value"]


def _list_games() -> list[dict]:  # Public API: imported by civbench_data.py
    """Fetch all games from Convex."""
    return convex_query("diary:listGames")


def _resolve_run_ids(identifiers: list[str], games: list[dict]) -> list[dict]:
    """Resolve game IDs or run IDs to game dicts."""
    results = []
    for ident in identifiers:
        for g in games:
            if g["runId"] == ident or g["gameId"] == ident:
                results.append(g)
                break
        else:
            print(f"Warning: '{ident}' not found", file=sys.stderr)
    return results


def _games_by_model(model: str, games: list[dict]) -> list[dict]:
    """Filter games by model name (substring match)."""
    return [g for g in games if model.lower() in (g.get("agentModel") or "").lower()]


_fs_cache: Any = None


def _get_fs() -> Any:  # Public API: imported by civbench_data.py
    """Lazy-init Azure fsspec filesystem.

    Auth order: SAS token → connection string → account key → DefaultAzureCredential.
    """
    global _fs_cache
    if _fs_cache is not None:
        return _fs_cache
    import fsspec

    env = _load_env()
    account = env.get("AZURE_STORAGE_ACCOUNT_NAME", "civbenchstorage")

    # SAS token (read-only collaborator access)
    sas = os.environ.get("AZURE_SAS_TOKEN") or env.get("AZURE_SAS_TOKEN", "")
    if sas:
        _fs_cache = fsspec.filesystem("az", account_name=account, sas_token=sas)
        return _fs_cache

    conn_str = env.get("AZURE_STORAGE_CONNECTION_STRING", "")
    if conn_str:
        _fs_cache = fsspec.filesystem("az", connection_string=conn_str)
    else:
        key = env.get("AZURE_STORAGE_ACCOUNT_KEY", "")
        if account and key:
            _fs_cache = fsspec.filesystem("az", account_name=account, account_key=key)
        elif account:
            from azure.identity import DefaultAzureCredential

            _fs_cache = fsspec.filesystem(
                "az", account_name=account, credential=DefaultAzureCredential()
            )
        else:
            raise RuntimeError(
                "No Azure credentials found. Set AZURE_SAS_TOKEN in .env "
                "or AZURE_STORAGE_ACCOUNT_KEY in evals/.env"
            )
    return _fs_cache


def _cloud_jsonl(
    run_id: str, filename: str
) -> list[dict]:  # Public API: imported by civbench_data.py
    """Fetch and cache a JSONL file from Azure blob storage."""
    CACHE_DIR.mkdir(exist_ok=True)
    cache_path = CACHE_DIR / f"{filename.replace('.jsonl', '')}_{run_id}.jsonl"

    if cache_path.exists():
        return [json.loads(l) for l in cache_path.read_text().splitlines() if l.strip()]

    fs = _get_fs()
    blob_path = f"telemetry/runs/{run_id}/{filename}"
    try:
        raw = fs.cat_file(blob_path)
    except FileNotFoundError:
        print(f"Warning: {blob_path} not found in Azure", file=sys.stderr)
        return []

    cache_path.write_bytes(raw)
    return [json.loads(l) for l in raw.decode().splitlines() if l.strip()]


def cloud_log(run_id: str) -> list[dict]:
    """Fetch and cache log.jsonl from Azure blob."""
    return _cloud_jsonl(run_id, "log.jsonl")


def cloud_diary(run_id: str) -> list[dict]:
    """Fetch and cache diary.jsonl from Azure blob."""
    return _cloud_jsonl(run_id, "diary.jsonl")


# ---------------------------------------------------------------------------
# Formatting helpers
# ---------------------------------------------------------------------------


def _table(headers: list[str], rows: list[list[str]], align: list[str] | None = None):
    """Print a formatted table."""
    if not rows:
        print("  (no data)")
        return
    widths = [len(h) for h in headers]
    for row in rows:
        for i, cell in enumerate(row):
            if i < len(widths):
                widths[i] = max(widths[i], len(str(cell)))
    if align is None:
        align = ["<"] * len(headers)

    header_line = "  ".join(f"{h:{a}{w}}" for h, w, a in zip(headers, widths, align))
    print(header_line)
    print("  ".join("-" * w for w in widths))
    for row in rows:
        cells = []
        for i, (cell, w, a) in enumerate(zip(row, widths, align)):
            cells.append(f"{str(cell):{a}{w}}")
        print("  ".join(cells))


def _sparkline(values: list[float], width: int = 40) -> str:
    """ASCII sparkline."""
    if not values:
        return ""
    blocks = " ▁▂▃▄▅▆▇█"
    mn, mx = min(values), max(values)
    rng = mx - mn if mx > mn else 1
    # Resample to width
    step = max(1, len(values) / width)
    sampled = []
    for i in range(width):
        idx = min(int(i * step), len(values) - 1)
        sampled.append(values[idx])
    return "".join(blocks[min(8, int((v - mn) / rng * 8))] for v in sampled)


def _pct(num: int, den: int) -> str:
    if den == 0:
        return "0.0%"
    return f"{100 * num / den:.1f}%"


def _percentile(vals: list[float], p: float) -> float:
    if not vals:
        return 0.0
    vals = sorted(vals)
    k = (len(vals) - 1) * p
    f = int(k)
    c = f + 1
    if c >= len(vals):
        return vals[-1]
    return vals[f] + (k - f) * (vals[c] - vals[f])


# ---------------------------------------------------------------------------
# Subcommands
# ---------------------------------------------------------------------------


def cmd_games(args):
    """List all games."""
    games = _list_games()
    if args.model:
        games = _games_by_model(args.model, games)

    headers = [
        "Model",
        "Scenario",
        "Turns",
        "Score",
        "Result",
        "Victory",
        "Winner",
        "RunID",
    ]
    align = ["<", "<", ">", ">", "<", "<", "<", "<"]
    rows = []
    for g in games:
        o = g.get("outcome") or {}
        rows.append(
            [
                g.get("agentModel") or "?",
                g.get("scenarioId") or "?",
                int(g.get("count") or 0),
                int(g.get("score") or 0),
                o.get("result") or g.get("status", "?"),
                o.get("victoryType") or "",
                o.get("winnerCiv") or "",
                g.get("runId") or "?",
            ]
        )
    _table(headers, rows, align)


def _analyze_log(entries: list[dict]) -> dict:
    """Compute analysis stats from log entries."""
    tool_calls = [e for e in entries if e.get("type") == "tool_call"]
    if not tool_calls:
        return {}

    tools = Counter(e.get("tool", "unknown") for e in tool_calls)
    cats = Counter(e.get("category", "unknown") for e in tool_calls)
    errors = [e for e in tool_calls if not e.get("success", True)]
    error_tools = Counter(e.get("tool", "unknown") for e in errors)

    # Per-turn stats
    per_turn: dict[int, int] = defaultdict(int)
    for e in tool_calls:
        per_turn[e.get("turn", 0)] += 1
    turn_counts = sorted(per_turn.values())

    # Duration stats
    durations_by_tool: dict[str, list[float]] = defaultdict(list)
    for e in tool_calls:
        d = e.get("duration_ms")
        if d is not None:
            durations_by_tool[e.get("tool", "unknown")].append(d)

    turns = sorted(set(e.get("turn") for e in tool_calls if e.get("turn") is not None))

    return {
        "total": len(tool_calls),
        "tools": tools,
        "categories": cats,
        "errors": len(errors),
        "error_tools": error_tools,
        "per_turn_counts": turn_counts,
        "turns": turns,
        "durations_by_tool": durations_by_tool,
        "tool_calls": tool_calls,
    }


def cmd_tools(args):
    """Tool calling analysis."""
    games = _list_games()

    if args.model:
        targets = _games_by_model(args.model, games)
    elif args.game_ids:
        targets = _resolve_run_ids(args.game_ids, games)
    else:
        targets = games

    for g in targets:
        rid = g["runId"]
        model = g.get("agentModel") or "?"
        o = g.get("outcome") or {}
        result = o.get("result") or g.get("status", "?")

        print(f"\n{'=' * 70}")
        print(
            f"  {rid} | {model} | {g.get('label', '?')} | {result} | T{int(g.get('count') or 0)}"
        )
        print(f"{'=' * 70}")

        entries = cloud_log(rid)
        stats = _analyze_log(entries)
        if not stats:
            print("  No tool call data found")
            continue

        # Category breakdown
        cats = stats["categories"]
        total = stats["total"]
        print(
            f"\n  Total calls: {total} | Errors: {stats['errors']} ({_pct(stats['errors'], total)})"
        )
        print(
            f"  Query: {cats.get('query', 0)} ({_pct(cats.get('query', 0), total)}) | "
            f"Action: {cats.get('action', 0)} ({_pct(cats.get('action', 0), total)}) | "
            f"Turn: {cats.get('turn', 0)} ({_pct(cats.get('turn', 0), total)})"
        )

        # Calls per turn
        tc = stats["per_turn_counts"]
        print(
            f"\n  Calls/turn: min={tc[0]}  med={tc[len(tc) // 2]}  "
            f"mean={sum(tc) / len(tc):.1f}  p95={_percentile(tc, 0.95):.0f}  max={tc[-1]}"
        )

        # Top 20 tools
        print(f"\n  Top 20 tools:")
        headers = ["Tool", "Count", "%", "Errors", "Med ms"]
        align = ["<", ">", ">", ">", ">"]
        rows = []
        for tool, count in stats["tools"].most_common(20):
            errs = stats["error_tools"].get(tool, 0)
            durs = sorted(stats["durations_by_tool"].get(tool, []))
            med = f"{durs[len(durs) // 2]:.0f}" if durs else "-"
            rows.append([tool, count, _pct(count, total), errs, med])
        _table(headers, rows, align)

        # Error-heavy tools
        if stats["error_tools"]:
            print(f"\n  Top error tools:")
            for tool, count in stats["error_tools"].most_common(10):
                total_for_tool = stats["tools"][tool]
                print(
                    f"    {tool:<30} {count:>4} errors / {total_for_tool:>4} calls ({_pct(count, total_for_tool)})"
                )

        # Slowest tools (by median)
        print(f"\n  Slowest tools (median ms):")
        med_durations = []
        for tool, durs in stats["durations_by_tool"].items():
            if len(durs) >= 3:
                s = sorted(durs)
                med_durations.append((tool, s[len(s) // 2], len(s)))
        med_durations.sort(key=lambda x: -x[1])
        for tool, med, n in med_durations[:10]:
            print(f"    {tool:<30} {med:>7.0f} ms  (n={n})")


def cmd_compare(args):
    """Side-by-side model comparison."""
    games = _list_games()

    if args.models:
        model_names = [m.strip() for m in args.models.split(",")]
    else:
        model_names = sorted(set(g.get("agentModel") or "unknown" for g in games))

    model_games: dict[str, list[dict]] = defaultdict(list)
    for g in games:
        m = g.get("agentModel") or "unknown"
        if m in model_names:
            model_games[m].append(g)

    # --- Outcome Aggregation (from Azure diary) ---
    print(f"\n  Outcome Aggregation")
    print("  " + "-" * 50)
    headers = [
        "Model",
        "Games",
        "Victories",
        "Defeats",
        "Incomplete",
        "Avg Turn",
        "Avg Score",
    ]
    align = ["<", ">", ">", ">", ">", ">", ">"]
    agg_rows = []
    for model in model_names:
        gg = model_games[model]
        victories = 0
        defeats = 0
        incomplete = 0
        final_turns = []
        final_scores = []
        for g in gg:
            rid = g.get("runId", "")
            if not rid:
                continue
            diary = cloud_diary(rid)
            agent = _agent_rows(diary)
            if agent:
                last = agent[-1]
                final_turns.append(last.get("turn", 0))
                if last.get("score") is not None:
                    final_scores.append(last["score"])
            go = _find_game_over(diary)
            if go:
                result = go.get("result") or go.get("outcome", {}).get("result", "")
                if "victory" in str(result).lower():
                    victories += 1
                elif "defeat" in str(result).lower():
                    defeats += 1
                else:
                    incomplete += 1
            else:
                o = g.get("outcome") or {}
                if o.get("result") == "victory":
                    victories += 1
                elif o.get("result") == "defeat":
                    defeats += 1
                else:
                    incomplete += 1
        avg_turn = f"{sum(final_turns) / len(final_turns):.0f}" if final_turns else "-"
        avg_score = (
            f"{sum(final_scores) / len(final_scores):.0f}" if final_scores else "-"
        )
        agg_rows.append(
            [
                model.rsplit("/", 1)[-1][:25],
                len(gg),
                victories,
                defeats,
                incomplete,
                avg_turn,
                avg_score,
            ]
        )
    _table(headers, agg_rows, align)

    # --- Win/Loss ---
    print("\n  Win/Loss Record")
    print("  " + "-" * 50)
    for model in model_names:
        gg = model_games[model]
        wins = sum(1 for g in gg if (g.get("outcome") or {}).get("result") == "victory")
        defeats = sum(
            1 for g in gg if (g.get("outcome") or {}).get("result") == "defeat"
        )
        live = sum(1 for g in gg if g.get("status") == "live" or not g.get("outcome"))
        print(f"    {model:<20} {wins}W / {defeats}L / {live}live  ({len(gg)} games)")

    # --- Aggregate tool patterns (per-game, then averaged) ---
    print(f"\n  Tool Calling Patterns (per-game averages)")
    print("  " + "-" * 50)

    # Compute per-game stats, then aggregate per model
    model_per_game: dict[str, list[dict]] = defaultdict(list)
    model_agg_tools: dict[str, Counter] = defaultdict(Counter)
    for model in model_names:
        for g in model_games[model]:
            entries = cloud_log(g["runId"])
            stats = _analyze_log(entries)
            if stats:
                model_per_game[model].append(stats)
                model_agg_tools[model] += stats["tools"]

    headers = ["Metric"] + model_names
    align = ["<"] + [">"] * len(model_names)
    rows = []

    def _stat(model: str, key: str) -> str:
        per_game = model_per_game.get(model, [])
        if not per_game:
            return "-"
        if key == "games":
            return str(len(per_game))
        if key == "total":
            avg = sum(s["total"] for s in per_game) / len(per_game)
            return f"{avg:.0f}"
        if key == "errors":
            avg_err = sum(s["errors"] for s in per_game) / len(per_game)
            avg_total = sum(s["total"] for s in per_game) / len(per_game)
            return f"{avg_err:.0f} ({_pct(int(avg_err), int(avg_total))})"
        if key == "q_ratio":
            total_q = sum(s["categories"].get("query", 0) for s in per_game)
            total_a = sum(s["categories"].get("action", 0) for s in per_game)
            return f"{_pct(total_q, total_q + total_a)} Q"
        if key == "calls_per_turn":
            # Average the per-game means
            means = []
            meds = []
            for s in per_game:
                tc = s["per_turn_counts"]
                means.append(sum(tc) / len(tc))
                meds.append(tc[len(tc) // 2])
            avg_mean = sum(means) / len(means)
            avg_med = sum(meds) / len(meds)
            return f"{avg_mean:.1f} (med {avg_med:.0f})"
        if key == "turns":
            avg = sum(len(s["turns"]) for s in per_game) / len(per_game)
            return f"{avg:.0f}"
        return "-"

    for key, label in [
        ("games", "Games"),
        ("total", "Avg calls/game"),
        ("turns", "Avg turns/game"),
        ("errors", "Avg errors/game"),
        ("q_ratio", "Query ratio"),
        ("calls_per_turn", "Calls/turn"),
    ]:
        rows.append([label] + [_stat(m, key) for m in model_names])
    _table(headers, rows, align)

    # --- Strategic tool usage (per 100 turns, averaged across games) ---
    print(f"\n  Strategic Tool Usage (per 100 turns, avg across games)")
    print("  " + "-" * 50)
    headers = ["Tool"] + model_names
    align = ["<"] + [">"] * len(model_names)
    rows = []
    for tool in STRATEGIC_TOOLS:
        vals = []
        for model in model_names:
            per_game = model_per_game.get(model, [])
            if not per_game:
                vals.append("-")
                continue
            rates = []
            for s in per_game:
                count = s["tools"].get(tool, 0)
                n_turns = len(s["turns"]) or 1
                rates.append(100 * count / n_turns)
            vals.append(f"{sum(rates) / len(rates):.1f}")
        rows.append([tool] + vals)
    _table(headers, rows, align)

    # --- Yield milestones from turnSeries ---
    print(f"\n  Yield Milestones (agent player)")
    print("  " + "-" * 50)
    milestones = [50, 100, 150, 200, 250]
    _summary_cache: dict[str, dict | None] = {}
    for metric in [
        "score",
        "science",
        "culture",
        "gold",
        "military",
        "cities",
        "territory",
    ]:
        print(f"\n    {metric}:")
        headers = ["Turn"] + model_names
        align = [">"] + [">"] * len(model_names)
        rows = []
        for turn in milestones:
            vals = []
            for model in model_names:
                # Average across games for this model
                game_vals = []
                for g in model_games[model]:
                    gid = g["gameId"]
                    if gid not in _summary_cache:
                        _summary_cache[gid] = convex_query(
                            "diary:getGameSummary", {"gameId": gid}
                        )
                    summary = _summary_cache[gid]
                    if not summary or not summary.get("turnSeries"):
                        continue
                    ts = summary["turnSeries"]
                    players = ts.get("players", ts)
                    for pid, pdata in players.items():
                        if pdata.get("is_agent"):
                            series = pdata.get("metrics", {}).get(metric, [])
                            if turn - 1 < len(series):
                                game_vals.append(series[turn - 1])
                if game_vals:
                    avg = sum(game_vals) / len(game_vals)
                    vals.append(f"{avg:.0f}")
                else:
                    vals.append("-")
            rows.append([f"T{turn}"] + vals)
        _table(headers, rows, align)


def cmd_strategy(args):
    """Strategic planning deep-dive."""
    games = _list_games()
    targets = _resolve_run_ids([args.game_id], games)
    if not targets:
        print(f"Game '{args.game_id}' not found")
        return
    g = targets[0]
    rid = g["runId"]
    model = g.get("agentModel") or "?"
    o = g.get("outcome") or {}

    print(f"\n{'=' * 70}")
    print(f"  Strategy Analysis: {rid} | {model}")
    print(
        f"  {g.get('label', '?')} ({g.get('leader', '?')}) | {o.get('result', g.get('status', '?'))}"
    )
    print(f"{'=' * 70}")

    entries = cloud_log(rid)
    tool_calls = [e for e in entries if e.get("type") == "tool_call"]

    # --- Strategic tool timeline ---
    print(f"\n  Strategic Tool Timeline")
    print("  " + "-" * 50)

    strategic_calls: dict[str, list[int]] = defaultdict(list)
    for e in tool_calls:
        if e.get("tool", "unknown") in STRATEGIC_TOOLS:
            t = e.get("turn")
            if t is not None:
                strategic_calls[e.get("tool", "unknown")].append(int(t))

    headers = ["Tool", "Count", "First", "Last", "Max Gap", "Avg Gap"]
    align = ["<", ">", ">", ">", ">", ">"]
    rows = []
    for tool in STRATEGIC_TOOLS:
        turns = sorted(strategic_calls.get(tool, []))
        if not turns:
            rows.append([tool, 0, "-", "-", "-", "-"])
            continue
        gaps = [turns[i + 1] - turns[i] for i in range(len(turns) - 1)]
        max_gap = max(gaps) if gaps else 0
        avg_gap = sum(gaps) / len(gaps) if gaps else 0
        rows.append(
            [
                tool,
                len(turns),
                turns[0],
                turns[-1],
                max_gap,
                f"{avg_gap:.0f}",
            ]
        )
    _table(headers, rows, align)

    # --- Large gaps (>30 turns without checking) ---
    print(f"\n  Notable Gaps (>30 turns without check)")
    print("  " + "-" * 50)
    found_gap = False
    for tool in STRATEGIC_TOOLS:
        turns = sorted(strategic_calls.get(tool, []))
        if len(turns) < 2:
            continue
        for i in range(len(turns) - 1):
            gap = turns[i + 1] - turns[i]
            if gap > 30:
                print(f"    {tool}: T{turns[i]} → T{turns[i + 1]} ({gap} turns)")
                found_gap = True
    if not found_gap:
        print("    (none)")

    # --- City expansion timeline (from turnSeries) ---
    print(f"\n  City Expansion Timeline")
    print("  " + "-" * 50)
    summary = convex_query("diary:getGameSummary", {"gameId": g["gameId"]})
    if summary and summary.get("turnSeries"):
        ts = summary["turnSeries"]
        players = ts.get("players", ts)
        for pid, pdata in players.items():
            if pdata.get("is_agent"):
                cities = pdata.get("metrics", {}).get("cities", [])
                if cities:
                    prev = 0
                    for turn, count in enumerate(cities, 1):
                        count = int(count)
                        if count > prev:
                            print(f"    T{turn:>3}: {count} cities")
                            prev = count
                    print(f"    Sparkline: {_sparkline(cities)}")

    # --- Score progression ---
    if summary and summary.get("turnSeries"):
        players = summary["turnSeries"].get("players", summary["turnSeries"])
        for pid, pdata in players.items():
            if pdata.get("is_agent"):
                for metric in ["score", "science", "culture", "military"]:
                    series = pdata.get("metrics", {}).get(metric, [])
                    if series:
                        print(
                            f"    {metric:<12}: {_sparkline(series)}  (final: {series[-1]:.0f})"
                        )

    # --- Research changes ---
    print(f"\n  Research Activity")
    print("  " + "-" * 50)
    research_calls = [e for e in tool_calls if e.get("tool") == "set_research"]
    if research_calls:
        print(f"    Total set_research calls: {len(research_calls)}")
        # Show first 10 and last 5
        for e in research_calls[:10]:
            p = e.get("params", {})
            tech = p.get("tech") or p.get("tech_or_civic") or "?"
            print(f"      T{e.get('turn', 0):>3}: {tech}")
        if len(research_calls) > 15:
            print(f"      ... ({len(research_calls) - 15} more)")
        if len(research_calls) > 10:
            for e in research_calls[-5:]:
                p = e.get("params", {})
                tech = p.get("tech") or p.get("tech_or_civic") or "?"
                print(f"      T{e.get('turn', 0):>3}: {tech}")

    # --- Diary reflections (planning field) ---
    print(f"\n  Agent Planning Reflections (from diary)")
    print("  " + "-" * 50)
    diary = cloud_diary(rid)
    agent_rows = [d for d in diary if d.get("is_agent") and d.get("reflections")]
    sample_turns = [1, 25, 50, 100, 150, 200, 250, 300]
    for t in sample_turns:
        for row in agent_rows:
            if row.get("turn") == t:
                refl = row.get("reflections", {})
                planning = refl.get("planning", "")
                hypothesis = refl.get("hypothesis", "")
                if planning or hypothesis:
                    print(f"\n    T{t} planning: {planning[:200]}")
                    if hypothesis:
                        print(f"    T{t} hypothesis: {hypothesis[:200]}")
                break

    # --- Error patterns ---
    print(f"\n  Error Patterns")
    print("  " + "-" * 50)
    error_calls = [e for e in tool_calls if not e.get("success", True)]
    if error_calls:
        error_by_turn = defaultdict(int)
        for e in error_calls:
            # Bucket into 50-turn ranges
            bucket = (e.get("turn", 0) // 50) * 50
            error_by_turn[bucket] += 1
        print(f"    Errors by era:")
        for bucket in sorted(error_by_turn.keys()):
            print(
                f"      T{bucket:>3}-T{bucket + 49:>3}: {error_by_turn[bucket]:>3} errors"
            )

        # Common error messages
        error_msgs = Counter()
        for e in error_calls:
            summary = e.get("result_summary", "")[:80]
            error_msgs[f"{e['tool']}: {summary}"] += 1
        print(f"\n    Top error patterns:")
        for msg, count in error_msgs.most_common(10):
            print(f"      {count:>3}x  {msg}")


def cmd_turns(args):
    """Per-turn breakdown."""
    games = _list_games()
    targets = _resolve_run_ids([args.game_id], games)
    if not targets:
        print(f"Game '{args.game_id}' not found")
        return
    g = targets[0]
    rid = g["runId"]

    entries = cloud_log(rid)
    tool_calls = [e for e in entries if e.get("type") == "tool_call"]

    # Parse turn range
    start, end = 1, 9999
    if args.range:
        parts = args.range.split("-")
        start = int(parts[0])
        end = int(parts[1]) if len(parts) > 1 else start

    # Filter to range
    in_range = [e for e in tool_calls if start <= (e.get("turn") or 0) <= end]

    # Per-turn tool counts
    per_turn: dict[int, Counter] = defaultdict(Counter)
    for e in in_range:
        per_turn[e.get("turn", 0)][e.get("tool", "unknown")] += 1

    turns = sorted(per_turn.keys())
    if not turns:
        print("No data in range")
        return

    # Metrics from turnSeries
    metrics = [m.strip() for m in (args.metric or "score,science,military").split(",")]
    summary = convex_query("diary:getGameSummary", {"gameId": g["gameId"]})
    if summary and summary.get("turnSeries"):
        players = summary["turnSeries"].get("players", summary["turnSeries"])
        for pid, pdata in players.items():
            if pdata.get("is_agent"):
                print(f"\n  Metric Sparklines (T{start}-T{end}):")
                for metric in metrics:
                    series = pdata.get("metrics", {}).get(metric, [])
                    if series:
                        sliced = series[max(0, start - 1) : end]
                        mn = min(sliced) if sliced else 0
                        mx = max(sliced) if sliced else 0
                        print(
                            f"    {metric:<15}: {_sparkline(sliced, 50)}  ({mn:.0f} → {mx:.0f})"
                        )

    # Per-turn tool heatmap
    print(f"\n  Tool calls per turn (T{start}-T{end}):")
    total_per_turn = [(t, sum(per_turn[t].values())) for t in turns]
    vals = [v for _, v in total_per_turn]
    print(
        f"    Total calls:  {_sparkline(vals, 50)}  (min={min(vals)} max={max(vals)})"
    )

    # Show turns with unusually high call counts
    mean = sum(vals) / len(vals)
    print(f"\n  Turns with >2x mean calls ({mean:.0f}):")
    high_turns = [(t, n) for t, n in total_per_turn if n > 2 * mean]
    if high_turns:
        for t, n in high_turns[:20]:
            top3 = per_turn[t].most_common(3)
            top_str = ", ".join(f"{tool}={c}" for tool, c in top3)
            print(f"    T{t:>3}: {n:>3} calls  ({top_str})")
        if len(high_turns) > 20:
            print(f"    ... and {len(high_turns) - 20} more")
    else:
        print("    (none)")

    # Error rate by turn
    errors_per_turn: dict[int, int] = defaultdict(int)
    for e in in_range:
        if not e.get("success", True):
            errors_per_turn[e.get("turn", 0)] += 1
    if errors_per_turn:
        err_vals = [errors_per_turn.get(t, 0) for t in turns]
        print(
            f"\n    Errors/turn:  {_sparkline(err_vals, 50)}  (total={sum(err_vals)})"
        )


# ---------------------------------------------------------------------------
# Research subcommands — paper-oriented analysis
# ---------------------------------------------------------------------------

# Tools classified by attention type for sensorium analysis
REACTIVE_TOOLS = {
    "unit_action",
    "set_city_production",
    "set_research",
    "end_turn",
    "respond_to_diplomacy",
    "respond_to_trade",
    "promote_unit",
    "choose_pantheon",
    "choose_dedication",
    "set_policies",
    "skip_remaining_units",
    "purchase_item",
    "purchase_tile",
    "found_religion",
    "send_envoy",
    "dismiss_popup",
}
PROACTIVE_TOOLS = {
    "get_victory_progress",
    "get_religion_spread",
    "get_diplomacy",
    "get_great_people",
    "get_strategic_map",
    "get_global_settle_advisor",
    "get_empire_resources",
    "get_trade_routes",
    "get_world_congress",
    "get_city_states",
    "get_spies",
    "get_builder_tasks",
    "get_district_advisor",
    "get_wonder_advisor",
}
ORIENTATION_TOOLS = {
    "get_game_overview",
    "get_units",
    "get_cities",
    "get_map_area",
    "get_notifications",
    "get_tech_civics",
    "get_city_production",
    "get_policies",
    "get_governors",
    "get_purchasable_tiles",
    "get_settle_advisor",
    "get_pathing_estimate",
    "get_unit_promotions",
    "get_pending_diplomacy",
    "get_pending_trades",
    "get_trade_destinations",
    "get_trade_options",
}


def _classify_tool(tool: str) -> str:
    if tool in REACTIVE_TOOLS:
        return "reactive"
    if tool in PROACTIVE_TOOLS:
        return "proactive"
    if tool in ORIENTATION_TOOLS:
        return "orientation"
    return "other"


def cmd_sensorium(args):
    """Sensorium effect analysis — quantify proactive vs reactive attention.

    Measures: proactive monitoring frequency, blind-spot windows (turns
    between strategic checks), reactive/proactive ratio, and per-domain
    monitoring coverage. Directly supports Section 5.2 of the paper.
    """
    games = _list_games()

    if args.model:
        targets = _games_by_model(args.model, games)
    elif args.game_ids:
        targets = _resolve_run_ids(args.game_ids, games)
    else:
        targets = games

    for g in targets:
        rid = g["runId"]
        model = g.get("agentModel") or "?"
        o = g.get("outcome") or {}

        print(f"\n{'=' * 70}")
        print(f"  Sensorium Analysis: {rid} | {model} | T{int(g.get('count') or 0)}")
        print(f"{'=' * 70}")

        entries = cloud_log(rid)
        tool_calls = [e for e in entries if e.get("type") == "tool_call"]
        if not tool_calls:
            print("  No data")
            continue

        turns = sorted(set(e.get("turn") or 0 for e in tool_calls))
        n_turns = len(turns) or 1

        # --- Attention classification ---
        attn = Counter(_classify_tool(e.get("tool", "unknown")) for e in tool_calls)
        total = len(tool_calls)
        print(f"\n  Attention Classification ({total} calls across {n_turns} turns)")
        print("  " + "-" * 50)
        for cat in ["reactive", "orientation", "proactive", "other"]:
            n = attn.get(cat, 0)
            bar = "█" * int(40 * n / total) if total else ""
            print(f"    {cat:<14} {n:>5} ({_pct(n, total):>5})  {bar}")

        proactive_ratio = attn.get("proactive", 0) / total if total else 0
        print(f"\n  Proactive attention ratio: {proactive_ratio:.3f}")
        print(
            f"  Proactive calls per 100 turns: {100 * attn.get('proactive', 0) / n_turns:.1f}"
        )

        # --- Per-domain monitoring frequency ---
        print(f"\n  Domain Monitoring (calls & gaps)")
        print("  " + "-" * 50)
        domains = {
            "Victory": ["get_victory_progress"],
            "Religion": ["get_religion_spread"],
            "Diplomacy": ["get_diplomacy", "get_city_states"],
            "Great People": ["get_great_people"],
            "Military Intel": ["get_strategic_map", "get_map_area"],
            "Economy": ["get_empire_resources", "get_trade_routes"],
            "Expansion": ["get_global_settle_advisor", "get_settle_advisor"],
        }
        headers = ["Domain", "Calls", "/100t", "First", "Last", "Max Gap", "Blind%"]
        align = ["<", ">", ">", ">", ">", ">", ">"]
        rows = []
        for domain, tools in domains.items():
            domain_turns = sorted(
                set(e.get("turn", 0) for e in tool_calls if e.get("tool") in tools)
            )
            count = sum(1 for e in tool_calls if e.get("tool") in tools)
            per100 = f"{100 * count / n_turns:.1f}" if n_turns else "0"

            if not domain_turns:
                rows.append([domain, 0, "0", "-", "-", "-", "100%"])
                continue

            gaps = [
                domain_turns[i + 1] - domain_turns[i]
                for i in range(len(domain_turns) - 1)
            ]
            max_gap = max(gaps) if gaps else 0
            # Blind%: fraction of turns with no check in surrounding ±10 turns
            checked = set()
            for t in domain_turns:
                for dt in range(-5, 6):
                    checked.add(t + dt)
            blind_pct = 1 - len(checked.intersection(turns)) / n_turns
            rows.append(
                [
                    domain,
                    count,
                    per100,
                    domain_turns[0],
                    domain_turns[-1],
                    max_gap,
                    f"{100 * blind_pct:.0f}%",
                ]
            )
        _table(headers, rows, align)

        # --- Blind-spot windows (>20 turns without any proactive check) ---
        print(f"\n  Blind-Spot Windows (>20 turns with zero proactive calls)")
        print("  " + "-" * 50)
        proactive_turns = sorted(
            set(
                e.get("turn", 0)
                for e in tool_calls
                if _classify_tool(e.get("tool", "unknown")) == "proactive"
            )
        )
        if proactive_turns:
            # Include game start and end
            all_boundaries = [turns[0]] + proactive_turns + [turns[-1]]
            windows = []
            for i in range(len(all_boundaries) - 1):
                gap = all_boundaries[i + 1] - all_boundaries[i]
                if gap > 20:
                    windows.append((all_boundaries[i], all_boundaries[i + 1], gap))
            if windows:
                for start, end, gap in sorted(windows, key=lambda x: -x[2]):
                    print(f"    T{start:>3} → T{end:>3}  ({gap} turns blind)")
            else:
                print("    (none — good proactive coverage)")
        else:
            print(f"    ENTIRE GAME ({n_turns} turns with zero proactive calls)")

        # --- Proactive attention sparkline ---
        proactive_per_turn = []
        for t in turns:
            n = sum(
                1
                for e in tool_calls
                if e.get("turn") == t
                and _classify_tool(e.get("tool", "unknown")) == "proactive"
            )
            proactive_per_turn.append(n)
        print(f"\n  Proactive calls/turn: {_sparkline(proactive_per_turn, 50)}")


def cmd_reflection_gap(args):
    """Reflection-action gap analysis — compare stated plans vs actual actions.

    Extracts planning intentions from diary entries and checks whether the
    agent followed through. Directly supports Section 5.3 of the paper.
    """
    games = _list_games()
    targets = _resolve_run_ids([args.game_id], games)
    if not targets:
        print(f"Game '{args.game_id}' not found")
        return
    g = targets[0]
    rid = g["runId"]
    model = g.get("agentModel") or "?"

    print(f"\n{'=' * 70}")
    print(f"  Reflection-Action Gap: {rid} | {model}")
    print(f"{'=' * 70}")

    diary = cloud_diary(rid)
    entries = cloud_log(rid)
    tool_calls = [e for e in entries if e.get("type") == "tool_call"]

    agent_rows = [d for d in diary if d.get("is_agent") and d.get("reflections")]

    if not agent_rows:
        print("  No diary reflections found")
        return

    # --- Stated vs actual: resource spending ---
    print(f"\n  Resource Spending: Plans vs Reality")
    print("  " + "-" * 50)
    spend_mentions = 0
    spend_actions = 0
    for row in agent_rows:
        turn = row.get("turn", 0)
        planning = (row.get("reflections") or {}).get("planning", "")
        if not planning:
            continue

        # Check if planning mentions spending/purchasing
        spend_keywords = ["spend", "purchase", "buy", "gold", "faith"]
        mentions_spend = any(kw in planning.lower() for kw in spend_keywords)
        if mentions_spend:
            spend_mentions += 1
            # Check if purchase_item was actually called within ±3 turns
            nearby_purchases = [
                e
                for e in tool_calls
                if e.get("tool")
                in ("purchase_item", "purchase_tile", "patronize_great_person")
                and abs(e.get("turn", 0) - turn) <= 3
            ]
            if nearby_purchases:
                spend_actions += 1

    if spend_mentions:
        print(f"    Mentioned spending: {spend_mentions} diary entries")
        print(
            f"    Actually purchased: {spend_actions} ({_pct(spend_actions, spend_mentions)} follow-through)"
        )
    else:
        print(f"    No spending plans found in diary")

    # --- Stated vs actual: monitoring intentions ---
    print(f"\n  Monitoring Plans vs Actual Checks")
    print("  " + "-" * 50)
    monitor_pairs = [
        ("victory", ["get_victory_progress"]),
        ("religion", ["get_religion_spread"]),
        ("diplomacy", ["get_diplomacy"]),
        ("great people", ["get_great_people"]),
        ("trade", ["get_trade_routes"]),
    ]
    for keyword, check_tools in monitor_pairs:
        mentions = 0
        followed = 0
        for row in agent_rows:
            turn = row.get("turn", 0)
            planning = (row.get("reflections") or {}).get("planning", "")
            if keyword in planning.lower():
                mentions += 1
                nearby = [
                    e
                    for e in tool_calls
                    if e.get("tool") in check_tools
                    and abs(e.get("turn", 0) - turn) <= 5
                ]
                if nearby:
                    followed += 1
        if mentions:
            pct = _pct(followed, mentions)
            print(
                f"    {keyword:<15} mentioned {mentions:>3}x, followed through {followed:>3}x ({pct})"
            )

    # --- Repeated unfulfilled intentions ---
    print(
        f"\n  Repeated Unfulfilled Intentions (≥3 consecutive mentions without action)"
    )
    print("  " + "-" * 50)
    # Track consecutive planning mentions of keywords without matching action
    action_keywords = {
        "encampment": ["set_city_production"],
        "holy site": ["set_city_production"],
        "settler": ["set_city_production"],
        "attack": ["unit_action"],
        "alliance": ["form_alliance", "send_diplomatic_action"],
        "campus": ["set_city_production"],
    }
    for keyword, action_tools in action_keywords.items():
        streak = 0
        max_streak = 0
        streak_start = 0
        for row in agent_rows:
            turn = row.get("turn", 0)
            planning = (row.get("reflections") or {}).get("planning", "")
            if keyword in planning.lower():
                if streak == 0:
                    streak_start = turn
                streak += 1
                # Check for action within ±5 turns
                nearby = [
                    e
                    for e in tool_calls
                    if e.get("tool") in action_tools
                    and keyword.upper().replace(" ", "_")
                    in str(e.get("params", "")).upper()
                    and abs(e.get("turn", 0) - turn) <= 5
                ]
                if nearby:
                    streak = 0  # resolved
            else:
                max_streak = max(max_streak, streak)
                streak = 0
        max_streak = max(max_streak, streak)
        if max_streak >= 3:
            print(
                f"    '{keyword}' — {max_streak} consecutive diary mentions without action (from ~T{streak_start})"
            )

    # --- Diary planning vs production timeline ---
    print(f"\n  Production Alignment")
    print("  " + "-" * 50)
    prod_calls = [
        e
        for e in tool_calls
        if e.get("tool") == "set_city_production" and e.get("success", True)
    ]
    if prod_calls:
        # Group by 50-turn eras
        era_items: dict[int, Counter] = defaultdict(Counter)
        for e in prod_calls:
            bucket = (e.get("turn", 0) // 50) * 50
            item = (e.get("params") or {}).get("item_name", "?")
            era_items[bucket][item] += 1
        for bucket in sorted(era_items.keys()):
            top = era_items[bucket].most_common(5)
            items_str = ", ".join(f"{item}({n})" for item, n in top)
            print(f"    T{bucket:>3}-T{bucket + 49}: {items_str}")


# ---------------------------------------------------------------------------
# Domain scoring — 8 dimensions from the paper (Table 5)
# ---------------------------------------------------------------------------

CHECKPOINTS = [50, 100, 150, 200, 250, 300]
TOTAL_TOOLS = 76  # current tool count

# Exploration benchmarks from CLAUDE.md
_EXPLORE_BENCHMARKS = {25: 15, 50: 25, 75: 35, 100: 50}
# City founding benchmarks
_CITY_BENCHMARKS = {40: 2, 60: 3, 80: 4, 100: 5}


def _diary_by_turn(diary: list[dict]) -> dict[int, list[dict]]:
    """Group diary rows by turn."""
    by_turn: dict[int, list[dict]] = defaultdict(list)
    for row in diary:
        by_turn[row.get("turn", 0)].append(row)
    return by_turn


def _agent_rows(
    diary: list[dict],
) -> list[dict]:  # Public API: imported by civbench_data.py
    """Extract agent-only rows, one per turn (last entry wins)."""
    by_turn: dict[int, dict] = {}
    for row in diary:
        if row.get("is_agent"):
            by_turn[row.get("turn", 0)] = row
    return [by_turn[t] for t in sorted(by_turn)]


def _all_at_turn(diary: list[dict], turn: int) -> list[dict]:
    """Get all player rows at the nearest turn <= target."""
    by_turn = _diary_by_turn(diary)
    for t in range(turn, -1, -1):
        if t in by_turn:
            return by_turn[t]
    return []


def _agent_at_turn(rows: list[dict], turn: int) -> dict | None:
    """Get agent's row at nearest turn <= target."""
    result = None
    for row in rows:
        if row.get("is_agent") and row.get("turn", 0) <= turn:
            result = row
    return result


def _rank_score(value: float, all_values: list[float]) -> float:
    """Rank-based score: 1st among N = 100, last = 0. Handles ties via midrank."""
    if not all_values or len(all_values) <= 1:
        return 50.0
    n = len(all_values)
    below = sum(1 for v in all_values if v < value)
    equal = sum(1 for v in all_values if v == value)
    # Midrank method: rank = below + 0.5 * equal (includes self)
    midrank = below + 0.5 * equal
    # Scale to 0-100 where top rank = 100
    return min(100, midrank / (n - 1) * 100) if n > 1 else 50.0


def _clamp(v: float, lo: float = 0, hi: float = 100) -> float:
    return max(lo, min(hi, v))


def _city_founding_turns(agent: list[dict]) -> list[int]:
    """Return list of turns when a new city was founded."""
    turns = []
    prev = 0
    for row in agent:
        c = int(row.get("cities", 0))
        if c > prev:
            turns.extend([row.get("turn", 0)] * (c - prev))
            prev = c
    return turns


# ── Per-dimension scorers ────────────────────────────────────────


def score_overall(diary: list[dict]) -> dict:
    """Score relative to AI leader at checkpoints."""
    agent = _agent_rows(diary)
    if not agent:
        return {"score": 0, "details": "No agent data", "checkpoints": {}}
    scores = {}
    for cp in CHECKPOINTS:
        all_players = _all_at_turn(diary, cp)
        if not all_players:
            continue
        agent_row = _agent_at_turn(agent, cp)
        if not agent_row:
            continue
        leader_score = max(r.get("score", 0) for r in all_players)
        agent_score = agent_row.get("score", 0)
        scores[cp] = _clamp(agent_score / max(leader_score, 1) * 100)
    avg = sum(scores.values()) / len(scores) if scores else 0
    last = agent[-1]
    return {
        "score": round(avg),
        "details": f"Score {last.get('score', 0)} at T{last.get('turn', 0)}",
        "checkpoints": {k: round(v) for k, v in scores.items()},
    }


def score_economic(diary: list[dict]) -> dict:
    """Yield growth vs AI average + hoarding penalty."""
    agent = _agent_rows(diary)
    if not agent or len(agent) < 2:
        return {"score": 0, "details": "Insufficient data", "checkpoints": {}}

    # Yield growth percentile at checkpoints
    scores = {}
    for cp in CHECKPOINTS:
        all_players = _all_at_turn(diary, cp)
        if not all_players:
            continue
        agent_row = _agent_at_turn(agent, cp)
        if not agent_row:
            continue

        # Combined yield — production isn't in per-player diary rows
        # (it's per-city), so we use science + culture + gold + faith as proxy
        def combined(r):
            return (
                r.get("science", 0)
                + r.get("culture", 0)
                + r.get("gold_per_turn", 0)
                + r.get("faith_per_turn", 0)
            )

        agent_yield = combined(agent_row)
        all_yields = [combined(r) for r in all_players]
        scores[cp] = _rank_score(agent_yield, all_yields)

    # Hoarding penalty: count turns where gold > 1000 (late-game economies
    # naturally sit above 500; 1000+ with no spending plan is the real issue)
    hoard_turns = sum(1 for r in agent if r.get("gold", 0) > 1000)
    hoard_penalty = min(15, hoard_turns * 0.3)  # max 15 point penalty

    avg = sum(scores.values()) / len(scores) if scores else 50
    final = _clamp(avg - hoard_penalty)
    last = agent[-1]
    return {
        "score": round(final),
        "details": (
            f"Sci {last.get('science', 0):.1f}/t, "
            f"Cul {last.get('culture', 0):.1f}/t, "
            f"Gold {last.get('gold_per_turn', 0):.1f}/t, "
            f"hoarded {hoard_turns} turns"
        ),
        "checkpoints": {k: round(v) for k, v in scores.items()},
    }


def score_military(diary: list[dict], log: list[dict]) -> dict:
    """Military strength percentile + attack efficiency."""
    agent = _agent_rows(diary)
    if not agent:
        return {"score": 0, "details": "No data", "checkpoints": {}}

    # Military strength percentile at checkpoints
    scores = {}
    for cp in CHECKPOINTS:
        all_players = _all_at_turn(diary, cp)
        if not all_players:
            continue
        agent_row = _agent_at_turn(agent, cp)
        if not agent_row:
            continue
        mil = agent_row.get("military", 0)
        all_mils = [r.get("military", 0) for r in all_players]
        scores[cp] = _rank_score(mil, all_mils)

    # Attack efficiency from log
    tool_calls = [e for e in log if e.get("type") == "tool_call"]
    attacks = [
        e
        for e in tool_calls
        if e.get("tool") == "unit_action"
        and (e.get("params") or {}).get("action") == "attack"
    ]
    successful = [e for e in attacks if e.get("success", True)]
    efficiency = len(successful) / max(len(attacks), 1) * 100

    avg = sum(scores.values()) / len(scores) if scores else 50
    final = _clamp(avg * 0.7 + efficiency * 0.3)  # 70% strength, 30% efficiency
    last = agent[-1]
    return {
        "score": round(final),
        "details": (
            f"Mil {last.get('military', 0)}, "
            f"{len(attacks)} attacks ({len(successful)} successful)"
        ),
        "checkpoints": {k: round(v) for k, v in scores.items()},
    }


def score_scientific(diary: list[dict]) -> dict:
    """Tech parity with AI leader + science yield percentile."""
    agent = _agent_rows(diary)
    if not agent:
        return {"score": 0, "details": "No data", "checkpoints": {}}

    scores = {}
    for cp in CHECKPOINTS:
        all_players = _all_at_turn(diary, cp)
        if not all_players:
            continue
        agent_row = _agent_at_turn(agent, cp)
        if not agent_row:
            continue
        agent_techs = agent_row.get("techs_completed", 0)
        leader_techs = max(r.get("techs_completed", 0) for r in all_players)
        tech_parity = _clamp(agent_techs / max(leader_techs, 1) * 100)
        # Also factor in science yield percentile
        agent_sci = agent_row.get("science", 0)
        all_sci = [r.get("science", 0) for r in all_players]
        sci_pct = _rank_score(agent_sci, all_sci)
        scores[cp] = tech_parity * 0.6 + sci_pct * 0.4

    avg = sum(scores.values()) / len(scores) if scores else 50
    last = agent[-1]
    turns = last.get("turn", 1)
    techs = last.get("techs_completed", 0)
    return {
        "score": round(avg),
        "details": (
            f"{techs} techs by T{turns} "
            f"({turns / max(techs, 1):.1f} turns/tech), "
            f"Sci {last.get('science', 0):.1f}/t"
        ),
        "checkpoints": {k: round(v) for k, v in scores.items()},
    }


def score_diplomatic(diary: list[dict], log: list[dict]) -> dict:
    """Diplomatic engagement: actions, favor, alliances, suzerainties."""
    agent = _agent_rows(diary)
    if not agent:
        return {"score": 0, "details": "No data", "checkpoints": {}}

    # Count diplomatic actions from log
    tool_calls = [e for e in log if e.get("type") == "tool_call"]
    diplo_tools = {
        "send_diplomatic_action",
        "form_alliance",
        "propose_trade",
        "send_envoy",
        "respond_to_diplomacy",
    }
    diplo_actions = [e for e in tool_calls if e.get("tool") in diplo_tools]

    # Final state diplomacy metrics
    last = agent[-1]
    favor_pt = last.get("favor_per_turn", 0)
    suzerainties = last.get("suzerainties", 0) or 0
    diplo_vp = last.get("diplo_vp", 0)
    diplo_states = last.get("diplo_states") or {}
    alliances = sum(
        1 for ds in diplo_states.values() if isinstance(ds, dict) and ds.get("alliance")
    )

    # Score components (tuned so typical games score 30-70, not easy 100)
    turns_played = last.get("turn", 1)
    actions_per_turn = len(diplo_actions) / max(turns_played, 1)
    action_score = min(40, actions_per_turn * 100)  # 0.4 actions/turn = 40
    relationship_score = min(
        60,
        alliances * 12 + suzerainties * 8 + favor_pt * 3 + diplo_vp * 2,
    )
    final = _clamp(action_score + relationship_score)

    return {
        "score": round(final),
        "details": (
            f"{len(diplo_actions)} actions, "
            f"{alliances} alliances, "
            f"{suzerainties} suzerainties, "
            f"{favor_pt:.0f} favor/t"
        ),
        "checkpoints": {},
    }


def score_spatial(diary: list[dict], log: list[dict]) -> dict:
    """Exploration vs benchmarks + city founding pace + territory."""
    agent = _agent_rows(diary)
    if not agent:
        return {"score": 0, "details": "No data", "checkpoints": {}}

    # Exploration vs benchmarks
    explore_scores = []
    for turn, benchmark in _EXPLORE_BENCHMARKS.items():
        row = _agent_at_turn(agent, turn)
        if row:
            actual = row.get("exploration_pct", 0)
            explore_scores.append(_clamp(actual / benchmark * 100))

    # City founding vs benchmarks
    city_turns = _city_founding_turns(agent)
    city_scores = []
    for turn, target_count in _CITY_BENCHMARKS.items():
        actual = sum(1 for t in city_turns if t <= turn)
        city_scores.append(_clamp(actual / target_count * 100))

    # Territory percentile at final turn
    last = agent[-1]
    all_final = _all_at_turn(diary, last.get("turn", 0))
    territory_pct = _rank_score(
        last.get("territory", 0),
        [r.get("territory", 0) for r in all_final],
    )

    # Map scan frequency from log
    tool_calls = [e for e in log if e.get("type") == "tool_call"]
    map_scans = sum(1 for e in tool_calls if e.get("tool") == "get_map_area")
    turns_played = last.get("turn", 1)
    scan_freq = map_scans / max(turns_played, 1)

    explore_avg = sum(explore_scores) / len(explore_scores) if explore_scores else 50
    city_avg = sum(city_scores) / len(city_scores) if city_scores else 50
    final = _clamp(
        explore_avg * 0.3
        + city_avg * 0.3
        + territory_pct * 0.2
        + min(100, scan_freq * 200) * 0.2
    )

    return {
        "score": round(final),
        "details": (
            f"{last.get('exploration_pct', 0):.0f}% explored, "
            f"{last.get('cities', 0)} cities, "
            f"{last.get('territory', 0)} territory, "
            f"{scan_freq:.1f} scans/turn"
        ),
        "checkpoints": {},
    }


def score_tool_fluency(log: list[dict]) -> dict:
    """Error rate, tool diversity, repeated failure penalty."""
    tool_calls = [e for e in log if e.get("type") == "tool_call"]
    if not tool_calls:
        return {"score": 0, "details": "No tool calls", "checkpoints": {}}

    errors = [e for e in tool_calls if not e.get("success", True)]
    error_rate = len(errors) / len(tool_calls)
    unique_tools = len(set(e.get("tool") for e in tool_calls))
    diversity = unique_tools / TOTAL_TOOLS

    # Repeated failure penalty (3+ consecutive errors to same tool)
    stuck_count = 0
    streak = 0
    last_tool = None
    for e in tool_calls:
        if not e.get("success", True):
            if e.get("tool") == last_tool:
                streak += 1
                if streak >= 3:
                    stuck_count += 1
            else:
                streak = 1
            last_tool = e.get("tool")
        else:
            streak = 0
            last_tool = None

    accuracy = (1 - error_rate) * 100
    diversity_score = diversity * 100
    stuck_penalty = min(20, stuck_count * 5)

    final = _clamp(accuracy * 0.5 + diversity_score * 0.3 + (100 - stuck_penalty) * 0.2)

    return {
        "score": round(final),
        "details": (
            f"{error_rate:.1%} error rate, "
            f"{unique_tools}/{TOTAL_TOOLS} tools used, "
            f"{stuck_count} stuck loops"
        ),
        "checkpoints": {},
    }


def score_coherence(diary: list[dict], log: list[dict]) -> dict:
    """Score rank stability + proactive monitoring + reflection follow-through."""
    agent = _agent_rows(diary)
    tool_calls = [e for e in log if e.get("type") == "tool_call"]
    if not agent or not tool_calls:
        return {"score": 0, "details": "No data", "checkpoints": {}}

    # 1. Score rank stability (low variance = good)
    ranks = []
    by_turn = _diary_by_turn(diary)
    for turn in sorted(by_turn.keys()):
        players = by_turn[turn]
        scores_at = sorted([r.get("score", 0) for r in players], reverse=True)
        agent_score = next((r.get("score", 0) for r in players if r.get("is_agent")), 0)
        rank = 1 + sum(1 for s in scores_at if s > agent_score)
        n_players = len(scores_at)
        if n_players > 1:
            ranks.append(rank / n_players)  # 0=first, 1=last
    # Trajectory score: reward maintaining or improving rank over time.
    # Compare first-half average rank to second-half (lower = better rank).
    # Improvement = positive score, decline = negative.
    trajectory_score = 50  # neutral default
    if len(ranks) >= 4:
        mid = len(ranks) // 2
        first_half = sum(ranks[:mid]) / mid
        second_half = sum(ranks[mid:]) / (len(ranks) - mid)
        # Improvement: second_half < first_half means rank got better
        delta = first_half - second_half  # positive = improved
        trajectory_score = _clamp(50 + delta * 200)  # 0.25 rank improvement = 100

    # 2. Proactive attention ratio
    proactive_count = sum(
        1 for e in tool_calls if _classify_tool(e.get("tool", "")) == "proactive"
    )
    proactive_ratio = proactive_count / max(len(tool_calls), 1)
    proactive_score = _clamp(proactive_ratio * 500)  # 20% proactive = 100

    # 3. Reflection follow-through (simplified from reflection-gap)
    planning_mentions = 0
    follow_throughs = 0
    check_tools = {
        "victory": ["get_victory_progress"],
        "religion": ["get_religion_spread"],
        "diplomacy": ["get_diplomacy"],
        "trade": ["get_trade_routes"],
        "great people": ["get_great_people"],
    }
    for row in agent:
        planning = (row.get("reflections") or {}).get("planning", "")
        turn = row.get("turn", 0)
        for keyword, tools in check_tools.items():
            if keyword in planning.lower():
                planning_mentions += 1
                nearby = [
                    e
                    for e in tool_calls
                    if e.get("tool") in tools and abs((e.get("turn") or 0) - turn) <= 5
                ]
                if nearby:
                    follow_throughs += 1
    follow_rate = follow_throughs / max(planning_mentions, 1) * 100

    final = _clamp(trajectory_score * 0.3 + proactive_score * 0.4 + follow_rate * 0.3)

    return {
        "score": round(final),
        "details": (
            f"Trajectory {trajectory_score:.0f}, "
            f"proactive {proactive_ratio:.1%}, "
            f"follow-through {follow_rate:.0f}%"
        ),
        "checkpoints": {},
    }


def score_game(diary: list[dict], log: list[dict]) -> dict[str, dict]:
    """Run all 8 dimension scorers."""
    return {
        "Overall Score": score_overall(diary),
        "Economic Management": score_economic(diary),
        "Military Competence": score_military(diary, log),
        "Scientific Progress": score_scientific(diary),
        "Diplomatic Skill": score_diplomatic(diary, log),
        "Spatial Reasoning": score_spatial(diary, log),
        "Tool-Use Fluency": score_tool_fluency(log),
        "Long-Horizon Coherence": score_coherence(diary, log),
    }


def cmd_score(args):
    """Score a game across all 8 evaluation dimensions."""
    games = _list_games()
    targets = _resolve_run_ids([args.game_id], games)
    if not targets:
        print(f"Game '{args.game_id}' not found")
        return
    g = targets[0]
    rid = g["runId"]
    model = g.get("agentModel") or "?"
    o = g.get("outcome") or {}

    diary = cloud_diary(rid)
    log_entries = cloud_log(rid)

    if not diary:
        print(f"No diary data for {rid}")
        return

    results = score_game(diary, log_entries)

    agent = _agent_rows(diary)
    last = agent[-1] if agent else {}
    turns = last.get("turn", 0)

    print(f"\n{'=' * 70}")
    print(f"  Game Score: {rid} | {model} | T{turns}")
    print(
        f"  {o.get('result', g.get('status', '?'))} "
        f"{o.get('victoryType', '')} {o.get('winnerCiv', '')}"
    )
    print(f"{'=' * 70}")

    # Dimension table
    headers = ["Dimension", "Score", "Details"]
    align = ["<", ">", "<"]
    rows = []
    total = 0
    for dim, r in results.items():
        rows.append([dim, r["score"], r["details"][:60]])
        total += r["score"]
    avg = total / len(results) if results else 0
    rows.append(["─" * 22, "─" * 5, "─" * 40])
    rows.append(["AGGREGATE", round(avg), f"(mean of {len(results)} dimensions)"])
    _table(headers, rows, align)

    # Checkpoint trajectory
    has_checkpoints = any(r.get("checkpoints") for r in results.values())
    if has_checkpoints:
        print(f"\n  Checkpoint Trajectory:")
        for cp in CHECKPOINTS:
            parts = []
            for dim, r in results.items():
                cp_val = r.get("checkpoints", {}).get(cp)
                if cp_val is not None:
                    short = dim.split()[0][:4]
                    parts.append(f"{short}:{cp_val}")
            if parts:
                print(f"    T{cp:>3}: {', '.join(parts)}")
    print()


def cmd_scorecard(args):
    """Side-by-side dimension scores averaged across games per model."""
    games = _list_games()

    if args.models:
        model_names = [m.strip() for m in args.models.split(",")]
    else:
        model_names = sorted(set(g.get("agentModel") or "unknown" for g in games))

    model_scores: dict[str, list[dict]] = defaultdict(list)
    for g in games:
        m = g.get("agentModel") or "unknown"
        if m not in model_names:
            continue
        if g.get("excludeReason"):
            continue
        rid = g.get("runId")
        if not rid:
            continue
        diary = cloud_diary(rid)
        log_entries = cloud_log(rid)
        if not diary:
            continue
        results = score_game(diary, log_entries)
        model_scores[m].append(results)

    if not model_scores:
        print("No scoreable games found")
        return

    dimensions = [
        "Overall Score",
        "Economic Management",
        "Military Competence",
        "Scientific Progress",
        "Diplomatic Skill",
        "Spatial Reasoning",
        "Tool-Use Fluency",
        "Long-Horizon Coherence",
    ]

    headers = ["Dimension"] + [m.rsplit("/", 1)[-1][:20] for m in model_names]
    align = ["<"] + [">"] * len(model_names)
    rows = []
    for dim in dimensions:
        row = [dim]
        for m in model_names:
            game_results = model_scores.get(m, [])
            if game_results:
                vals = [gr[dim]["score"] for gr in game_results]
                avg = sum(vals) / len(vals)
                row.append(f"{avg:.0f} ({len(vals)}g)")
            else:
                row.append("-")
        rows.append(row)

    # Aggregate row
    rows.append(["─" * 22] + ["─" * 10] * len(model_names))
    agg_row = ["AGGREGATE"]
    for m in model_names:
        game_results = model_scores.get(m, [])
        if game_results:
            all_scores = []
            for gr in game_results:
                all_scores.append(
                    sum(gr[d]["score"] for d in dimensions) / len(dimensions)
                )
            avg = sum(all_scores) / len(all_scores)
            agg_row.append(f"{avg:.0f} ({len(game_results)}g)")
        else:
            agg_row.append("-")
    rows.append(agg_row)

    print(f"\n  CivBench Scorecard")
    print(f"  {'─' * 60}")
    _table(headers, rows, align)
    print()


# ---------------------------------------------------------------------------
# Cross-model analysis helpers
# ---------------------------------------------------------------------------

_substantial_cache: list[dict] | None = None


def _all_substantial_games(
    model_filter: str | None = None, scenario_filter: str | None = None
) -> list[dict]:
    """Fetch manifests + diary stats for all runs with diary > 50KB.

    Returns list of dicts with keys: run_id, model_id, scenario_id,
    manifest (full dict), diary_size.  Caches aggressively.
    """
    global _substantial_cache
    if _substantial_cache is None:
        fs = _get_fs()
        try:
            run_dirs = fs.ls("telemetry/runs/", detail=False)
        except FileNotFoundError:
            print("Warning: telemetry/runs/ not found in Azure", file=sys.stderr)
            return []

        results = []
        for run_dir in run_dirs:
            run_id = run_dir.rstrip("/").rsplit("/", 1)[-1]
            # Check diary size
            diary_path = f"telemetry/runs/{run_id}/diary.jsonl"
            try:
                info = fs.info(diary_path)
                size = info.get("size") or info.get("content_length") or 0
            except (FileNotFoundError, Exception):
                continue
            if size < 50 * 1024:
                continue

            # Read manifest
            manifest_path = f"telemetry/runs/{run_id}/manifest.json"
            try:
                raw = fs.cat_file(manifest_path)
                manifest = json.loads(raw)
            except (FileNotFoundError, Exception):
                manifest = {}

            metadata = manifest.get("metadata", {})
            results.append(
                {
                    "run_id": run_id,
                    "model_id": metadata.get("model_id", "unknown"),
                    "scenario_id": metadata.get("scenario_id", "unknown"),
                    "manifest": manifest,
                    "diary_size": size,
                }
            )
        _substantial_cache = results

    out = _substantial_cache
    if model_filter:
        out = [g for g in out if model_filter.lower() in g["model_id"].lower()]
    if scenario_filter:
        out = [g for g in out if scenario_filter.lower() in g["scenario_id"].lower()]
    return out


def _scoreboard_at_turn(diary: list[dict], target_turn: int) -> dict | None:
    """Find the scoreboard entry closest to (but <= ) target_turn for the agent."""
    best = None
    for row in diary:
        if not row.get("is_agent"):
            continue
        t = row.get("turn", 0)
        if t <= target_turn:
            best = row
    return best


def _find_game_over(diary: list[dict]) -> dict | None:
    """Find a game_over entry in diary."""
    for row in reversed(diary):
        if row.get("game_over") or row.get("type") == "game_over":
            return row
    return None


def _rank_among_players(diary: list[dict], turn: int) -> int | None:
    """Get agent's rank among all players at a given turn."""
    by_turn = _diary_by_turn(diary)
    # Find nearest turn <= target
    for t in range(turn, -1, -1):
        if t in by_turn:
            rows = by_turn[t]
            if len(rows) < 2:
                continue
            scores = sorted(
                [(r.get("score", 0), r.get("is_agent", False)) for r in rows],
                key=lambda x: -x[0],
            )
            for rank, (sc, is_agent) in enumerate(scores, 1):
                if is_agent:
                    return rank
            break
    return None


# ---------------------------------------------------------------------------
# New subcommands
# ---------------------------------------------------------------------------


def cmd_performance(args):
    """Cross-model performance scorecard from Azure diary data."""
    games = _all_substantial_games(
        model_filter=args.model, scenario_filter=args.scenario
    )
    if not games:
        print("No substantial games found (diary > 50KB)")
        return

    checkpoints = [50, 100, 150, 200, 250]

    # Group by model
    by_model: dict[str, list[dict]] = defaultdict(list)
    for g in games:
        by_model[g["model_id"]].append(g)

    model_names = sorted(by_model.keys())
    _parsed_diary: dict[str, list[dict]] = {}
    print(f"\n  Cross-Model Performance Scorecard ({len(games)} games)")
    print(f"  {'=' * 70}")

    # --- Outcome summary ---
    print(f"\n  Outcome Summary")
    print("  " + "-" * 50)
    headers = ["Model", "Games", "Victories", "Defeats", "Incomplete", "Avg Turn"]
    align = ["<", ">", ">", ">", ">", ">"]
    rows = []
    for model in model_names:
        gg = by_model[model]
        victories = 0
        defeats = 0
        incomplete = 0
        final_turns = []
        for g in gg:
            rid = g["run_id"]
            if rid not in _parsed_diary:
                _parsed_diary[rid] = cloud_diary(rid)
            diary = _parsed_diary[rid]
            agent = _agent_rows(diary)
            if agent:
                final_turns.append(agent[-1].get("turn", 0))
            go = _find_game_over(diary)
            if go:
                result = go.get("result") or go.get("outcome", {}).get("result", "")
                if "victory" in str(result).lower():
                    victories += 1
                elif "defeat" in str(result).lower():
                    defeats += 1
                else:
                    incomplete += 1
            else:
                incomplete += 1
        avg_turn = f"{sum(final_turns) / len(final_turns):.0f}" if final_turns else "-"
        rows.append(
            [
                model.rsplit("/", 1)[-1][:30],
                len(gg),
                victories,
                defeats,
                incomplete,
                avg_turn,
            ]
        )
    _table(headers, rows, align)

    # --- Checkpoint comparison ---
    print(f"\n  Score at Checkpoints (agent score, avg across games)")
    print("  " + "-" * 50)
    headers = ["Turn"] + [m.rsplit("/", 1)[-1][:20] for m in model_names]
    align = [">"] + [">"] * len(model_names)
    rows = []
    for cp in checkpoints:
        vals = []
        for model in model_names:
            scores = []
            for g in by_model[model]:
                rid = g["run_id"]
                if rid not in _parsed_diary:
                    _parsed_diary[rid] = cloud_diary(rid)
                diary = _parsed_diary[rid]
                row = _scoreboard_at_turn(diary, cp)
                if row and row.get("score") is not None:
                    scores.append(row["score"])
            if scores:
                vals.append(f"{sum(scores) / len(scores):.0f}")
            else:
                vals.append("-")
        rows.append([f"T{cp}"] + vals)
    _table(headers, rows, align)

    # --- Cities at checkpoints ---
    print(f"\n  Cities at Checkpoints (avg)")
    print("  " + "-" * 50)
    rows = []
    for cp in checkpoints:
        vals = []
        for model in model_names:
            cities_list = []
            for g in by_model[model]:
                rid = g["run_id"]
                if rid not in _parsed_diary:
                    _parsed_diary[rid] = cloud_diary(rid)
                diary = _parsed_diary[rid]
                row = _scoreboard_at_turn(diary, cp)
                if row and row.get("cities") is not None:
                    cities_list.append(row["cities"])
            if cities_list:
                vals.append(f"{sum(cities_list) / len(cities_list):.1f}")
            else:
                vals.append("-")
        rows.append([f"T{cp}"] + vals)
    _table(headers, rows, align)

    # --- Science at checkpoints ---
    print(f"\n  Science at Checkpoints (avg)")
    print("  " + "-" * 50)
    rows = []
    for cp in checkpoints:
        vals = []
        for model in model_names:
            sci_list = []
            for g in by_model[model]:
                rid = g["run_id"]
                if rid not in _parsed_diary:
                    _parsed_diary[rid] = cloud_diary(rid)
                diary = _parsed_diary[rid]
                row = _scoreboard_at_turn(diary, cp)
                if row and row.get("science") is not None:
                    sci_list.append(row["science"])
            if sci_list:
                vals.append(f"{sum(sci_list) / len(sci_list):.1f}")
            else:
                vals.append("-")
        rows.append([f"T{cp}"] + vals)
    _table(headers, rows, align)

    # --- Rank at checkpoints ---
    print(f"\n  Agent Rank vs Rivals at Checkpoints (avg, 1=best)")
    print("  " + "-" * 50)
    rows = []
    for cp in checkpoints:
        vals = []
        for model in model_names:
            ranks = []
            for g in by_model[model]:
                rid = g["run_id"]
                if rid not in _parsed_diary:
                    _parsed_diary[rid] = cloud_diary(rid)
                diary = _parsed_diary[rid]
                r = _rank_among_players(diary, cp)
                if r is not None:
                    ranks.append(r)
            if ranks:
                vals.append(f"{sum(ranks) / len(ranks):.1f}")
            else:
                vals.append("-")
        rows.append([f"T{cp}"] + vals)
    _table(headers, rows, align)


def cmd_efficiency(args):
    """Tool efficiency analysis by game phase."""
    games = _all_substantial_games(model_filter=args.model)
    if not games:
        print("No substantial games found (diary > 50KB)")
        return

    phases = [
        ("Early (T1-50)", 1, 50),
        ("Mid (T51-150)", 51, 150),
        ("Late (T150+)", 151, 9999),
    ]

    by_model: dict[str, list[dict]] = defaultdict(list)
    for g in games:
        by_model[g["model_id"]].append(g)

    model_names = sorted(by_model.keys())
    _parsed_log: dict[str, list[dict]] = {}
    _parsed_diary: dict[str, list[dict]] = {}
    print(f"\n  Tool Efficiency by Game Phase ({len(games)} games)")
    print(f"  {'=' * 70}")

    for model in model_names:
        print(f"\n  Model: {model.rsplit('/', 1)[-1]}")
        print("  " + "-" * 50)

        phase_stats: dict[str, dict] = {}
        for phase_name, t_start, t_end in phases:
            all_calls_per_turn = []
            all_unique_per_turn = []
            all_score_per_call = []
            all_redundant = []

            for g in by_model[model]:
                rid = g["run_id"]
                if rid not in _parsed_log:
                    _parsed_log[rid] = cloud_log(rid)
                log = _parsed_log[rid]
                if rid not in _parsed_diary:
                    _parsed_diary[rid] = cloud_diary(rid)
                diary = _parsed_diary[rid]
                tool_calls = [
                    e
                    for e in log
                    if e.get("type") == "tool_call"
                    and t_start <= (e.get("turn") or 0) <= t_end
                ]
                if not tool_calls:
                    continue

                # Calls per turn
                per_turn: dict[int, list[str]] = defaultdict(list)
                for e in tool_calls:
                    per_turn[e.get("turn", 0)].append(e.get("tool", "unknown"))

                if per_turn:
                    for t, tools in per_turn.items():
                        all_calls_per_turn.append(len(tools))
                        all_unique_per_turn.append(len(set(tools)))
                        # Redundant: same tool called 2+ times in same turn
                        tool_counts = Counter(tools)
                        redundant = sum(c - 1 for c in tool_counts.values() if c > 1)
                        all_redundant.append(redundant)

                # Score per call
                score_start_row = _scoreboard_at_turn(diary, t_start)
                score_end_row = _scoreboard_at_turn(diary, t_end)
                if score_start_row and score_end_row:
                    s0 = score_start_row.get("score", 0)
                    s1 = score_end_row.get("score", 0)
                    n_calls = len(tool_calls)
                    if n_calls > 0:
                        all_score_per_call.append((s1 - s0) / n_calls)

            avg_calls = (
                f"{sum(all_calls_per_turn) / len(all_calls_per_turn):.1f}"
                if all_calls_per_turn
                else "-"
            )
            avg_unique = (
                f"{sum(all_unique_per_turn) / len(all_unique_per_turn):.1f}"
                if all_unique_per_turn
                else "-"
            )
            avg_spc = (
                f"{sum(all_score_per_call) / len(all_score_per_call):.2f}"
                if all_score_per_call
                else "-"
            )
            avg_redundant = (
                f"{sum(all_redundant) / len(all_redundant):.1f}"
                if all_redundant
                else "-"
            )

            phase_stats[phase_name] = {
                "calls/turn": avg_calls,
                "unique/turn": avg_unique,
                "score/call": avg_spc,
                "redundant/turn": avg_redundant,
            }

        headers = ["Metric"] + [p[0] for p in phases]
        align = ["<"] + [">"] * len(phases)
        rows = []
        for metric in ["calls/turn", "unique/turn", "score/call", "redundant/turn"]:
            row = [metric]
            for phase_name, _, _ in phases:
                row.append(phase_stats.get(phase_name, {}).get(metric, "-"))
            rows.append(row)
        _table(headers, rows, align)

    # --- Redundant call detail ---
    print(f"\n  Redundant Call Hotspots (same tool 2+ times in one turn)")
    print("  " + "-" * 50)
    redundant_counter: Counter = Counter()
    for g in games:
        rid = g["run_id"]
        if rid not in _parsed_log:
            _parsed_log[rid] = cloud_log(rid)
        log = _parsed_log[rid]
        tool_calls = [e for e in log if e.get("type") == "tool_call"]
        per_turn: dict[int, list[str]] = defaultdict(list)
        for e in tool_calls:
            per_turn[e.get("turn", 0)].append(e.get("tool", "unknown"))
        for t, tools in per_turn.items():
            for tool, count in Counter(tools).items():
                if count >= 2:
                    redundant_counter[tool] += count - 1

    headers = ["Tool", "Redundant Calls"]
    align = ["<", ">"]
    rows = [[tool, count] for tool, count in redundant_counter.most_common(15)]
    _table(headers, rows, align)


def cmd_context_growth(args):
    """Context size estimation from result_summary lengths."""
    games = _all_substantial_games(model_filter=args.model)
    if not games:
        print("No substantial games found (diary > 50KB)")
        return

    by_model: dict[str, list[dict]] = defaultdict(list)
    for g in games:
        by_model[g["model_id"]].append(g)

    model_names = sorted(by_model.keys())
    _parsed_log: dict[str, list[dict]] = {}
    print(f"\n  Context Growth Analysis ({len(games)} games)")
    print(f"  {'=' * 70}")

    checkpoints = [50, 100, 150]

    # --- Per-model context at checkpoints ---
    print(f"\n  Avg Cumulative Context Size at Checkpoints (chars)")
    print("  " + "-" * 50)
    headers = ["Turn"] + [m.rsplit("/", 1)[-1][:20] for m in model_names]
    align = [">"] + [">"] * len(model_names)
    rows = []
    for cp in checkpoints:
        vals = []
        for model in model_names:
            sizes = []
            for g in by_model[model]:
                rid = g["run_id"]
                if rid not in _parsed_log:
                    _parsed_log[rid] = cloud_log(rid)
                log = _parsed_log[rid]
                cum = 0
                for e in log:
                    if (e.get("turn") or 0) <= cp:
                        cum += len(e.get("result_summary", ""))
                if cum > 0:
                    sizes.append(cum)
            if sizes:
                avg = sum(sizes) / len(sizes)
                vals.append(f"{avg / 1000:.0f}K")
            else:
                vals.append("-")
        rows.append([f"T{cp}"] + vals)
    _table(headers, rows, align)

    # --- Top 5 context-heavy tools ---
    print(
        f"\n  Top 10 Context-Heavy Tools (total result_summary chars across all games)"
    )
    print("  " + "-" * 50)
    tool_chars: Counter = Counter()
    tool_call_count: Counter = Counter()
    for g in games:
        rid = g["run_id"]
        if rid not in _parsed_log:
            _parsed_log[rid] = cloud_log(rid)
        log = _parsed_log[rid]
        for e in log:
            if e.get("type") == "tool_call":
                chars = len(e.get("result_summary", ""))
                tool_chars[e.get("tool", "unknown")] += chars
                tool_call_count[e.get("tool", "unknown")] += 1

    headers = ["Tool", "Total Chars", "Calls", "Avg Chars/Call"]
    align = ["<", ">", ">", ">"]
    rows = []
    for tool, total_chars in tool_chars.most_common(10):
        calls = tool_call_count[tool]
        avg = total_chars / calls if calls else 0
        rows.append(
            [
                tool,
                f"{total_chars / 1000:.0f}K",
                calls,
                f"{avg:.0f}",
            ]
        )
    _table(headers, rows, align)

    # --- Context per turn sparklines ---
    print(f"\n  Context Chars/Turn Sparklines")
    print("  " + "-" * 50)
    for model in model_names:
        for g in by_model[model]:
            rid = g["run_id"]
            if rid not in _parsed_log:
                _parsed_log[rid] = cloud_log(rid)
            log = _parsed_log[rid]
            if not log:
                continue
            per_turn: dict[int, int] = defaultdict(int)
            for e in log:
                t = e.get("turn") or 0
                per_turn[t] += len(e.get("result_summary", ""))
            if not per_turn:
                continue
            max_turn = max(per_turn.keys())
            vals = [per_turn.get(t, 0) for t in range(1, max_turn + 1)]
            if vals:
                label = f"{model.rsplit('/', 1)[-1][:15]} {g['run_id'][:8]}"
                total = sum(vals)
                print(
                    f"    {label:<28} {_sparkline(vals, 40)}  ({total / 1000:.0f}K total)"
                )


# ---------------------------------------------------------------------------
# Save scumming detection
# ---------------------------------------------------------------------------

_SAVE_TOOLS = {"load_game_save", "load_save", "list_saves", "restart_and_load"}


def _analyze_scumming(run_id: str, log: list[dict]) -> dict:
    """Analyze a game log for save-scumming patterns.

    Key signals:
    - **distinct_play_turns_with_loads**: loads at different *in-play* turns
      (T0 loads are boot retries, not scumming). This is the primary signal —
      a legitimate deadlock has all loads clustered at one turn; scumming
      spreads them across many turns.
    - **play_regressions**: turn drops observed via tool_call turn field while
      *playing* (not at T0 or during a single-turn debug cluster).
    - **non_recovery_loads**: loads not immediately preceded by a HANG or error.

    Verdicts:
        CLEAN       — zero loads
        MINOR       — boot retries only, or <3 distinct-play-turn loads
        SUSPICIOUS  — 3-4 distinct-play-turn loads or any real regression
        SCUMMING    — 5+ distinct-play-turn loads with regressions
    """
    tool_calls = [e for e in log if e.get("type") == "tool_call"]

    save_events = []  # list of (idx, turn, tool)
    for i, e in enumerate(tool_calls):
        tool = e.get("tool", "")
        if tool in _SAVE_TOOLS:
            save_events.append((i, e.get("turn", 0) or 0, tool))

    load_events = [
        se
        for se in save_events
        if se[2] in ("load_game_save", "load_save", "restart_and_load")
    ]

    # Boot loads (turn 0) vs play loads (turn > 0)
    boot_loads = [se for se in load_events if se[1] == 0]
    play_loads = [se for se in load_events if se[1] > 0]

    distinct_play_turns = sorted({se[1] for se in play_loads})
    n_distinct_play_turns = len(distinct_play_turns)

    # Turn regressions: detect drops in max-turn-seen across tool_call turn field,
    # but only count "play regressions" — drops that are meaningfully backwards
    # during play, not just flickers within a debug cluster at a single turn.
    max_turn_seen = 0
    raw_regressions: list[tuple[int, int]] = []
    for e in tool_calls:
        t = e.get("turn", 0) or 0
        if t == 0:
            continue
        if max_turn_seen > 0 and t < max_turn_seen - 1:
            raw_regressions.append((max_turn_seen, t))
        if t > max_turn_seen:
            max_turn_seen = t

    # Deduplicate and keep unique (from, to) pairs
    seen = set()
    unique_regressions: list[tuple[int, int]] = []
    for r in raw_regressions:
        if r not in seen:
            seen.add(r)
            unique_regressions.append(r)

    max_regression = max((a - b for a, b in unique_regressions), default=0)

    # A regression is a "play rollback" (i.e., save scumming) if the agent
    # went from max_turn_seen DOWN to an earlier turn AND then continued to
    # make progress from the earlier turn (i.e., not just flickering within
    # a debug cluster at one sticking point).
    #
    # Key distinction:
    # - Deadlock debugging: loads at T326, sees T316-326 flickering, but
    #   never progresses past T326 — all play stops at the same terminal turn.
    # - Scumming: loads at T122 back to T114, then plays T114-T122 again,
    #   possibly reaching higher max later.
    #
    # Detection: a "real rollback" exists if there are load events at
    # non-sequential turns — e.g. loads at T106, T110, T116, T122 means the
    # agent kept reloading at different points as the game progressed.
    real_regressions: list[tuple[int, int]] = []
    if play_loads:
        load_turns_sorted = sorted(set(se[1] for se in play_loads))
        # If loads span more than 5 distinct turns AND the turns are spread
        # (not all within 5 turns of each other), this is rollback behaviour
        if len(load_turns_sorted) >= 3:
            span = load_turns_sorted[-1] - load_turns_sorted[0]
            if span >= 10:
                # Spread-out loads are the primary signal
                real_regressions = [
                    (from_t, to_t)
                    for from_t, to_t in unique_regressions
                    if from_t - to_t >= 3
                ]

    # Hang/error recovery context
    hang_recovery = 0
    for idx, turn, tool in load_events:
        if turn == 0:
            continue  # boot loads aren't "recovery" in play terms
        for j in range(max(0, idx - 5), idx):
            prior = tool_calls[j]
            prior_result = str(prior.get("result", ""))
            if (
                "HANG" in prior_result
                or "Blocker:" in prior_result
                or prior.get("type") == "error"
            ):
                hang_recovery += 1
                break

    load_count = len(load_events)
    play_load_count = len(play_loads)

    # Check load turn spread (distance between first and last load turn)
    load_span = 0
    if play_loads:
        load_turns = sorted(se[1] for se in play_loads)
        load_span = load_turns[-1] - load_turns[0]

    # Hang context ratio — if most loads follow a HANG/Blocker/error,
    # it's legitimate recovery, not scumming
    hang_ratio = hang_recovery / play_load_count if play_load_count else 1.0

    # Verdict logic — the key distinction is WHETHER THE LOADS ARE SPREAD
    # across the game (scumming) or CLUSTERED at a few sticking points
    # (legitimate deadlock debugging).
    if load_count == 0:
        verdict = "CLEAN"
        reason = "no save loads"
    elif play_load_count == 0:
        verdict = "MINOR"
        reason = f"{len(boot_loads)} boot loads only (no in-play loads)"
    elif n_distinct_play_turns >= 5 and load_span >= 30 and hang_ratio < 0.5:
        # Loads across many turns, spread across the game, not driven by hangs
        verdict = "SCUMMING"
        reason = (
            f"{play_load_count} loads across {n_distinct_play_turns} play turns "
            f"(span {load_span}), hang ratio {hang_ratio:.0%}"
        )
    elif n_distinct_play_turns >= 3 and load_span >= 20 and hang_ratio < 0.7:
        verdict = "SUSPICIOUS"
        reason = (
            f"{play_load_count} loads across {n_distinct_play_turns} play turns "
            f"(span {load_span}), hang ratio {hang_ratio:.0%}"
        )
    elif hang_ratio >= 0.7 or n_distinct_play_turns <= 2:
        # High hang context or clustered loads = legitimate recovery
        verdict = "MINOR"
        reason = (
            f"{play_load_count} loads, {hang_recovery}/{play_load_count} in hang context, "
            f"{n_distinct_play_turns} distinct turns"
        )
    else:
        verdict = "SUSPICIOUS"
        reason = (
            f"{play_load_count} loads across {n_distinct_play_turns} play turns "
            f"(span {load_span})"
        )

    return {
        "run_id": run_id,
        "save_calls": len(save_events),
        "load_calls": load_count,
        "play_load_count": play_load_count,
        "boot_load_count": len(boot_loads),
        "distinct_play_turns": n_distinct_play_turns,
        "hang_recovery_loads": hang_recovery,
        "max_regression": max_regression,
        "real_regressions": real_regressions,
        "all_regressions": unique_regressions,
        "verdict": verdict,
        "reason": reason,
    }


def cmd_scumming(args):
    """Detect save-scumming patterns across games."""
    games = _list_games()
    targets = games
    if args.game_id:
        targets = _resolve_run_ids([args.game_id], games)
        if not targets:
            return

    print(f"\n  Save Scumming Audit ({len(targets)} games)")
    print("  " + "=" * 80)

    results = []
    for g in targets:
        rid = g.get("runId")
        if not rid:
            continue
        try:
            log = cloud_log(rid)
        except Exception as exc:
            print(f"  [skip] {rid}: {exc}", file=sys.stderr)
            continue
        if not log:
            continue
        r = _analyze_scumming(rid, log)
        r["model"] = g.get("agentModel") or "?"
        r["scenario"] = g.get("scenarioId") or "?"
        r["turns"] = int(g.get("count") or 0)
        r["game_id"] = g.get("gameId", "")
        r["admissible"] = g.get("admissible")
        results.append(r)

    # Sort: scumming first, then suspicious, then minor, then clean
    verdict_order = {"SCUMMING": 0, "SUSPICIOUS": 1, "MINOR": 2, "CLEAN": 3}
    results.sort(key=lambda x: (verdict_order.get(x["verdict"], 9), -x["load_calls"]))

    headers = [
        "Verdict",
        "Model",
        "Scenario",
        "T",
        "PlayLoads",
        "PlayTurns",
        "RealReg",
        "Recovery",
        "Run ID",
    ]
    align = ["<", "<", "<", ">", ">", ">", ">", ">", "<"]
    rows = []
    for r in results:
        model_short = r["model"].rsplit("/", 1)[-1][:20]
        scenario_short = r["scenario"][:15]
        rows.append(
            [
                r["verdict"],
                model_short,
                scenario_short,
                r["turns"],
                r["play_load_count"],
                r["distinct_play_turns"],
                len(r["real_regressions"]),
                f"{r['hang_recovery_loads']}/{r['play_load_count']}"
                if r["play_load_count"]
                else "-",
                r["run_id"][:40],
            ]
        )
    _table(headers, rows, align)

    counts = Counter(r["verdict"] for r in results)
    print()
    print(
        f"  Summary: CLEAN={counts['CLEAN']}  MINOR={counts['MINOR']}  "
        f"SUSPICIOUS={counts['SUSPICIOUS']}  SCUMMING={counts['SCUMMING']}"
    )

    scumming = [r for r in results if r["verdict"] == "SCUMMING"]
    if scumming:
        print()
        print("  SCUMMING games:")
        for r in scumming:
            print(f"    {r['game_id']}")
            print(f"      reason: {r['reason']}")
            if r["real_regressions"]:
                print(f"      real regressions: {r['real_regressions'][:5]}")

    # --apply: mark scumming games with excludeReason
    if args.apply and scumming:
        print()
        print(f"  Applying excludeReason='save_scumming' to {len(scumming)} games...")
        import httpx

        env = _load_env()
        # Try web/.env.prod first
        prod_env = {}
        prod_path = Path(__file__).parent.parent / "web" / ".env.prod"
        if prod_path.exists():
            for line in prod_path.read_text().splitlines():
                if "=" in line and not line.startswith("#"):
                    k, v = line.split("=", 1)
                    prod_env[k.strip()] = v.strip()
        url = prod_env.get("CONVEX_URL", "").rstrip("/")
        key = prod_env.get("CONVEX_DEPLOY_KEY", "")
        if not url or not key:
            print(
                "  Error: need CONVEX_URL and CONVEX_DEPLOY_KEY in web/.env.prod",
                file=sys.stderr,
            )
            return
        client = httpx.Client(
            timeout=30,
            headers={
                "Content-Type": "application/json",
                "Authorization": f"Convex {key}",
            },
        )
        for r in scumming:
            resp = client.post(
                f"{url}/api/mutation",
                json={
                    "path": "ingest:patchExcludeReason",
                    "args": {
                        "gameId": r["game_id"],
                        "excludeReason": "save_scumming",
                    },
                    "format": "json",
                },
            )
            data = resp.json()
            if data.get("status") == "success":
                print(f"    OK  {r['game_id']}")
            else:
                print(f"    FAIL {r['game_id']}: {data}")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main():
    parser = argparse.ArgumentParser(
        description="CivBench game analysis CLI",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    sub = parser.add_subparsers(dest="command")

    # games
    p_games = sub.add_parser("games", help="List all games")
    p_games.add_argument("--model", help="Filter by model name")

    # tools
    p_tools = sub.add_parser("tools", help="Tool calling analysis")
    p_tools.add_argument("game_ids", nargs="*", help="Game/run IDs")
    p_tools.add_argument("--model", help="Analyze all games for a model")

    # compare
    p_compare = sub.add_parser("compare", help="Side-by-side model comparison")
    p_compare.add_argument("--models", help="Comma-separated model names")

    # strategy
    p_strategy = sub.add_parser("strategy", help="Strategic planning deep-dive")
    p_strategy.add_argument("game_id", help="Game or run ID")

    # turns
    p_turns = sub.add_parser("turns", help="Per-turn breakdown")
    p_turns.add_argument("game_id", help="Game or run ID")
    p_turns.add_argument("--range", help="Turn range, e.g. 50-100")
    p_turns.add_argument("--metric", help="Metrics to show (comma-separated)")

    # sensorium
    p_sensor = sub.add_parser(
        "sensorium", help="Sensorium effect analysis (paper §5.2)"
    )
    p_sensor.add_argument("game_ids", nargs="*", help="Game/run IDs")
    p_sensor.add_argument("--model", help="Analyze all games for a model")

    # reflection-gap
    p_refl = sub.add_parser(
        "reflection-gap", help="Reflection-action gap analysis (paper §5.3)"
    )
    p_refl.add_argument("game_id", help="Game or run ID")

    # score
    p_score = sub.add_parser("score", help="Score a game across 8 dimensions")
    p_score.add_argument("game_id", help="Game or run ID")

    # scorecard
    p_card = sub.add_parser("scorecard", help="Side-by-side model scorecard")
    p_card.add_argument("--models", help="Comma-separated model names")

    # performance
    p_perf = sub.add_parser("performance", help="Cross-model performance scorecard")
    p_perf.add_argument("--model", help="Filter by model name")
    p_perf.add_argument("--scenario", help="Filter by scenario")

    # efficiency
    p_eff = sub.add_parser("efficiency", help="Tool efficiency by game phase")
    p_eff.add_argument("--model", help="Filter by model name")

    # context
    p_ctx = sub.add_parser("context", help="Context growth analysis")
    p_ctx.add_argument("--model", help="Filter by model name")

    # scumming
    p_scum = sub.add_parser("scumming", help="Detect save-scumming patterns")
    p_scum.add_argument("--game-id", help="Analyze a single game")
    p_scum.add_argument(
        "--apply",
        action="store_true",
        help="Mark detected scumming games as excludeReason='save_scumming'",
    )

    args = parser.parse_args()
    if not args.command:
        parser.print_help()
        return

    dispatch = {
        "games": cmd_games,
        "tools": cmd_tools,
        "compare": cmd_compare,
        "strategy": cmd_strategy,
        "turns": cmd_turns,
        "sensorium": cmd_sensorium,
        "reflection-gap": cmd_reflection_gap,
        "score": cmd_score,
        "scorecard": cmd_scorecard,
        "performance": cmd_performance,
        "efficiency": cmd_efficiency,
        "context": cmd_context_growth,
        "scumming": cmd_scumming,
    }
    dispatch[args.command](args)


if __name__ == "__main__":
    main()
