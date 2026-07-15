import { mutation } from "./_generated/server";
import { v } from "convex/values";

// Eval metadata: JSONL snake_case → Convex camelCase field mapping
const EVAL_FIELD_MAP = [
  ["mcp_version", "mcpVersion"], ["mcp_git_sha", "mcpGitSha"],
  ["mcp_git_describe", "gitDescribe"],
  ["scenario_id", "scenarioId"], ["difficulty", "difficulty"],
  ["map_type", "mapType"], ["map_size", "mapSize"],
  ["game_speed", "gameSpeed"], ["eval_track", "evalTrack"],
] as const;

// eslint-disable-next-line @typescript-eslint/no-explicit-any
function extractEvalMeta(source: any): Record<string, string> {
  const meta: Record<string, string> = {};
  for (const [src, dst] of EVAL_FIELD_MAP) {
    if (source[src]) meta[dst] = source[src];
  }
  return meta;
}

// Metrics to precompute for sparkline charts
const SERIES_METRICS = [
  "score", "science", "culture", "gold", "military",
  "faith", "territory", "exploration_pct", "pop", "cities", "tourism",
] as const;

type SeriesPlayer = {
  civ: string;
  leader: string;
  is_agent: boolean;
  metrics: Record<string, number[]>;
};

/** Merge new turn data into existing turnSeries on a games doc. */
// eslint-disable-next-line @typescript-eslint/no-explicit-any
function mergeTurnSeries(existing: any | undefined, rows: any[]): { turns: number[]; players: Record<string, SeriesPlayer> } {
  const prev = existing ?? { turns: [], players: {} };
  const turns: number[] = [...prev.turns];
  const players: Record<string, SeriesPlayer> = {};

  // Copy existing player data
  for (const [pid, p] of Object.entries(prev.players as Record<string, SeriesPlayer>)) {
    players[pid] = {
      civ: p.civ,
      leader: p.leader,
      is_agent: p.is_agent,
      metrics: {} as Record<string, number[]>,
    };
    for (const m of SERIES_METRICS) {
      players[pid].metrics[m] = [...(p.metrics[m] ?? [])];
    }
  }

  // Group incoming rows by turn
  const byTurn = new Map<number, typeof rows>();
  for (const r of rows) {
    if (!byTurn.has(r.turn)) byTurn.set(r.turn, []);
    byTurn.get(r.turn)!.push(r);
  }

  for (const [turn, turnRows] of byTurn) {
    let idx = turns.indexOf(turn);
    if (idx === -1) {
      // Insert in sorted position
      idx = turns.findIndex((t) => t > turn);
      if (idx === -1) idx = turns.length;
      turns.splice(idx, 0, turn);
      // Insert placeholder at idx for all existing players
      for (const p of Object.values(players)) {
        for (const m of SERIES_METRICS) {
          p.metrics[m].splice(idx, 0, 0);
        }
      }
    }

    for (const r of turnRows) {
      const pid = String(r.pid);
      if (!players[pid]) {
        players[pid] = {
          civ: r.civ,
          leader: r.leader,
          is_agent: r.is_agent,
          metrics: {} as Record<string, number[]>,
        };
        // Backfill zeros for existing turns
        for (const m of SERIES_METRICS) {
          players[pid].metrics[m] = new Array(turns.length).fill(0);
        }
      }
      for (const m of SERIES_METRICS) {
        players[pid].metrics[m][idx] = typeof r[m] === "number" ? r[m] : 0;
      }
    }
  }

  return { turns, players };
}

