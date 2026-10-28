// The Changes panel: what the project's work looks like, the way the Mac app's shows it —
// the files, folded, with their changes, a comment on a line that goes to the agent with
// the next message, and a commit the session's model can write the message for.

import { useEffect, useState } from "react";
import { Symbol } from "./components/symbols";
import { ConfirmAction } from "./components/confirm-action";
import { api } from "./api";
import { diffGutterWidth, diffNumber, diffSide, foldRows, parsePatch, type DiffLine } from "./diff.mjs";
import { commentMatches, type ReviewComment } from "./review-comments.mjs";
import { complain, notify, render, state, useStore } from "./store";

type ChangeFile = { file: string; patch?: string; additions?: number; deletions?: number; status?: string; tooBig?: boolean };

const SCOPES = [
  ["uncommitted", "Uncommitted"],
  ["unstaged", "Unstaged"],
  ["staged", "Staged"],
  ["branch", "Branch"],
  ["session", "This Session"],
] as const;

export function ChangesPanel() {
  useStore();
  // The user's initials in a circle, the Mac's own (ChangesPanel.swift:1214-1233).
  const initials = (() => {
    const name = (window as unknown as { kuvo?: { userName?: string } }).kuvo?.userName ?? "";
    const letters = String(name).split(" ").filter(Boolean).slice(0, 2).map(part => part[0]).join("");
    return letters ? letters.toUpperCase() : "?";
  })();
  const [scope, setScope] = useState<string>("uncommitted");
  const [files, setFiles] = useState<ChangeFile[]>([]);
  const [open, setOpen] = useState<string[]>([]);
  const [git, setGit] = useState(false);
  const [base, setBase] = useState<string | null>(null);
  const [branch, setBranch] = useState("");
  const [message, setMessage] = useState("");
  const [suggesting, setSuggesting] = useState(false);
  const [working, setWorking] = useState(false);
  // Whether the commit pushes afterwards, kept for the next time (the Mac's
  // "changes.pushAfterCommit", ChangesPanel.swift:304).
  const [pushes, setPushes] = useState(() => {
    try { return localStorage.getItem("kuvo-pushAfterCommit") === "on"; } catch { return false; }
  });
  const [failure, setFailure] = useState("");
  // The line a comment is being written on, as it read then
  // (ChangesPanel.swift:24-33).
  const [draft, setDraft] = useState<{ file: string; side: "new" | "old"; number: number; text: string } | null>(null);
  const [draftText, setDraftText] = useState("");
  // The folds that are open, by their name (ChangesPanel.swift:18, 899).
  const [expandedFolds, setExpandedFolds] = useState<string[]>([]);
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
        const answer = await api<{ files: ChangeFile[]; git: boolean; base?: string | null; branch?: string }>(`/api/changes?directory=${encodeURIComponent(state.project)}&scope=${scope}`);
        if (!alive) return;
        setFiles(answer.files ?? []);
        setGit(Boolean(answer.git));
        setBase(answer.base ?? null);
        setBranch(answer.branch ?? "");
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

  // A comment is written on the line it was written on: the line's number, and — once the
  // file has changed — the line's text, so it doesn't slide onto another line
  // (ChangesPanel.swift:24-33, 873-880).
  const comment = (file: string, line: DiffLine) => {
    setDraft({ file, side: diffSide(line), number: diffNumber(line), text: line.text });
    setDraftText("");
  };

  const saveComment = () => {
    if (!draft || !draftText.trim()) { setDraft(null); return; }
    state.lineComments = [
      ...(state.lineComments ?? []),
      {
        id: `${draft.file}:${draft.side}:${draft.number}:${state.lineComments?.length ?? 0}`,
        file: draft.file,
        line: draft.number,
        side: draft.side,
        snippet: draft.text.trim(),
        text: draftText.trim(),
      },
    ];
    setDraft(null);
    setDraftText("");
  };

  const deleteComment = (one: ReviewComment) => {
    state.lineComments = (state.lineComments ?? []).filter(other => other.id !== one.id);
    render();
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
        body: { directory: state.project, message, push: pushes, files: scope === "staged" ? [] : files.map(file => file.file) },
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
          {SCOPES.map(([value, title]) => (
            <option key={value} value={value} hidden={value === "branch" && !base}>{title}</option>
          ))}
        </select>
        {scope === "branch" && base ? <span className="where">{`${branch || "this branch"} against ${base}`}</span> : null}
        {!git && scope !== "session" ? <span className="where">Not a git project</span> : null}
      </div>

      <div id="changes-files" className="changes-files">
        {files.length === 0 ? (
          <div className="where">{scope === "session" ? "This session has not changed anything yet." : "Nothing has changed here."}</div>
        ) : files.map(file => {
          const isOpen = open.includes(file.file);
          // The file's lines, as the Mac reads them (ProjectChanges.swift:40-48).
          const lines = parsePatch(file.patch ?? "");
          return (
            <div className="changes-file" key={file.file}>
              <div className="changes-file-head">
                <button className="changes-file-toggle" onClick={() => toggle(file.file)}>
                  <span className="where"><Symbol name="chevron.right" size={11} className={isOpen ? "turned" : ""} /></span>
                  <span className="changes-file-name">{file.file}</span>
                  <span className="where">{`+${file.additions ?? 0} −${file.deletions ?? 0}`}</span>
                </button>
                {scope !== "session" ? (
                  <ConfirmAction
                    title="Put this file back as it was"
                    question={`Put ${file.file} back as it was?`}
                    confirmLabel="Revert"
                    onConfirm={async () => {
                      try {
                        await api("/api/changes/revert", { method: "POST", body: { directory: state.project, file: file.file } });
                      } catch (error) { complain(error); }
                    }}
                  >
                    Revert
                  </ConfirmAction>
                ) : null}
              </div>
              {isOpen ? (
                // A file too big to read through is named, not shown (ProjectChanges.swift:507-511).
                file.tooBig ? null : (
                <div className="changes-diff" style={{ "--gutter": `${diffGutterWidth(lines)}px` } as React.CSSProperties}>
                  {foldRows(lines, expandedFolds, file.file).map(row => {
                    // A fold: the long unchanged stretches, folded until they are opened
                    // (ChangesPanel.swift:890-927, 929-952).
                    if (row.kind === "fold") {
                      return (
                        <button
                          className="diff-fold"
                          key={row.id}
                          title="Show these lines"
                          aria-label={`Show ${row.count} unmodified lines`}
                          onClick={() => setExpandedFolds(current => [...current, row.id])}
                        >
                          <span className="diff-fold-mark" aria-hidden="true">
                            <Symbol name="chevron.up.chevron.down" size={10} />
                          </span>
                          <span>{`${row.count} unmodified lines`}</span>
                        </button>
                      );
                    }
                    // A gap: the lines git left out, which cannot be opened.
                    if (row.kind === "gap") {
                      return (
                        <div className="diff-fold gap" key={row.id}>
                          <span className="diff-fold-mark" aria-hidden="true">
                            <Symbol name="ellipsis" size={10} />
                          </span>
                        </div>
                      );
                    }
                    const line = lines[row.index ?? 0];
                    // The number in the gutter is the line's own: the old one for a removed
                    // line, the new one otherwise (ChangesPanel.swift:882-885).
                    const number = diffNumber(line);
                    const kind = line.kind === "added" ? "add" : line.kind === "removed" ? "del" : "ctx";
                    // The comments written on this line, and the one being written now
                    // (ChangesPanel.swift:789-799).
                    const mine = (state.lineComments ?? []).filter(one => one.file === file.file && commentMatches(one, line));
                    const writing = Boolean(
                      draft && draft.file === file.file && draft.side === diffSide(line)
                      && draft.number === number && draft.text === line.text,
                    );
                    return (
                      <div className="diff-row" key={row.id}>
                        <div className={`diff-line ${kind}`}>
                          <span className="diff-number">{number || ""}</span>
                          <button
                            className="diff-comment"
                            title="Comment on This Line"
                            aria-label="Comment on This Line"
                            onClick={() => comment(file.file, line)}
                          >
                            {/* The Mac's mark in the gutter: a plus, drawn. */}
                            <Symbol name="plus" size={9} />
                          </button>
                          <span className="diff-text">{line.text || " "}</span>
                        </div>
                        {mine.map(one => (
                          <div className="comment-card" key={one.id}>
                            <div className="comment-head">
                              <span className="comment-avatar" aria-hidden="true">{initials}</span>
                              <span className="comment-you">You</span>
                              <span className="comment-where">
                                {`Comment on line ${one.side === "old" ? "L" : "R"}${one.line}`}
                              </span>
                            </div>
                            <div className="comment-text">{one.text}</div>
                            <div className="comment-foot">
                              <button className="small" onClick={() => deleteComment(one)}>Delete</button>
                            </div>
                          </div>
                        ))}
                        {writing ? (
                          <div className="comment-editor">
                            <div className="comment-head">
                              <span className="comment-avatar" aria-hidden="true">{initials}</span>
                              <span className="comment-you">You</span>
                            </div>
                            <textarea
                              autoFocus
                              rows={2}
                              value={draftText}
                              placeholder="Add a comment…"
                              onChange={event => setDraftText(event.target.value)}
                              onKeyDown={event => {
                                if (event.key === "Escape") { setDraft(null); setDraftText(""); return; }
                                // Here, not on the button: a button's Ctrl+Return would take it
                                // from the composer too (ChangesPanel.swift:1182-1187).
                                if (event.key === "Enter" && (event.ctrlKey || event.metaKey)) {
                                  event.preventDefault();
                                  saveComment();
                                }
                              }}
                            />
                            <div className="comment-foot">
                              <button className="small" onClick={() => { setDraft(null); setDraftText(""); }}>Cancel</button>
                              <button
                                className="primary small"
                                title="Comment (Ctrl+Return)"
                                disabled={!draftText.trim()}
                                onClick={saveComment}
                              >
                                Comment
                              </button>
                            </div>
                          </div>
                        ) : null}
                      </div>
                    );
                  })}
                </div>
                )
              ) : null}
            </div>
          );
        })}
      </div>

      <div className="changes-foot">
        <div className="changes-pr">
          <button
            className="small"
            disabled={working || !git}
            title="Push the branch and open the pull request's page, with a title and a description the model writes"
            onClick={async () => {
              setWorking(true);
              setFailure("");
              try {
                const pushed = await api<{ page?: string | null; branch: string }>("/api/changes/push", {
                  method: "POST",
                  body: { directory: state.project, branch, base: base ?? "main" },
                });
                const written = await api<{ title: string; description: string }>("/api/changes/suggest-pr", {
                  method: "POST",
                  body: { directory: state.project, session: state.session?.id, base: base ?? "main", instructions },
                });
                const page = pushed.page
                  ? `${pushed.page}&title=${encodeURIComponent(written.title)}&body=${encodeURIComponent(written.description)}`
                  : null;
                if (page) window.open(page, "_blank");
                notify("Kuvo Code", page ? "The branch is pushed; the pull request's page is open." : "The branch is pushed.");
              } catch (error) {
                setFailure(error instanceof Error ? error.message : String(error));
              }
              setWorking(false);
            }}
          >
            Create Pull Request
          </button>
        </div>
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
            <input
              type="checkbox"
              checked={pushes}
              onChange={event => {
                setPushes(event.target.checked);
                try { localStorage.setItem("kuvo-pushAfterCommit", event.target.checked ? "on" : "off"); } catch {}
              }}
            /> Push afterwards
          </label>
          <button className="primary small" disabled={working} onClick={() => void commit()}>{pushes ? "Commit and Push" : "Commit"}</button>
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
