"use client";

import { useEffect, useRef, useState, useDeferredValue } from "react";
import { AgentOverview } from "@/components/agent-overview";
import { LeaderboardTable } from "@/components/leaderboard-table";
import { CitiesPanel } from "@/components/cities-panel";
import { MilitaryPanel } from "@/components/military-panel";
import { DiplomacyPanel } from "@/components/diplomacy-panel";
import { ProgressPanel } from "@/components/progress-panel";
import { ReflectionsPanel } from "@/components/reflections-panel";
import { SparklineSidebar } from "@/components/sparkline-sidebar";
import { useDiarySummary, useDiaryTurn } from "@/lib/use-diary";
import { OutcomeBanner, statusColor } from "@/components/game-status-badge";
import { CivSymbol } from "@/components/civ-icon";
import { useTurnNavigation } from "@/lib/use-turn-navigation";
import {
  ChevronLeft,
  ChevronRight,
  ChevronsLeft,
  ChevronsRight,
  X,
  BarChart3,
  Eye,
  Map,
} from "lucide-react";
import { SCENARIOS, DIFFICULTY_META } from "@/lib/scenarios";
import { SkeletonBlock, SkeletonLine } from "./skeleton";

interface GameDiaryViewProps {
  filename: string;
}

export function GameDiaryView({ filename }: GameDiaryViewProps) {
  const [showSidebar, setShowSidebar] = useState(false);

  // Summary subscription — 1 doc, returns sparklines + turn list + metadata
  const {
    turnSeries,
    turnNumbers,
    loading,
    outcome,
    agentModelOverride,
    scenarioId,
    difficulty,
    mapType,
    mapSize,
  } = useDiarySummary(filename);

  const scenarioDef = scenarioId ? SCENARIOS[scenarioId] : null;

  // After agent elimination, remaining turns have no agent row and render blank.
  // Trim the navigable range to the last turn the agent was alive.
  const navTurns = outcome && !outcome.playerAlive
    ? turnNumbers.filter((t) => t <= outcome.turn)
    : turnNumbers;

  const maxIdx = Math.max(0, navTurns.length - 1);
  const { index, goPrev, goNext, goFirst, goLast, seek } =
    useTurnNavigation(maxIdx);

  // Defer the turn detail fetch so the slider stays responsive during drags.
  // `index` updates immediately (smooth slider), `deferredIndex` catches up
  // when React has idle time, avoiding hundreds of Convex queries per drag.
  const deferredIndex = useDeferredValue(index);
  const selectedTurn = navTurns[deferredIndex];
  const prevTurnNum = deferredIndex > 0 ? navTurns[deferredIndex - 1] : undefined;

  const currentTurnRaw = useDiaryTurn(filename, selectedTurn, agentModelOverride);
  const prevTurnRaw = useDiaryTurn(filename, prevTurnNum, agentModelOverride);
  const isStale = deferredIndex !== index;

  // Keep showing the last valid turn data while new data loads,
  // preventing blank flashes during navigation.
  const lastCurrentRef = useRef(currentTurnRaw);
  const lastPrevRef = useRef(prevTurnRaw);
  if (currentTurnRaw) lastCurrentRef.current = currentTurnRaw;
  if (prevTurnRaw) lastPrevRef.current = prevTurnRaw;
  const currentTurn = currentTurnRaw ?? lastCurrentRef.current;
  const prevTurn = prevTurnRaw ?? lastPrevRef.current;

  const hasTurns = navTurns.length > 1;
  const isLastTurn = index === maxIdx;

  return (
    <>
      {/* Turn navigation */}
      <div className="shrink-0 border-b border-marble-300 bg-marble-50/50 px-3 py-2 sm:px-6">
        <div className="mx-auto flex max-w-4xl items-center justify-center gap-1">
          <button onClick={goFirst} disabled={index === 0} aria-label="First entry" className="rounded-sm p-2.5 text-marble-500 transition-colors hover:bg-marble-200 hover:text-marble-700 disabled:opacity-30" title="First entry (Home)">
            <ChevronsLeft className="h-5 w-5" />
          </button>
          <button onClick={goPrev} disabled={index === 0} aria-label="Previous entry" className="rounded-sm p-2.5 text-marble-500 transition-colors hover:bg-marble-200 hover:text-marble-700 disabled:opacity-30" title="Previous entry (Left arrow)">
            <ChevronLeft className="h-5 w-5" />
          </button>

          {hasTurns && (
            <input
              type="range"
              min={0}
              max={maxIdx}
              value={index}
              aria-label="Turn navigation"
              onChange={(e) => seek(parseInt(e.target.value, 10))}
              className="turn-slider mx-2 w-24 sm:w-48"
            />
          )}

          <button onClick={goNext} disabled={index >= maxIdx} aria-label="Next entry" className="rounded-sm p-2.5 text-marble-500 transition-colors hover:bg-marble-200 hover:text-marble-700 disabled:opacity-30" title="Next entry (Right arrow)">
            <ChevronRight className="h-5 w-5" />
          </button>
          <button onClick={goLast} disabled={index >= maxIdx} aria-label="Last entry" className="rounded-sm p-2.5 text-marble-500 transition-colors hover:bg-marble-200 hover:text-marble-700 disabled:opacity-30" title="Last entry (End)">
            <ChevronsRight className="h-5 w-5" />
          </button>

          {navTurns[index] !== undefined && (
            <span className={`ml-2 font-mono text-xs tabular-nums transition-opacity ${isStale ? "text-marble-400 opacity-60" : "text-marble-500"}`}>
              Turn {navTurns[index]}
            </span>
          )}
          {outcome && (
            <span
              className="ml-1.5 rounded-sm px-1.5 py-0.5 font-display text-xs font-bold uppercase tracking-[0.08em]"
              style={{
                color: statusColor(outcome.result === "victory" ? "victory" : "defeat"),
                backgroundColor: outcome.result === "victory" ? "var(--status-victory-bg)" : "var(--status-defeat-bg)",
              }}
            >
              {outcome.result === "victory" ? "Victory" : "Defeat"} T{outcome.turn}
            </span>
          )}
        </div>
      </div>

      {/* Main content */}
      <div className="flex min-h-0 flex-1">
        <div className={`flex-1 overflow-y-auto px-3 py-4 sm:px-6 sm:py-6 transition-opacity duration-150 ${isStale ? "opacity-70" : ""}`}>
          {loading && (
            <div className="mx-auto max-w-2xl space-y-4">
              {/* Agent overview skeleton */}
              <div className="rounded-sm border border-marble-300/50 bg-marble-50 p-4">
                <div className="flex items-center gap-3">
                  <SkeletonBlock className="h-10 w-10 rounded-full" />
                  <div className="flex-1 space-y-2">
                    <SkeletonLine className="w-40" />
                    <SkeletonLine className="w-24" />
                  </div>
                  <SkeletonLine className="w-16" />
                </div>
                <div className="mt-4 grid grid-cols-4 gap-3">
                  {[0, 1, 2, 3].map((i) => (
                    <SkeletonBlock key={i} className="h-12 w-full" />
                  ))}
                </div>
              </div>
              {/* Leaderboard skeleton */}
              <div className="rounded-sm border border-marble-300/50 bg-marble-50 p-4">
                <SkeletonLine className="mb-3 w-28" />
                {[0, 1, 2, 3].map((i) => (
                  <div key={i} className="flex items-center gap-3 py-2">
                    <SkeletonBlock className="h-5 w-5 rounded-full" />
                    <SkeletonLine className="w-28" />
                    <div className="flex-1" />
                    <SkeletonLine className="w-12" />
                  </div>
                ))}
              </div>
              {/* Panel skeletons */}
              {[0, 1].map((i) => (
                <SkeletonBlock key={i} className="h-24 w-full" />
              ))}
            </div>
          )}

          {!loading && turnNumbers.length === 0 && (
            <div className="flex h-full items-center justify-center">
              <div className="flex flex-col items-center gap-3 text-center">
                <Map className="h-8 w-8 text-marble-300" />
                <p className="font-display text-sm tracking-[0.08em] uppercase text-marble-500">
                  The scribes await
                </p>
                <p className="text-sm text-marble-400">
                  Start a game with diary enabled to record your empire&apos;s history.
                </p>
              </div>
            </div>
          )}

          {!loading && currentTurn && (
            <>
              {outcome && isLastTurn && (
                <div className="mx-auto mb-4 w-full max-w-2xl">
                  <OutcomeBanner outcome={outcome} />
                </div>
              )}
              {scenarioDef && index === 0 && (
                <div className="mx-auto mb-4 w-full max-w-2xl">
                  <div
                    className="flex items-stretch gap-0 rounded-sm border border-marble-300/50 bg-marble-50"
                  >
                    <div
                      className="w-1.5 shrink-0 rounded-l-sm"
                      style={{ backgroundColor: DIFFICULTY_META[scenarioDef.difficulty]?.color }}
                    />
                    <div className="flex-1 px-3 py-2.5 space-y-1">
                      <div className="flex items-center gap-2">
                        <span
                          className="inline-flex items-center gap-1 rounded-sm px-1.5 py-0.5 text-xs font-bold uppercase tracking-[0.08em]"
                          style={{
                            color: DIFFICULTY_META[scenarioDef.difficulty]?.color,
                            backgroundColor: `${DIFFICULTY_META[scenarioDef.difficulty]?.color}15`,
                          }}
                        >
                          <span
                            className="inline-block h-1.5 w-1.5 rounded-full"
                            style={{ backgroundColor: DIFFICULTY_META[scenarioDef.difficulty]?.color }}
                          />
                          {difficulty ?? scenarioDef.difficulty}
                        </span>
                        <span className="font-display text-sm font-bold uppercase tracking-[0.08em] text-marble-800">
                          {scenarioDef.name}
                        </span>
                      </div>
                      <div className="flex items-center gap-3 text-xs text-marble-500">
                        <span className="flex items-center gap-1">
                          <CivSymbol civ={scenarioDef.civilization} className="h-3 w-3" />
                          {scenarioDef.civilization} ({scenarioDef.leader})
                        </span>
                        <span className="flex items-center gap-1">
                          <Map className="h-2.5 w-2.5" />
                          {mapType ?? scenarioDef.mapType}, {mapSize ?? scenarioDef.mapSize}
                        </span>
                      </div>
                      <div className="flex items-center gap-1 text-xs text-marble-500">
                        <Eye className="h-2.5 w-2.5" />
                        Tests: {scenarioDef.blindSpot}
                      </div>
                    </div>
                  </div>
                </div>
              )}
              <AgentOverview
                turnData={currentTurn}
                prevTurnData={prevTurn ?? undefined}
                index={index}
                total={navTurns.length}
              />
              <LeaderboardTable
                turnData={currentTurn}
                prevTurnData={prevTurn ?? undefined}
              />
              <CitiesPanel cities={currentTurn.agentCities} />
              <MilitaryPanel agent={currentTurn.agent} prevAgent={prevTurn?.agent} />
              <DiplomacyPanel agent={currentTurn.agent} />
              <ProgressPanel agent={currentTurn.agent} prevAgent={prevTurn?.agent} scenarioId={scenarioId ?? undefined} />
              <ReflectionsPanel reflections={currentTurn.agent.reflections} />
            </>
          )}
        </div>

        {/* Sparkline sidebar — desktop */}
        {hasTurns && turnSeries && (
          <div className="hidden w-80 shrink-0 overflow-y-auto border-l border-marble-300 bg-marble-50 p-4 lg:block xl:w-96">
            <SparklineSidebar turnSeries={turnSeries} currentIndex={index} />
          </div>
        )}

        {/* Sparkline sidebar — mobile overlay */}
        {hasTurns && turnSeries && showSidebar && (
          <MobileSidebar onClose={() => setShowSidebar(false)}>
            <SparklineSidebar turnSeries={turnSeries} currentIndex={index} />
          </MobileSidebar>
        )}

        {/* Mobile chart toggle */}
        {hasTurns && (
          <button
            onClick={() => setShowSidebar(true)}
            className="fixed bottom-4 right-4 z-30 flex h-11 w-11 items-center justify-center rounded-full border border-marble-300 bg-marble-50 text-marble-600 shadow-md transition-colors hover:bg-marble-100 lg:hidden"
            aria-label="Show trends"
          >
            <BarChart3 className="h-5 w-5" />
          </button>
        )}
      </div>
    </>
  );
}

