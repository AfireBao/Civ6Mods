#!/usr/bin/env python3
"""Bulk runner for CivBench scenarios.

Runs scenarios sequentially (one game at a time) across one or more models.
Results are stored in Inspect's default log directory and viewable via
`inspect view`.

Usage:
    # Single model, all scenarios
    uv run python evals/runner.py --model openai/azure/gpt-5.2

    # Multiple models
    uv run python evals/runner.py \
        --models openai/azure/gpt-5.2,google/vertex/gemini-3.1-pro-preview

    # All default models
    uv run python evals/runner.py --all

    # Specific scenarios
    uv run python evals/runner.py \
        --model openai/azure/gpt-5.2 \
        --scenarios ground_control,snowflake

    # Short test run (10 messages per sample)
    uv run python evals/runner.py \
        --model openai/azure/gpt-5.2 \
        --scenarios ground_control \
        --message-limit 10

Prerequisites:
    - Civilization VI running with FireTuner enabled (port 4318)
    - Benchmark save files in evals/saves/
    - evals/.env with API credentials (see evals/.env.example)
"""

import argparse
import json
import os
import socket
import subprocess
import sys
import time
from pathlib import Path

# ---------------------------------------------------------------------------
# Load credentials from evals/.env
# ---------------------------------------------------------------------------

EVALS_DIR = Path(__file__).parent
_ENV_FILE = EVALS_DIR / ".env"

if _ENV_FILE.exists():
    for line in _ENV_FILE.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        key, _, value = line.partition("=")
        key, value = key.strip(), value.strip()
        if key and value:
            os.environ.setdefault(key, value)

# ---------------------------------------------------------------------------
# Pre-flight: ensure game is running
# ---------------------------------------------------------------------------

_TUNER_PORT = 4318


def _port_reachable(port: int = _TUNER_PORT) -> bool:
    """Quick TCP connect test."""
    try:
        s = socket.create_connection(("127.0.0.1", port), timeout=2)
        s.close()
        return True
    except (ConnectionRefusedError, OSError):
        return False


def ensure_game_ready() -> None:
    """Ensure Civ 6 is running and the FireTuner port is reachable.

    If the game isn't running, launches it and waits for the port to open.
    Call this before spawning inspect eval so the game is ready.

    Does NOT handshake with the tuner — the single tuner connection must
    be reserved for the eval agent's MCP server.
    """
    # Import game_launcher from the project
    project_src = str(EVALS_DIR.parent / "src")
    if project_src not in sys.path:
        sys.path.insert(0, project_src)

    from civ_mcp.game_launcher import _launch_game_sync, is_game_running

    if is_game_running() and _port_reachable():
        print("Pre-flight: Civ 6 is running, FireTuner port is open.")
        return

    if _port_reachable() and not is_game_running():
        print(
            "Pre-flight: Port 4318 is open but game is NOT running "
            "(likely FireTuner.exe or stale connection). Launching game..."
        )
    else:
        print("Pre-flight: FireTuner port not reachable — launching Civ 6...")

    result = _launch_game_sync()
    print(f"Pre-flight: {result}")

    if not _port_reachable():
        print("FATAL: Game launched but FireTuner port never opened.")
        print("Check that EnableTuner=1 is set and the Civ 6 SDK is installed.")
        sys.exit(1)


# ---------------------------------------------------------------------------
# Model catalogue — verified working models
# ---------------------------------------------------------------------------

# Azure OpenAI
AZURE_MODELS = [
    "openai/azure/gpt-5.4",
    "openai/azure/gpt-5.2",
    "openai/azure/gpt-5.1",
    "openai/azure/gpt-5",
    "openai/azure/Kimi-K2.5",
    "openai/azure/Kimi-K2-Thinking",
    "openai/azure/DeepSeek-V3.2",
]

# Azure supports Responses API but NOT /responses/input_tokens (token counting)
# or /responses/compact — Inspect's context compaction crashes with 404.
# Force chat completions until Azure adds full v1 parity.
_NEEDS_CHAT_COMPLETIONS = {"gpt-5.4", "gpt-5.2", "gpt-5.1", "gpt-5"}

# GCP Vertex AI (Gemini + Anthropic)
VERTEX_MODELS = [
    "anthropic/vertex/claude-opus-4-6",
    "google/vertex/gemini-3.1-pro-preview",
    "google/vertex/gemini-3.1-flash-lite-preview",
    "google/vertex/gemini-3-pro-preview",
    "google/vertex/gemini-3-flash-preview",
]

ALL_MODELS = AZURE_MODELS + VERTEX_MODELS

# ---------------------------------------------------------------------------
# Register custom model context windows not in inspect's built-in database.
# inspect falls back to 128K when unknown, which causes premature compaction.
# ---------------------------------------------------------------------------


