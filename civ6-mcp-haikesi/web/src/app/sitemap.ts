import type { MetadataRoute } from "next";

const BASE = "https://civ6-mcp.lwilko.com";

export default async function sitemap(): Promise<MetadataRoute.Sitemap> {
  return [
    { url: BASE, changeFrequency: "weekly", priority: 1 },
    { url: `${BASE}/about`, changeFrequency: "monthly", priority: 0.8 },
    { url: `${BASE}/games`, changeFrequency: "daily", priority: 0.9 },
    { url: `${BASE}/civbench`, changeFrequency: "weekly", priority: 0.9 },
    { url: `${BASE}/docs`, changeFrequency: "monthly", priority: 0.7 },
  ];
}
