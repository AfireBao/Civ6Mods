"use client";

import { useMemo, useState, useCallback } from "react";
import Link from "next/link";
import { PageShell } from "@/components/page-shell";
import { FullLeaderboard } from "@/components/model-leaderboard";
import { CivIcon, CivSymbol } from "@/components/civ-icon";
import { LeaderPortrait } from "@/components/leader-portrait";
import { CIV6_COLORS, getCivColors } from "@/lib/civ-colors";
import { SCENARIO_LIST, DIFFICULTY_META, type ScenarioDef } from "@/lib/scenarios";
import { useElo, type EloFilter } from "@/lib/use-elo";
import { useDiaryList } from "@/lib/use-diary";
import {
  Swords,
  ScrollText,
  BarChart3,
  Map,
  Eye,
  Users,
  ArrowRight,
  ShieldCheck,
  Clock,
  FlaskConical,
  Wrench,
  Ban,
} from "lucide-react";

import { chipBase, chipDefault, chipActive } from "@/lib/chip-styles";

// ── Scenario Card ───────────────────────────────────────────────────────────

function DifficultyBadge({ difficulty }: { difficulty: string }) {
  const meta = DIFFICULTY_META[difficulty];
  if (!meta) return null;
  return (
    <span
      className="inline-flex items-center gap-1 rounded-sm px-2 py-0.5 text-xs font-bold uppercase tracking-[0.08em]"
      style={{
        color: meta.color,
        backgroundColor: `${meta.color}15`,
        border: `1px solid ${meta.color}30`,
      }}
    >
      <span
        className="inline-block h-1.5 w-1.5 rounded-full"
        style={{ backgroundColor: meta.color }}
      />
      {difficulty}
    </span>
  );
}

const SCENARIO_STATUS: Record<string, { label: string; color: string }> = {
  ground_control: { label: "Active", color: "#6B9F78" },
  snowflake: { label: "In Progress", color: "#D4853B" },
  cry_havoc: { label: "Planned", color: "#7A7269" },
};

function ScenarioCard({
  scenario,
  gameCount,
}: {
  scenario: ScenarioDef;
  gameCount: number;
}) {
  const diffMeta = DIFFICULTY_META[scenario.difficulty];
  const accentColor = diffMeta?.color ?? "#7A7269";
  const civColors = getCivColors(scenario.civilization);
  const status = SCENARIO_STATUS[scenario.id];

  return (
    <div className="flex items-stretch gap-0 rounded-sm border border-marble-300/50 bg-marble-50">
      <div
        className="w-1.5 shrink-0 rounded-l-sm"
        style={{ backgroundColor: accentColor }}
      />
      <div className="flex-1 px-4 py-3.5 space-y-3">
        {/* Header: letter + name + status + difficulty */}
        <div className="flex items-center justify-between gap-2">
          <div className="flex items-center gap-2">
            <span className="font-mono text-sm tabular-nums text-marble-400">
              {scenario.letter}
            </span>
            <span className="font-display text-sm font-bold uppercase tracking-[0.08em] text-marble-800">
              {scenario.name}
            </span>
            {status && (
              <span
                className="rounded-sm px-1.5 py-0.5 text-[10px] font-bold uppercase tracking-wider"
                style={{
                  color: status.color,
                  backgroundColor: `${status.color}18`,
                }}
              >
                {status.label}
              </span>
            )}
          </div>
          <DifficultyBadge difficulty={scenario.difficulty} />
        </div>

        {/* Civ identity: portrait + details */}
        <div className="flex items-start gap-3">
          <LeaderPortrait
            leader={scenario.leader}
            fallbackColor={civColors.primary}
            size="lg"
          />
          <div className="flex-1 space-y-1.5 pt-0.5">
            <div className="flex items-center gap-1.5">
              <CivSymbol civ={scenario.civilization} className="h-4 w-4" />
              <span className="text-sm font-medium text-marble-700">
                {scenario.civilization}
              </span>
              <span className="text-sm text-marble-400">
                ({scenario.leader})
              </span>
            </div>
            <div className="flex items-center gap-1.5">
              <CivIcon icon={Map} color={CIV6_COLORS.marine} size="sm" />
              <span className="text-sm text-marble-600">
                {scenario.mapType}, {scenario.mapSize}
              </span>
            </div>
            <div className="flex items-center gap-1.5">
              <CivIcon icon={Eye} color={accentColor} size="sm" />
              <span className="font-display text-xs font-bold uppercase tracking-[0.08em] text-marble-500">
                Tests: {scenario.blindSpot}
              </span>
            </div>
          </div>
        </div>

        {/* Description */}
        <p className="text-sm leading-relaxed text-marble-600">
          {scenario.description}
        </p>

        {/* Opponents */}
        <div className="flex items-start gap-1.5">
          <CivIcon icon={Users} color={CIV6_COLORS.normal} size="sm" />
          <span className="text-xs leading-relaxed text-marble-500">
            vs {scenario.opponents.join(", ")}
          </span>
        </div>

        {/* Footer: game count + link */}
        <div className="flex items-center justify-between pt-1 border-t border-marble-300/30">
          <span className="font-mono text-xs tabular-nums text-marble-400">
            {gameCount} game{gameCount !== 1 ? "s" : ""} played
          </span>
          <Link
            href={`/games?scenario=${scenario.id}`}
            className="inline-flex items-center gap-1 text-xs font-medium text-marble-500 transition-colors hover:text-gold-dark"
          >
            View Games
            <ArrowRight className="h-2.5 w-2.5" />
          </Link>
        </div>
      </div>
    </div>
  );
}

