// The window itself: the conversation, the title bar and the panels, drawn by the app's
// own code (windows/app/src). The whole page is one client-side app, talking to the
// engine over the harness's API.
//
// The app draws with the DOM, so the exported page is the shell and the app takes over
// in the browser: Next prerenders the page (there is no server to render it later), and
// the window is drawn the moment the page is alive.

"use client";

import { useEffect, useState } from "react";
import { App } from "../src/App";

export default function Page() {
  const [alive, setAlive] = useState(false);
  useEffect(() => setAlive(true), []);
  if (!alive) return <div className="starting">Starting…</div>;
  return <App />;
}
