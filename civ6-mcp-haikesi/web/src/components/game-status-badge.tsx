"use client";

import type { LucideIcon } from "lucide-react";
import {
  Trophy,
  Skull,
  FlaskConical,
  Swords,
  Church,
  Landmark,
  Luggage,
  Timer,
} from "lucide-react";
import type { GameOutcome } from "@/lib/diary-types";
import { CIV6_COLORS } from "@/lib/civ-colors";
import { CivIcon, CivSymbol } from "./civ-icon";
import { PulsingDot } from "./pulsing-dot";

const STATUS_COLORS: Record<string, string> = {
  live: "var(--status-live)",
  victory: "var(--status-victory)",
  defeat: "var(--status-defeat)",
  unfinished: "var(--status-unfinished)",
};

/** Returns a color for a simple status string (live, victory, defeat, unfinished). */
export function statusColor(status: string): string {
  return STATUS_COLORS[status] ?? STATUS_COLORS.unfinished;
}

/** Returns the semantic color for a game's current state. */
export function getGameStatusColor(
  status?: "live" | "completed",
  outcome?: GameOutcome | null,
): string {
  if (status === "live") return statusColor("live");
  if (outcome?.result === "victory") return statusColor("victory");
  if (outcome?.result === "defeat") return statusColor("defeat");
  return statusColor("unfinished");
}

interface VictoryMeta {
  icon: LucideIcon;
  color: string;
  label: string;
}

const VICTORY_TYPE_MAP: Record<string, VictoryMeta> = {
  technology: { icon: FlaskConical, color: CIV6_COLORS.science, label: "Science" },
  science: { icon: FlaskConical, color: CIV6_COLORS.science, label: "Science" },
  conquest: { icon: Swords, color: CIV6_COLORS.military, label: "Domination" },
  domination: { icon: Swords, color: CIV6_COLORS.military, label: "Domination" },
  religious: { icon: Church, color: CIV6_COLORS.faith, label: "Religious" },
  diplomatic: { icon: Landmark, color: CIV6_COLORS.favor, label: "Diplomatic" },
  culture: { icon: Luggage, color: CIV6_COLORS.tourism, label: "Cultural" },
  cultural: { icon: Luggage, color: CIV6_COLORS.tourism, label: "Cultural" },
  score: { icon: Trophy, color: CIV6_COLORS.goldMetal, label: "Score" },
  elimination: { icon: Skull, color: CIV6_COLORS.military, label: "Eliminated" },
  turnlimit: { icon: Timer, color: CIV6_COLORS.goldMetal, label: "Time" },
};

const FALLBACK_VICTORY: VictoryMeta = {
  icon: Trophy,
  color: CIV6_COLORS.goldMetal,
  label: "Unknown",
};

/** Resolve victory type string to icon, color, and display label. */
export function getVictoryTypeMeta(victoryType?: string): VictoryMeta {
  if (!victoryType) return FALLBACK_VICTORY;
  return VICTORY_TYPE_MAP[victoryType.toLowerCase()] ?? { ...FALLBACK_VICTORY, label: victoryType };
}

interface GameStatusBadgeProps {
  status?: "live" | "completed";
  outcome?: GameOutcome | null;
  turnCount: number;
}

export function GameStatusBadge({
  status,
  outcome,
  turnCount,
}: GameStatusBadgeProps) {
  if (status === "live") {
    return (
      <div className="text-right">
        <div className="flex items-center justify-end gap-1.5">
          <PulsingDot />
          <span className="font-display text-xs font-bold uppercase tracking-[0.08em] text-patina">
            Live
          </span>
          <span className="font-mono text-xs tabular-nums text-marble-500">
            T{turnCount}
          </span>
        </div>
      </div>
    );
  }

  if (outcome) {
    const isVictory = outcome.result === "victory";
    const vt = getVictoryTypeMeta(outcome.victoryType);
    const Icon = vt.icon;
    return (
      <div className="shrink-0 text-right">
        <div className="flex items-center justify-end gap-1">
          <span
            className="font-display text-xs font-bold uppercase tracking-[0.08em] whitespace-nowrap"
            style={{ color: isVictory ? STATUS_COLORS.victory : STATUS_COLORS.defeat }}
          >
            {isVictory ? "Victory" : "Defeated"}
          </span>
          {outcome.turn != null && (
            <span className="font-mono text-xs tabular-nums text-marble-500">
              T{outcome.turn}
            </span>
          )}
        </div>
        <div className="mt-0.5 flex items-center justify-end gap-1">
          <CivIcon icon={Icon} color={vt.color} size="sm" />
          <span className="text-xs truncate max-w-[5rem]" style={{ color: vt.color }}>{vt.label}</span>
        </div>
      </div>
    );
  }

  return (
    <div className="text-right">
      <span className="font-mono text-xs tabular-nums text-marble-500">
        T{turnCount}
      </span>
    </div>
  );
}

// ── Outcome banner (used in diary view) ──────────────────────────────────────

export function OutcomeBanner({ outcome }: { outcome: GameOutcome }) {
  const isVictory = outcome.result === "victory";
  const vt = getVictoryTypeMeta(outcome.victoryType);
  const VtIcon = vt.icon;
  const bgColor = isVictory
    ? "var(--status-victory-bg)"
    : "var(--status-defeat-bg)";
  const borderColor = isVictory
    ? "var(--status-victory-border)"
    : "var(--status-defeat-border)";
  const headColor = isVictory
    ? STATUS_COLORS.victory
    : STATUS_COLORS.defeat;

  return (
    <div
      role="status"
      aria-label={isVictory ? `Victory: ${vt.label}` : `Defeat: ${vt.label} victory by ${outcome.winnerCiv}`}
      className="mx-auto w-full max-w-2xl animate-[banner-enter_0.4s_ease-out] rounded-sm border px-4 py-3 motion-reduce:animate-none"
      style={{
        backgroundColor: bgColor,
        borderColor,
        ...(isVictory ? { animation: "banner-enter 0.4s ease-out, victory-glow 3s ease-in-out 0.5s infinite" } : {}),
      }}
    >
      <div className="flex items-center gap-3">
        <CivIcon
          icon={isVictory ? Trophy : Skull}
          color={headColor}
          size="md"
        />
        <div className="flex-1">
          <div className="flex items-center gap-2">
            <span
              className="font-display text-base font-bold uppercase tracking-[0.08em]"
              style={{ color: headColor }}
            >
              {isVictory ? "Victory" : "Defeated"}
            </span>
            <span className="font-mono text-xs tabular-nums text-marble-500">
              Turn {outcome.turn}
            </span>
          </div>
          <div className="mt-0.5 flex items-center gap-1.5">
            <CivIcon icon={VtIcon} color={vt.color} size="sm" />
            <span className="text-xs" style={{ color: vt.color }}>
              {vt.label} Victory
            </span>
            <span className="text-xs text-marble-500">—</span>
            <CivSymbol civ={outcome.winnerCiv} className="h-3.5 w-3.5" />
            <span className="text-xs text-marble-700">
              {outcome.winnerCiv} ({outcome.winnerLeader})
            </span>
          </div>
        </div>
      </div>
    </div>
  );
}