export const ingestPlayerRows = mutation({
  args: {
    gameId: v.string(),
    civ: v.string(),
    leader: v.string(),
    seed: v.string(),
    rows: v.array(v.any()),
    runId: v.optional(v.string()),
    evalFiles: v.optional(v.array(v.string())),
    excludeReason: v.optional(v.string()),
  },
  handler: async (ctx, { gameId, civ, leader, seed, rows, runId, evalFiles, excludeReason }) => {
    for (const row of rows) {
      // Backfill fields added after early game data was recorded
      if (row.exploration_pct === undefined) row.exploration_pct = 0;

      // Strip techs/civics arrays — only the _completed counts are displayed
      delete row.techs;
      delete row.civics;

      // Upsert by (gameId, turn, pid) — handles reflection merges
      const existing = await ctx.db
        .query("playerRows")
        .withIndex("by_game_turn_pid", (q) =>
          q.eq("gameId", gameId).eq("turn", row.turn).eq("pid", row.pid),
        )
        .unique();
      if (existing) {
        await ctx.db.replace(existing._id, { gameId, ...row });
      } else {
        await ctx.db.insert("playerRows", { gameId, ...row });
      }
    }

    // Upsert games entry
    const turns = rows.map((r: { turn: number }) => r.turn);
    const maxTurn = Math.max(...turns);
    const game = await ctx.db
      .query("games")
      .withIndex("by_gameId", (q) => q.eq("gameId", gameId))
      .unique();

    // Denormalize agent model/score and ELO player snapshot
    const agentRow = rows.find(
      (r: { is_agent: boolean }) => r.is_agent,
    );
    // Extract eval metadata from agent row (set by MCP server from env vars)
    const evalMeta = agentRow ? extractEvalMeta(agentRow) : {};

    if (game) {
      const patch: Record<string, unknown> = {
        lastTurn: Math.max(game.lastTurn ?? 0, maxTurn),
        lastUpdated: Date.now(),
        turnCount: Math.max(game.turnCount ?? 0, maxTurn),
        ...evalMeta,
      };
      // Don't regress a completed game back to "live" when the sync
      // watcher delivers late diary rows after completeGame has run.
      if (game.status !== "completed") {
        patch.status = "live";
      }
      // Diary has canonical display names (e.g. "Babylon" vs log's "babylon_stk")
      if (leader) patch.leader = leader;
      if (civ) patch.civ = civ;
      if (runId) patch.runId = runId;
      if (excludeReason) patch.excludeReason = excludeReason;
      if (evalFiles?.length) {
        const existing = game.evalFiles ?? [];
        patch.evalFiles = [...new Set([...existing, ...evalFiles])];
      }
      // Denormalized fields (eloPlayers set at completion by completeGame, not here)
      if (agentRow) {
        if (agentRow.agent_model) patch.agentModel = agentRow.agent_model;
        if (typeof agentRow.score === "number") patch.agentScore = agentRow.score;
      }
      // Update sparkline series
      patch.turnSeries = mergeTurnSeries(game.turnSeries, rows);
      await ctx.db.patch(game._id, patch);
    } else {
      await ctx.db.insert("games", {
        gameId,
        civ,
        leader,
        seed,
        status: "live",
        lastTurn: maxTurn,
        lastUpdated: Date.now(),
        turnCount: maxTurn,
        hasCities: false,
        ...evalMeta,
        ...(runId ? { runId } : {}),
        ...(excludeReason ? { excludeReason } : {}),
        ...(evalFiles?.length ? { evalFiles } : {}),
        ...(agentRow?.agent_model ? { agentModel: agentRow.agent_model } : {}),
        ...(typeof agentRow?.score === "number" ? { agentScore: agentRow.score } : {}),
        turnSeries: mergeTurnSeries(undefined, rows),
      });
    }
  },
});

export const ingestCityRows = mutation({
  args: {
    gameId: v.string(),
    rows: v.array(v.any()),
  },
  handler: async (ctx, { gameId, rows }) => {
    for (const row of rows) {
      // Upsert by (gameId, turn, city_id)
      const existing = await ctx.db
        .query("cityRows")
        .withIndex("by_game_turn", (q) =>
          q.eq("gameId", gameId).eq("turn", row.turn),
        )
        .filter((q) => q.eq(q.field("city_id"), row.city_id))
        .unique();
      if (existing) {
        await ctx.db.replace(existing._id, { gameId, ...row });
      } else {
        await ctx.db.insert("cityRows", { gameId, ...row });
      }
    }

    // Mark game as having cities
    const game = await ctx.db
      .query("games")
      .withIndex("by_gameId", (q) => q.eq("gameId", gameId))
      .unique();
    if (game && !game.hasCities) {
      await ctx.db.patch(game._id, {
        hasCities: true,
        lastUpdated: Date.now(),
      });
    }
  },
});

