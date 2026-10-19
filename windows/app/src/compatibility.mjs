// The Mac app's ProviderCompatibility (KuvoCode/Stores/ProviderCompatibility.swift): GitHub
// Copilot's Claude models from 5.1 on reject the thinking.block_binding the engine adds for
// Claude 5.1 and later ("thinking.adaptive.block_binding: Extra inputs are not permitted").
// opencode (2.0.32 still) leaves it out only for the models named in its settings, one by
// one — so the app names them, and writes it where the engine reads its settings.
//
// This file is pure — which models, and what to write — so the test can hold it to the
// Mac's. The app's half is in the store.

// Copilot's Claude models from 5.1 on, as of October 2026, until an engine has listed them.
export const KNOWN_COPILOT_CLAUDE = [
  "claude-opus-5.5",
  "claude-sonnet-5.5",
  "claude-haiku-5.5",
  "claude-fable-5.1",
];

/**
 * The Copilot models the engine knows, and that are Claude's. A model only the settings put
 * there has no family, and is left out — the next engine started leaves it out of its
 * settings.
 *
 * @param {{providerID?: string, id?: string, family?: string}[]} models
 * @returns {string[]}
 */
export function copilotClaude(models) {
  return (models ?? [])
    .filter(model => model?.providerID === "github-copilot" && String(model?.id ?? "").startsWith("claude-") && model?.family)
    .map(model => model.id)
    .sort();
}

/**
 * The settings to write: the models the engine must not add the binding to.
 *
 * @param {string[]} [learned] what an earlier run learned from the engine's own list
 * @returns {{providers: {"github-copilot": {models: Record<string, {compatibility: {supportsThinkingBlockBinding: boolean}}>}}} | null}
 */
export function compatibilitySettings(learned) {
  const named = Array.isArray(learned) && learned.length > 0 ? learned : KNOWN_COPILOT_CLAUDE;
  if (named.length === 0) return null;
  const models = {};
  for (const model of named) models[model] = { compatibility: { supportsThinkingBlockBinding: false } };
  return { providers: { "github-copilot": { models } } };
}
