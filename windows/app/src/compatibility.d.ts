// The Mac app's provider compatibility, as it is written in compatibility.mjs; this
// declares its shape for TypeScript.

declare module "*/compatibility.mjs" {
  export const KNOWN_COPILOT_CLAUDE: string[];
  export function copilotClaude(
    models: { providerID?: string; id?: string; family?: string }[],
  ): string[];
  export function compatibilitySettings(learned?: string[]): {
    providers: {
      "github-copilot": {
        models: Record<string, { compatibility: { supportsThinkingBlockBinding: boolean } }>;
      };
    };
  } | null;
}