export const markGameCompleted = mutation({
  args: { gameId: v.string() },
  handler: async (ctx, { gameId }) => {
    const game = await ctx.db
      .query("games")
      .withIndex("by_gameId", (q) => q.eq("gameId", gameId))
      .unique();
    if (game) {
      await ctx.db.patch(game._id, { status: "completed" });
    }
  },
});

export const patchGameOutcome = mutation({
  args: {
    gameId: v.string(),
    outcome: v.object({
      result: v.union(v.literal("victory"), v.literal("defeat")),
      winnerCiv: v.string(),
      winnerLeader: v.string(),
      victoryType: v.string(),
      turn: v.number(),
      playerAlive: v.boolean(),
    }),
  },
  handler: async (ctx, { gameId, outcome }) => {
    const game = await ctx.db
      .query("games")
      .withIndex("by_gameId", (q) => q.eq("gameId", gameId))
      .unique();
    if (game) {
      await ctx.db.patch(game._id, { status: "completed", outcome });
    }
  },
});

// ── Admissibility helpers ────────────────────────────────────────────────────

// ── Admissibility helpers ────────────────────────────────────────────────────

type EloPlayer = {
  pid: number;
  civ: string;
  leader: string;
  is_agent: boolean;
  agent_model: string | null;
};

type PlayerRow = {
  pid: number;
  civ: string;
  leader: string;
  is_agent: boolean;
  agent_model?: string | null;
};

type GameIdentity = {
  civ: string;
  leader: string;
  agentModel?: string | null;
  agentModelOverride?: string | null;
};

function resolveAgentModel(
  game: GameIdentity,
  argModel?: string,
): string | null {
  return argModel ?? game.agentModel ?? game.agentModelOverride ?? null;
}

/** Build eloPlayers from playerRows, inferring agent identity and injecting
 *  eliminated agents when necessary. */
function buildEloPlayers(
  playerRows: PlayerRow[],
  existing: EloPlayer[] | undefined,
  game: GameIdentity,
  model: string | null,
): EloPlayer[] | undefined {
  let players: EloPlayer[] | undefined = existing;

  if (playerRows.length >= 2) {
    const hasAgent = playerRows.some((r) => r.is_agent);
    players = playerRows.map((r) => {
      const isAgent = hasAgent ? r.is_agent : r.civ === game.civ;
      return {
        pid: r.pid,
        civ: r.civ,
        leader: r.leader,
        is_agent: isAgent,
        agent_model: isAgent && model ? model : (r.agent_model ?? null),
      };
    });
  }

  // If the agent was eliminated, their civ won't be in lastTurn rows.
  // Inject them from the game doc so ELO can identify the model.
  if (model && players && !players.some((p) => p.is_agent && p.agent_model)) {
    const agentExists = players.some((p) => p.civ === game.civ);
    if (!agentExists) {
      players = [
        ...players,
        { pid: 0, civ: game.civ, leader: game.leader, is_agent: true, agent_model: model },
      ];
    } else {
      players = players.map((p) =>
        p.civ === game.civ
          ? { ...p, is_agent: true, agent_model: model }
          : p,
      );
    }
  }

  return players;
}

type AdmissibilityInputs = {
  outcome?: { result: string; winnerCiv: string } | null;
  excludeReason?: string;
  turnCount: number;
  evalTrack?: string;
  eloPlayers?: EloPlayer[];
};

function isAdmissible(game: AdmissibilityInputs): boolean {
  return (
    !!game.outcome &&
    !!game.eloPlayers &&
    game.eloPlayers.length >= 2 &&
    game.eloPlayers.some((p) => p.is_agent && !!p.agent_model) &&
    !game.excludeReason &&
    game.turnCount >= 50 &&
    !!game.evalTrack &&
    game.evalTrack !== "development"
  );
}

// ── Completion mutations ─────────────────────────────────────────────────────

/** Atomically complete a game: set outcome, snapshot eloPlayers, compute admissible.
 *  Idempotent — no-op if game is already completed (unless force=true). */
