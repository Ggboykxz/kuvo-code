// What a conversation view shows: the engine's history, kept current by applying its events.
// Mirrors Packages/OpenCodeKit's Transcript (the Mac app's reference): text and reasoning
// blocks are keyed by their ordinal within a step, tools by their call id, permissions by
// their request id, and only events for this session change anything.
//
// Plain ESM with no imports, so the browser and the tests load the same copy.

export function emptyTranscript(sessionID) {
  return { sessionID, running: false, entries: [], permissions: [], pending: [] };
}

/// The session an event belongs to: the engine puts it beside every payload.
export function sessionOf(event) {
  return event?.data?.sessionID ?? event?.sessionID ?? null;
}

function messageEntry(message) {
  const created = message.time?.created ?? 0;
  switch (message.type) {
    case "user":
      return { kind: "user", id: message.id, created, text: message.text ?? "", files: (message.files ?? []).map(file => ({ mime: file.mime, name: file.name, data: file.data ?? null, uri: file.source?.type === "uri" ? file.source.uri : null })) };
    case "assistant": {
      const entry = { kind: "assistant", id: message.id, created, completed: message.time?.completed ?? 0, parts: [], agent: message.agent, model: message.model?.id, error: message.error, finish: message.finish, cost: message.cost, tokens: message.tokens };
      (message.content ?? []).forEach((block, ordinal) => {
        if (block.type === "text") entry.parts.push({ type: "text", ordinal, text: block.text ?? "", done: !!block.time?.completed });
        else if (block.type === "reasoning") entry.parts.push({
          type: "reasoning", ordinal, text: block.text ?? "", done: !!block.time?.completed,
          created: block.time?.created ?? 0, completed: block.time?.completed ?? 0,
        });
        else if (block.type === "tool") entry.parts.push({
          type: "tool",
          id: block.id,
          name: block.name,
          status: block.state?.status ?? "running",
          input: block.state?.input,
          output: block.state?.content,
          error: block.state?.error,
        });
      });
      return entry;
    }
    case "synthetic":
    case "system":
      return { kind: "notice", id: message.id, created, text: message.text ?? "" };
    case "shell":
      return { kind: "shell", id: message.id, created, command: message.command, status: message.status, exit: message.exit, output: message.output?.output ?? "" };
    case "idle":
      return { kind: "idle", id: message.id, created, outcome: message.outcome, error: message.error };
    default:
      return null;
  }
}

/// A fresh view from what the engine has: a session's messages and its open asks.
export function fromHistory(sessionID, messages, permissions = [], running = false) {
  const transcript = emptyTranscript(sessionID);
  transcript.permissions = permissions.filter(request => request.sessionID === sessionID);
  for (const message of messages) {
    const entry = messageEntry(message);
    if (entry) transcript.entries.push(entry);
  }
  // A run is running while its last words are unfinished — the Mac app's own measure
  // (Message.isRunning reads the message's status), not the engine's session flag, which
  // can still say "running" for a moment after the turn is over.
  // The Mac's own measure (Message.isRunning): the *last* words of the conversation, and
  // whether they are finished. The parts can lag behind the message in the engine's
  // history, and an earlier message that never finished is not a run under way.
  const last = [...transcript.entries].reverse().find(entry => entry.kind === "assistant");
  const unfinished = Boolean(last) && !last.completed && (last.parts ?? []).some(part => {
    if (part.type === "text" || part.type === "reasoning") return part.done === false;
    return part.status === "running" || part.status === "pending";
  });
  // The Mac's own measure, both halves of it: the conversation's last words are
  // unfinished (Message.isRunning reads the message's status), and the engine still has
  // the session among the active ones (SessionModel.swift:573-587 reads the engine's own
  // answer when it loads a session). Either can end a run — the engine's flag can still
  // say "running" for a moment after the turn is over, and its stored words can lag the
  // other way, so a page that loaded just then would keep showing that the agent is at
  // work long after it stopped. A run that has begun but has not written a word yet is
  // the engine's own answer alone.
  const written = Boolean(last) && (last.parts ?? []).length > 0;
  transcript.running = Boolean(running) && (unfinished || !written);
  return transcript;
}

function assistant(transcript, id, created = Date.now()) {
  let entry = transcript.entries.find(item => item.kind === "assistant" && item.id === id);
  if (!entry) {
    entry = { kind: "assistant", id, created, parts: [] };
    transcript.entries.push(entry);
  }
  return entry;
}

