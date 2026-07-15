"use client";

import { useId, useRef, useState } from "react";
import { ChevronDown } from "lucide-react";

interface CollapsiblePanelProps {
  icon: React.ReactNode;
  title: string;
  defaultOpen?: boolean;
  summary?: React.ReactNode;
  children: React.ReactNode;
}

export function CollapsiblePanel({
  icon,
  title,
  defaultOpen = false,
  summary,
  children,
}: CollapsiblePanelProps) {
  const [expanded, setExpanded] = useState(defaultOpen);
  const contentId = useId();
  const innerRef = useRef<HTMLDivElement>(null);

  return (
    <div className="mx-auto mb-4 w-full max-w-2xl rounded-sm border border-marble-300/50 bg-marble-50">
      <button
        onClick={() => setExpanded(!expanded)}
        aria-expanded={expanded}
        aria-controls={contentId}
        className="flex w-full items-center gap-2 px-3 py-2 text-left transition-colors hover:bg-marble-100"
      >
        {icon}
        <span className="flex-1 font-display text-sm font-bold uppercase tracking-[0.08em] text-marble-700">
          {title}
        </span>
        {summary}
        <ChevronDown
          className={`h-3 w-3 text-marble-400 transition-transform duration-200 ${expanded ? "rotate-180" : ""}`}
        />
      </button>
      <div
        id={contentId}
        role="region"
        aria-label={title}
        className="grid transition-[grid-template-rows] duration-200 ease-out motion-reduce:transition-none"
        style={{ gridTemplateRows: expanded ? "1fr" : "0fr" }}
      >
        <div className="overflow-hidden">
          <div ref={innerRef} className="border-t border-marble-300/30 px-3 py-2">
            {children}
          </div>
        </div>
      </div>
    </div>
  );
}