export const completeGame = mutation({
  args: {
    gameId: v.string(),
    outcome: v.optional(
      v.object({
        result: v.union(v.literal("victory"), v.literal("defeat")),
        winnerCiv: v.string(),
        winnerLeader: v.string(),
        victoryType: v.string(),
        turn: v.number(),
        playerAlive: v.boolean(),
      }),
    ),
    agentModel: v.optional(v.string()),
    force: v.optional(v.boolean()),
  },
  handler: async (ctx, { gameId, outcome, agentModel, force }) => {
    const game = await ctx.db
      .query("games")
      .withIndex("by_gameId", (q) => q.eq("gameId", gameId))
      .unique();
    if (!game) throw new Error(`Game not found: ${gameId}`);
    if (game.status === "completed" && !force) {
      return { gameId, admissible: game.admissible ?? false, skipped: true };
    }

    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const patch: Record<string, any> = { status: "completed" as const };

    if (outcome) patch.outcome = outcome;
    const finalOutcome = outcome ?? game.outcome;

    const model = resolveAgentModel(game, agentModel);
    if (model && !game.agentModel) patch.agentModel = model;

    const playerRows = await ctx.db
      .query("playerRows")
      .withIndex("by_game_turn", (q) =>
        q.eq("gameId", gameId).eq("turn", game.lastTurn),
      )
      .collect();

    const eloPlayers = buildEloPlayers(playerRows, game.eloPlayers, game, model);
    if (eloPlayers) patch.eloPlayers = eloPlayers;

    if (game.agentModelOverride) {
      if (!patch.agentModel) patch.agentModel = game.agentModelOverride;
      patch.agentModelOverride = undefined;
    }

    patch.admissible = isAdmissible({
      outcome: finalOutcome,
      excludeReason: game.excludeReason,
      turnCount: game.turnCount,
      evalTrack: game.evalTrack,
      eloPlayers,
    });

    await ctx.db.patch(game._id, patch);
    return { gameId, admissible: patch.admissible, skipped: false };
  },
});

/** Recompute admissible + eloPlayers for completed games. Migration/admin tool. */
export const recomputeAdmissible = mutation({
  args: { gameId: v.optional(v.string()) },
  handler: async (ctx, { gameId }) => {
    let games;
    if (gameId) {
      const game = await ctx.db
        .query("games")
        .withIndex("by_gameId", (q) => q.eq("gameId", gameId))
        .unique();
      games = game ? [game] : [];
    } else {
      games = await ctx.db.query("games").collect();
      games = games.filter((g) => g.status === "completed");
    }

    let patched = 0;
    for (const game of games) {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const patch: Record<string, any> = {};

      const model = resolveAgentModel(game);

      const playerRows = await ctx.db
        .query("playerRows")
        .withIndex("by_game_turn", (q) =>
          q.eq("gameId", game.gameId).eq("turn", game.lastTurn),
        )
        .collect();

      const eloPlayers = buildEloPlayers(playerRows, game.eloPlayers, game, model);
      if (eloPlayers) patch.eloPlayers = eloPlayers;

      // Fold agentModelOverride
      if (game.agentModelOverride) {
        if (!game.agentModel) patch.agentModel = game.agentModelOverride;
        patch.agentModelOverride = undefined;
      }

      // Denormalize agentModel/agentScore from agent row
      const agentRow = playerRows.find((r) => r.is_agent);
      if (agentRow) {
        if (agentRow.agent_model && !game.agentModel) patch.agentModel = agentRow.agent_model;
        if (typeof agentRow.score === "number") patch.agentScore = agentRow.score;
      }

      patch.admissible = isAdmissible({
        outcome: game.outcome,
        excludeReason: game.excludeReason,
        turnCount: game.turnCount,
        evalTrack: game.evalTrack,
        eloPlayers,
      });

      if (Object.keys(patch).length > 0) {
        await ctx.db.patch(game._id, patch);
        patched++;
      }
    }
    return { patched, total: games.length };
  },
});

export const patchExcludeReason = mutation({
  args: { gameId: v.string(), excludeReason: v.optional(v.string()) },
  handler: async (ctx, { gameId, excludeReason }) => {
    const game = await ctx.db
      .query("games")
      .withIndex("by_gameId", (q) => q.eq("gameId", gameId))
      .unique();
    if (!game) throw new Error(`Game not found: ${gameId}`);
    // Re-evaluate admissibility with the new excludeReason
    const admissible = isAdmissible({
      outcome: game.outcome,
      excludeReason,
      turnCount: game.turnCount,
      evalTrack: game.evalTrack,
      eloPlayers: game.eloPlayers,
    });
    await ctx.db.patch(game._id, { excludeReason, admissible });
    return { gameId, excludeReason: excludeReason ?? null, admissible };
  },
});

