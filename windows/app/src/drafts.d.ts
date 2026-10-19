// The Mac app's drafts, as they are written in drafts.mjs; this declares their shape for
// TypeScript.

declare module "*/drafts.mjs" {
  export type Draft = {
    text: string;
    files: { name?: string; uri?: string; mime?: string }[];
  };
  export type Storage = {
    getItem: (key: string) => string | null;
    setItem: (key: string, value: string) => void;
    removeItem: (key: string) => void;
  };
  export function draftKey(sessionId: string | null, project: string | null): string;
  export function readDraft(storage: Storage, key: string): Draft | null;
  export function saveDraft(
    storage: Storage,
    key: string,
    draft: { text?: string; files?: { name?: string; uri?: string; mime?: string }[] },
  ): void;
  export function clearDraft(storage: Storage, key: string): void;
}
