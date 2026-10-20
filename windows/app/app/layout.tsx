// The window's frame. The Mac app's own chrome is drawn inside it (the title bar, the
// conversation, the panels), so the shell here is as plain as a page can be.

import "./globals.css";
import "katex/dist/katex.min.css";

export const metadata = {
  title: "Kuvo Code",
  description: "Kuvo Code for Windows: a native shell around the engine and the conversation view.",
  icons: { icon: "/icon.png" },
};

export default function RootLayout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <body>{children}</body>
    </html>
  );
}
