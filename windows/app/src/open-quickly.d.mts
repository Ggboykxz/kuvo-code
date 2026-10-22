export declare function openQuicklyMatches(
  query: string,
  files: { name: string; relative?: string; path?: string }[],
  limit?: number,
): { name: string; relative?: string; path?: string }[];
