import type { DiaryFile } from "./diary-types";
import { getModelMeta } from "./model-registry";
import { getVictoryTypeMeta } from "@/components/game-status-badge";

export function formatTimeAgo(ms: number): string {
  const seconds = Math.floor((Date.now() - ms) / 1000);
  if (seconds < 60) return "just now";
  const minutes = Math.floor(seconds / 60);
  if (minutes < 60) return `${minutes}m ago`;
  const hours = Math.floor(minutes / 60);
  if (hours < 24) return `${hours}h ago`;
  const days = Math.floor(hours / 24);
  if (days < 30) return `${days}d ago`;
  return new Date(ms).toLocaleDateString("en-US", {
    month: "short",
    day: "numeric",
  });
}

export function deriveStatus(game: DiaryFile): string {
  if (game.status === "live") return "live";
  if (game.outcome?.result === "victory") return "victory";
  if (game.outcome?.result === "defeat") return "defeat";
  return "unfinished";
}

export function deriveProvider(game: DiaryFile): string {
  return game.agentModel ? getModelMeta(game.agentModel).provider : "Unknown";
}

export function deriveVictoryLabel(game: DiaryFile): string | null {
  if (!game.outcome?.victoryType) return null;
  return getVictoryTypeMeta(game.outcome.victoryType).label;
}

const TRACK_LABELS: Record<string, string> = {
  civbench_standard: "Standard",
  civbench_open: "Open",
  development: "Development",
};

export function formatEvalTrack(track: string): string {
  return TRACK_LABELS[track] ?? track;
}

export function formatExcludeReason(reason: string): string {
  return reason
    .replace(/-/g, " ")
    .replace(/\b\w/g, (c) => c.toUpperCase());
}

/** Clean raw enum-style names: "CIVILIZATION_BABYLON" → "Babylon", "LEADER_HAMMURABI" → "Hammurabi" */
export function cleanEnumName(raw: string): string {
  return raw
    .replace(/^CIVILIZATION_/, "")
    .replace(/^LEADER_/, "")
    .replace(/_/g, " ")
    .replace(/\b\w/g, (c) => c.toUpperCase())
    .replace(/\bStk\b/, ""); // strip "Stk" suffix from labels
}
