// A provider's mark, from the same logo set opencode's own apps use (models.dev, by
// provider id) — the Mac's `ProviderLogo.swift`. Monochrome, so it follows the ink; in the
// maker's own colour where it has one.
//
// The mark is fetched from models.opencode.ai, the way the Mac fetches it, and kept for
// the page's lifetime: until it arrives, the provider's initial stands in for it, at 55 %
// of the size, semibold and rounded — the Mac's own fallback (`ProviderLogo.swift:24-26`).
// The harness does the fetching: the page asks it for the mark, and an empty answer means
// the initial stands in.

import { useEffect, useState } from "react";

/// The makers whose marks have a colour of their own (`ProviderLogo.swift:41-46`). The
/// rest are black and white, and keep the ink around them.
const MAKER_COLORS: Record<string, number> = {
  anthropic: 0xd97757,
  google: 0x4285f4,
  "google-vertex": 0x4285f4,
  mistral: 0xfa520f,
  deepseek: 0x4d6bfe,
  meta: 0x0866ff,
  alibaba: 0xff6a00,
  xiaomi: 0xff6900,
  "amazon-bedrock": 0xff9900,
  azure: 0x0078d4,
  nvidia: 0x76b900,
  perplexity: 0x20808d,
  groq: 0xf55036,
};

/// The marks already fetched: each one is asked for once, and kept (`LogoCache`).
const marks = new Map<string, string | null>();

export function ProviderLogo({ id, size = 20, colored = false }: { id: string; size?: number; colored?: boolean }) {
  const [mark, setMark] = useState<string | null>(() => marks.get(id) ?? null);
  useEffect(() => {
    let cancelled = false;
    if (marks.has(id)) {
      setMark(marks.get(id) ?? null);
      return;
    }
    void fetch(`/api/logo/${encodeURIComponent(id)}`)
      .then(response => (response.ok ? response.text() : null))
      .then(text => {
        const href = text && text.includes("<svg") ? `data:image/svg+xml;utf8,${encodeURIComponent(text)}` : null;
        marks.set(id, href);
        if (!cancelled) setMark(href);
      })
      .catch(() => {
        marks.set(id, null);
      });
    return () => {
      cancelled = true;
    };
  }, [id]);
  const maker = colored && MAKER_COLORS[id] !== undefined ? `#${MAKER_COLORS[id].toString(16).padStart(6, "0")}` : undefined;
  if (!mark) {
    return (
      <span className="provider-logo fallback" style={{ width: size, height: size, fontSize: size * 0.55, color: maker }} aria-hidden="true">
        {id.slice(0, 1).toUpperCase()}
      </span>
    );
  }
  return (
    <span
      className="provider-logo"
      style={{
        width: size,
        height: size,
        backgroundColor: maker ?? "currentColor",
        WebkitMaskImage: `url("${mark}")`,
        maskImage: `url("${mark}")`,
      }}
      aria-hidden="true"
    />
  );
}
