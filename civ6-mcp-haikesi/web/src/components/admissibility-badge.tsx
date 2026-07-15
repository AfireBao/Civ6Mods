"use client";

import { ShieldCheck, ShieldX, Clock } from "lucide-react";
import {
  Tooltip,
  TooltipTrigger,
  TooltipContent,
} from "@/components/ui/tooltip";

const EXCLUDE_LABELS: Record<string, string> = {
  save_scumming: "Save scumming detected",
  "pre-v1.1.5-dirty-tooling": "Pre-v1.1.5 tooling",
  "pre-v1.1.1-abandoned": "Pre-v1.1.1 abandoned",
  run_id_collision_replaced: "Replaced (ID collision)",
  run_id_collision_stale_data: "Stale data (ID collision)",
  incomplete_session_terminated: "Session terminated early",
  incomplete_infra_failure: "Infrastructure failure",
  incomplete_agent_loop: "Agent loop detected",
};

export function AdmissibilityBadge({
  admissible,
  excludeReason,
  status,
  evalTrack,
}: {
  admissible?: boolean | null;
  excludeReason?: string | null;
  status?: "live" | "completed";
  evalTrack?: string | null;
}) {
  if (status === "live" && !excludeReason) {
    return (
      <Tooltip>
        <TooltipTrigger asChild>
          <Clock className="h-3.5 w-3.5 text-marble-400" aria-label="In progress" />
        </TooltipTrigger>
        <TooltipContent>Game in progress</TooltipContent>
      </Tooltip>
    );
  }
  if (admissible) {
    return (
      <Tooltip>
        <TooltipTrigger asChild>
          <ShieldCheck className="h-3.5 w-3.5 text-patina" aria-label="Admissible" />
        </TooltipTrigger>
        <TooltipContent>Admissible for benchmark rankings</TooltipContent>
      </Tooltip>
    );
  }
  const reason =
    excludeReason
      ? EXCLUDE_LABELS[excludeReason] ?? excludeReason.replace(/_/g, " ")
      : evalTrack === "development"
        ? "Development track"
        : "Does not meet admissibility criteria";
  return (
    <Tooltip>
      <TooltipTrigger asChild>
        <ShieldX className="h-3.5 w-3.5 text-marble-400" aria-label="Not admissible" />
      </TooltipTrigger>
      <TooltipContent>{reason}</TooltipContent>
    </Tooltip>
  );
}
