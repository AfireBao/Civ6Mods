import type { Metadata } from "next";

export const metadata: Metadata = {
  title: "CivBench",
  description:
    "Five benchmark scenarios for evaluating LLM strategic reasoning in Civilization VI",
};

export default function CivBenchLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return children;
}