def _register_custom_models() -> None:
    from inspect_ai.model import ModelInfo, set_model_info

    # Kimi-K2.5: 256K context (canonical name: openai/Kimi-K2.5 after azure prefix strip)
    _kimi_info = ModelInfo(
        context_length=262_144, output_tokens=16_384, organization="Moonshot AI"
    )
    set_model_info("openai/Kimi-K2.5", _kimi_info)
    set_model_info("openai/Kimi-K2-Thinking", _kimi_info)


_register_custom_models()

ALL_SCENARIOS = [
    "ground_control",
    "snowflake",
    "cry_havoc",
]


def _build_diary_summary(diary_glob: str = "diary_*.jsonl") -> str | None:
    """Build a compact game history summary from the most recent diary file.

    Reads the agent's diary JSONL (pid=0, is_agent=True entries only) and
    produces a markdown summary with milestones, current state, and recent
    strategic thinking.
    """
    diary_dir = Path.home() / ".civ6-mcp"
    if not diary_dir.exists():
        return None
    files = sorted(diary_dir.glob(diary_glob), key=lambda p: p.stat().st_mtime)
    if not files:
        return None
    diary_path = files[-1]  # most recent

    entries = []
    for line in diary_path.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        try:
            e = json.loads(line)
        except json.JSONDecodeError:
            continue
        if e.get("is_agent"):
            entries.append(e)
    if not entries:
        return None

    # Deduplicate by turn (keep last entry per turn)
    by_turn: dict[int, dict] = {}
    for e in entries:
        by_turn[e.get("turn", 0)] = e
    turns = sorted(by_turn.keys())
    last = by_turn[turns[-1]]

    # Milestones
    milestones = []
    prev_cities, prev_era = 0, ""
    for t in turns:
        e = by_turn[t]
        c = e.get("cities", 0)
        era = e.get("era", "")
        if c > prev_cities:
            milestones.append(f"- T{t}: Founded city #{c}")
            prev_cities = c
        if era != prev_era:
            milestones.append(f"- T{t}: Entered {era.replace('ERA_', '')}")
            prev_era = era

    # Current state
    state_lines = [
        f"**Turn {turns[-1]}** | Score: {last.get('score')} | "
        f"Cities: {last.get('cities')} | Pop: {last.get('pop')}",
        f"Science: {last.get('science')}/t | Culture: {last.get('culture')}/t | "
        f"Gold: {last.get('gold_per_turn')}/t ({last.get('gold')}g)",
        f"Techs: {last.get('techs_completed')} | Civics: {last.get('civics_completed')} | "
        f"Military: {last.get('military')}",
        f"Era: {last.get('era')} | Government: {last.get('government')}",
        f"Science VP: {last.get('sci_vp', 0)} | Diplo VP: {last.get('diplo_vp', 0)}",
        f"Units: {last.get('unit_composition', {})}",
    ]

    # Last 5 turns of strategic thinking
    recent = []
    for t in turns[-5:]:
        r = by_turn[t].get("reflections", {})
        if r.get("strategic"):
            recent.append(f"**T{t}:** {r['strategic'][:300]}")

    parts = ["#### Milestones\n"]
    parts.extend(milestones)
    parts.append("\n#### Current State\n")
    parts.extend(state_lines)
    if recent:
        parts.append("\n#### Recent Strategy\n")
        parts.extend(recent)

    return "\n".join(parts)


def _find_latest_autosave() -> str | None:
    """Find the most recent autosave for auto-resume after crash."""
    try:
        project_src = str(EVALS_DIR.parent / "src")
        if project_src not in sys.path:
            sys.path.insert(0, project_src)
        from civ_mcp.autosave import get_latest_autosave

        return get_latest_autosave()
    except Exception as e:
        print(f"  WARNING: Could not find autosave: {e}")
        return None


def _discover_run_id() -> str | None:
    """Find the run_id from the most recent diary file.

    Extracts from filename: diary_{civ}_{seed}_{run_id}.jsonl
    The run_id is the last underscore-delimited segment before .jsonl.
    """
    diary_dir = Path.home() / ".civ6-mcp"
    if not diary_dir.exists():
        return None
    # Exclude _cities files
    files = [
        f
        for f in diary_dir.glob("diary_*.jsonl")
        if not f.name.endswith("_cities.jsonl")
    ]
    if not files:
        return None
    latest = max(files, key=lambda p: p.stat().st_mtime)
    # diary_babylon_stk_-1498189056_050d5491.jsonl → 050d5491
    stem = latest.stem  # diary_babylon_stk_-1498189056_050d5491
    run_id = stem.rsplit("_", 1)[-1]
    return run_id if run_id else None