export const setModelOverride = mutation({
  args: { gameId: v.string(), model: v.optional(v.string()) },
  handler: async (ctx, { gameId, model }) => {
    const game = await ctx.db
      .query("games")
      .withIndex("by_gameId", (q) => q.eq("gameId", gameId))
      .unique();
    if (!game) throw new Error(`Game not found: ${gameId}`);
    await ctx.db.patch(game._id, { agentModelOverride: model });
    return { gameId, agentModelOverride: model ?? null };
  },
});

export const patchEvalTrack = mutation({
  args: { fromTrack: v.string(), toTrack: v.string() },
  handler: async (ctx, { fromTrack, toTrack }) => {
    const games = await ctx.db.query("games").collect();
    let patched = 0;
    for (const game of games) {
      if (game.evalTrack === fromTrack) {
        const admissible = isAdmissible({
          outcome: game.outcome,
          excludeReason: game.excludeReason,
          turnCount: game.turnCount,
          evalTrack: toTrack,
          eloPlayers: game.eloPlayers,
        });
        await ctx.db.patch(game._id, { evalTrack: toTrack, admissible });
        patched++;
      }
    }
    return { patched };
  },
});

export const markCompleted = mutation({
  args: { gameId: v.string() },
  handler: async (ctx, { gameId }) => {
    const game = await ctx.db
      .query("games")
      .withIndex("by_gameId", (q) => q.eq("gameId", gameId))
      .unique();
    if (game) {
      await ctx.db.patch(game._id, { status: "completed" });
      return { gameId, status: "completed" };
    }
    return { gameId, status: "not_found" };
  },
});

/** Delete up to `limit` rows from a single table for a game.
 *  Returns how many were deleted — call repeatedly until 0. */
export const deleteGameBatch = mutation({
  args: {
    gameId: v.string(),
    table: v.union(
      v.literal("playerRows"),
      v.literal("cityRows"),
      v.literal("spatialTurns"),
      v.literal("spatialMaps"),
      v.literal("mapData"),
      v.literal("games"),
    ),
    limit: v.optional(v.number()),
  },
  handler: async (ctx, { gameId, table, limit }) => {
    const batchSize = limit ?? 500;

    if (table === "games") {
      const game = await ctx.db
        .query("games")
        .withIndex("by_gameId", (q) => q.eq("gameId", gameId))
        .unique();
      if (game) {
        await ctx.db.delete(game._id);
        return { deleted: 1 };
      }
      return { deleted: 0 };
    }

    // Each table has its own index — query explicitly to satisfy TS
    let deleted = 0;
    if (table === "playerRows") {
      const rows = await ctx.db.query("playerRows")
        .withIndex("by_game_turn", (q) => q.eq("gameId", gameId)).take(batchSize);
      for (const r of rows) await ctx.db.delete(r._id);
      deleted = rows.length;
    } else if (table === "cityRows") {
      const rows = await ctx.db.query("cityRows")
        .withIndex("by_game_turn", (q) => q.eq("gameId", gameId)).take(batchSize);
      for (const r of rows) await ctx.db.delete(r._id);
      deleted = rows.length;
    } else if (table === "spatialTurns") {
      const rows = await ctx.db.query("spatialTurns")
        .withIndex("by_game_turn", (q) => q.eq("gameId", gameId)).take(batchSize);
      for (const r of rows) await ctx.db.delete(r._id);
      deleted = rows.length;
    } else if (table === "spatialMaps") {
      const rows = await ctx.db.query("spatialMaps")
        .withIndex("by_gameId", (q) => q.eq("gameId", gameId)).take(batchSize);
      for (const r of rows) await ctx.db.delete(r._id);
      deleted = rows.length;
    } else if (table === "mapData") {
      const rows = await ctx.db.query("mapData")
        .withIndex("by_gameId", (q) => q.eq("gameId", gameId)).take(batchSize);
      for (const r of rows) await ctx.db.delete(r._id);
      deleted = rows.length;
    }
    return { deleted };
  },
});

