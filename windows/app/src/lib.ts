// Small helpers the view needs: markdown the way the Mac app renders it, and the
// few words the page says about time, size and failure.

import { marked } from "marked";

export const escapeHtml = (text: unknown) =>
  String(text).replace(/[&<>"']/g, char => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;" }[char]) as string);

/// The engine's words can carry anything: keep the structure, drop the dangerous parts.
export function sanitizeHtml(html: string): string {
  const doc = new DOMParser().parseFromString(html, "text/html");
  doc.querySelectorAll("script, iframe, object, embed, link, meta, base, style").forEach(node => node.remove());
  doc.querySelectorAll("*").forEach(node => {
    [...node.attributes].forEach(attr => {
      if (attr.name.startsWith("on") || /^\s*javascript:/i.test(attr.value)) node.removeAttribute(attr.name);
    });
  });
  return doc.body.innerHTML;
}

export function renderMarkdown(text: string): string {
  const html = sanitizeHtml(marked.parse(String(text), { breaks: true, gfm: true }) as string);
  const doc = new DOMParser().parseFromString(html, "text/html");
  doc.querySelectorAll("pre").forEach(pre => {
    const button = doc.createElement("button");
    button.className = "small code-copy";
    button.textContent = "Copy";
    button.addEventListener("click", () => {
      void navigator.clipboard?.writeText(pre.querySelector("code")?.textContent ?? "").catch(() => {});
      button.textContent = "Copied";
      setTimeout(() => { button.textContent = "Copy"; }, 1200);
    });
    pre.style.position = "relative";
    pre.append(button);
  });
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
