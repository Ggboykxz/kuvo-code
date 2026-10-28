// The project's files, as the panel's tree shows them (FilesView.swift:250-275): the
// flat list is folded into folders, and the project's own folder is the root. A path is
// written with the platform's separator — a Windows path's is the other kind — so both
// are read the same way here.

/// The flat list of files, as a tree. The project's prefix is dropped from both kinds of
/// path, so the tree's root is the project's own folder and not the drive above it.
export function buildTree(files, project = "") {
  const slashed = value => String(value ?? "").replace(/\\/g, "/");
  const base = slashed(project).replace(/\/+$/, "");
  const root = [];
  const folders = new Map();
  for (const file of files) {
    const full = slashed(file.path);
    const relative = base && (full === base || full.startsWith(`${base}/`))
      ? full.slice(base.length).replace(/^\/+/, "")
      : full;
    const parts = relative.split("/").filter(Boolean);
    if (parts.length === 0) continue;
    let folder = "";
    let level = root;
    for (const part of parts.slice(0, -1)) {
      folder = folder ? `${folder}/${part}` : part;
      let node = folders.get(folder);
      if (!node) {
        node = { path: folder, name: part, kind: "dir", children: [] };
        folders.set(folder, node);
        level.push(node);
      }
      level = node.children ?? [];
    }
    level.push({ path: file.path, name: parts.at(-1) ?? file.name, kind: file.kind === "dir" ? "dir" : "file" });
  }
  return root;
}
