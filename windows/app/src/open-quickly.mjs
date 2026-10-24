// Open Quickly's matches, without a browser: the Mac's Mentions.matches
// (Mentions.swift:21-45) over a project's files. The files arrive newest first (the
// Mac's ProjectFiles.newestFirst), so with nothing typed the newest ten are offered.

/** The folder a project-relative path sits in; empty at the project's root. */
const folderOf = file => {
  const path = String(file.relative ?? file.path ?? "");
  const cut = path.lastIndexOf("/");
  return cut > 0 ? path.slice(0, cut) : "";
};

const pathOf = file => String(file.relative ?? file.path ?? "");
const nameOf = file => String(file.name ?? pathOf(file).split("/").pop() ?? "");
const before = (left, right) => left < right;

/**
 * The matches, best first, as the Mac ranks them: the name itself, the start of the name,
 * the name anywhere, then the path. Ties go by folder, shorter path, then path.
 *
 * @param {string} query
 * @param {{ name: string, relative?: string, path?: string }[]} files
 * @param {number} [limit]
 * @returns {{ name: string, relative?: string, path?: string }[]}
 */
export function openQuicklyMatches(query, files, limit = 10) {
  const needle = String(query).toLowerCase();
  if (!needle) return files.slice(0, limit);
  const found = [];
  for (const file of files) {
    const name = nameOf(file).toLowerCase();
    const path = pathOf(file).toLowerCase();
    const rank = name === needle ? 0 : name.startsWith(needle) ? 1 : name.includes(needle) ? 2 : path.includes(needle) ? 3 : null;
    if (rank === null) continue;
    found.push({ file, rank, folder: folderOf(file).toLowerCase(), length: pathOf(file).length, path: pathOf(file).toLowerCase() });
  }
  found.sort((a, b) => a.rank - b.rank
    || (before(a.folder, b.folder) ? -1 : before(b.folder, a.folder) ? 1 : 0)
    || a.length - b.length
    || (before(a.path, b.path) ? -1 : before(b.path, a.path) ? 1 : 0));
  return found.slice(0, limit).map(match => match.file);
}
