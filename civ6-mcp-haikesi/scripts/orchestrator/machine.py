"""Machine abstraction — SSH-based remote management."""

from __future__ import annotations

import base64
import json
import logging
import subprocess
from dataclasses import dataclass

from .config import MachineConfig

log = logging.getLogger("orchestrator")


@dataclass
class Machine:
    """Remote machine wrapper with SSH-based operations."""

    config: MachineConfig
    ssh_timeout: int = 20

    @property
    def name(self) -> str:
        return self.config.name

    @property
    def os(self) -> str:
        return self.config.os

    @property
    def ssh_target(self) -> str:
        return self.config.ssh_target

    @property
    def repo(self) -> str:
        return self.config.repo

    # ── SSH primitives ──────────────────────────────────────────

    def ssh(self, cmd: str, timeout: int | None = None) -> tuple[int, str]:
        t = timeout or self.ssh_timeout
        try:
            r = subprocess.run(
                [
                    "ssh",
                    "-o",
                    f"ConnectTimeout={t}",
                    "-o",
                    "BatchMode=yes",
                    self.ssh_target,
                    cmd,
                ],
                capture_output=True,
                text=True,
                timeout=t + 10,
            )
            return r.returncode, r.stdout.strip()
        except subprocess.TimeoutExpired:
            return -1, "SSH_TIMEOUT"
        except Exception as e:
            return -1, str(e)

    # ── Health checks ───────────────────────────────────────────

    def is_reachable(self) -> bool:
        rc, _ = self.ssh("echo ok", timeout=10)
        return rc == 0

    def get_version(self) -> str:
        if self.os == "windows":
            cmd = f"cd /d {self.repo} && git describe --tags --always 2>nul"
        else:
            cmd = f"cd {self.repo} && git describe --tags --always"
        rc, out = self.ssh(cmd)
        return out if rc == 0 else "UNKNOWN"

    def verify_packages(self) -> tuple[bool, str]:
        """Check that inspect CLI and key packages are installed."""
        if self.os == "windows":
            cmd = f"cd /d {self.repo} && .venv\\Scripts\\inspect.exe --version 2>nul"
        else:
            cmd = f"cd {self.repo} && .venv/bin/inspect --version 2>/dev/null"
        rc, out = self.ssh(cmd, timeout=15)
        if rc != 0:
            return False, "inspect CLI not found"
        return True, out.strip()

    def verify_features(self, markers: list[tuple[str, str]]) -> tuple[bool, str]:
        """Verify each (module, attribute) exists on the remote Python.

        Prevents deploying to a machine whose code doesn't contain an
        expected feature — catches the class of bug where a commit is
        "latest main" but main is missing an uncommitted local fix.

        Markers are passed as (module_path, attribute_name) tuples, e.g.
        ("civ_mcp.end_turn", "_check_save_scumming").
        """
        # Reject markers with shell metacharacters — the Python one-liner is
        # embedded in a double-quoted string inside an SSH command, and any
        # &|<>^"\' in the identifier would break the shell parsing silently.
        unsafe = set("^&|<>\"'`$;()")
        for module, attr in markers:
            combined = module + attr
            if any(c in combined for c in unsafe):
                return False, f"unsafe marker chars in {module}.{attr}"

        # Build a one-liner that imports each module and checks for the attr
        imports = []
        checks = []
        for i, (module, attr) in enumerate(markers):
            imports.append(f"import {module} as m{i}")
            checks.append(f"assert hasattr(m{i}, {attr!r}), {module + '.' + attr!r}")
        py = "; ".join(imports + checks)
        if self.os == "windows":
            cmd = f'cd /d {self.repo} && .venv\\Scripts\\python.exe -c "{py}" 2>&1'
        else:
            cmd = f'cd {self.repo} && .venv/bin/python -c "{py}" 2>&1'
        rc, out = self.ssh(cmd, timeout=20)
        if rc != 0:
            stripped = out.strip()
            msg = stripped.splitlines()[-1] if stripped else "import failed"
            return False, msg
        return True, f"{len(markers)} markers present"

    def sync_packages(self) -> bool:
        """Run uv sync with all required extras for this machine."""
        launcher = f"launcher-{self.os}"
        extras = f"--extra evals --extra {launcher} --extra cloud"
        if self.os == "windows":
            cmd = f"cd /d {self.repo} && uv sync {extras} 2>&1"
        else:
            cmd = f"cd {self.repo} && uv sync {extras} 2>&1"
        rc, out = self.ssh(cmd, timeout=120)
        if rc != 0:
            log.warning("uv sync failed on %s: %s", self.name, out[:200])
        return rc == 0

    def clear_heartbeat(self) -> None:
        """Remove stale heartbeat file before launching a new runner."""
        if self.os == "windows":
            # CMD `del` cannot handle dot-prefixed directories — use PowerShell
            self.ssh(
                'powershell -Command "Remove-Item $env:USERPROFILE\\.civ6-mcp\\heartbeat.json '
                '-Force -ErrorAction SilentlyContinue"',
                timeout=5,
            )
        else:
            self.ssh("rm -f ~/.civ6-mcp/heartbeat.json", timeout=5)

    def is_game_running(self) -> bool:
        if self.os == "windows":
            rc, out = self.ssh(
                'tasklist /FI "IMAGENAME eq CivilizationVI_DX12.exe" /NH 2>nul '
                "| findstr /I Civ >nul && echo YES || echo NO"
            )
        else:
            # Match either Civ6 (current Aspyr builds) or Civ6Sub (legacy).
            rc, out = self.ssh(
                "(pgrep -x Civ6 >/dev/null 2>&1 || pgrep -x Civ6Sub >/dev/null 2>&1) "
                "&& echo YES || echo NO"
            )
        return "YES" in out

    def read_heartbeat(self) -> dict | None:
        if self.os == "windows":
            cmd = "type %USERPROFILE%\\.civ6-mcp\\heartbeat.json 2>nul"
        else:
            cmd = "cat ~/.civ6-mcp/heartbeat.json 2>/dev/null"
        rc, out = self.ssh(cmd, timeout=10)
        if rc != 0 or not out.strip():
            return None
        try:
            return json.loads(out.strip())
        except json.JSONDecodeError:
            return None

    def check_completed(self) -> bool:
        if self.os == "windows":
            rc, out = self.ssh(
                "if exist %USERPROFILE%\\civbench_done (echo YES) else (echo NO)",
                timeout=10,
            )
        else:
            rc, out = self.ssh(
                "test -f ~/civbench_done && echo YES || echo NO", timeout=10
            )
        return "YES" in out

    def get_latest_turn(self) -> int | None:
        if self.os == "windows":
            cmd = (
                'powershell -Command "'
                "$f = Get-ChildItem $env:USERPROFILE\\.civ6-mcp\\diary_*.jsonl "
                "-Exclude '*cities*' -ErrorAction SilentlyContinue "
                "| Sort-Object LastWriteTime -Descending | Select-Object -First 1; "
                "if ($f) { (Get-Content $f.FullName -Tail 1 | ConvertFrom-Json).turn }"
                '"'
            )
        else:
            cmd = (
                "ls -t ~/.civ6-mcp/diary_*.jsonl 2>/dev/null | grep -v cities | head -1 "
                "| xargs -I{} tail -1 {} 2>/dev/null "
                '| python3 -c \'import sys,json; print(json.load(sys.stdin).get("turn",""))\' 2>/dev/null'
            )
        rc, out = self.ssh(cmd, timeout=15)
        try:
            return int(out.strip()) if out.strip().isdigit() else None
        except (ValueError, AttributeError):
            return None

    # ── Operations ──────────────────────────────────────────────

    def kill_game(self) -> None:
        if self.os == "windows":
            ps = (
                "Get-Process | Where-Object { $_.ProcessName -match 'CivilizationVI' } "
                "| Stop-Process -Force -ErrorAction SilentlyContinue"
            )
            encoded = base64.b64encode(ps.encode("utf-16-le")).decode("ascii")
            self.ssh(f"powershell -EncodedCommand {encoded}", timeout=15)
        else:
            self.ssh("killall -9 Civ6Sub Civ6 2>/dev/null", timeout=10)

    def kill_runner(self) -> None:
        if self.os == "windows":
            ps = (
                "Get-Process python -ErrorAction SilentlyContinue "
                "| Where-Object { $_.CommandLine -match 'runner|civ.mcp' } "
                "| Stop-Process -Force -ErrorAction SilentlyContinue; "
                "Get-Process 'civ-mcp' -ErrorAction SilentlyContinue "
                "| Stop-Process -Force -ErrorAction SilentlyContinue"
            )
            encoded = base64.b64encode(ps.encode("utf-16-le")).decode("ascii")
            self.ssh(f"powershell -EncodedCommand {encoded}", timeout=15)
            self.ssh("schtasks /End /TN CivBench 2>nul", timeout=10)
            self.ssh("schtasks /Delete /TN CivBench /F 2>nul", timeout=10)
        else:
            hb = self.read_heartbeat()
            hb_pid = hb.get("pid") if hb else None
            if hb_pid and str(hb_pid).isdigit():
                self.ssh(f"kill -9 {hb_pid} 2>/dev/null", timeout=10)
            self.ssh(
                "tmux kill-session -t civbench 2>/dev/null; "
                "pkill -f runner.py 2>/dev/null; "
                "pkill -f civ-mcp 2>/dev/null",
                timeout=10,
            )

    def clean_autosaves(self) -> str:
        if self.os == "windows":
            save_dir = "C:\\Users\\%USERNAME%\\Documents\\My Games\\Sid Meier's Civilization VI\\Saves\\Single"
            rc, out = self.ssh(
                f'del /Q "{save_dir}\\0_MCP_*.Civ6Save" 2>nul && echo CLEANED || echo NONE'
            )
        else:
            save_dir = "~/.local/share/aspyr-media/Sid*Civilization*VI/Saves/Single"
            rc, out = self.ssh(
                f"rm -f {save_dir}/0_MCP_*.Civ6Save 2>/dev/null && echo CLEANED || echo NONE"
            )
        return out

    def clear_completion_sentinel(self) -> None:
        if self.os == "windows":
            self.ssh("del %USERPROFILE%\\civbench_done 2>nul", timeout=5)
        else:
            self.ssh("rm -f ~/civbench_done", timeout=5)

    def clear_local_telemetry(self) -> str:
        if self.os == "windows":
            rc, out = self.ssh(
                'powershell -Command "Remove-Item $env:USERPROFILE\\.civ6-mcp\\* '
                '-Force -ErrorAction SilentlyContinue; echo CLEARED"',
                timeout=15,
            )
        else:
            rc, out = self.ssh("rm -rf ~/.civ6-mcp/* && echo CLEARED", timeout=10)
        return out

    # ── Sync watcher (persistent) ───────────────────────────────
    #
    # Runs `convex_sync.py --watch --prod` in a background session (tmux on
    # Linux, schtasks on Windows). Streams diary/log updates to Convex
    # incrementally as the game plays, so the web frontend shows live state.
    # Not tied to a specific game — streams whatever the MCP server writes
    # into ~/.civ6-mcp/. Kept running across game boundaries.

    def is_sync_watcher_running(self) -> bool:
        if self.os == "windows":
            # /FO LIST prints "Status: Running" on its own line when the
            # task is executing; "Status: Ready" when idle-scheduled.
            rc, out = self.ssh(
                'schtasks /Query /TN "CivBench-Sync" /FO LIST 2>nul',
                timeout=10,
            )
            return rc == 0 and "Running" in out
        else:
            rc, out = self.ssh(
                "tmux has-session -t civbench-sync 2>/dev/null && echo YES || echo NO",
                timeout=10,
            )
            return "YES" in out

    def start_sync_watcher(self) -> bool:
        """Start the persistent convex_sync.py --watch process. Idempotent."""
        if self.os == "windows":
            bat_content = (
                f"@echo off\r\n"
                f"cd /d {self.repo}\r\n"
                f".venv\\Scripts\\python.exe scripts\\convex_sync.py "
                f"--watch --prod >> %USERPROFILE%\\civbench_sync.log 2>&1\r\n"
            )
            encoded = base64.b64encode(bat_content.encode("utf-8")).decode("ascii")
            self.ssh(
                f'powershell -Command "[System.Text.Encoding]::UTF8.GetString('
                f"[System.Convert]::FromBase64String('{encoded}'))"
                f" | Set-Content -Path '{self.repo}\\run_sync.bat' -NoNewline\""
            )
            # Idempotent: delete any existing task then create fresh
            self.ssh('schtasks /Delete /TN "CivBench-Sync" /F 2>nul', timeout=10)
            self.ssh(
                'schtasks /Create /TN "CivBench-Sync" /TR '
                f'"{self.repo}\\run_sync.bat" /SC ONCE /ST 00:00 /RL HIGHEST /IT /F',
                timeout=15,
            )
            rc, out = self.ssh('schtasks /Run /TN "CivBench-Sync"', timeout=10)
            return "SUCCESS" in out or rc == 0
        else:
            # Kill any existing watcher first (idempotent)
            self.ssh("tmux kill-session -t civbench-sync 2>/dev/null", timeout=5)
            rc, out = self.ssh(
                f"tmux new-session -d -s civbench-sync "
                f'"cd {self.repo} && uv run python scripts/convex_sync.py '
                f'--watch --prod 2>&1 | tee -a ~/civbench_sync.log"',
                timeout=15,
            )
            return rc == 0

    def stop_sync_watcher(self) -> None:
        if self.os == "windows":
            self.ssh('schtasks /End /TN "CivBench-Sync" 2>nul', timeout=10)
            self.ssh('schtasks /Delete /TN "CivBench-Sync" /F 2>nul', timeout=10)
        else:
            self.ssh("tmux kill-session -t civbench-sync 2>/dev/null", timeout=5)

    def launch_runner(self, model: str, scenario: str, runs: int = 1) -> bool:
        if self.os == "windows":
            bat_content = (
                f"@echo off\r\n"
                f"cd /d {self.repo}\r\n"
                f".venv\\Scripts\\python.exe -u evals/runner.py "
                f"--model {model} --scenarios {scenario} --runs {runs} "
                f">> %USERPROFILE%\\civbench_run.log 2>&1\r\n"
                f"if %ERRORLEVEL% EQU 0 echo DONE > %USERPROFILE%\\civbench_done\r\n"
            )
            encoded = base64.b64encode(bat_content.encode("utf-8")).decode("ascii")
            self.ssh(
                f'powershell -Command "[System.Text.Encoding]::UTF8.GetString('
                f"[System.Convert]::FromBase64String('{encoded}'))"
                f" | Set-Content -Path '{self.repo}\\run_bench.bat' -NoNewline\""
            )
            self.ssh(
                'schtasks /Create /TN "CivBench" /TR '
                f'"{self.repo}\\run_bench.bat" /SC ONCE /ST 00:00 /RL HIGHEST /IT /F'
            )
            rc, out = self.ssh('schtasks /Run /TN "CivBench"')
            return "SUCCESS" in out or rc == 0
        else:
            env_parts = [f"export {k}={v};" for k, v in self.config.display_env.items()]
            env_str = " ".join(env_parts)
            self.ssh("tmux kill-session -t civbench 2>/dev/null", timeout=5)
            rc, out = self.ssh(
                f"{env_str} tmux new-session -d -s civbench "
                f'"cd {self.repo} && uv run python -u evals/runner.py '
                f"--model {model} --scenarios {scenario} --runs {runs} "
                f'2>&1 | tee -a ~/civbench_run.log && touch ~/civbench_done"'
            )
            return rc == 0

    def discover_run_id(self) -> str | None:
        if self.os == "windows":
            ps = (
                "$f = Get-ChildItem $env:USERPROFILE\\.civ6-mcp\\diary_*.jsonl "
                "-Exclude '*cities*' -ErrorAction SilentlyContinue "
                "| Sort-Object LastWriteTime -Descending | Select-Object -First 1; "
                "if ($f) { $f.BaseName.Split('_')[-1] }"
            )
            encoded = base64.b64encode(ps.encode("utf-16-le")).decode("ascii")
            cmd = f"powershell -EncodedCommand {encoded}"
        else:
            cmd = (
                "ls -t ~/.civ6-mcp/diary_*.jsonl 2>/dev/null | grep -v cities | head -1 "
                "| xargs -I{} basename {} .jsonl | rev | cut -d_ -f1 | rev"
            )
        rc, out = self.ssh(cmd, timeout=15)
        rid = out.strip().split("\n")[-1].strip()
        return rid if rc == 0 and rid and len(rid) > 2 else None

    def sync_to_convex(self) -> bool:
        if self.os == "windows":
            cmd = (
                f"cd /d {self.repo} && "
                f".venv\\Scripts\\python.exe scripts/convex_sync.py "
                f"--upload %USERPROFILE%\\.civ6-mcp --prod"
            )
        else:
            cmd = (
                f"cd {self.repo} && "
                f"uv run python scripts/convex_sync.py "
                f"--upload ~/.civ6-mcp --prod"
            )
        rc, out = self.ssh(cmd, timeout=300)
        if rc != 0:
            log.warning("Sync failed on %s: %s", self.name, out[:200])
        return rc == 0

    def tail_log(self, n: int = 10) -> str:
        if self.os == "windows":
            rc, out = self.ssh(
                f'powershell -Command "Get-Content %USERPROFILE%\\civbench_run.log -Tail {n}"',
                timeout=15,
            )
        else:
            rc, out = self.ssh(f"tail -{n} ~/civbench_run.log 2>/dev/null", timeout=10)
        return out
