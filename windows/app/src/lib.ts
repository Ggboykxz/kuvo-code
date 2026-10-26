// Small helpers the view needs: markdown the way the Mac app renders it, and the
// few words the page says about time, size and failure.

import katex from "katex";
import { marked } from "marked";
import { fileIn } from "./filelinks.mjs";

export const escapeHtml = (text: unknown) =>
  String(text).replace(/[&<>"']/g, char => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[char]) as string);

/// The engine's words can carry anything: keep the structure, drop the dangerous parts.
export function sanitizeHtml(html: string): string {
  const doc = new DOMParser().parseFromString(html, "text/html");
  doc.querySelectorAll("script, iframe, object, embed, link, meta, base, style, form, input, button, textarea, select, svg, math").forEach(node => node.remove());
  doc.querySelectorAll("*").forEach(node => {
    [...node.attributes].forEach(attr => {
      const name = attr.name.toLowerCase();
      const value = attr.value.trim();
      if (name.startsWith("on") || name === "srcdoc" || name === "style" || name === "srcset") { node.removeAttribute(attr.name); return; }
      if ((name === "href" || name === "src" || name === "xlink:href" || name === "poster") &&
          /^\s*(javascript|vbscript|data):/i.test(value)) {
        node.removeAttribute(attr.name);
      }
    });
  });
  return doc.body.innerHTML;
}

/// The matches of a find, marked in the text — the text nodes only, so the markup the
/// markdown made is left as it is.
function highlight(root: Node, query: string) {
  const needle = query.toLowerCase();
  const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
  const texts: Text[] = [];
  while (walker.nextNode()) texts.push(walker.currentNode as Text);
  for (const node of texts) {
    const value = node.textContent ?? "";
    const at = value.toLowerCase().indexOf(needle);
    if (at < 0) continue;
    const mark = document.createElement("mark");
    mark.className = "find-mark";
    mark.textContent = value.slice(at, at + needle.length);
    const rest = document.createTextNode(value.slice(at + needle.length));
    const before = document.createTextNode(value.slice(0, at));
    node.replaceWith(before, mark, rest);
  }
}

/// The formulas, as the Mac app's MathText renders them: $inline$ and $$block$$.
/// The code is put aside first, so a dollar sign in a snippet stays a dollar sign.
export function renderMath(text: string): string {
  const kept: string[] = [];
  const hold = (code: string) => {
    kept.push(code);
    return `\u0000${kept.length - 1}\u0000`;
  };
  let source = String(text)
    .replace(/```[\s\S]*?```/g, hold)
    .replace(/`[^`\n]*`/g, hold);
  const formula = (tex: string, display: boolean) => {
    try {
      return katex.renderToString(tex, { displayMode: display, throwOnError: false, output: "html" });
    } catch {
      return display ? `$$${tex}$$` : `$${tex}$`;
    }
  };
  source = source.replace(/\$\$([\s\S]+?)\$\$/g, (_, tex) => formula(tex, true));
  source = source.replace(/\$([^$\n]+?)\$/g, (_, tex) => formula(tex, false));
  // The formulas are held aside while the text is parsed, and put back after: a NUL
  // cannot occur in the text itself, and it cannot be typed in a formula.
  // oxlint-disable-next-line eslint/no-control-regex -- the placeholders are marked with NUL on purpose
  return source.replace(/\u0000(\d+)\u0000/g, (_, index) => kept[Number(index)]);
}

export function renderMarkdown(text: string, files: string[] = [], query = ""): string {
  const html = sanitizeHtml(marked.parse(renderMath(text), { breaks: true, gfm: true }) as string);
  const doc = new DOMParser().parseFromString(html, "text/html");
  doc.querySelectorAll("pre").forEach(pre => {
    const button = doc.createElement("button");
    button.className = "small code-copy";
    button.title = "Copy";
    button.setAttribute("aria-label", "Copy");
    // The Mac's copy mark, which becomes a check when the text is copied
    // (CodeBlockStyle.swift).
    const mark = (name: string) =>
      `<svg viewBox="0 0 16 16" width="13" height="13" fill="none" stroke="currentColor" stroke-width="1.4" stroke-linecap="round" stroke-linejoin="round"><path d="${
        name === "checkmark" ? "M3.2 8.4l3.1 3.1 6.5-6.5" : "M5.5 5.5h-3A1.5 1.5 0 0 0 1 6.9h3.4M3 5.5H2.2A1.3 1.3 0 0 0 1.3 6.8h2.1M9 2.2h3.3A1.5 1.5 0 0 1 13.8 3.7v6.8a1.5 1.5 0 0 1-1.5 1.5H8.2a1.5 1.5 0 0 1-1.5-1.5V6.2a1.5 1.5 0 0 1 1.5-1.5M6 8.2h5"
      }"/></svg>`;
    button.innerHTML = mark("doc.on.doc");
    button.addEventListener("click", () => {
      void navigator.clipboard?.writeText(pre.querySelector("code")?.textContent ?? "").catch(() => {});
      button.innerHTML = mark("checkmark");
      button.classList.add("copied");
      setTimeout(() => {
        button.innerHTML = mark("doc.on.doc");
        button.classList.remove("copied");
      }, 1200);
    });
    pre.style.position = "relative";
    pre.append(button);
  });
  // The Mac app's file links: a code span that names a file of the project opens it, in the
  // side panel, when it is clicked.
  if (files.length > 0) {
    doc.querySelectorAll("code").forEach(code => {
      if (code.closest("pre")) return;
      const file = fileIn(code.textContent ?? "", files);
      if (!file) return;
      const link = doc.createElement("a");
      link.className = "file-link";
      link.dataset.path = file.path;
      if (file.line) link.dataset.line = String(file.line);
      link.textContent = file.label;
      code.replaceWith(link);
    });
  }
  // The Mac's find: what is found is marked in the text (FindBar.swift).
  if (query.trim().length > 1) highlight(doc.body, query.trim());
  return doc.body.innerHTML;
}

export const when = (stamp?: number) => {
  if (!stamp) return "";
  const seconds = Math.round((Date.now() - stamp) / 1000);
  if (seconds < 60) return "just now";
  if (seconds < 3600) return `${Math.round(seconds / 60)} min ago`;
  if (seconds < 86_400) return `${Math.round(seconds / 3600)} h ago`;
  return new Date(stamp).toLocaleDateString();
};

export const brief = (value: unknown, limit = 1600): string => {
  let text: string;
  try {
    text = typeof value === "string" ? value : JSON.stringify(value, null, 2);
  } catch {
    text = String(value);
  }
  if (text === undefined) return "";
  return text.length > limit ? `${text.slice(0, limit)}…` : text;
};

export const errorText = (error: unknown): string => {
  if (!error) return "";
  if (typeof error === "string") return error;
  const known = error as { message?: string; type?: string };
  return known.message ?? known.type ?? brief(error, 400);
};

export const compactTokens = (n: number) => {
  if (n >= 1e6) return `${(n / 1e6).toFixed(1)}M`;
  if (n >= 1e3) return `${(n / 1e3).toFixed(1)}K`;
  return String(n);
};
