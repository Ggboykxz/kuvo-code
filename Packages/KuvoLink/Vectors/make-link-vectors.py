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

json.dump({"addresses": addresses, "relay": relay, "frames": frames, "messages": messages}, open("link.json", "w"), indent=2)
