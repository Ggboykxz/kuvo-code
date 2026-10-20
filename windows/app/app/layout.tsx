// The window's frame. The Mac app's own chrome is drawn inside it (the title bar, the
// conversation, the panels), so the shell here is as plain as a page can be.

import "./globals.css";
import "katex/dist/katex.min.css";
// The terminal's own styles, from beside the hand-written page (one copy, shared).
import "../../harness/ui/vendor/xterm.css";
import "../../harness/ui/vendor/github.min.css";
import Script from "next/script";

export const metadata = {
  title: "Kuvo Code",
  description: "Kuvo Code for Windows: a native shell around the engine and the conversation view.",
  icons: { icon: "/icon.png" },
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <head>
        <meta
          httpEquiv="Content-Security-Policy"
          content="default-src 'self'; script-src 'self' 'unsafe-inline' 'unsafe-eval'; style-src 'self' 'unsafe-inline'; connect-src 'self' ws: wss:; img-src 'self' data:; font-src 'self' data:;"
        />
      </head>
      <body>
        {/* The terminal, when the panel asks for it. */}
        <Script src="/vendor/xterm.min.js" strategy="beforeInteractive" />
        <Script src="/vendor/addon-fit.min.js" strategy="beforeInteractive" />
        {children}
      </body>
    </html>
  );
}
