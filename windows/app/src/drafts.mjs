// The Mac app's drafts (KuvoCode/Stores/Drafts.swift): what is typed in a composer but not
// sent yet, by session — or by a project's new session — kept across launches. Attachments
// that are gone are dropped.
//
// The storage is given, so the test can hold this to the Mac's without a browser.

const KEY = "kuvo-composer-drafts";

/**
 * The key a draft is kept under: its session, or the project's new session.
 *
 * @param {string | null} sessionId
 * @param {string | null} project
 * @returns {string}
 */
export const draftKey = (sessionId, project) => sessionId ?? `new:${project ?? ""}`;

const all = storage => {
  try {
    const read = JSON.parse(storage.getItem(KEY) ?? "{}");
    return read && typeof read === "object" ? read : {};
  } catch {
    return {};
  }
};

/**
 * The draft of a composer: its words, and the attachments that still exist.
 *
 * @param {{getItem: (key: string) => string | null, setItem: (key: string, value: string) => void, removeItem: (key: string) => void}} storage
 * @param {string} key
 * @returns {{text: string, files: {name?: string, uri?: string, mime?: string}[]} | null}
 */
export function readDraft(storage, key) {
  const draft = all(storage)[key];
  if (!draft || typeof draft !== "object") return null;
  const files = (Array.isArray(draft.files) ? draft.files : []).filter(file => file && file.uri);
  const text = String(draft.text ?? "");
  if (!text && files.length === 0) return null;
  return { text, files };
}

/**
 * What is written down: the words, and the attachments that still exist. An empty draft is
 * forgotten, the Mac's way.
 *
 * @param {{getItem: (key: string) => string | null, setItem: (key: string, value: string) => void, removeItem: (key: string) => void}} storage
 * @param {string} key
 * @param {{text?: string, files?: {name?: string, uri?: string, mime?: string}[]}} draft
 */
export function saveDraft(storage, key, draft) {
  try {
    const drafts = all(storage);
    const files = (Array.isArray(draft?.files) ? draft.files : []).filter(file => file && file.uri);
    const text = String(draft?.text ?? "");
    if (!text && files.length === 0) delete drafts[key];
    else drafts[key] = { text, files };
    storage.setItem(KEY, JSON.stringify(drafts));
  } catch {}
}

/**
 * The draft is gone: it was sent.
 *
 * @param {{getItem: (key: string) => string | null, setItem: (key: string, value: string) => void, removeItem: (key: string) => void}} storage
 * @param {string} key
 */
export function clearDraft(storage, key) {
  try {
    const drafts = all(storage);
    if (!(key in drafts)) return;
    delete drafts[key];
    storage.setItem(KEY, JSON.stringify(drafts));
  } catch {}
}