export const backfillDenormalized = mutation({
  args: {},
  handler: async (ctx) => {
    const games = await ctx.db.query("games").collect();
    let patched = 0;
    for (const game of games) {
      // eslint-disable-next-line @typescript-eslint/no-explicit-any
      const patch: Record<string, any> = {};

      // Backfill agentModel, agentScore, eloPlayers from playerRows
      const playerRows = await ctx.db
        .query("playerRows")
        .withIndex("by_game_turn", (q) =>
          q.eq("gameId", game.gameId).eq("turn", game.lastTurn),
        )
        .collect();
      if (playerRows.length >= 2) {
        patch.eloPlayers = playerRows.map((r) => ({
          pid: r.pid,
          civ: r.civ,
          leader: r.leader,
          is_agent: r.is_agent,
          agent_model: r.agent_model ?? null,
        }));
      }
      const agentRow = playerRows.find((r) => r.is_agent);
      if (agentRow) {
        if (agentRow.agent_model) patch.agentModel = agentRow.agent_model;
        if (typeof agentRow.score === "number") patch.agentScore = agentRow.score;
      }

      if (Object.keys(patch).length > 0) {
        await ctx.db.patch(game._id, patch);
        patched++;
      }
    }
    return { patched, total: games.length };
  },
});

/** Backfill one game: strip techs/civics from playerRows + compute turnSeries.
 *  Run per-game to stay within Convex mutation time limits. */
export const backfillStripAndSeries = mutation({
  args: { gameId: v.string() },
  handler: async (ctx, { gameId }) => {
    const game = await ctx.db
      .query("games")
      .withIndex("by_gameId", (q) => q.eq("gameId", gameId))
      .first();
    if (!game) return { error: "game not found" };

    // Read all playerRows for this game
    const allRows = await ctx.db
      .query("playerRows")
      .withIndex("by_game_turn", (q) => q.eq("gameId", gameId))
      .collect();

    // Strip techs/civics from each row
    let stripped = 0;
    for (const row of allRows) {
      if (row.techs || row.civics) {
        await ctx.db.patch(row._id, { techs: undefined, civics: undefined });
        stripped++;
      }
    }

    // Build turnSeries from all rows
    const turnSeries = mergeTurnSeries(undefined, allRows);
    await ctx.db.patch(game._id, { turnSeries });

    return { gameId, stripped, totalRows: allRows.length, seriesTurns: turnSeries.turns.length };
  },
});

/** List all gameIds for batch backfill. */
export const listGameIds = mutation({
  args: {},
  handler: async (ctx) => {
    const games = await ctx.db.query("games").collect();
    return games.map((g) => g.gameId);
  },
});

// Spatial metrics to merge into turnSeries (agent player only)
const SPATIAL_METRICS = ["spatial_tiles", "spatial_actions", "spatial_cumulative"] as const;

export const ingestSpatialTurns = mutation({
  args: {
    gameId: v.string(),
    rows: v.array(v.any()),
  },
  handler: async (ctx, { gameId, rows }) => {
    // 1. Upsert spatialTurns rows
    for (const row of rows) {
      const existing = await ctx.db
        .query("spatialTurns")
        .withIndex("by_game_turn", (q) =>
          q.eq("gameId", gameId).eq("turn", row.turn),
        )
        .unique();
      if (existing) {
        await ctx.db.replace(existing._id, { gameId, ...row });
      } else {
        await ctx.db.insert("spatialTurns", { gameId, ...row });
      }
    }

    // 2. Merge spatial sparkline metrics into games.turnSeries
    const game = await ctx.db
      .query("games")
      .withIndex("by_gameId", (q) => q.eq("gameId", gameId))
      .first();
    if (!game) return;

    const patch: Record<string, unknown> = { hasSpatial: true, lastUpdated: Date.now() };

    if (game.turnSeries) {
      const ts = {
        turns: [...game.turnSeries.turns],
        players: {} as Record<string, SeriesPlayer>,
      };
      // Deep-copy existing players
      for (const [pid, p] of Object.entries(
        game.turnSeries.players as Record<string, SeriesPlayer>,
      )) {
        ts.players[pid] = {
          civ: p.civ,
          leader: p.leader,
          is_agent: p.is_agent,
          metrics: {} as Record<string, number[]>,
        };
        // Copy all existing metrics (diary + any prior spatial)
        for (const [m, arr] of Object.entries(p.metrics)) {
          ts.players[pid].metrics[m] = [...(arr ?? [])];
        }
        // Ensure spatial metric arrays exist with correct length
        if (p.is_agent) {
          for (const m of SPATIAL_METRICS) {
            if (!ts.players[pid].metrics[m]) {
              ts.players[pid].metrics[m] = new Array(ts.turns.length).fill(0);
            }
          }
        }
      }

      // For each incoming row, find the turn index and set spatial values
      for (const row of rows) {
        const idx = ts.turns.indexOf(row.turn);
        if (idx === -1) continue; // Turn not in diary series yet — skip
        for (const [, p] of Object.entries(ts.players)) {
          if (!p.is_agent) continue;
          p.metrics["spatial_tiles"][idx] = row.tiles_observed ?? 0;
          p.metrics["spatial_actions"][idx] = row.tool_calls ?? 0;
          p.metrics["spatial_cumulative"][idx] = row.cumulative_tiles ?? 0;
        }
      }
      patch.turnSeries = ts;
    }

    await ctx.db.patch(game._id, patch);
  },
});