function textBlock(entry, ordinal, type) {
  const wanted = ordinal ?? 0;
  let part = entry.parts.find(item => item.type === type && item.ordinal === wanted);
  if (!part) {
    part = { type, ordinal: wanted, text: "", done: false };
    // Keep the step's blocks in ordinal order, tools where they were called.
    const at = entry.parts.findIndex(item => item.type === type && (item.ordinal ?? 0) > wanted);
    if (at < 0) entry.parts.push(part); else entry.parts.splice(at, 0, part);
  }
  return part;
}

function toolBlock(entry, id, name) {
  let part = entry.parts.find(item => item.type === "tool" && item.id === id);
  if (!part) {
    part = { type: "tool", id, name: name ?? "tool", status: "streaming" };
    entry.parts.push(part);
  }
  if (name) part.name = name;
  return part;
}

function idleEntry(transcript, event, error) {
  const payload = event.data ?? {};
  const outcome = event.type === "session.execution.succeeded" ? "succeeded" : event.type === "session.execution.failed" ? "failed" : "interrupted";
  // A shutdown isn't the conversation's own ending; the app shows nothing for it either.
  if (payload.reason === "shutdown") return;
  transcript.entries.push({ kind: "idle", id: `idle_${event.id ?? transcript.entries.length}`, created: event.created ?? Date.now(), outcome, error: error ?? payload.error });
}

