import type { Metadata } from "next";

export const metadata: Metadata = {
  title: "Games",
  description:
    "Browse CivBench game sessions with filtering by model, scenario, and outcome",
};

export default function GamesLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return children;
}