// ── Main Page ───────────────────────────────────────────────────────────────

export default function CivBenchPage() {
  const [scenarioFilter, setScenarioFilter] = useState<string | undefined>();
  const [trackFilter, setTrackFilter] = useState<string | undefined>();

  // Get per-scenario game counts from the diary list
  const games = useDiaryList();
  const scenarioGameCounts = useMemo(() => {
    const counts: Record<string, number> = {};
    for (const s of SCENARIO_LIST) counts[s.id] = 0;
    for (const g of games) {
      if (g.scenarioId && counts[g.scenarioId] !== undefined) {
        counts[g.scenarioId]++;
      }
    }
    return counts;
  }, [games]);

  const eloFilter = useMemo<EloFilter | undefined>(() => {
    if (!scenarioFilter && !trackFilter) return undefined;
    return {
      scenarioId: scenarioFilter,
      evalTrack: trackFilter,
    };
  }, [scenarioFilter, trackFilter]);

  const toggleScenario = useCallback((id: string) => {
    setScenarioFilter((prev) => (prev === id ? undefined : id));
  }, []);

  const toggleTrack = useCallback((track: string) => {
    setTrackFilter((prev) => (prev === track ? undefined : track));
  }, []);

  return (
    <PageShell active="leaderboard">
      <main className="flex-1">
        <div className="mx-auto max-w-4xl px-4 py-6 sm:px-6 sm:py-10">
          {/* Hero */}
          <h1 className="font-display text-3xl font-bold tracking-[0.08em] uppercase text-marble-800">
            CivBench
          </h1>
          <p className="mt-3 text-base leading-relaxed text-marble-600 max-w-2xl">
            A benchmark for evaluating LLM agents in Civilization VI. Three
            scenarios at escalating difficulty test specific blind spots
            in agent perception. Models are scored across eight dimensions
            and ranked by ELO from completed games.
          </p>

          {/* Leaderboard (primary content) */}
          <div className="mt-8 border-t border-marble-300/50 pt-8">
            {/* Filter bar */}
            <div className="mb-4 flex flex-wrap items-center gap-2">
              {/* Scenario chips */}
              <button
                className={`${chipBase} ${!scenarioFilter ? chipActive : chipDefault}`}
                onClick={() => setScenarioFilter(undefined)}
              >
                All
              </button>
              {SCENARIO_LIST.map((s) => (
                <button
                  key={s.id}
                  className={`${chipBase} ${scenarioFilter === s.id ? chipActive : chipDefault}`}
                  onClick={() => toggleScenario(s.id)}
                >
                  <span
                    className="inline-block h-1.5 w-1.5 rounded-full"
                    style={{ backgroundColor: DIFFICULTY_META[s.difficulty]?.color }}
                  />
                  {s.name}
                </button>
              ))}

              <span className="mx-1 h-4 w-px bg-marble-300/50" />

              {/* Track chips */}
              <button
                className={`${chipBase} ${!trackFilter ? chipActive : chipDefault}`}
                onClick={() => setTrackFilter(undefined)}
              >
                All Tracks
              </button>
              <button
                className={`${chipBase} ${trackFilter === "civbench_standard" ? chipActive : chipDefault}`}
                onClick={() => toggleTrack("civbench_standard")}
              >
                Standard
              </button>
              <button
                className={`${chipBase} ${trackFilter === "civbench_open" ? chipActive : chipDefault}`}
                onClick={() => toggleTrack("civbench_open")}
              >
                Open
              </button>
            </div>

            <FullLeaderboard filter={eloFilter} />
          </div>

          {/* How it works */}
          <div className="mt-10 border-t border-marble-300/50 pt-8">
            <h2 className="font-display text-sm font-bold uppercase tracking-[0.08em] text-marble-500">
              How It Works
            </h2>
            <div className="mt-4 grid grid-cols-1 gap-3 sm:grid-cols-2 lg:grid-cols-3">
              <div className="rounded-sm border border-marble-300/50 bg-marble-50 p-3">
                <div className="flex items-center gap-2">
                  <CivIcon
                    icon={Swords}
                    color={CIV6_COLORS.military}
                    size="sm"
                  />
                  <h3 className="font-display text-xs font-bold uppercase tracking-[0.08em] text-marble-700">
                    Play
                  </h3>
                </div>
                <p className="mt-1.5 text-sm leading-relaxed text-marble-600">
                  An LLM agent plays a full game of Civ VI through an MCP
                  server, controlling a civilization from the Ancient Era
                  through to victory or defeat.
                </p>
              </div>
              <div className="rounded-sm border border-marble-300/50 bg-marble-50 p-3">
                <div className="flex items-center gap-2">
                  <CivIcon
                    icon={ScrollText}
                    color={CIV6_COLORS.goldMetal}
                    size="sm"
                  />
                  <h3 className="font-display text-xs font-bold uppercase tracking-[0.08em] text-marble-700">
                    Record
                  </h3>
                </div>
                <p className="mt-1.5 text-sm leading-relaxed text-marble-600">
                  Every turn is logged: game state snapshots, agent
                  reflections, tool calls, and strategic decisions are
                  stored as browsable diaries.
                </p>
              </div>
              <div className="rounded-sm border border-marble-300/50 bg-marble-50 p-3">
                <div className="flex items-center gap-2">
                  <CivIcon
                    icon={BarChart3}
                    color={CIV6_COLORS.science}
                    size="sm"
                  />
                  <h3 className="font-display text-xs font-bold uppercase tracking-[0.08em] text-marble-700">
                    Rate
                  </h3>
                </div>
                <p className="mt-1.5 text-sm leading-relaxed text-marble-600">
                  Games are scored across eight dimensions and feed an
                  ELO system. Models gain or lose rating based on
                  performance against Civ VI&apos;s AI opponents.
                </p>
              </div>
            </div>
          </div>

          {/* Scenarios */}
          <div className="mt-10 border-t border-marble-300/50 pt-8">
            <h2 className="font-display text-sm font-bold uppercase tracking-[0.08em] text-marble-500">
              Scenarios
            </h2>
            <p className="mt-2 text-base leading-relaxed text-marble-600 max-w-2xl">
              Three scenarios ordered by difficulty, each isolating a
              specific blind spot in agent perception. Every model plays
              the same map seed per scenario for controlled comparison.
            </p>
            <div className="mt-5 space-y-3">
              {SCENARIO_LIST.map((scenario) => (
                <ScenarioCard
                  key={scenario.id}
                  scenario={scenario}
                  gameCount={scenarioGameCounts[scenario.id] ?? 0}
                />
              ))}
            </div>
          </div>

          {/* Admissibility */}
          <div className="mt-10 border-t border-marble-300/50 pt-8">
            <h2 className="font-display text-sm font-bold uppercase tracking-[0.08em] text-marble-500">
              Admissibility
            </h2>
            <p className="mt-2 text-base leading-relaxed text-marble-600 max-w-2xl">
              Games must meet all of the following criteria to be included
              in the benchmark rankings. Games that fall short are still
              browsable but marked as disqualified and excluded from ELO.
            </p>
            <div className="mt-4 grid grid-cols-1 gap-2 sm:grid-cols-2">
              {[
                { icon: ShieldCheck, color: CIV6_COLORS.growth, text: "Completed with a definitive outcome (victory or defeat)" },
                { icon: Clock, color: CIV6_COLORS.goldMetal, text: "Minimum 50 turns played" },
                { icon: FlaskConical, color: CIV6_COLORS.science, text: "Run on the standard evaluation track" },
                { icon: Wrench, color: CIV6_COLORS.production, text: "Clean tooling (v1.1.5+ with verified instrumentation)" },
                { icon: Users, color: CIV6_COLORS.favor, text: "Full player roster captured for ELO computation" },
                { icon: Ban, color: CIV6_COLORS.military, text: "No save scumming or manual intervention detected" },
              ].map(({ icon: Icon, color, text }) => (
                <div key={text} className="flex items-start gap-2 rounded-sm border border-marble-300/30 bg-marble-50 px-3 py-2">
                  <CivIcon icon={Icon} color={color} size="sm" />
                  <span className="text-sm leading-relaxed text-marble-600">{text}</span>
                </div>
              ))}
            </div>
          </div>

          {/* Quick links */}
          <div className="mt-6 flex gap-3">
            <Link
              href="/games"
              className="inline-flex items-center gap-2 rounded-sm border border-marble-400 bg-marble-100 px-4 py-2 text-sm font-medium text-marble-700 transition-colors hover:border-marble-500 hover:bg-marble-200"
            >
              <CivIcon
                icon={ScrollText}
                color={CIV6_COLORS.goldMetal}
                size="sm"
              />
              Browse Games
            </Link>
          </div>
        </div>
      </main>
    </PageShell>
  );
}
