// The diff's lines, as they are written in diff.mjs; this declares their shape for
// TypeScript. The reading of a patch is pure, so the test holds it to the Mac's without
// a browser.

export type DiffKind = "context" | "added" | "removed";

export type DiffLine = {
  kind: DiffKind;
  /** The line's number on the old side, when it has one. */
  oldNumber?: number;
  /** The line's number on the new side, when it has one. */
  newNumber?: number;
  /** The line as it reads, without the patch's sign. */
  text: string;
};

export const DIFF_KINDS: DiffKind[];
export function parsePatch(patch: string): DiffLine[];
export function diffNumber(line: DiffLine): number;
export function diffSide(line: DiffLine): "old" | "new";
export function diffGutterWidth(lines: DiffLine[]): number;
