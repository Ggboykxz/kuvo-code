# Security policy

## Reporting a vulnerability

Please do not open a public issue for a vulnerability. Use GitHub's
[private vulnerability reporting](https://github.com/serhatandic/kuvo-code/security/advisories/new)
so the report, reproduction steps, and any proposed fix remain private. If you
can't use it, email [info@kuvo.run](mailto:info@kuvo.run) instead.

Include the affected version and macOS version, the impact, and the smallest
reproduction you can provide. Kuvo Code's sessions and logs can contain your
prompts, code, file paths and account names, so remove anything identifying
from logs and screenshots before you share them.

You should receive an acknowledgement within seven days. Confirmed issues will
be coordinated privately until a fix and release are available.

## Scope

Reports are especially welcome about:

- the engine download: the pinned opencode build, its checksum and the code
  signature check before it runs;
- the private engine server, its password, and who else on the Mac can reach
  it;
- the browser tools Kuvo Code serves to the agent on `127.0.0.1`, and their
  token;
- what a web page in the panel's browser can reach, including the agent's
  browsing;
- how the app asks for and answers the engine's permission requests, so the
  agent never runs something you didn't allow;
- where sign-ins and API keys are stored, and the logins of other tools the
  usage tracker reads and renews;
- attachments and review comments, and what they send to the model.

Vulnerabilities in opencode itself should go to the
[opencode project](https://github.com/anomalyco/opencode). Tell us too if Kuvo
Code's setup makes one easier to exploit.

## Windows client

The Windows client (`windows/`) is a separate product built from this repository. Its
surface is:

- the Electron shell: the window, the menu bar, the tray, the update check, and the
  ConPTY terminal;
- the harness: a localhost HTTP server that starts the pinned engine and serves the
  conversation page;
- the React page: the conversation, the panels and Settings.

Reports are welcome about the shell's IPC handlers (especially anything that runs a
command), the harness's localhost boundary and engine password, the page's Content
Security Policy, the terminal's WebSocket, and the update download. The Windows
installer and portable build are unsigned, so the update path is worth extra
scrutiny.

Client-only settings such as bots and machines are kept in the page's
`localStorage`; they are not secrets, but a report that shows them leaking into a
log or a remote request is in scope. The GitHub token used by the release tooling
lives in a git-ignored file and is never read by the app.

## Supported versions

Kuvo Code is pre-1.0. Security fixes are made on `main` and released in the
newest build; older builds are not maintained separately.
