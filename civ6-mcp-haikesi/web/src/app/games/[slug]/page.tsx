"use client";

import dynamic from "next/dynamic";
import { useParams, useSearchParams, useRouter } from "next/navigation";
import { Download } from "lucide-react";
import { PageShell } from "@/components/page-shell";
import { AdmissibilityBadge } from "@/components/admissibility-badge";
import { TooltipProvider } from "@/components/ui/tooltip";
import { GameDiaryView } from "@/components/game-diary-view";
import { useDiarySummary } from "@/lib/use-diary";
import { SkeletonBlock } from "@/components/skeleton";

const StrategicMap = dynamic(
  () => import("@/components/strategic-map").then((m) => m.StrategicMap),
  { ssr: false, loading: () => <SkeletonBlock className="h-[600px] w-full" /> },
);

type Tab = "diary" | "map";

const BLOB_BASE = process.env.NEXT_PUBLIC_BLOB_BASE_URL;

function TabButton({ tab, active, label, setTab }: { tab: Tab; active: Tab; label: string; setTab: (t: Tab) => void }) {
  return (
    <button
      role="tab"
      id={`tab-${tab}`}
      aria-selected={active === tab}
      aria-controls={`tabpanel-${tab}`}
      onClick={() => setTab(tab)}
      className={`border-b-2 px-4 py-2 text-sm font-medium transition-colors ${
        active === tab
          ? "border-gold-dark text-gold-dark"
          : "border-transparent text-marble-500 hover:text-marble-700"
      }`}
    >
      {label}
    </button>
  );
}

export default function GameDetailPage() {
  const params = useParams<{ slug: string }>();
  const searchParams = useSearchParams();
  const router = useRouter();

  const slug = params.slug;
  const filename = `diary_${slug}.jsonl`;
  const rawTab = searchParams.get("tab");
  const tab: Tab =
    rawTab === "spatial" || rawTab === "map" ? "map" :
    "diary";

  const { runId, evalFiles, evalTrack, gitDescribe, admissible, excludeReason, status } = useDiarySummary(filename);
  const logUrl = BLOB_BASE && runId ? `${BLOB_BASE}/runs/${runId}/log.jsonl` : null;

  const setTab = (t: Tab) => {
    const url = t === "diary" ? `/games/${slug}` : `/games/${slug}?tab=${t}`;
    router.replace(url);
  };

  return (
    <PageShell active="games" footer={false}>

      {/* Tab bar */}
      <div className="shrink-0 border-b border-marble-300 bg-marble-50 px-3 sm:px-6">
        <div className="mx-auto flex max-w-4xl items-center" role="tablist">
          <TabButton tab="diary" active={tab} label="Diary" setTab={setTab} />
          <TabButton tab="map" active={tab} label="Map" setTab={setTab} />
          <div className="ml-auto flex items-center gap-2">
            {runId && (
              <TooltipProvider>
              <span className="flex items-center gap-1 font-mono text-[10px] text-marble-400">
                {runId}
                <AdmissibilityBadge
                  admissible={admissible}
                  excludeReason={excludeReason}
                  status={status}
                  evalTrack={evalTrack}
                />
              </span>
              </TooltipProvider>
            )}
            {evalTrack && evalTrack !== "civbench_standard" && (
              <span className="rounded-sm bg-marble-200 px-1.5 py-0.5 text-[10px] font-medium uppercase tracking-wider text-marble-500">
                {evalTrack === "development" ? "Dev" : evalTrack}
              </span>
            )}
            {gitDescribe && (
              <span className="font-mono text-[10px] text-marble-300">{gitDescribe}</span>
            )}
            {logUrl && (
              <a
                href={logUrl}
                target="_blank"
                rel="noopener noreferrer"
                className="inline-flex items-center gap-1.5 border-b-2 border-transparent px-4 py-2 text-sm font-medium text-marble-500 transition-colors hover:text-marble-700"
              >
                <Download className="h-3.5 w-3.5" />
                Turn Log
              </a>
            )}
            {BLOB_BASE && runId && evalFiles && evalFiles.length > 0 && (
              <a
                href={`${BLOB_BASE}/runs/${runId}/${evalFiles[evalFiles.length - 1]}`}
                target="_blank"
                rel="noopener noreferrer"
                className="inline-flex items-center gap-1.5 border-b-2 border-transparent px-4 py-2 text-sm font-medium text-marble-500 transition-colors hover:text-marble-700"
              >
                <Download className="h-3.5 w-3.5" />
                Eval Log
              </a>
            )}
          </div>
        </div>
      </div>

      {/* Tab content */}
      {tab === "diary" ? (
        <div role="tabpanel" id="tabpanel-diary" aria-labelledby="tab-diary" className="flex min-h-0 flex-1 flex-col">
          <GameDiaryView filename={filename} />
        </div>
      ) : (
        <div role="tabpanel" id="tabpanel-map" aria-labelledby="tab-map" className="flex min-h-0 flex-1 flex-col">
          <StrategicMap gameId={slug} />
        </div>
      )}
    </PageShell>
  );
}
