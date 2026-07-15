const shimmer =
  "relative overflow-hidden rounded-sm bg-marble-200/50 " +
  "before:absolute before:inset-0 before:bg-gradient-to-r " +
  "before:from-transparent before:via-marble-100/40 before:to-transparent " +
  "before:animate-[skeleton-shimmer_1.5s_infinite] before:bg-[length:400px_100%] " +
  "motion-reduce:before:animate-none";

/** Animated placeholder for a single line of text. */
export function SkeletonLine({ className = "w-24" }: { className?: string }) {
  return <div className={`h-3.5 ${shimmer} ${className}`} />;
}

/** Animated placeholder block with configurable height. */
export function SkeletonBlock({
  className = "h-20 w-full",
}: {
  className?: string;
}) {
  return <div className={`${shimmer} ${className}`} />;
}
