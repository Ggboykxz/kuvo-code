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
`kuvo-link mail v1`: one handshake message carrying the payload, JSON:

```json
{"t": "notify", "title": "…", "body": "…", "category": "permission", "thread": "…", "data": {}}
```

An APNs push holds at most 4 KB, so a notification's mail stays under about 2.5 KB.

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
  prompts, permissions, questions, events, providers, agents, commands). Never accounts or
  keys.
- `kuvo/info`: what the host is and runs.
- On a Mac, `kuvo/hosts`: the machines this phone may reach directly, with their addresses
  and static keys, so pairing once with the Mac reaches them all.

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
{"relay": "wss://…", "secret": "…", "key": "<static private key>", "phones": [{"key": "…", "name": "…", "added": 1760000000, "from": "mac"}]}
```

The Mac sets the phones paired with it (`"from": "mac"`), so they reach the machine too,
and takes a phone off when you unpair; phones paired with the machine itself (`"pair"`)
stay. The machine's keys stay when no phones are left, so pairing again gives the same
address. The bridge reads the file every 30 seconds: a phone taken off loses its sessions,
and with no phones and no pairing waiting the bridge stops.
