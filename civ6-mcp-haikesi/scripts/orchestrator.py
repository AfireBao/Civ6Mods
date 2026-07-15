#!/usr/bin/env python3
"""CivBench Orchestrator — dispatch, monitor, and manage benchmark runs.

Usage:
    python scripts/orchestrator.py launch --config benchmark.yaml
    python scripts/orchestrator.py launch --scenarios S --models M --runs N --machines M1,M2
    python scripts/orchestrator.py resume
    python scripts/orchestrator.py preflight [--machines M1,M2]
    python scripts/orchestrator.py status
    python scripts/orchestrator.py kill-all
    python scripts/orchestrator.py sync [--machines M1,M2]
    python scripts/orchestrator.py summary
    python scripts/orchestrator.py logs --machine M [--last N] [--errors]

Config: ~/.civbench/machines.yaml + ~/.civbench/benchmark.yaml
State:  ~/.civbench/state.json
"""

from __future__ import annotations

import argparse
import logging
import sys
import time
from collections import defaultdict
from pathlib import Path

from orchestrator.config import CONFIG_DIR, build_config
from orchestrator.dispatch import build_machines, run_batch
from orchestrator.eta import estimate_eta
from orchestrator.machine import Machine
from orchestrator.state import BatchState

log = logging.getLogger("orchestrator")

REPO_ROOT = Path(__file__).resolve().parent.parent

# Feature markers checked by preflight and launch. Each tuple is
# (module_path, attribute). A launch is aborted if any marker is missing on
# a target machine, even if the git commit hash matches — this catches the
# class of bug where a machine is "on latest main" but main itself doesn't
# contain the fix you expected to deploy (uncommitted local work).
#
# One marker per feature area is enough: if `_check_save_scumming` imports
# from civ_mcp.end_turn, the adjacent scumming/budget infrastructure in the
# same PR must also be present. Keep the list small so preflight stays fast.
FEATURE_MARKERS: list[tuple[str, str]] = [
    ("civ_mcp.end_turn", "_check_save_scumming"),
]


# ---------------------------------------------------------------------------
# Legacy commands (preflight, status, kill-all, sync, summary, logs)
# These operate directly on Machine objects without the dispatch loop.
# ---------------------------------------------------------------------------


