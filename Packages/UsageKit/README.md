# UsageKit

The usage tracker in Kuvo Code's menu bar: plan limits with pace and reset countdowns, local spend
(today, yesterday, 30 days, a total across providers, a 30-day trend), notifications, and
customizable menu bar metrics, for Antigravity, Claude, Codex, Copilot, Cursor, Devin, Grok,
Ollama, OpenCode, OpenRouter and Z.ai.

**This is a fork of [OpenUsage](https://github.com/robinebers/openusage) by Robin Ebers (MIT),
not the official OpenUsage, and isn't affiliated with or endorsed by it.** It was imported at
upstream commit `05c7a87` and follows upstream up to `bae20d9`. The OpenUsage name and logo are Robin Ebers' trademarks and aren't used
here.

## What's different from upstream

- **Embedded, not a standalone app.** `UsageMenuBar` replaces OpenUsage's app delegate. It never
  changes the activation policy or quits the app, and the first-run welcome opens on the first
  click of the menu bar item instead of at launch. It tells the host when the panel opens (`UsageMenuBar.onPanelShown`), for the host's own counts.
- **Removed:** Sparkle updates, PostHog analytics, the local HTTP API on port 6736, the `openusage`
  command-line tool, iCloud sync, single-instance handling and OpenUsage's own logo.
- **The host's identity.** Names, the user agent, logs (`~/Library/Logs/<app>/Usage.log`) and
  caches (`~/Library/Application Support/<bundle id>/Usage`) follow the app UsageKit runs in, so it
  never shares files with an installed OpenUsage. A proxy goes in `Usage/proxy.json` there.
- **The host's accounts** (`HostAccounts`). Copilot, OpenRouter and Z.ai accounts connected in Kuvo
  Code are used. OpenCode also reads the databases of Kuvo Code's private engine, so Kuvo Code's own
  runs count toward spend, and its OpenCode Go key is found there.

- **Plan limits for the host** (`Embedding/PlanLimits.swift`): the latest limits of one provider,
  read from what the panel already has, for Kuvo Code to show beside a session.
- **API keys pasted into the panel go into the Keychain** (`Providers/APIKeySecrets.swift`), not a
  JSON file; a key an earlier version saved in a file moves there the next time it's read.
- **A Bars style for the dashboard**, the default (`Views/UsageBarsView.swift`): one compact bar
  per provider in a pastel of its brand color, with thin monospaced labels, showing the limit closest to running out, and today's spend
  as one bar on top. Clicking a bar opens every metric underneath in the same style (`Views/UsageBarDetail.swift`), not the card.
  Settings › Style switches back to the cards.
- **Only the host's accounts** (`Stores/ProviderAvailability.swift`): the panel follows the providers whose accounts are connected in
  Kuvo Code (`HostAccounts.setConnectedProviders`), turning on newly connected ones, and leaves out tools signed in elsewhere on the
  Mac. Of those, one whose refresh finds no login, or no usage for its account, stays off the dashboard, the menu bar and Total
  Spend too, and Customize (which lists only connected providers) says why.

Everything else, including providers, pricing, pace, layout and the views, is upstream code. Kuvo
Code-specific code lives in `Sources/UsageKit/Embedding` and `Support/HostApp.swift`. Other edits are
kept small and marked "fork addition" where they aren't obvious.

## Network

Each provider talks only to its own service, with the login it found. Pricing for spend estimates
is refreshed about hourly from three public price lists: LiteLLM on raw.githubusercontent.com,
models.dev, and OpenUsage's pricing supplement on GitHub Pages. These requests carry no usage data.

## Tests

```sh
swift test
```

Upstream's suite, minus the tests for the removed parts.