def _upload_eval_logs(
    local_dir: Path, cloud_url: str, run_id: str | None = None
) -> None:
    """Upload .eval files from local_dir to cloud storage with retries.

    When run_id is provided, uploads to {cloud_url}/runs/{run_id}/ so .eval
    files live alongside the diary/log telemetry for the same game.
    Falls back to {cloud_url}/evals/ when no run_id is available.

    Transient DNS/network errors are caught — the local file is preserved.
    """
    import time

    eval_files = list(local_dir.glob("*.eval"))
    if not eval_files:
        return

    try:
        import fsspec

        fs, _, paths = fsspec.get_fs_token_paths(cloud_url)
        base_path = paths[0] if paths else cloud_url
    except Exception as e:
        print(f"  WARNING: Could not init cloud filesystem: {e}")
        print(f"  .eval files preserved in {local_dir}")
        return

    for eval_file in eval_files:
        if run_id:
            dest = f"{base_path}/runs/{run_id}/{eval_file.name}"
            display = f"{cloud_url}/runs/{run_id}/{eval_file.name}"
        else:
            dest = f"{base_path}/evals/{eval_file.name}"
            display = f"{cloud_url}/evals/{eval_file.name}"
        for attempt in range(3):
            try:
                fs.put(str(eval_file), dest)
                print(f"  Uploaded {eval_file.name} → {display}")
                eval_file.unlink()
                break
            except Exception as e:
                print(f"  Upload attempt {attempt + 1}/3 failed: {e}")
            if attempt < 2:
                time.sleep(5 * (attempt + 1))
        else:
            print(f"  WARNING: Failed to upload {eval_file.name} after 3 attempts.")
            print(f"  File preserved at: {eval_file}")


