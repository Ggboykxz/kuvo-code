// The reducer the page uses to read the engine's history and to follow its events.
// It lives with the harness (one copy, shared); this declares its shape for TypeScript.

declare module "*/transcript.mjs" {
  export function apply(transcript: any, event: any): any;
  export function emptyTranscript(): any;
  export function fromHistory(id: string, messages: any[], permissions: any[], running: boolean): any;
  export function sessionOf(event: any): string | null;
}
