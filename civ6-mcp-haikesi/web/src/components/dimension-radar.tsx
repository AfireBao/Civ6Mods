"use client";

import {
  RadarChart,
  PolarGrid,
  PolarAngleAxis,
  PolarRadiusAxis,
  Radar,
  Tooltip,
  ResponsiveContainer,
} from "recharts";
import {
  Trophy,
  Coins,
  Swords,
  FlaskConical,
  Handshake,
  Map,
  Wrench,
  Brain,
  type LucideIcon,
} from "lucide-react";
import { CIV6_COLORS } from "@/lib/civ-colors";

export interface DimensionScores {
  overall: number;
  economic: number;
  military: number;
  scientific: number;
  diplomatic: number;
  spatial: number;
  toolFluency: number;
  coherence: number;
}

export const DIMENSIONS: {
  key: keyof DimensionScores;
  label: string;
  icon: LucideIcon;
  color: string;
}[] = [
  { key: "overall", label: "Overall", icon: Trophy, color: CIV6_COLORS.goldMetal },
  { key: "economic", label: "Economic", icon: Coins, color: CIV6_COLORS.gold },
  { key: "military", label: "Military", icon: Swords, color: CIV6_COLORS.military },
  { key: "scientific", label: "Science", icon: FlaskConical, color: CIV6_COLORS.science },
  { key: "diplomatic", label: "Diplomacy", icon: Handshake, color: CIV6_COLORS.favor },
  { key: "spatial", label: "Spatial", icon: Map, color: CIV6_COLORS.spatial },
  { key: "toolFluency", label: "Tool Use", icon: Wrench, color: CIV6_COLORS.production },
  { key: "coherence", label: "Coherence", icon: Brain, color: CIV6_COLORS.culture },
];

// Custom tick renderer: icon at each axis endpoint
function IconTick({
  payload,
  x,
  y,
}: {
  payload: { value: string };
  x: number;
  y: number;
}) {
  const dim = DIMENSIONS.find((d) => d.label === payload.value);
  if (!dim) return null;
  const Icon = dim.icon;
  const iconSize = 13;
  return (
    <g transform={`translate(${x - iconSize / 2},${y - iconSize / 2})`}>
      <title>{dim.label}</title>
      <Icon
        width={iconSize}
        height={iconSize}
        stroke={dim.color}
        strokeWidth={1.5}
        aria-label={dim.label}
        role="img"
      />
    </g>
  );
}

interface DimensionRadarProps {
  scores: DimensionScores;
  color: string;
  size?: number;
}

export function DimensionRadar({
  scores,
  color,
  size = 220,
}: DimensionRadarProps) {
  const data = DIMENSIONS.map((d) => ({
    dimension: d.label,
    value: Math.round(scores[d.key]),
  }));

  return (
    <ResponsiveContainer width={size} height={size}>
      <RadarChart data={data} cx="50%" cy="50%" outerRadius="78%">
        <PolarGrid stroke="var(--color-marble-200, #d4cfc3)" />
        <PolarAngleAxis
          dataKey="dimension"
          tick={IconTick as any}
        />
        <PolarRadiusAxis
          domain={[0, 100]}
          tick={false}
          axisLine={false}
        />
        <Radar
          dataKey="value"
          stroke={color}
          fill={color}
          fillOpacity={0.15}
          strokeWidth={1.5}
        />
        <Tooltip
          contentStyle={{
            fontSize: 12,
            backgroundColor: "var(--color-marble-50, #f5f2ec)",
            border: "1px solid var(--color-marble-300, #c4bfb1)",
            borderRadius: 2,
          }}
          formatter={(value) => [`${value ?? 0}`, "Score"]}
        />
      </RadarChart>
    </ResponsiveContainer>
  );
}

export function averageDimensionScores(
  allScores: (DimensionScores | null | undefined)[],
): DimensionScores | null {
  const valid = allScores.filter(
    (s): s is DimensionScores => s != null,
  );
  if (valid.length === 0) return null;

  const sum: DimensionScores = {
    overall: 0, economic: 0, military: 0, scientific: 0,
    diplomatic: 0, spatial: 0, toolFluency: 0, coherence: 0,
  };
  for (const s of valid) {
    for (const key of Object.keys(sum) as (keyof DimensionScores)[]) {
      sum[key] += s[key];
    }
  }
  const n = valid.length;
  return {
    overall: Math.round(sum.overall / n),
    economic: Math.round(sum.economic / n),
    military: Math.round(sum.military / n),
    scientific: Math.round(sum.scientific / n),
    diplomatic: Math.round(sum.diplomatic / n),
    spatial: Math.round(sum.spatial / n),
    toolFluency: Math.round(sum.toolFluency / n),
    coherence: Math.round(sum.coherence / n),
  };
}
