// The model's own words: the name of the effort a model is asked for. It lives with the
// harness (one copy, shared); this declares its shape for TypeScript.

declare module "*/models.mjs" {
  export function effortTitle(id: string): string;
}
