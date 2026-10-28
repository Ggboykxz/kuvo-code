// The Mac app's file links, as they are written in filelinks.mjs; this declares their shape
// for TypeScript.

export function fileIn(
    span: string,
    files: string[],
  ): { path: string; label: string; line: number | null } | null;
  export function fileLabel(text: string, files: string[]): string | null;
