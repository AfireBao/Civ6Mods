"use client";

import { useEffect } from "react";

const QUOTES = [
  ["The whole history of the world is summed up in the fact that, when nations are strong, they are not always just, and when they wish to be just, they are no longer strong.", "Winston Churchill"],
  ["Any sufficiently advanced technology is indistinguishable from magic.", "Arthur C. Clarke"],
  ["I know not with what weapons World War III will be fought, but World War IV will be fought with sticks and stones.", "Albert Einstein"],
  ["The only thing new in the world is the history you don't know.", "Harry S. Truman"],
  ["In the midst of chaos, there is also opportunity.", "Sun Tzu"],
  ["The map is not the territory.", "Alfred Korzybski"],
  ["All models are wrong, but some are useful.", "George E. P. Box"],
  ["The best time to plant a tree was twenty years ago. The second best time is now.", "Chinese Proverb"],
  ["Victorious warriors win first and then go to war, while defeated warriors go to war first and then seek to win.", "Sun Tzu"],
  ["It is a capital mistake to theorize before one has data.", "Arthur Conan Doyle"],
  ["The real problem is not whether machines think but whether men do.", "B. F. Skinner"],
  ["Strategy without tactics is the slowest route to victory. Tactics without strategy is the noise before defeat.", "Sun Tzu"],
];

export function ConsoleEgg() {
  useEffect(() => {
    const [quote, author] = QUOTES[Math.floor(Math.random() * QUOTES.length)];
    console.log(
      `%c"${quote}"\n%c— ${author}`,
      "color: #D4A853; font-style: italic; font-size: 13px; line-height: 1.6;",
      "color: #A39B8F; font-size: 11px;",
    );
    console.log(
      "%cciv6-mcp %c· An MCP server for Civilization VI\n%chttps://github.com/lmwilki/civ6-mcp",
      "color: #D4A853; font-weight: bold; font-size: 12px;",
      "color: #7A7269; font-size: 12px;",
      "color: #4A90A4; font-size: 11px;",
    );
  }, []);

  return null;
}
