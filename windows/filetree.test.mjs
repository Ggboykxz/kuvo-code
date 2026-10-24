// The panel's tree — the project's flat list of files folded into folders — checked here,
// without a browser, on both kinds of path: a Windows path's separator is the other one,
// and the project's own folder must be the tree's root on either.
//
//   node --test windows/filetree.test.mjs

import assert from "node:assert/strict";
import { test } from "node:test";

import { buildTree } from "./app/src/filetree.mjs";

const file = (path, name) => ({ path, name, kind: "file" });

test("the project's folder is the tree's root on a Mac's path", () => {
  const tree = buildTree([
    file("/tmp/kuvo-page-1/notes.txt", "notes.txt"),
    file("/tmp/kuvo-page-1/z-long.txt", "z-long.txt"),
    file("/tmp/kuvo-page-1/sub/one.txt", "one.txt"),
    file("/tmp/kuvo-page-1/sub/two.txt", "two.txt"),
  ], "/tmp/kuvo-page-1");
  assert.deepEqual(tree.map(node => [node.name, node.kind]), [
    ["notes.txt", "file"],
    ["z-long.txt", "file"],
    ["sub", "dir"],
  ]);
  // One folder for the folder, however many files it holds.
  assert.deepEqual(tree[2].children.map(node => node.name), ["one.txt", "two.txt"]);
  assert.equal(tree[2].children[0].path, "/tmp/kuvo-page-1/sub/one.txt", "a file keeps the path the app opens");
});

test("the project's folder is the tree's root on a Windows path", () => {
  const tree = buildTree([
    file("C:\\work\\kuvo\\notes.txt", "notes.txt"),
    file("C:\\work\\kuvo\\sub\\one.txt", "one.txt"),
  ], "C:\\work\\kuvo");
  assert.deepEqual(tree.map(node => [node.name, node.kind]), [
    ["notes.txt", "file"],
    ["sub", "dir"],
  ]);
  assert.equal(tree[1].children[0].name, "one.txt");
});

test("a trailing separator on the project's path changes nothing", () => {
  const tree = buildTree([file("C:\\work\\kuvo\\notes.txt", "notes.txt")], "C:\\work\\kuvo\\");
  assert.deepEqual(tree.map(node => node.name), ["notes.txt"]);
});

test("a folder that only starts with the project's name is not the project", () => {
  const tree = buildTree([file("C:\\work\\kuvo-other\\one.txt", "one.txt")], "C:\\work\\kuvo");
  // Nothing is stripped: the path is shown as it came, rather than losing its front.
  assert.deepEqual(tree.map(node => node.name), ["C:"]);
  assert.deepEqual(tree[0].children[0].children[0].children[0].name, "one.txt");
});
