// A comment on a line of the changes, as they are written in review-comments.mjs; this
// declares their shape for TypeScript. The rules about a comment are pure, so the test
// holds them to the Mac's without a browser.

export type CommentSide = "new" | "old";

export type ReviewComment = {
  /** The comment's own name, so the panel can tell two apart. */
  id: string;
  /** The file the comment is on, as the panel names it. */
  file: string;
  /** The line's number, on the side the comment was written on. */
  line: number;
  /** Which side of the change the line is on. */
  side: CommentSide;
  /** The line as it read when the comment was written. */
  snippet: string;
  /** What the comment says. */
  text: string;
};

export type DiffLineish = {
  kind: string;
  oldNumber?: number;
  newNumber?: number;
  text: string;
};

export const BLOCK_START: string;
export const BLOCK_END: string;
export const BLOCK_HEADING: string;
export function commentMatches(comment: ReviewComment, line: DiffLineish): boolean;
export function commentLocation(comment: ReviewComment): string;
export function findBlock(text: string): { open: number; lines: string[] } | null;
export function escapeBlock(text: string): string;
export function commentsText(text: string, comments: ReviewComment[]): string;
export function splitComments(text: string): { text: string; comments: ReviewComment[] };
