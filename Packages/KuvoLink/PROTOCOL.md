# Kuvo Link

How Kuvo Code on a phone reaches the agents on a Mac or a machine, from anywhere,
through a relay that can't read what passes through it.

- **Hosts** serve an engine: the Mac app, and a bridge on each machine (`kuvo-link.js`,
  run by the engine's own runtime). A host connects out to the relay; it never listens.
- **The phone** connects out to the relay too, and opens an encrypted session with each
  host it's paired with.
- **The relay** matches connections by address and passes bytes along. It keeps no
  content. It also sends Apple push notifications, whose content it can't read either.

Everything below is implemented twice, in Swift (`Sources/KuvoLink`, for the Mac app and
the phone) and in JavaScript (`Sources/KuvoLink/Resources/kuvo-link.js`, for machines). `Vectors/` holds the
test vectors both run against.

## Keys and addresses

Each device (a phone, a Mac, a machine) has:

- a **static key**, an X25519 key pair, which identifies it to the devices it's paired with;
- a **relay secret**, 32 random bytes, which it shows only to the relay.

Its **address** is the first 16 bytes of `SHA-256("kuvo-link address v1" || secret)`. The
relay checks a connection's secret against the address it claims, so it needs no accounts
or storage, and only the device itself can receive what's sent to its address.

In text (links, JSON) keys, secrets, addresses and tokens are base64url without padding.

## The relay

One WebSocket per device, binary messages, first byte the kind:

| Kind | From | Bytes | Meaning |
| --- | --- | --- | --- |
| `0x01` hello | device | `secret(32)` | Must come first. A second connection with the same address replaces the first (closed with 4002). |
| `0x01` welcome | relay | `address(16)` | The secret was fine; this is your address. |
| `0x02` send | device | `to(16) payload` | Pass `payload` to the device at `to`. |
| `0x02` deliver | relay | `from(16) payload` | Something sent to you. |
| `0x03` unreachable | relay | `to(16)` | Nothing is connected at `to`; what you sent is dropped. |
| `0x04` register | phone | JSON | `{"token", "environment": "sandbox"\|"production", "topic", "senders": [address]}`: send pushes to this APNs token, only from these addresses. Kept for 90 days; the phone sends it again whenever it connects. |
| `0x05` push | host | `to(16) payload` | Push `payload` (a mail frame, below) to `to`'s phone. |
| `0x06` pushed | relay | `to(16) status(1)` | 0 sent, 1 no phone registered, 2 not one of its senders, 3 Apple refused. |

`payload` is at most 65,600 bytes. The relay closes a connection that sends anything else
(4000), a wrong secret (4001), far too much too fast (4003), or one too many from the same
IP address (4005). A device a little too fast, or sending faster than the one it sends to
takes in, is held back: the relay stops reading from it for a moment.

An APNs push carries `{"aps": {"alert": {"title": "Kuvo Code", "body": "New activity"},
"mutable-content": 1}, "f": "<sender's address>", "k": "<payload, base64>"}`. The phone's
notification extension decrypts `k` with the key of the host at `f`, and replaces the text,
the category (for its buttons) and the thread.

## Link frames

What one device sends another, inside the relay's `payload`:

```
kind(1) session(4) body
```

`session` is a random number the phone picks for each session, so frames from an older one
can't be confused with a newer one.

| Kind | Body |
| --- | --- |
| `0x01` | Handshake message 1, phone to host |
| `0x02` | Handshake message 2, host to phone |
| `0x03` | A transport message: one encrypted message (below) |
| `0x04` | Close: no body. Either side stops the session. |
| `0x05` | Mail: one message, encrypted for a device that may not be connected (`session` is 0) |

## Sessions

Sessions use **Noise_IK_25519_AESGCM_SHA256** ([the Noise protocol](https://noiseprotocol.org/noise.html)),
with the prologue `kuvo-link v1`. The phone starts, knowing the host's static key from
pairing; the host learns the phone's from the first message and checks it.

The first message's payload is JSON:

```json
{"v": 1, "name": "My iPhone", "app": "0.1.0", "pair": "<token>"}
```

`pair` is there only while pairing. The host answers if the phone's key is one it has
paired, or if `pair` is the token it's showing; otherwise it sends a close. Its answer's
payload:

```json
{"v": 1, "kind": "mac", "name": "My MacBook", "app": "0.4.0", "engine": "2.0.30"}
```

`kind` is `mac` or `machine`. Each side checks `v` and closes the session on a version it
doesn't know.

Transport messages then go both ways, in order (the relay keeps the order of one
connection). Any message that doesn't decrypt ends the session.

## Mail

Pushes and other messages for a device that may not be connected use
**Noise_K_25519_AESGCM_SHA256** (both static keys known), with the prologue
`kuvo-link mail v1`: one handshake message carrying the payload. A host's push carries a
notification, below.

## Notifications

What the Mac shows as a notification goes to each paired phone too, as the relay's `push`
with a mail frame, sealed with the sender's static key for the phone's. Its payload, JSON:

```json
{"t": "notify", "title": "Fixer", "subtitle": "kuvo-ai", "body": "Wants to run a command: npm test",
 "category": "permission", "thread": "ses_…", "data": {"session": "ses_…", "request": "per_…"}}
```

| Field | Meaning |
| --- | --- |
| `title` | Who's telling: a bot's name, a session's title, a group chat's name. |
| `subtitle` | Optional: the project, or who in a group chat. |
| `body` | What the Mac shows: the request, the question, the last words of a reply. |
| `category` | What it's about, below. |
| `thread` | What it's grouped under: the session's id, or the group chat's. |
| `data` | Where it opens: `session` or `group`; `request` for a permission or a form, with `requestSession` when the session asking isn't the one shown (a subagent's); `ask` for a browser ask. |

| Category | When |
| --- | --- |
| `permission` | An agent asks to do something. `request` is the permission. |
| `question` | An agent asks a question, or for a form filled in. `request` is the form. |
| `ask` | An agent browsing asks for a sign-in, a code or a step. `ask` is it. |
| `finished` | A run finished. |
| `failed` | A run stopped with an error. |
| `report` | A bot's run finished: a wake-up's or a watch's news. |
| `message` | Something in a group chat. |

A phone should ignore a category it doesn't know, and show the notification plainly.

The payload stays under 2,500 bytes, so the push fits the 4 KB Apple takes: a body that
doesn't fit is cut, ending in "…". Keys are sorted, as both sides write them.

Who sends it:

- **The Mac**, for its own sessions, its group chats and browser asks, and the sessions on
  a machine it's connected to. Only while you're away from it (no input for two minutes, or
  its screen locked), or while a phone has a session open (the phone leaves out what's on
  its screen); at the Mac, its own notifications are enough.
- **A machine's bridge**, for that machine's sessions (permissions, questions, runs finished
  or failed, bots' news), while no Mac is connected to it. A Mac that's connected touches
  `~/.kuvo-code/run/present/<its id>` each minute and removes it when it quits; the bridge
  tells your phones only when none of those files is less than 150 seconds old. The Mac
  tells them only for 120 seconds after it last touched its file, so the two never both do.

## Messages in a session

Each transport message decrypts to:

```
headLength(2) head(JSON) body
```

and is at most 65,519 bytes, so longer bodies go in pieces. The phone asks, the host answers,
like HTTP:

| Head | Meaning |
| --- | --- |
| `{"t": "req", "id": 7, "m": "GET", "p": "api/session?limit=50", "h": {}, "end": true}` | A request. `id` counts up from 1 for each session. `end: false` means `data` pieces follow. |
| `{"t": "res", "id": 7, "s": 200, "h": {"content-type": "…"}, "end": false}` | The response's status and headers, with the first piece of its body. |
| `{"t": "data", "id": 7, "end": false}` | More body. Event streams (`api/event`) go on until cancelled. |
| `{"t": "cancel", "id": 7}` | Either side stops request 7. |
| `{"t": "ping"}`, `{"t": "pong"}` | Is the other end still there? The relay's own pings only reach the relay. |

`h` holds `x-opencode-directory` and `content-type`; the host adds the engine's password
itself. A host serves:

- `api/…`: passed to its engine, if the path is on the host's list (sessions, messages,
  prompts, permissions, questions, events, providers, agents, commands, a project's files,
  terminals). Never accounts or keys. The commands the engine runs for agents are read only:
  `GET api/shell` (those running in the folder `x-opencode-directory` names), `GET
  api/shell/<id>` and `GET api/shell/<id>/output?cursor=&limit=`; running one or removing it is
  refused. Their `shell.created`, `shell.exited` and `shell.deleted` come with `api/event`.
  A subagent's session (`metadata.sessionID` of the `subagent` step that started it) is a session
  like any other, which is how the phone watches and talks to one, as the Mac's subagent tab does:
  read its messages, prompt it (`steer` while it works: it reads it at its next step; once it's
  done, it carries on), `POST api/session/<id>/interrupt` to stop it (the agent waiting on it
  hears it was cancelled, and carries on), and choose its model. Choose it without interrupting:
  an interrupt, even with `resume`, ends that agent's wait, and it gives up on the subagent.
- `POST kuvo/shell/<id>/stop` (`{"session": "ses_…"}`, which may be left out): stops a command an
  agent left running, as Stop over the Mac's composer does: SIGTERM to its process group, so the
  engine sees it end and tells the agent, with what it printed; only if that can't be sent, the
  engine's own remove (which deletes the output, and the agent hears the command wasn't found).
  Answers `200 {"stopped": "signal"}` or `200 {"stopped": "removed"}`, or `404 {}` when no such
  command runs. A machine's bridge does it there (from 0.5.1), with the Mac closed too.
- `kuvo/info`: what the host is and runs; a Mac also names its folder of chats (conversations of
  no project), whether its coding agents' bridge is up (`agents`), and `integrations`, each integration's name by its MCP server's (`{"microsoft-365":
  "Outlook and Microsoft 365", …}`), for a card when one asks something.
- On a Mac, `kuvo/agents/api/…`: the coding agents you already have (Claude Code, Codex,
  Cursor, Grok, Antigravity), through the Mac's agents bridge, which answers the same paths as
  the engine for them: sessions, messages, prompts, permissions, questions, events
  (`kuvo/agents/api/event`) and models (`kuvo/agents/api/model`, only signed-in agents'). Its
  sessions carry `metadata.kuvoAgent` and run on the Mac; a new session with one of their
  models (providers `claude-code`, `codex-cli`, `cursor`, `grok-cli`, `antigravity`) is made
  there, never on the engine. `kuvo/info` has `agents: true` while the bridge is up; otherwise
  these answer 503.
- On a Mac, `kuvo/hosts`: the machines this phone may reach directly, with their addresses
  and static keys, so pairing once with the Mac reaches them all.
- On a Mac, `kuvo/bots`: your bots by their session, wherever they live, with their name,
  look and job, and what only the Mac knows: paused, the next wake-up, how many things each
  watches.
- On a Mac, `kuvo/asks`: what agents ask you for while they browse, on the Mac or a machine: a
  sign-in (the fields the page has, and the accounts Passwords keeps for the site, never
  their passwords), a one-time code, or a step only you can do. `kuvo/asks/events` is the same
  list as a response that doesn't end: a line of JSON now, and another each time it changes.
  `POST kuvo/asks/<id>` answers one: `{"answer": "signIn", "username", "password", "save"}`
  (or `"saved": "<account>"`, which the Mac fills in from Passwords itself), `{"answer":
  "code", "code"}`, `{"answer": "done"}` or `{"answer": "declined"}`. What's typed goes into
  the page, never to the agent.
- On a Mac, `kuvo/groups`: your group chats, with their bots (face, name, session), who's
  talking, whether one is under way or paused, and the last thing said; `kuvo/groups/events`
  streams that list as it changes, and `kuvo/groups/<id>/events` one chat's latest messages,
  the same way. `POST kuvo/groups/<id>` writes to it (`{"text"}`); `…/stop`, `…/keep-going`
  and `…/viewed` do what they say; `…/undo` (`{"message"}`) takes a message of yours back and
  answers with what was taken. A wrap-up can carry `tasks`, who does what: each with `id`, `bot`,
  `task`, `state` (`proposed`, `waiting`, `working`, `done` or `failed`), `started`/`finished`,
  and `after` (the bots whose parts come first; it waits for them);
  `…/start` (`{"message"}`, the wrap-up) hands each proposed part to its bot's own conversation.
  A bot's message with `report` (a task's id) is it reporting back on its part. Times are
  seconds since 1970.
- On a Mac, `kuvo/usage`: the menu bar's usage panel as its Bars view lists it (each provider's
  name, plan, brand color, mark as a PNG to tint, notice, whether it's outdated, and its lines as
  UsageKit writes them), whether a refresh is under way and when the last one ended;
  `kuvo/usage/events` streams it as it changes, and `POST kuvo/usage/refresh` refreshes it all.
  A Mac without the usage panel answers 404. Times are seconds since 1970.

### Sockets

A request with `h.upgrade = "websocket"` opens a WebSocket on the host's engine; today only a
terminal's (`api/pty/<id>/connect`). Its body is empty. The host answers `res` with `s: 101`
once the engine's socket is open, or another status and `end: true` if it won't open. Then
each `data` message for that `id`, either way, is one message on the socket: text, or binary
if `h.type = "binary"`. Text from the engine too long for one message goes in several;
binary that long doesn't go. The phone closes it with `cancel` (or `data` with `end: true`);
when the engine closes it, the host sends `data` with `end: true`.

## Pairing

A host shows a link, as a QR code:

```
kuvo-link://pair?v=1&relay=<relay URL>&host=<address>&key=<static key>&token=<16 bytes>&name=<name>
```

The phone opens a session with `pair` set to the token. The host checks it (and on a Mac
asks you to confirm), then keeps the phone's static key. A token works for 10 minutes and
once.

On a machine the bridge keeps its state in `~/.kuvo-code/run/link.json` (mode 600):

```json
{"relay": "wss://…", "secret": "…", "key": "<static private key>", "phones": [{"key": "…", "name": "…", "added": 1760000000, "from": "mac", "address": "…"}]}
```

The Mac sets the phones paired with it (`"from": "mac"`), so they reach the machine too,
and takes a phone off when you unpair; phones paired with the machine itself (`"pair"`)
stay. `address` is the phone's on the relay, where its notifications go: the Mac passes on
what it knows, and the bridge notes it each time the phone comes in. The machine's keys stay when no phones are left, so pairing again gives the same
address. The bridge reads the file every 30 seconds: a phone taken off loses its sessions,
and with no phones and no pairing waiting the bridge stops.