def cmd_preflight(
    machines: dict[str, Machine], machine_names: list[str] | None
) -> bool:
    """Validate all machines are ready."""
    targets = {
        n: machines[n] for n in (machine_names or machines.keys()) if n in machines
    }
    all_ok = True

    for name, m in targets.items():
        print(f"\n  {name} ({m.os}, {m.ssh_target})")
        print(f"  {'─' * 40}")

        if not m.is_reachable():
            print("    ✗ OFFLINE")
            all_ok = False
            continue
        print("    ✓ Reachable")

        version = m.get_version()
        print(f"    {'✓' if version != 'UNKNOWN' else '✗'} Version: {version}")
        if version == "UNKNOWN":
            all_ok = False

        # Feature markers — verify expected code is actually importable on
        # the remote Python, not just that the git hash matches.
        feat_ok, feat_msg = m.verify_features(FEATURE_MARKERS)
        print(f"    {'✓' if feat_ok else '✗'} Features: {feat_msg}")
        if not feat_ok:
            all_ok = False

        # Sync watcher — informational only (not blocking). Launch will
        # start the watcher if it's missing.
        watcher_running = m.is_sync_watcher_running()
        print(
            f"    {'✓' if watcher_running else '○'} Sync watcher: "
            f"{'running' if watcher_running else 'stopped (will start at launch)'}"
        )

        # Package sync
        if m.os == "windows":
            rc, sync_out = m.ssh(
                f"cd /d {m.repo} && uv sync --extra evals --extra cloud "
                f"--extra launcher-windows --dry-run 2>&1",
                timeout=30,
            )
        else:
            rc, sync_out = m.ssh(
                f"cd {m.repo} && uv sync --extra evals --extra cloud "
                f"--extra launcher-linux --dry-run 2>&1",
                timeout=30,
            )
        needs_install = "install" in sync_out.lower() or "uninstall" in sync_out.lower()
        if not needs_install:
            print("    ✓ Packages: in sync")
        else:
            changes = [
                line.strip()
                for line in sync_out.splitlines()
                if line.strip().startswith(("+", "-", "~"))
            ]
            print(f"    ✗ Packages: {len(changes)} change(s) pending — run uv sync")
            all_ok = False

        game = m.is_game_running()
        print(
            f"    {'●' if game else '○'} Civ VI: {'running' if game else 'not running'}"
        )

        # Steam (Linux only)
        if m.os == "linux":
            rc, out = m.ssh("pgrep -x steam >/dev/null 2>&1 && echo YES || echo NO")
            steam_ok = "YES" in out
            print(
                f"    {'✓' if steam_ok else '✗'} Steam: {'running' if steam_ok else 'NOT RUNNING'}"
            )
            if not steam_ok:
                all_ok = False

        # Stale processes
        if not game:
            if m.os == "windows":
                import base64

                ps = "(Get-Process python,'civ-mcp' -EA Silent | Measure).Count"
                encoded = base64.b64encode(ps.encode("utf-16-le")).decode("ascii")
                rc, out = m.ssh(f"powershell -EncodedCommand {encoded}", timeout=15)
            else:
                rc, out = m.ssh("pgrep -c 'Civ6|Civ6Sub|civ-mcp' 2>/dev/null || echo 0")
            last_word = out.strip().split()[-1] if out.strip() else "0"
            count = int(last_word) if last_word.isdigit() else 0
            if count > 0:
                print(f"    ✗ Stale processes: {count} orphan(s)")
                all_ok = False
            else:
                print("    ✓ No stale processes")

        # Telemetry
        if m.os == "windows":
            rc, out = m.ssh(
                'powershell -Command "(Get-ChildItem $env:USERPROFILE\\.civ6-mcp -File -EA Silent | Measure).Count"',
                timeout=10,
            )
        else:
            rc, out = m.ssh("ls ~/.civ6-mcp/ 2>/dev/null | wc -l")
        file_count = int(out.strip()) if out.strip().isdigit() else 0
        if file_count == 0:
            print("    ✓ Telemetry: clean")
        else:
            print(
                f"    ! Telemetry: {file_count} stale file(s) — will be cleared at launch"
            )

        # Saves
        if m.os == "windows":
            rc, out = m.ssh(
                f"dir {m.repo}\\evals\\saves\\0A_GROUND_CONTROL.Civ6Save 2>nul && echo FOUND || echo MISSING"
            )
        else:
            rc, out = m.ssh(
                f"test -f {m.repo}/evals/saves/0A_GROUND_CONTROL.Civ6Save && echo FOUND || echo MISSING"
            )
        has_saves = "FOUND" in out
        print(
            f"    {'✓' if has_saves else '✗'} Saves: {'present' if has_saves else 'MISSING'}"
        )
        if not has_saves:
            all_ok = False

        # API credentials
        if m.os == "windows":
            rc, out = m.ssh(
                f'cd /d {m.repo} && findstr "AZURE_OPENAI_API_KEY" evals\\.env >nul 2>nul '
                f"&& echo CREDS_OK || echo CREDS_MISSING"
            )
        else:
            rc, out = m.ssh(
                f"cd {m.repo} && grep -q AZURE_OPENAI_API_KEY evals/.env 2>/dev/null "
                f"&& echo CREDS_OK || echo CREDS_MISSING"
            )
        creds_ok = "CREDS_OK" in out
        print(
            f"    {'✓' if creds_ok else '✗'} API credentials: {'present' if creds_ok else 'MISSING'}"
        )
        if not creds_ok:
            all_ok = False

    print()
    return all_ok


