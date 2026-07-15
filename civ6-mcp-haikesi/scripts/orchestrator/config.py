"""Configuration loading — machines.yaml + benchmark.yaml."""

from __future__ import annotations

import sys
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import yaml

CONFIG_DIR = Path.home() / ".civbench"
MACHINES_PATH = CONFIG_DIR / "machines.yaml"
BENCHMARK_PATH = CONFIG_DIR / "benchmark.yaml"
STATE_PATH = CONFIG_DIR / "state.json"


@dataclass
class MachineConfig:
    name: str
    ssh_target: str
    os: str  # "windows" | "linux" | "macos"
    repo: str
    display_env: dict[str, str] = field(default_factory=dict)


@dataclass
class JobSpec:
    """A single job in the benchmark matrix."""

    machine: str
    model: str  # full inspect model ID
    scenario: str
    runs: int = 3


@dataclass
class Defaults:
    ssh_timeout: int = 20
    poll_interval: int = 30
    stall_alert_minutes: int = 30
    stall_kill_minutes: int = 60
    max_boot_retries: int = 3
    max_game_retries: int = 2
    boot_timeout: int = 600
    playing_timeout: int = 600
    alert_webhook: str = ""


@dataclass
class Config:
    machines: dict[str, MachineConfig]
    model_aliases: dict[str, str]
    defaults: Defaults
    jobs: list[JobSpec] = field(default_factory=list)
    scenario: str = "ground_control"


def load_machines_config() -> dict[str, Any]:
    """Load raw machines.yaml."""
    if not MACHINES_PATH.exists():
        print(f"Error: {MACHINES_PATH} not found", file=sys.stderr)
        sys.exit(1)
    with open(MACHINES_PATH) as f:
        return yaml.safe_load(f)


def load_benchmark_config(path: Path | None = None) -> dict[str, Any] | None:
    """Load benchmark.yaml (optional)."""
    p = path or BENCHMARK_PATH
    if not p.exists():
        return None
    with open(p) as f:
        return yaml.safe_load(f)


def resolve_model(alias: str, aliases: dict[str, str]) -> str:
    """Resolve a model alias to a full inspect model ID."""
    return aliases.get(alias, alias)


def build_config(
    benchmark_path: Path | None = None,
    cli_models: list[str] | None = None,
    cli_machines: list[str] | None = None,
    cli_runs: int | None = None,
    cli_scenarios: list[str] | None = None,
) -> Config:
    """Build unified config from machines.yaml + benchmark.yaml + CLI overrides."""
    raw = load_machines_config()

    # Parse machines
    machines: dict[str, MachineConfig] = {}
    for name, mdef in raw.get("machines", {}).items():
        machines[name] = MachineConfig(
            name=name,
            ssh_target=mdef["ssh"],
            os=mdef["os"],
            repo=mdef["repo"],
            display_env=mdef.get("display_env", {}),
        )

    aliases = raw.get("model_aliases", {})

    # Parse defaults
    raw_defaults = raw.get("defaults", {})
    defaults = Defaults(
        ssh_timeout=raw_defaults.get("ssh_timeout", 20),
        poll_interval=raw_defaults.get("poll_interval", 30),
        stall_alert_minutes=raw_defaults.get("stall_alert_minutes", 30),
        stall_kill_minutes=raw_defaults.get("stall_kill_minutes", 60),
        max_boot_retries=raw_defaults.get(
            "max_boot_retries", raw_defaults.get("max_retries", 3)
        ),
        max_game_retries=raw_defaults.get(
            "max_game_retries", raw_defaults.get("max_retries", 2)
        ),
        boot_timeout=raw_defaults.get("boot_timeout", 600),
        playing_timeout=raw_defaults.get("playing_timeout", 600),
        alert_webhook=raw_defaults.get("alert_webhook", ""),
    )

    # Build job matrix
    jobs: list[JobSpec] = []
    scenario = "ground_control"

    # Try benchmark.yaml first
    bench = load_benchmark_config(benchmark_path)
    if bench:
        scenario = bench.get("scenario", scenario)
        bench_defaults = bench.get("defaults", {})
        for k, v in bench_defaults.items():
            if hasattr(defaults, k):
                setattr(defaults, k, v)
        for jdef in bench.get("jobs", []):
            model = resolve_model(jdef["model"], aliases)
            jobs.append(
                JobSpec(
                    machine=jdef["machine"],
                    model=model,
                    scenario=jdef.get("scenario", scenario),
                    runs=jdef.get("runs", 3),
                )
            )

    # CLI overrides (generate job matrix from --models --machines --runs)
    if cli_models and cli_machines:
        jobs = []
        scenarios = cli_scenarios or [scenario]
        runs = cli_runs or 3
        for s in scenarios:
            for i, model_alias in enumerate(cli_models):
                model = resolve_model(model_alias, aliases)
                machine_name = cli_machines[i % len(cli_machines)]
                jobs.append(
                    JobSpec(
                        machine=machine_name,
                        model=model,
                        scenario=s,
                        runs=runs,
                    )
                )
        if cli_scenarios:
            scenario = cli_scenarios[0]

    return Config(
        machines=machines,
        model_aliases=aliases,
        defaults=defaults,
        jobs=jobs,
        scenario=scenario,
    )
