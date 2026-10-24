// The Mac app's provider compatibility, checked here: which Copilot models are named, and
// what is written in the engine's settings.
//
//   node --test windows/compatibility.test.mjs

import assert from "node:assert/strict";
import { test } from "node:test";

import {
  KNOWN_COPILOT_CLAUDE,
  compatibilitySettings,
  copilotClaude,
} from "./app/src/compatibility.mjs";

const model = (id, providerID, family) => ({ id, providerID, family });

test("the Copilot models the engine knows are the ones to name", () => {
  const models = [
    model("claude-opus-5.5", "github-copilot", "claude-opus-5.5"),
    model("claude-sonnet-4.5", "github-copilot", "claude-sonnet-4.5"),
    model("gpt-5.5", "github-copilot", "gpt-5.5"),
    model("claude-opus-5.5", "anthropic", "claude-opus-5.5"),
  ];
  assert.deepEqual(copilotClaude(models), ["claude-opus-5.5", "claude-sonnet-4.5"]);
});

test("a model only the settings put there has no family, and is left out", () => {
  assert.deepEqual(copilotClaude([model("claude-opus-5.5", "github-copilot", undefined)]), []);
  assert.deepEqual(copilotClaude([model("claude-opus-5.5", "github-copilot", "")]), []);
});

test("without a Copilot account, nothing is learned", () => {
  assert.deepEqual(copilotClaude([model("claude-opus-5.5", "anthropic", "claude-opus-5.5")]), []);
  assert.deepEqual(copilotClaude([]), []);
});

test("the settings name every model, and the engine is told not to bind", () => {
  const settings = compatibilitySettings(["claude-opus-5.5"]);
  assert.deepEqual(settings.providers["github-copilot"].models["claude-opus-5.5"], {
    compatibility: { supportsThinkingBlockBinding: false },
  });
  // And what is learned is what is written; without anything learned, the known ones are.
  const known = compatibilitySettings([]);
  for (const model of KNOWN_COPILOT_CLAUDE) {
    assert.ok(known.providers["github-copilot"].models[model], `${model} is named`);
  }
});