def _find_state_for_job(job_id: str) -> BatchState | None:
    """Search all state files for a job ID."""
    for p in CONFIG_DIR.glob("state_*.json"):
        state = BatchState.load(p)
        if job_id in state.jobs:
            return state
    # Also check legacy state.json
    state = BatchState.load()
    if job_id in state.jobs:
        return state
    return None


def _load_all_states() -> BatchState:
    """Load and merge all state files into one view.

    Per-machine files take precedence over legacy state.json.
    """
    merged = BatchState()
    # Legacy first (lowest priority)
    legacy = BatchState.load()
    merged.jobs.update(legacy.jobs)
    # Per-machine files overwrite legacy on collision
    for p in CONFIG_DIR.glob("state_*.json"):
        state = BatchState.load(p)
        merged.jobs.update(state.jobs)
    return merged


def cmd_status(machines: dict[str, Machine]) -> None:
    """Show fleet status dashboard."""
    state = _load_all_states()

    print("\n╔═══════════════════════════════════════════════════╗")
    print(f"║  CivBench Orchestrator     {time.strftime('%H:%M %b %d %Y')}  ║")
    print("╚═══════════════════════════════════════════════════╝")

    print("\nFleet")
    print(f"  {'─' * 50}")
    for name, m in machines.items():
        if not m.is_reachable():
            print(f"  {name:<12} OFFLINE")
            continue
        version = m.get_version()
        game = m.is_game_running()
        hb = m.read_heartbeat()
        phase = hb.get("phase", "") if hb else ""
        try:
            turn = int(hb.get("turn", 0)) if hb else 0
        except (ValueError, TypeError):
            turn = 0
        print(
            f"  {name:<12} {version:<20} {'CIV' if game else '   '} {phase:<10} T{turn}"
        )

    if state.jobs:
        counts = state.summary()
        print(f"\nJobs: {counts}")
        active = [j for j in state.jobs.values() if j.state in ("booting", "running")]
        if active:
            print("\nActive Jobs")
            print(f"  {'─' * 60}")
            for j in active:
                elapsed_h = (time.time() - j.started_at) / 3600 if j.started_at else 0
                short = j.model.rsplit("/", 1)[-1]
                rate_str = ""
                eta_str = ""
                if j.turn > 5 and elapsed_h > 0.01:
                    rate_str = f"{elapsed_h * 60 / j.turn:.1f}m/t"
                    est = estimate_eta(j.model, j.turn, elapsed_h)
                    eta_str = f"~{est['eta_h']}h [{est['lo_h']}-{est['hi_h']}h]"
                print(
                    f"  {j.machine:<10} {short:<18} T{j.turn:>3}  "
                    f"{elapsed_h:.1f}h  {rate_str:>7}  {eta_str:>10}  {j.run_id or ''}"
                )
    print()


# Job states that represent "this job needs a watcher on its machine".
# Includes `completing` (final diary writes still draining) and
# `needs_attention` (can be retried without relaunch — watcher must be up).
ACTIVE_JOB_STATES = {
    "pending",
    "launching",
    "booting",
    "running",
    "completing",
    "needs_attention",
}


def _ensure_watchers(targets: dict[str, Machine]) -> None:
    """Start sync watchers on every target machine that needs one.

    Called by both launch and resume paths so a machine that lost its
    watcher (e.g. kill-all then resume, or REHOBOAM reboot) gets it back.
    Non-blocking: logs a warning on failure but doesn't abort.
    """
    log.info("Ensuring sync watchers are running...")
    for name, m in targets.items():
        if m.is_sync_watcher_running():
            log.info("  %s: watcher already running", name)
        else:
            ok = m.start_sync_watcher()
            log.info(
                "  %s: %s",
                name,
                "watcher started" if ok else "WATCHER FAILED TO START (continuing)",
            )


