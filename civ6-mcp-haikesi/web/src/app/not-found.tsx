import Link from "next/link";
import { Compass } from "lucide-react";

export default function NotFound() {
  return (
    <div className="flex min-h-screen flex-col items-center justify-center gap-6 px-6">
      <Compass className="h-10 w-10 text-marble-300" />
      <div className="text-center">
        <p className="font-mono text-sm text-marble-400">404</p>
        <h1 className="mt-1 font-display text-2xl font-bold tracking-[0.08em] uppercase text-marble-800">
          This tile is still in fog of war
        </h1>
        <p className="mt-2 text-sm text-marble-500">
          Send a scout to explore, or try one of these known routes.
        </p>
      </div>
      <div className="flex gap-3">
        <Link
          href="/"
          className="rounded-sm border border-marble-400 bg-marble-100 px-4 py-2 text-sm font-medium text-marble-700 transition-colors hover:border-marble-500 hover:bg-marble-200"
        >
          Back to Home
        </Link>
        <Link
          href="/games"
          className="rounded-sm border border-gold/30 bg-gold/10 px-4 py-2 text-sm font-medium text-gold-dark transition-colors hover:bg-gold/20"
        >
          Browse Games
        </Link>
      </div>
    </div>
  );
}
