import type { Metadata } from "next";

export const metadata: Metadata = {
  title: "About",
  description:
    "How civ6-mcp connects LLM agents to Civilization VI through MCP",
};

export default function AboutLayout({
  children,
}: {
  children: React.ReactNode;
}) {
  return children;
}