/** Accessible mobile sidebar overlay with focus trap and Escape key. */
function MobileSidebar({
  onClose,
  children,
}: {
  onClose: () => void;
  children: React.ReactNode;
}) {
  const panelRef = useRef<HTMLDivElement>(null);

  // Close on Escape
  useEffect(() => {
    const handler = (e: KeyboardEvent) => {
      if (e.key === "Escape") onClose();
    };
    document.addEventListener("keydown", handler);
    return () => document.removeEventListener("keydown", handler);
  }, [onClose]);

  // Focus the panel on mount
  useEffect(() => {
    panelRef.current?.focus();
  }, []);

  return (
    <div
      className="fixed inset-0 z-40 flex lg:hidden"
      role="dialog"
      aria-modal="true"
      aria-label="Trend charts"
    >
      <div className="absolute inset-0 bg-black/30" onClick={onClose} />
      <div
        ref={panelRef}
        tabIndex={-1}
        className="relative ml-auto h-full w-80 max-w-[85vw] overflow-y-auto bg-marble-50 p-4 shadow-lg outline-none"
      >
        <button
          onClick={onClose}
          className="absolute right-3 top-3 flex h-8 w-8 items-center justify-center rounded-sm text-marble-500 hover:bg-marble-200 hover:text-marble-700"
          aria-label="Close trends"
        >
          <X className="h-4 w-4" />
        </button>
        {children}
      </div>
    </div>
  );
}
