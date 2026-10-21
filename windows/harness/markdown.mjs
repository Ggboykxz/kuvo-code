// A conversation as Markdown, the Mac's own way (ConversationExport.swift:9-69): the title
// over it, "You" and "Agent" as the speakers, the agent's steps listed together until it
// says something, the blocks a blank line apart.
//
// Plain ESM with no imports, so the browser and the tests load the same copy.

/**
 * A conversation as Markdown, the Mac's own way (ConversationExport.swift:9-69): the title
 * over it, "You" and "Agent" as the speakers, the agent's steps listed together until it
 * says something, the blocks a blank line apart.
 *
 * `summary(part)`: the tool's line in words ("Read notes.txt"), the Mac's own
 * (ToolCallView.swift:164-200). Without one, the tool's own name stands in.
 *
 * @param {string} title
 * @param {any} transcript
 * @param {{ directory?: string, summary?: ((part: any) => string) | null }} [options]
 * @returns {string}
 */
export function conversationMarkdown(title, transcript, { directory = "", summary = null } = {}) {
  const blocks = [`# ${title || "New Session"}`];
  let speaker = null;
  // The agent's steps, listed together until it says something.
  let steps = [];
  const say = (who, text) => {
    if (steps.length) {
      const list = steps.map(step => `- ${step}`).join("\n");
      steps = [];
      say("Agent", list);
    }
    if (speaker !== who) blocks.push(`**${who}**`);
    speaker = who;
    blocks.push(text);
  };
  for (const entry of transcript?.entries ?? []) {
    if (entry.kind === "user") {
      const lines = [];
      if (entry.text) lines.push(entry.text);
      const attached = (entry.files ?? []).map(file => file.name).filter(Boolean);
      if (attached.length) lines.push(`Attached: ${attached.join(", ")}`);
      if (lines.length) say("You", lines.join("\n\n"));
    } else if (entry.kind === "assistant") {
      for (const part of entry.parts ?? []) {
        if (part.type === "text") {
          const text = (part.text ?? "").trim();
          if (text) say("Agent", text);
        } else if (part.type === "tool") {
          steps.push(summary ? summary(part) : (part.name ?? "tool"));
        }
      }
    } else if (entry.kind === "shell") {
      // A command the user ran, and what it said (ConversationExport.swift:58-60).
      const output = (entry.output ?? "").trim();
      say("You", `Ran \`${entry.command ?? ""}\`` + (output ? `\n\n\`\`\`\n${output}\n\`\`\`` : ""));
    }
  }
  if (steps.length) say("Agent", "");
  return blocks.filter(block => block !== "").join("\n\n") + "\n";
}