/// Applies one event; events for other sessions change nothing.
export function apply(transcript, event) {
  if (!event?.type) return transcript;
  const payload = event.data ?? {};
  const type = event.type;

  // Permissions carry their session inside the request itself.
  if (type === "permission.asked") {
    if (payload.sessionID && payload.sessionID !== transcript.sessionID) return transcript;
    transcript.permissions = transcript.permissions.filter(request => request.id !== payload.id);
    transcript.permissions.push(payload);
    return transcript;
  }
  if (type === "permission.replied") {
    transcript.permissions = transcript.permissions.filter(request => request.id !== payload.requestID);
    return transcript;
  }

  if (sessionOf(event) !== transcript.sessionID) return transcript;
  const now = event.created ?? Date.now();

  switch (type) {
    case "session.inbox.enqueued":
      if (payload.item?.type !== "user") return transcript;
      if (!transcript.entries.some(entry => entry.id === payload.inboxID) && !transcript.pending.some(item => item.id === payload.inboxID)) {
        transcript.pending.push({ id: payload.inboxID, text: payload.item.payload?.text ?? "", delivery: payload.item.delivery });
      }
      return transcript;
    case "session.inbox.delivered": {
      const item = transcript.pending.find(entry => entry.id === payload.inboxID);
      transcript.pending = transcript.pending.filter(entry => entry.id !== payload.inboxID);
      if (item && !transcript.entries.some(entry => entry.id === item.id)) {
        transcript.entries.push({ kind: "user", id: item.id, created: now, text: item.text });
      }
      return transcript;
    }
    case "session.inbox.cancelled":
      transcript.pending = transcript.pending.filter(entry => entry.id !== payload.inboxID);
      return transcript;
    case "session.inbox.delivery.changed": {
      const item = transcript.pending.find(entry => entry.id === payload.inboxID);
      if (item) item.delivery = payload.delivery;
      return transcript;
    }

    case "session.execution.started":
      transcript.running = true;
      return transcript;
    case "session.execution.succeeded":
    case "session.execution.failed":
    case "session.execution.interrupted":
      transcript.running = false;
      idleEntry(transcript, event, payload.error);
      return transcript;

    case "session.retry.scheduled": {
      const entry = assistant(transcript, payload.assistantMessageID, now);
      entry.retry = { attempt: payload.attempt, at: payload.at };
      return transcript;
    }

    case "session.step.started": {
      const entry = assistant(transcript, payload.assistantMessageID, payload.started ?? now);
      entry.error = undefined;
      entry.finish = undefined;
      entry.retry = undefined;
      if (payload.agent) entry.agent = payload.agent;
      if (payload.model) entry.model = payload.model.id;
      return transcript;
    }
    case "session.step.streamed": {
      // The step's words are streaming (Transcript.swift:310-312).
      const entry = assistant(transcript, payload.assistantMessageID, now);
      entry.streamed = now;
      return transcript;
    }
    case "session.step.ended":
    case "session.step.failed": {
      const entry = assistant(transcript, payload.assistantMessageID, now);
      entry.finish = payload.finish ?? (payload.error ? "error" : entry.finish);
      entry.error = payload.error ?? entry.error;
      entry.cost = payload.cost ?? entry.cost;
      entry.tokens = payload.tokens ?? entry.tokens;
      entry.retry = undefined;
      return transcript;
    }

    case "session.text.started":
      transcript.running = true;
      textBlock(assistant(transcript, payload.assistantMessageID, now), payload.ordinal, "text");
      return transcript;
    case "session.text.delta": {
      const block = textBlock(assistant(transcript, payload.assistantMessageID, now), payload.ordinal, "text");
      block.text += payload.delta ?? "";
      return transcript;
    }
    case "session.text.ended": {
      const block = textBlock(assistant(transcript, payload.assistantMessageID, now), payload.ordinal, "text");
      block.text = payload.text ?? block.text;
      block.done = true;
      return transcript;
    }

    case "session.reasoning.started":
      transcript.running = true;
      textBlock(assistant(transcript, payload.assistantMessageID, now), payload.ordinal, "reasoning");
      return transcript;
    case "session.reasoning.delta": {
      const block = textBlock(assistant(transcript, payload.assistantMessageID, now), payload.ordinal, "reasoning");
      if (!block.done) block.text += payload.delta ?? "";
      return transcript;
    }
    case "session.reasoning.ended": {
      const block = textBlock(assistant(transcript, payload.assistantMessageID, now), payload.ordinal, "reasoning");
      block.text = payload.text ?? block.text;
      block.done = true;
      return transcript;
    }

    case "session.tool.input.started":
      // At work: whatever said otherwise (a read that missed the run) was wrong.
      transcript.running = true;
      toolBlock(assistant(transcript, payload.assistantMessageID, now), payload.id, payload.name);
      return transcript;
    case "session.tool.input.delta": {
      const part = toolBlock(assistant(transcript, payload.assistantMessageID, now), payload.id);
      part.inputText = (part.inputText ?? "") + (payload.delta ?? "");
      return transcript;
    }
    case "session.tool.input.ended": {
      const part = toolBlock(assistant(transcript, payload.assistantMessageID, now), payload.id);
      part.inputText = payload.text ?? "";
      return transcript;
    }
    case "session.tool.called": {
      const part = toolBlock(assistant(transcript, payload.assistantMessageID, now), payload.id);
      // Done already: a read since has its result.
      if (part.status === "completed" || part.status === "error") return transcript;
      part.status = "running";
      part.input = payload.input ?? part.input;
      return transcript;
    }
    case "session.tool.progress": {
      // The tool is still going, and says how far (Transcript.swift:413-417).
      const part = toolBlock(assistant(transcript, payload.assistantMessageID, now), payload.id);
      part.metadata = payload.metadata ?? part.metadata;
      return transcript;
    }
    case "session.tool.success": {
      const part = toolBlock(assistant(transcript, payload.assistantMessageID, now), payload.id);
      part.status = "completed";
      part.output = payload.content ?? part.output;
      return transcript;
    }
    case "session.tool.failed": {
      const part = toolBlock(assistant(transcript, payload.assistantMessageID, now), payload.id);
      if (part.status === "completed" || part.status === "error") return transcript;
      part.status = "error";
      part.error = payload.error;
      part.output = payload.content ?? part.output;
      return transcript;
    }

    case "session.agent.selected": {
      // The run switched to another agent (Transcript.swift:434-436).
      const entry = { kind: "notice", id: payload.assistantMessageID ?? `agent_${now}`, created: now, text: `Agent: ${payload.agent ?? ""}` };
      transcript.entries.push(entry);
      return transcript;
    }
    case "session.model.selected": {
      // The run switched to another model (Transcript.swift:437-439).
      const entry = { kind: "notice", id: payload.assistantMessageID ?? `model_${now}`, created: now, text: `Model: ${payload.model?.id ?? ""}` };
      transcript.entries.push(entry);
      return transcript;
    }
    case "session.synthetic":
      transcript.entries.push({ kind: "notice", id: `note_${event.id ?? now}`, created: now, text: payload.text ?? "" });
      return transcript;

    case "session.shell.started": {
      const shell = payload.shell ?? {};
      transcript.entries.push({ kind: "shell", id: `shell_${shell.id ?? event.id}`, created: now, command: shell.command, status: shell.status ?? "running", exit: shell.exit, output: "" });
      return transcript;
    }
    case "session.shell.ended": {
      const shell = payload.shell ?? {};
      const entry = transcript.entries.find(item => item.kind === "shell" && item.id === `shell_${shell.id}`)
        ?? transcript.entries.findLast(item => item.kind === "shell");
      if (entry) {
        entry.status = shell.status ?? entry.status;
        entry.exit = shell.exit ?? entry.exit;
        entry.output = payload.output?.output ?? entry.output;
      }
      return transcript;
    }

    default:
      return transcript;
  }
}

export function applyAll(transcript, events) {
  for (const event of events) apply(transcript, event);
  return transcript;
}
