"""Background game-over watchdog — detects victories independent of tool calls.

The LLM might stop calling tools (context exhaustion, API error, model hang).
All 5 game-over check sites in end_turn.py require a tool call to fire.
This watchdog polls check_game_over() on a timer so the orchestrator and
telemetry pipeline still detect the outcome.
"""

import asyncio
import logging

from civ_mcp import heartbeat
from civ_mcp.game_state import GameState

log = logging.getLogger(__name__)

INTERVAL = 30  # seconds between checks


class GameOverWatchdog:
    """Polls check_game_over() every INTERVAL seconds after arming.

    On detection: writes heartbeat "finished", logs game_over event,
    and stashes GameOverStatus on gs so the next tool call (if any)
    picks it up immediately.
    """

    def __init__(self, gs: GameState, logger: "GameLogger") -> None:  # noqa: F821
        self._gs = gs
        self._logger = logger
        self._task: asyncio.Task | None = None
        self._armed = asyncio.Event()

    def arm(self) -> None:
        """Call after first successful end_turn to start polling."""
        self._armed.set()

    def start(self) -> None:
        self._task = asyncio.create_task(self._run(), name="game-over-watchdog")

    async def stop(self) -> None:
        if self._task:
            self._task.cancel()
            try:
                await self._task
            except asyncio.CancelledError:
                pass

    async def _run(self) -> None:
        await self._armed.wait()
        while True:
            await asyncio.sleep(INTERVAL)
            try:
                result = await self._gs.check_game_over()
                if result is None:
                    continue

                log.warning(
                    "Watchdog detected game over: %s %s (%s)",
                    "DEFEAT" if result.is_defeat else "VICTORY",
                    result.winner_name,
                    result.victory_type,
                )

                self._gs._last_game_over = result
                heartbeat.write("finished", turn=self._gs._high_water_turn)

                vtype = (
                    result.victory_type.replace("VICTORY_", "")
                    .replace("_", " ")
                    .title()
                )
                await self._logger.log_game_over(
                    is_defeat=result.is_defeat,
                    winner_civ=result.winner_name,
                    winner_leader=result.winner_leader,
                    victory_type=vtype,
                    player_alive=result.player_alive,
                )
                return

            except asyncio.CancelledError:
                raise
            except Exception:
                log.debug("Watchdog check failed", exc_info=True)