def cmd_kill_all(machines: dict[str, Machine]) -> None:
    for name, m in machines.items():
        print(f"  Killing {name}... ", end="", flush=True)
        if not m.is_reachable():
            print("OFFLINE")
            continue
        m.kill_runner()
        m.kill_game()
        m.stop_sync_watcher()
        print("done")

    # Mark all active jobs as failed across all state files
    for p in CONFIG_DIR.glob("state_*.json"):
        state = BatchState.load(p)
        changed = False
        for j in state.jobs.values():
            if j.state in (
                "launching",
                "booting",
                "running",
                "completing",
                "needs_attention",
            ):
                j.transition("failed", "killed by operator")
                changed = True
        if changed:
            state.save()
    # Also check legacy
    state = BatchState.load()
    for j in state.jobs.values():
        if j.state in (
            "launching",
            "booting",
            "running",
            "completing",
            "needs_attention",
        ):
            j.transition("failed", "killed by operator")
    state.save()
    print("  All active jobs marked as failed.")


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def main() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)s %(message)s",
        datefmt="%H:%M:%S",
    )
    CONFIG_DIR.mkdir(parents=True, exist_ok=True)
    fh = logging.FileHandler(CONFIG_DIR / "orchestrator.log")
    fh.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
    logging.getLogger("orchestrator").addHandler(fh)

    parser = argparse.ArgumentParser(description="CivBench Orchestrator v2")
    sub = parser.add_subparsers(dest="command")

    # preflight
    p_pre = sub.add_parser("preflight", help="Validate machines are ready")
    p_pre.add_argument("--machines", help="Comma-separated machine names")

    # launch
    p_launch = sub.add_parser("launch", help="Launch benchmark runs")
    p_launch.add_argument("--config", help="Path to benchmark.yaml")
    p_launch.add_argument("--scenarios", help="Comma-separated scenario IDs")
    p_launch.add_argument("--models", help="Comma-separated model aliases or full IDs")
    p_launch.add_argument(
        "--runs", type=int, default=3, help="Runs per (model, scenario)"
    )
    p_launch.add_argument("--machines", help="Comma-separated machine names")
    p_launch.add_argument(
        "--allow-dirty",
        action="store_true",
        help="Permit launch with uncommitted local changes (default: refuse)",
    )
    p_launch.add_argument(
        "--skip-feature-check",
        action="store_true",
        help="Skip the preflight feature-marker verification (NOT RECOMMENDED)",
    )

    # resume
    sub.add_parser("resume", help="Resume from saved state")

    # status
    sub.add_parser("status", help="Show fleet status + active job details")

    # kill-all
    sub.add_parser("kill-all", help="Kill all runners and games")

    # sync
    p_sync = sub.add_parser("sync", help="Sync telemetry to Convex")
    p_sync.add_argument(
        "--machines", help="Comma-separated machine names (default: all)"
    )

    # summary
    sub.add_parser("summary", help="Aggregate results by model and scenario")

    # retry — recover a stalled job
    p_retry = sub.add_parser(
        "retry", help="Kill and retry a needs_attention or failed job"
    )
    p_retry.add_argument("job_id", help="Job ID to retry")

    # abandon — give up on a stalled job
    p_abandon = sub.add_parser("abandon", help="Mark a needs_attention job as failed")
    p_abandon.add_argument("job_id", help="Job ID to abandon")

    # logs
    p_logs = sub.add_parser("logs", help="Tail remote runner logs")
    p_logs.add_argument("--machine", required=True)
    p_logs.add_argument("--last", type=int, default=30)
    p_logs.add_argument("--errors", action="store_true")

    args = parser.parse_args()
    if not args.command:
        parser.print_help()
        return

    # Build config
    config = build_config(
        benchmark_path=Path(args.config)
        if hasattr(args, "config") and args.config
        else None,
        cli_models=[m.strip() for m in args.models.split(",")]
        if hasattr(args, "models") and args.models
        else None,
        cli_machines=[m.strip() for m in args.machines.split(",")]
        if hasattr(args, "machines") and args.machines
        else None,
        cli_runs=args.runs if hasattr(args, "runs") else None,
        cli_scenarios=[s.strip() for s in args.scenarios.split(",")]
        if hasattr(args, "scenarios") and args.scenarios
        else None,
    )
    machines = build_machines(config)

    if args.command == "preflight":
        names = args.machines.split(",") if args.machines else None
        ok = cmd_preflight(machines, names)
        sys.exit(0 if ok else 1)

    elif args.command == "status":
        cmd_status(machines)

    elif args.command == "kill-all":
        cmd_kill_all(machines)

    elif args.command == "launch":
        if not config.jobs:
            print(
                "Error: no jobs configured. Use --config or --models + --machines.",
                file=sys.stderr,
            )
            sys.exit(1)

        # Discipline gate 1: local working tree must be clean.
        import subprocess

        result = subprocess.run(
            ["git", "-C", str(REPO_ROOT), "status", "--porcelain"],
            capture_output=True,
            text=True,
        )
        dirty = result.stdout.strip()
        if dirty and not args.allow_dirty:
            log.error(
                "LOCAL WORKING TREE IS DIRTY — uncommitted changes will NOT "
                "be deployed to the fleet:"
            )
            for line in dirty.splitlines():
                log.error("  %s", line)
            log.error(
                "Untracked files (??) are also blocked — `git add` or move "
                "them out of the repo."
            )
            log.error("Commit and push first, or pass --allow-dirty to proceed anyway.")
            sys.exit(1)
        if dirty and args.allow_dirty:
            log.warning("Launching with dirty working tree (--allow-dirty)")

        # Discipline gate 2: feature markers must be present on every target.
        # This catches the "deployed to right commit but missing uncommitted
        # fix" failure mode.
        target_names = {job.machine for job in config.jobs}
        targets = {n: machines[n] for n in target_names if n in machines}

        if not args.skip_feature_check:
            log.info("Verifying feature markers on all target machines...")
            for name, m in targets.items():
                ok, msg = m.verify_features(FEATURE_MARKERS)
                if ok:
                    log.info("  %s: %s", name, msg)
                else:
                    log.error("  %s: FAILED — %s", name, msg)
                    log.error(
                        "Aborting launch. Pull latest on %s or pass "
                        "--skip-feature-check (NOT RECOMMENDED).",
                        name,
                    )
                    sys.exit(1)

        # Ensure sync watchers are running on all target machines so live
        # game state streams to Convex in real time.
        _ensure_watchers(targets)

        run_batch(config)

    elif args.command == "resume":
        # Derive state path from machine config
        machine_names = {m for m in config.machines}
        state_path = BatchState.path_for_machines(machine_names)
        state = BatchState.load(state_path)
        if not state.jobs:
            print("No saved state to resume.")
            return
        # Validate machine references and re-activate in-flight jobs
        for j in state.jobs.values():
            if j.state not in ("done", "failed") and j.machine not in config.machines:
                log.error("Job %s references unknown machine '%s'", j.id, j.machine)
                j.transition("failed", f"machine '{j.machine}' not in config")
                continue
            if j.state in ("launching", "booting", "running"):
                log.info("Resuming %s from state %s at T%d", j.id, j.state, j.turn)
        pending = sum(1 for j in state.jobs.values() if j.state == "pending")
        active = sum(
            1
            for j in state.jobs.values()
            if j.state in ("launching", "booting", "running")
        )
        done = sum(1 for j in state.jobs.values() if j.state == "done")
        failed = sum(1 for j in state.jobs.values() if j.state == "failed")
        print(
            f"Resuming: {active} active, {pending} pending, {done} done, {failed} failed"
        )

        # Ensure watchers on all machines that still have active jobs.
        # `completing` is included so final diary writes still drain to
        # Convex; `needs_attention` is included so retried jobs have a live
        # watcher waiting.
        resume_targets = {
            j.machine for j in state.jobs.values() if j.state in ACTIVE_JOB_STATES
        }
        targets = {n: machines[n] for n in resume_targets if n in machines}
        _ensure_watchers(targets)

        run_batch(config, state=state)

    elif args.command == "retry":
        state = _find_state_for_job(args.job_id)
        if state is None:
            print(f"Unknown job: {args.job_id} (not found in any state file)")
            sys.exit(1)
        job = state.jobs[args.job_id]
        if job.state not in ("needs_attention", "failed"):
            print(
                f"Job {args.job_id} is in state '{job.state}' — can only retry needs_attention or failed"
            )
            sys.exit(1)
        m = machines.get(job.machine)
        if m and m.is_reachable():
            print(f"  Killing processes on {job.machine}...")
            m.kill_runner()
            m.kill_game()
            m.clear_heartbeat()
        job.turn = 0
        job.transition("pending", "retried by operator")
        state.save()
        print(f"  {args.job_id} → pending (will dispatch on next orchestrator poll)")
        return

    elif args.command == "abandon":
        state = _find_state_for_job(args.job_id)
        if state is None:
            print(f"Unknown job: {args.job_id} (not found in any state file)")
            sys.exit(1)
        job = state.jobs[args.job_id]
        if job.state != "needs_attention":
            print(
                f"Job {args.job_id} is in state '{job.state}' — can only abandon needs_attention"
            )
            sys.exit(1)
        m = machines.get(job.machine)
        if m and m.is_reachable():
            print(f"  Killing processes on {job.machine}...")
            m.kill_runner()
            m.kill_game()
            m.clear_heartbeat()
        job.transition("failed", "abandoned by operator")
        state.save()
        print(f"  {args.job_id} → failed")
        return

    elif args.command == "sync":
        names = (
            [n.strip() for n in args.machines.split(",")]
            if args.machines
            else list(machines.keys())
        )
        for name in names:
            if name not in machines:
                log.warning("Unknown machine: %s", name)
                continue
            m = machines[name]
            print(f"  Syncing {name}... ", end="", flush=True)
            if not m.is_reachable():
                print("OFFLINE")
                continue
            print("OK" if m.sync_to_convex() else "FAILED")

    elif args.command == "summary":
        state = _load_all_states()
        if not state.jobs:
            print("No jobs in state.")
        else:
            by_scenario: dict[str, dict[str, list]] = defaultdict(
                lambda: defaultdict(list)
            )
            for j in state.jobs.values():
                short = j.model.rsplit("/", 1)[-1]
                by_scenario[j.scenario][short].append(j)
            for scenario, models_dict in sorted(by_scenario.items()):
                total = sum(len(jl) for jl in models_dict.values())
                done = sum(
                    1 for jl in models_dict.values() for j in jl if j.state == "done"
                )
                print(f"\n{scenario} ({done}/{total} done)")
                print(f"  {'─' * 55}")
                for model, jlist in sorted(models_dict.items()):
                    n = len(jlist)
                    d = sum(1 for j in jlist if j.state == "done")
                    turns = [j.turn for j in jlist if j.state == "done"]
                    avg_t = f"avg T{sum(turns) // len(turns)}" if turns else ""
                    rids = [j.run_id or "?" for j in jlist if j.state == "done"]
                    print(f"  {model:<22} {d}/{n}  {avg_t:>8}  {' '.join(rids)}")
            print()

    elif args.command == "logs":
        m = machines.get(args.machine)
        if not m:
            print(f"Unknown machine: {args.machine}", file=sys.stderr)
            sys.exit(1)
        output = m.tail_log(args.last)
        if args.errors:
            output = "\n".join(
                line
                for line in output.split("\n")
                if any(
                    kw in line.lower()
                    for kw in ("error", "warning", "fail", "traceback", "exception")
                )
            )
        print(output)


if __name__ == "__main__":
    main()