export const ingestSpatialMap = mutation({
  args: {
    gameId: v.string(),
    minX: v.number(),
    maxX: v.number(),
    minY: v.number(),
    maxY: v.number(),
    tileCount: v.number(),
    tiles: v.array(v.number()),
  },
  handler: async (ctx, args) => {
    const existing = await ctx.db
      .query("spatialMaps")
      .withIndex("by_gameId", (q) => q.eq("gameId", args.gameId))
      .unique();
    if (existing) {
      await ctx.db.replace(existing._id, args);
    } else {
      await ctx.db.insert("spatialMaps", args);
    }
  },
});

export const ingestMapData = mutation({
  args: {
    gameId: v.string(),
    gridW: v.number(),
    gridH: v.number(),
    // JSON-encoded number[] strings — Convex caps arrays at 8192 elements
    terrain: v.string(),
    initialOwners: v.string(),
    initialRoutes: v.optional(v.string()),
    initialTurn: v.number(),
    // Legacy: inline frames for small games that fit in one doc
    ownerFrames: v.optional(v.string()),
    cityFrames: v.optional(v.string()),
    roadFrames: v.optional(v.string()),
    cityNames: v.optional(v.string()),
    players: v.array(v.object({ pid: v.number(), civ: v.string(), csType: v.optional(v.string()) })),
    maxTurn: v.number(),
    frameChunks: v.optional(v.number()),
  },
  handler: async (ctx, args) => {
    const existing = await ctx.db
      .query("mapData")
      .withIndex("by_gameId", (q) => q.eq("gameId", args.gameId))
      .first();
    if (existing) {
      await ctx.db.replace(existing._id, args);
    } else {
      await ctx.db.insert("mapData", args);
    }

    // Mark game as having map data
    const game = await ctx.db
      .query("games")
      .withIndex("by_gameId", (q) => q.eq("gameId", args.gameId))
      .unique();
    if (game && !game.hasMap) {
      await ctx.db.patch(game._id, { hasMap: true, lastUpdated: Date.now() });
    }
  },
});

export const ingestMapFrames = mutation({
  args: {
    gameId: v.string(),
    chunk: v.number(),
    ownerFrames: v.string(),
    cityFrames: v.string(),
    roadFrames: v.string(),
  },
  handler: async (ctx, args) => {
    const existing = await ctx.db
      .query("mapFrames")
      .withIndex("by_gameId_chunk", (q) =>
        q.eq("gameId", args.gameId).eq("chunk", args.chunk),
      )
      .first();
    if (existing) {
      await ctx.db.replace(existing._id, args);
    } else {
      await ctx.db.insert("mapFrames", args);
    }
  },
});

/** Merge one batch of rows from sourceGameId into targetGameId.
 *  Re-keys data, skipping duplicates (target wins). Call repeatedly until remaining=0.
 *  Then delete the source games entry and run backfillStripAndSeries on the target. */
