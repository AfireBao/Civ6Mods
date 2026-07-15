"use client";

import { useQuery } from "convex/react";
import { api } from "../../convex/_generated/api";
import { useMemo } from "react";
import {
  computeElo,
  type DimensionScores,
  type EloData,
  type GameResult,
  type Participant,
} from "./elo";
import type { EloFilter } from "./use-elo";

export function useEloConvex(filter?: EloFilter): EloData {
  const raw = useQuery(api.diary.getEloData);

  return useMemo(() => {
    if (raw === undefined) return { ratings: [], gameCount: 0, loading: true, error: null };
    if (!raw || raw.length === 0)
      return { ratings: [], gameCount: 0, loading: false, error: null };

    // Apply optional filters before ELO computation
    let games = raw;
    if (filter?.scenarioId) {
      games = games.filter((g) => g.scenarioId === filter.scenarioId);
    }
    if (filter?.evalTrack) {
      games = games.filter((g) => g.evalTrack === filter.evalTrack);
    }

    const results: GameResult[] = games.map((g) => {
      const participants: Participant[] = g.players.map((p) => {
        const isAgent = p.is_agent;
        const id =
          isAgent && p.agent_model
            ? `model:${p.agent_model}`
            : `ai:${p.leader}`;
        return {
          id,
          name: isAgent && p.agent_model ? p.agent_model : p.leader,
          type: (isAgent && p.agent_model ? "model" : "ai_leader") as
            | "model"
            | "ai_leader",
          civ: p.civ,
          won: p.civ === g.winnerCiv,
        };
      });
      return { gameId: g.gameId, participants };
    });

    // Aggregate dimension scores per model
    const modelScoresMap: Record<string, DimensionScores[]> = {};
    for (const g of games) {
      if (!g.dimensionScores) continue;
      const agent = g.players.find((p) => p.is_agent && p.agent_model);
      if (!agent?.agent_model) continue;
      const model = agent.agent_model;
      if (!modelScoresMap[model]) modelScoresMap[model] = [];
      modelScoresMap[model].push(g.dimensionScores as DimensionScores);
    }

    const modelScores: Record<string, DimensionScores> = {};
    for (const [model, scores] of Object.entries(modelScoresMap)) {
      const n = scores.length;
      const avg: DimensionScores = {
        overall: 0, economic: 0, military: 0, scientific: 0,
        diplomatic: 0, spatial: 0, toolFluency: 0, coherence: 0,
      };
      for (const s of scores) {
        for (const k of Object.keys(avg) as (keyof DimensionScores)[]) {
          avg[k] += s[k] / n;
        }
      }
      for (const k of Object.keys(avg) as (keyof DimensionScores)[]) {
        avg[k] = Math.round(avg[k]);
      }
      modelScores[model] = avg;
    }

    return {
      ratings: computeElo(results),
      gameCount: results.length,
      loading: false,
      error: null,
      modelScores: Object.keys(modelScores).length > 0 ? modelScores : undefined,
    };
  }, [raw, filter?.scenarioId, filter?.evalTrack]);
}
