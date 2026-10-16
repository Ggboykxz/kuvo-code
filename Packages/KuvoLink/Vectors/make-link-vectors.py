#!/usr/bin/env python3
"""Writes link.json: addresses, relay messages, link frames and session messages, worked out
here independently of the Swift and JavaScript implementations, which both check against it."""
import hashlib, json, struct

def address(secret):
    return hashlib.sha256(b"kuvo-link address v1" + secret).digest()[:16]

secrets = [bytes(range(32)), bytes([0xff] * 32), hashlib.sha256(b"kuvo").digest()]
addresses = [{"secret": s.hex(), "address": address(s).hex()} for s in secrets]
a, b = address(secrets[0]), address(secrets[1])

relay = [
    {"name": "hello", "from": "device", "bytes": (b"\x01" + secrets[0]).hex()},
    {"name": "welcome", "from": "relay", "address": a.hex(), "bytes": (b"\x01" + a).hex()},
    {"name": "send", "from": "device", "to": b.hex(), "payload": "68656c6c6f", "bytes": (b"\x02" + b + b"hello").hex()},
    {"name": "deliver", "from": "relay", "address": a.hex(), "payload": "68656c6c6f", "bytes": (b"\x02" + a + b"hello").hex()},
    {"name": "unreachable", "from": "relay", "address": b.hex(), "bytes": (b"\x03" + b).hex()},
    {"name": "pushed", "from": "relay", "address": b.hex(), "status": 2, "bytes": (b"\x06" + b + b"\x02").hex()},
]

frames = [
    {"kind": kind, "session": session, "body": body.hex(), "bytes": (bytes([kind]) + struct.pack(">I", session) + body).hex()}
    for kind, session, body in [(1, 1, b"\x00" * 3), (3, 0xDEADBEEF, b"ciphertext"), (4, 42, b""), (5, 0, b"mail")]
]

def message(head, body):
    encoded = json.dumps(head, separators=(",", ":"), sort_keys=True).encode()
    return {"head": head, "body": body.hex(), "bytes": (struct.pack(">H", len(encoded)) + encoded + body).hex()}

messages = [
    message({"t": "req", "id": 1, "m": "GET", "p": "api/session?limit=50", "h": {"x-opencode-directory": "/home/me/p"}, "end": True}, b""),
    message({"t": "res", "id": 1, "s": 200, "h": {"content-type": "application/json"}, "end": True}, b'[{"id":"ses_1"}]'),
    message({"t": "data", "id": 7, "end": False}, b"data: {}\n\n"),
    message({"t": "cancel", "id": 7}, b""),
    message({"t": "ping"}, b""),
]

# What a phone may ask an engine for, through a Mac or a machine: the same on both.
routes = [{"path": p, "allowed": a} for p, a in [
    ("api/session", True), ("api/session?limit=50&order=desc", True), ("api/session/ses_1/prompt", True),
    ("api/session/active", True), ("api/event", True), ("api/event?x=1", True), ("api/info", True),
    ("api/provider", True), ("api/model/default", True), ("api/permission/saved", True), ("api/form", True),
    ("api/experimental/session/ses_1/wait", True), ("api/experimental/session/ses_1/instructions/entries/k", False),
    ("api/credential", False), ("api/credential/anthropic", False), ("api/integration/github/connect/key", False),
    ("api/config", False), ("api/config/shell", False), ("api/mcp", False), ("api/plugin", False),
    ("api/fs/list", True), ("api/fs/list?path=Sources", True), ("api/fs/find?query=main", True),
    ("api/fs/read/Sources/main.swift", True), ("api/fs/read", False), ("api/fs/write/x", False), ("api/fs/read/../../etc/hosts", False),
    ("api/fs/list?path=%2E%2E", False), ("api/fs/list?path=..%2F", False), ("api/fs/read/%2e%2e%2fsecret", False),
    ("api/session/%2E%2E/credential", False), ("api/session/%2e%2e/credential", False), ("api/session%2f..%2fcredential", False),
    ("api/fs/read/..%5c..%5csecret", False), ("api/fs/read/a%5cb", False), ("api/fs/read/bad%E0%A4%A", False),
    ("api/sessions", False), ("api/eventual", False), ("api/session/../credential", False), ("kuvo/info", False), ("", False),
]]

json.dump({"addresses": addresses, "relay": relay, "frames": frames, "messages": messages, "routes": routes}, open("link.json", "w"), indent=2)