export const mergeGame = mutation({
  args: {
    sourceGameId: v.string(),
    targetGameId: v.string(),
    table: v.union(
      v.literal("playerRows"),
      v.literal("cityRows"),
      v.literal("spatialTurns"),
    ),
    limit: v.optional(v.number()),
  },
  handler: async (ctx, { sourceGameId, targetGameId, table, limit }) => {
    const batchSize = limit ?? 200;
    let merged = 0;
    let skipped = 0;

    if (table === "playerRows") {
      const rows = await ctx.db.query("playerRows")
        .withIndex("by_game_turn", (q) => q.eq("gameId", sourceGameId))
        .take(batchSize);
      for (const row of rows) {
        const dup = await ctx.db.query("playerRows")
          .withIndex("by_game_turn_pid", (q) =>
            q.eq("gameId", targetGameId).eq("turn", row.turn).eq("pid", row.pid))
          .unique();
        if (!dup) {
          const { _id, _creationTime, gameId: _, ...data } = row;
          await ctx.db.insert("playerRows", { gameId: targetGameId, ...data });
          merged++;
        } else {
          skipped++;
        }
        await ctx.db.delete(row._id);
      }
      const remaining = await ctx.db.query("playerRows")
        .withIndex("by_game_turn", (q) => q.eq("gameId", sourceGameId))
        .first();
      return { merged, skipped, remaining: remaining ? true : false };

    } else if (table === "cityRows") {
      const rows = await ctx.db.query("cityRows")
        .withIndex("by_game_turn", (q) => q.eq("gameId", sourceGameId))
        .take(batchSize);
      for (const row of rows) {
        const dup = await ctx.db.query("cityRows")
          .withIndex("by_game_turn", (q) =>
            q.eq("gameId", targetGameId).eq("turn", row.turn))
          .filter((q) => q.eq(q.field("city_id"), row.city_id))
          .unique();
        if (!dup) {
          const { _id, _creationTime, gameId: _, ...data } = row;
          await ctx.db.insert("cityRows", { gameId: targetGameId, ...data });
          merged++;
        } else {
          skipped++;
        }
        await ctx.db.delete(row._id);
      }
      const remaining = await ctx.db.query("cityRows")
        .withIndex("by_game_turn", (q) => q.eq("gameId", sourceGameId))
        .first();
      return { merged, skipped, remaining: remaining ? true : false };

    } else if (table === "spatialTurns") {
      const rows = await ctx.db.query("spatialTurns")
        .withIndex("by_game_turn", (q) => q.eq("gameId", sourceGameId))
        .take(batchSize);
      for (const row of rows) {
        const dup = await ctx.db.query("spatialTurns")
          .withIndex("by_game_turn", (q) =>
            q.eq("gameId", targetGameId).eq("turn", row.turn))
          .unique();
        if (!dup) {
          const { _id, _creationTime, gameId: _, ...data } = row;
          await ctx.db.insert("spatialTurns", { gameId: targetGameId, ...data });
          merged++;
        } else {
          skipped++;
        }
        await ctx.db.delete(row._id);
      }
      const remaining = await ctx.db.query("spatialTurns")
        .withIndex("by_game_turn", (q) => q.eq("gameId", sourceGameId))
        .first();
      return { merged, skipped, remaining: remaining ? true : false };
    }

    return { merged, skipped, remaining: false };
  },
});

/** Admin: patch arbitrary fields on a game doc (for fixing bad state). */
export const patchGameFields = mutation({
  args: {
    gameId: v.string(),
    patch: v.any(),
  },
  handler: async (ctx, { gameId, patch }) => {
    const game = await ctx.db
      .query("games")
      .withIndex("by_gameId", (q) => q.eq("gameId", gameId))
      .unique();
    if (!game) throw new Error(`Game not found: ${gameId}`);
    await ctx.db.patch(game._id, patch);
    return { gameId, patched: Object.keys(patch) };
  },
});

export const backfillAgentModel = mutation({
  args: { model: v.string() },
  handler: async (ctx, { model }) => {
    const rows = await ctx.db
      .query("playerRows")
      .filter((q) => q.eq(q.field("is_agent"), true))
      .collect();
    let patched = 0;
    for (const row of rows) {
      if (!row.agent_model) {
        await ctx.db.patch(row._id, { agent_model: model });
        patched++;
      }
    }
    return { patched, total: rows.length };
  },
});
