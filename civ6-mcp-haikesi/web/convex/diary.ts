import { query } from "./_generated/server";
import { v } from "convex/values";

/** List all games — returns shape compatible with DiaryFile[]
 *  Pass minTurns to filter out micro-runs (default: include all). */
export const listGames = query({
  args: { minTurns: v.optional(v.number()) },
  handler: async (ctx, { minTurns }) => {
    let games = await ctx.db
      .query("games")
      .withIndex("by_status")
      .order("desc")
      .collect();

    if (minTurns) {
      games = games.filter((g) => g.turnCount >= minTurns);
    }

    return games.map((g) => ({
      gameId: g.gameId,
      filename: `diary_${g.gameId}.jsonl`,
      label: g.civ,
      count: g.turnCount,
      hasCities: g.hasCities,
      status: g.status,
      leader: g.leader,
      lastUpdated: g.lastUpdated,
      outcome: g.outcome ?? null,
      agentModel: g.agentModel ?? null,
      score: g.agentScore ?? null,
      scenarioId: g.scenarioId ?? null,
      difficulty: g.difficulty ?? null,
      mapType: g.mapType ?? null,
      mapSize: g.mapSize ?? null,
      evalTrack: g.evalTrack ?? null,
      excludeReason: g.excludeReason ?? null,
      gitDescribe: g.gitDescribe ?? null,
      runId: g.runId ?? null,
      admissible: g.admissible ?? null,
      dimensionScores: g.dimensionScores ?? null,
    }));
  },
});

/** Get the most recently updated live game (if any) */
export const getLiveGame = query({
  args: {},
  handler: async (ctx) => {
    const live = await ctx.db
      .query("games")
      .withIndex("by_status", (q) => q.eq("status", "live"))
      .order("desc")
      .first();
    if (!live) return null;
    return {
      gameId: live.gameId,
      civ: live.civ,
      leader: live.leader,
      lastTurn: live.lastTurn,
    };
  },
});

/** Get ELO data — admissible games only. Admissibility is precomputed on the
 *  game doc by completeGame/recomputeAdmissible. */
export const getEloData = query({
  args: {},
  handler: async (ctx) => {
    const games = await ctx.db
      .query("games")
      .withIndex("by_status", (q) => q.eq("status", "completed"))
      .collect();

    return games
      .filter((g) => g.admissible === true)
      .map((g) => ({
        gameId: g.gameId,
        scenarioId: g.scenarioId ?? null,
        difficulty: g.difficulty ?? null,
        evalTrack: g.evalTrack ?? null,
        winnerCiv: g.outcome!.winnerCiv,
        players: g.eloPlayers!.map((p) => ({
          pid: p.pid,
          civ: p.civ,
          leader: p.leader,
          is_agent: p.is_agent,
          agent_model: p.agent_model,
        })),
        dimensionScores: g.dimensionScores ?? null,
      }));
  },
});

/** Game summary — metadata + sparkline series. Cheap: reads 1 doc. */
export const getGameSummary = query({
  args: { gameId: v.string() },
  handler: async (ctx, { gameId }) => {
    const game = await ctx.db
      .query("games")
      .withIndex("by_gameId", (q) => q.eq("gameId", gameId))
      .first();
    if (!game) return null;
    return {
      status: game.status,
      outcome: game.outcome ?? null,
      agentModelOverride: game.agentModelOverride ?? null,
      turnCount: game.turnCount,
      lastTurn: game.lastTurn,
      turnSeries: game.turnSeries ?? null,
      hasSpatial: game.hasSpatial ?? false,
      hasMap: game.hasMap ?? false,
      scenarioId: game.scenarioId ?? null,
      difficulty: game.difficulty ?? null,
      mapType: game.mapType ?? null,
      mapSize: game.mapSize ?? null,
      gameSpeed: game.gameSpeed ?? null,
      evalTrack: game.evalTrack ?? null,
      runId: game.runId ?? null,
      gitDescribe: game.gitDescribe ?? null,
      evalFiles: game.evalFiles ?? null,
      admissible: game.admissible ?? null,
      excludeReason: game.excludeReason ?? null,
    };
  },
});

/** All spatial attention aggregates for a game. */
export const getSpatialTurns = query({
  args: { gameId: v.string() },
  handler: async (ctx, { gameId }) => {
    return ctx.db
      .query("spatialTurns")
      .withIndex("by_game_turn", (q) => q.eq("gameId", gameId))
      .collect();
  },
});

/** Strategic map data for terrain + replay. One doc per game. */
export const getMapData = query({
  args: { gameId: v.string() },
  handler: async (ctx, { gameId }) => {
    return ctx.db
      .query("mapData")
      .withIndex("by_gameId", (q) => q.eq("gameId", gameId))
      .first();
  },
});

/** Chunked replay frames for large games. Multiple docs per game. */
export const getMapFrames = query({
  args: { gameId: v.string() },
  handler: async (ctx, { gameId }) => {
    return ctx.db
      .query("mapFrames")
      .withIndex("by_gameId_chunk", (q) => q.eq("gameId", gameId))
      .collect();
  },
});

/** Tile-level spatial attention map for hex heatmap. One doc per game. */
export const getSpatialMap = query({
  args: { gameId: v.string() },
  handler: async (ctx, { gameId }) => {
    return ctx.db
      .query("spatialMaps")
      .withIndex("by_gameId", (q) => q.eq("gameId", gameId))
      .first();
  },
});

/** Single turn's player + city rows. Reads ~12 docs instead of ~2000. */
export const getGameTurnDetail = query({
  args: { gameId: v.string(), turn: v.number() },
  handler: async (ctx, { gameId, turn }) => {
    const [playerRows, cityRows] = await Promise.all([
      ctx.db
        .query("playerRows")
        .withIndex("by_game_turn", (q) =>
          q.eq("gameId", gameId).eq("turn", turn),
        )
        .collect(),
      ctx.db
        .query("cityRows")
        .withIndex("by_game_turn", (q) =>
          q.eq("gameId", gameId).eq("turn", turn),
        )
        .collect(),
    ]);
    return { playerRows, cityRows };
  },
});
