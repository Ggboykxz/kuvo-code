// The conversation written out as Markdown, the Mac's own way. It lives with the harness
// (one copy, shared); this declares its shape for TypeScript.

declare module "*/markdown.mjs" {
  export function conversationMarkdown(
    title: string,
    transcript: any,
    options?: { directory?: string; summary?: ((part: any) => string) | null },
  ): string;
}
