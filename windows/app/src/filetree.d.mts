// The tree's shape, as it is built in filetree.mjs; this declares it for TypeScript.
// The tree is pure, so the test holds it to the Mac's without a browser.

export type TreeNode = {
  path: string;
  name: string;
  kind: string;
  children?: TreeNode[];
};

export function buildTree(
  files: { path: string; name: string; kind: string }[],
  project?: string,
): TreeNode[];