def run_scenario(
    model: str,
    scenario: str,
    track: str = "civbench_standard",
    message_limit: int | None = None,
    resume_save: str | None = None,
    extra_args: list[str] | None = None,
) -> int:
    """Run a single scenario and return the exit code."""
    # Log locally first, upload to cloud after — avoids Inspect crashing
    # on transient DNS/network errors during log_finish().
    cloud_bucket = os.environ.get("CIV_MCP_TELEMETRY_BUCKET", "")
    local_log_dir = EVALS_DIR.parent / "logs"
    local_log_dir.mkdir(exist_ok=True)
    os.environ["INSPECT_LOG_DIR"] = str(local_log_dir)

    # Extract clean model name for diary/log attribution
    # e.g. "openai/azure/gpt-5.2" → "gpt-5.2"
    clean_model = model.rsplit("/", 1)[-1]
    # Resolve inspect CLI from the same venv as the running Python interpreter
    import shutil

    inspect_bin = shutil.which("inspect") or str(
        Path(sys.executable).parent / "inspect"
    )
    cmd = [
        inspect_bin,
        "eval",
        f"evals/civbench.py@{track}",
        "--model",
        model,
        "-T",
        f"scenarios={scenario}",
        "-T",
        f"model_id={clean_model}",
        "--max-samples",
        "1",  # one game at a time
        "--attempt-timeout",
        "600",  # 10 min max per API call — prevents indefinite hangs
        "--max-retries",
        "20",  # high count to survive transient network outages (exp backoff)
    ]
    # Azure doesn't support the OpenAI Responses API
    deployment = clean_model
    if deployment in _NEEDS_CHAT_COMPLETIONS:
        cmd.extend(["-M", "responses_api=false"])
    if message_limit is not None:
        cmd.extend(["--message-limit", str(message_limit)])
    if resume_save:
        cmd.extend(["-T", f"resume_save={resume_save}"])
        # Discover original run_id from existing diary files so the resumed
        # game appends to the same JSONL files (and same Convex game entry).
        original_run_id = _discover_run_id()
        if original_run_id:
            cmd.extend(["-T", f"run_id={original_run_id}"])
        diary_summary = _build_diary_summary()
        if diary_summary:
            # Write to temp file to avoid shell escaping issues
            ctx_file = EVALS_DIR / ".resume_context.md"
            ctx_file.write_text(diary_summary, encoding="utf-8")
            cmd.extend(["-T", f"resume_context=file://{ctx_file}"])
    if extra_args:
        cmd.extend(extra_args)

    print(f"\n{'=' * 60}")
    print(f"  {model} | {scenario}")
    print(f"  {' '.join(cmd)}")
    print(f"{'=' * 60}\n")

    result = subprocess.run(
        cmd,
        cwd=str(EVALS_DIR.parent),
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.returncode != 0 and result.stderr:
        print(f"  STDERR (last 2000 chars):\n{result.stderr[-2000:]}")

    # Cleanup orphaned game/MCP processes after eval exits
    try:
        project_src = str(EVALS_DIR.parent / "src")
        if project_src not in sys.path:
            sys.path.insert(0, project_src)
        from civ_mcp.game_launcher import _kill_game_sync

        _kill_game_sync()
    except Exception:
        pass

    # Upload .eval logs to cloud storage (retry-safe, won't crash on DNS failure)
    if cloud_bucket:
        run_id = os.environ.get("CIV_MCP_RUN_ID")
        _upload_eval_logs(local_log_dir, cloud_bucket.rstrip("/"), run_id)

    return result.returncode


def main():
    parser = argparse.ArgumentParser(
        description="Run CivBench scenarios across models."
    )
    group = parser.add_mutually_exclusive_group()
    group.add_argument(
        "--model",
        help="Single model to evaluate (e.g. openai/azure/gpt-5.2)",
    )
    group.add_argument(
        "--models",
        help="Comma-separated list of models to evaluate",
    )
    group.add_argument(
        "--all",
        action="store_true",
        help="Run all default models",
    )
    parser.add_argument(
        "--scenarios",
        default=None,
        help="Comma-separated scenario IDs (default: all)",
    )
    parser.add_argument(
        "--track",
        default="civbench_standard",
        choices=["civbench_standard", "civbench_open"],
        help="Evaluation track (default: civbench_standard)",
    )
    parser.add_argument(
        "--message-limit",
        type=int,
        default=None,
        help="Override message limit (useful for test runs)",
    )
    parser.add_argument(
        "--resume-save",
        default=None,
        help="Resume from an autosave (e.g. 0_MCP_0221)",
    )
    parser.add_argument(
        "--runs",
        type=int,
        default=1,
        help="Number of runs per (model, scenario) pair (default: 1)",
    )
    parser.add_argument(
        "--list-models",
        action="store_true",
        help="Print available models and exit",
    )
    args, extra = parser.parse_known_args()

    if args.list_models:
        print("Azure OpenAI:")
        for m in AZURE_MODELS:
            print(f"  {m}")
        print("\nGCP Vertex AI:")
        for m in VERTEX_MODELS:
            print(f"  {m}")
        return

    # Resolve models
    if args.all:
        models = ALL_MODELS
    elif args.models:
        models = [m.strip() for m in args.models.split(",")]
    elif args.model:
        models = [args.model]
    else:
        parser.error("Provide --model, --models, or --all")
        return

    # Resolve scenarios
    scenarios = (
        [s.strip() for s in args.scenarios.split(",")]
        if args.scenarios
        else ALL_SCENARIOS
    )

    if args.resume_save and len(scenarios) > 1:
        parser.error("--resume-save requires exactly one scenario (use --scenarios)")
        return

    # Pre-flight: ensure game is running before first scenario
    ensure_game_ready()

    # Run
    runs = args.runs
    results: list[tuple[str, str, int, int]] = []
    total = len(models) * len(scenarios) * runs
    current = 0

    for model in models:
        for scenario in scenarios:
            for run_num in range(1, runs + 1):
                current += 1
                run_label = f" (run {run_num}/{runs})" if runs > 1 else ""
                print(
                    f"\n[{current}/{total}] Running {scenario} with {model}{run_label}"
                )
                rc = run_scenario(
                    model=model,
                    scenario=scenario,
                    track=args.track,
                    message_limit=args.message_limit,
                    resume_save=args.resume_save,
                    extra_args=extra if extra else None,
                )

                # Auto-resume on crash: find latest autosave and retry once.
                # Safe from infinite loops — this block runs at most once per
                # iteration because the resumed run_scenario is not recursive.
                if rc != 0:
                    latest = _find_latest_autosave()
                    if latest:
                        print(f"  CRASH (exit {rc}) — auto-resuming from {latest}")
                        ensure_game_ready()
                        rc = run_scenario(
                            model=model,
                            scenario=scenario,
                            track=args.track,
                            message_limit=args.message_limit,
                            resume_save=latest,
                            extra_args=extra if extra else None,
                        )

                results.append((model, scenario, rc, run_num))
                if rc != 0:
                    print(f"  WARNING: {scenario} exited with code {rc}")

    # Summary
    print(f"\n{'=' * 60}")
    print("  RESULTS SUMMARY")
    print(f"{'=' * 60}")
    for model, scenario, rc, *_ in results:
        status = "OK" if rc == 0 else f"FAIL (exit {rc})"
        print(f"  {model:45s} | {scenario:20s} | {status}")
    print()

    # Exit with non-zero if any scenario failed
    failures = sum(1 for *_, rc, _ in results if rc != 0)
    if failures:
        print(f"{failures}/{total} scenario(s) failed.")
        sys.exit(1)


if __name__ == "__main__":
    main()
