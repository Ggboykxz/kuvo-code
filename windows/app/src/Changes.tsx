// The Changes panel: what the project's work looks like, the way the Mac app's shows it —
// the files, folded, with their changes, a comment on a line that goes to the agent with
// the next message, and a commit the session's model can write the message for.

import { useEffect, useState } from "react";
import { api } from "./api";
import { complain, state, useStore } from "./store";

type ChangeFile = { file: string; patch?: string; additions?: number; deletions?: number; status?: string };

const SCOPES = [
  ["uncommitted", "Uncommitted"],
  ["unstaged", "Unstaged"],
  ["staged", "Staged"],
  ["session", "This session"],
] as const;

export function ChangesPanel() {
  useStore();
  const [scope, setScope] = useState<string>("uncommitted");
  const [files, setFiles] = useState<ChangeFile[]>([]);
  const [open, setOpen] = useState<string[]>([]);
  const [git, setGit] = useState(false);
  const [message, setMessage] = useState("");
  const [suggesting, setSuggesting] = useState(false);
  const [working, setWorking] = useState(false);
  const [pushes, setPushes] = useState(false);
  const [failure, setFailure] = useState("");
  const [draft, setDraft] = useState<{ file: string; line: number } | null>(null);
  const [draftText, setDraftText] = useState("");
  const [instructions, setInstructions] = useState("");

  // The changes, looked at again every few seconds while the panel is open, as the Mac's.
  useEffect(() => {
    let alive = true;
    const load = async () => {
      if (!state.project) return;
      try {
        if (scope === "session") {
          const { diff } = await api<{ diff: ChangeFile[] }>(`/api/sessions/${encodeURIComponent(state.session?.id ?? "")}/diff`);
          if (alive) setFiles(Array.isArray(diff) ? diff : []);
          return;
        }
        const answer = await api<{ files: ChangeFile[]; git: boolean }>(`/api/changes?directory=${encodeURIComponent(state.project)}&scope=${scope}`);
        if (!alive) return;
        setFiles(answer.files ?? []);
        setGit(Boolean(answer.git));
      } catch {
        if (alive) setFiles([]);
      }
    };
    void load();
    const timer = setInterval(load, 3000);
    return () => { alive = false; clearInterval(timer); };
  }, [scope, state.project, state.session?.id]);

  // The commit instructions, the ones the Mac keeps for the model.
  useEffect(() => {
    void api<{ git?: { commitInstructions?: string } }>("/api/app-settings")
      .then(answer => setInstructions(answer.git?.commitInstructions ?? ""))
      .catch(() => {});
  }, []);

  const toggle = (file: string) => setOpen(current => current.includes(file) ? current.filter(name => name !== file) : [...current, file]);

  const comment = (file: string, line: number) => {
    setDraft({ file, line });
    setDraftText("");
  };

  const saveComment = () => {
    if (!draft || !draftText.trim()) { setDraft(null); return; }
    state.lineComments = [...(state.lineComments ?? []), { file: draft.file, line: draft.line, text: draftText.trim() }];
    setDraft(null);
    setDraftText("");
  };

  const suggest = async () => {
    if (!state.session) return;
    setSuggesting(true);
    setFailure("");
    try {
      const answer = await api<{ message: string }>("/api/changes/suggest", {
        method: "POST",
        body: { directory: state.project, session: state.session.id, scope, instructions },
      });
      setMessage(answer.message ?? "");
    } catch (error) {
      setFailure(error instanceof Error ? error.message : String(error));
    }
    setSuggesting(false);
  };

  const commit = async () => {
    if (!message.trim()) { setFailure("A commit needs a message."); return; }
    setWorking(true);
    setFailure("");
    try {
      await api("/api/changes/commit", {
        method: "POST",
        body: { directory: state.project, message, files: scope === "staged" ? [] : files.map(file => file.file) },
      });
      setMessage("");
      setOpen([]);
    } catch (error) {
      setFailure(error instanceof Error ? error.message : String(error));
    }
    setWorking(false);
  };

  return (
    <div id="changes-panel" className="changes-panel">
      <div className="changes-head">
        <select id="changes-scope" value={scope} onChange={event => setScope(event.target.value)}>
          {SCOPES.map(([value, title]) => <option key={value} value={value}>{title}</option>)}
        </select>
        {!git && scope !== "session" ? <span className="where">Not a git project</span> : null}
      </div>

      <div id="changes-files" className="changes-files">
        {files.length === 0 ? (
          <div className="where">{scope === "session" ? "This session has not changed anything yet." : "Nothing has changed here."}</div>
        ) : files.map(file => {
          const isOpen = open.includes(file.file);
          return (
            <div className="changes-file" key={file.file}>
              <button className="changes-file-head" onClick={() => toggle(file.file)}>
                <span className="where">{isOpen ? "▾" : "▸"}</span>
                <span className="changes-file-name">{file.file}</span>
                <span className="where">{`+${file.additions ?? 0} −${file.deletions ?? 0}`}</span>
              </button>
              {isOpen ? (
                <div className="changes-diff">
                  {String(file.patch ?? "").split("\n").map((line, index) => {
                    if (line === "") return null;
                    const kind = line.startsWith("+") ? "add" : line.startsWith("-") ? "del" : "ctx";
                    return (
                      <div className={`diff-line ${kind}`} key={index}>
                        <span className="diff-text">{line}</span>
                        <button className="small diff-comment" title="Say something about this line; it goes to the agent with your next message" onClick={() => comment(file.file, index)}>✎</button>
                        {draft?.file === file.file && draft.line === index ? (
                          <span className="diff-draft">
                            <input
                              type="text"
                              autoFocus
                              value={draftText}
                              placeholder="What should the agent know?"
                              onChange={event => setDraftText(event.target.value)}
                              onKeyDown={event => { if (event.key === "Enter") saveComment(); if (event.key === "Escape") setDraft(null); }}
                            />
                            <button className="small" onClick={saveComment}>Say it</button>
                          </span>
                        ) : null}
                      </div>
                    );
                  })}
                </div>
              ) : null}
            </div>
          );
        })}
      </div>

      <div className="changes-foot">
        <input
          id="changes-message"
          type="text"
          value={message}
          placeholder="The commit message"
          onChange={event => setMessage(event.target.value)}
        />
        <div className="changes-buttons">
          <button className="small" disabled={suggesting || !state.session} onClick={() => void suggest()}>
            {suggesting ? "Writing…" : "Suggest a Message"}
          </button>
          <label className="where">
            <input type="checkbox" checked={pushes} onChange={event => setPushes(event.target.checked)} /> Push afterwards
          </label>
          <button className="primary small" disabled={working} onClick={() => void commit()}>Commit</button>
        </div>
        {failure ? <div className="entry-error">{failure}</div> : null}
        {state.lineComments?.length ? (
          <div className="where">{`${state.lineComments.length} note(s) go with your next message.`}</div>
        ) : null}
      </div>
    </div>
  );
}

export { complain };
