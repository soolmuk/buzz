#!/usr/bin/env python3
"""Deep offline verification: NIP-42 auth, publish, read-back.

Run from a workstation that has python3 + the `websockets` package:

    python3 scripts/verify-nip42.py wss://203.0.113.10:40009   # wss verifies against offline/certs/ca.crt

It signs a real Nostr auth event (BIP340, pure Python — no dependencies beyond
`websockets`), authenticates, publishes a kind:1 event and reads it back by id.
This is what proves the write path works, not just that a socket opens.

Exit codes: 0 pass, 1 fail.
"""

from __future__ import annotations

import asyncio
import hashlib
import json
import os
import secrets
import ssl
import sys
import time

try:
    import websockets
except ImportError:  # pragma: no cover - operator hint
    sys.exit("python3 -m pip install websockets  (then re-run)")

# ── secp256k1 / BIP340, small enough to keep the bundle dependency-free ──────
P = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEFFFFFC2F
N = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFEBAAEDCE6AF48A03BBFD25E8CD0364141
G = (
    0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798,
    0x483ADA7726A3C4655DA4FBFC0E1108A8FD17B448A68554199C47D08FFB10D4B8,
)


def _inv(a: int) -> int:
    return pow(a, P - 2, P)


def _add(a, b):
    if a is None:
        return b
    if b is None:
        return a
    if a[0] == b[0] and (a[1] + b[1]) % P == 0:
        return None
    if a == b:
        lam = 3 * a[0] * a[0] % P * _inv(2 * a[1] % P) % P
    else:
        lam = (b[1] - a[1]) % P * _inv((b[0] - a[0]) % P) % P
    x = (lam * lam - a[0] - b[0]) % P
    return (x, (lam * (a[0] - x) - a[1]) % P)


def _mul(k: int, point):
    result = None
    addend = point
    while k:
        if k & 1:
            result = _add(result, addend)
        addend = _add(addend, addend)
        k >>= 1
    return result


def _tagged_hash(tag: str, msg: bytes) -> bytes:
    th = hashlib.sha256(tag.encode()).digest()
    return hashlib.sha256(th + th + msg).digest()


def schnorr_sign(seckey: bytes, msg: bytes):
    d0 = int.from_bytes(seckey, "big")
    if not 0 < d0 < N:
        raise ValueError("invalid secret key")
    point = _mul(d0, G)
    d = d0 if point[1] % 2 == 0 else N - d0
    px = point[0].to_bytes(32, "big")
    aux = _tagged_hash("BIP0340/nonce", px + d.to_bytes(32, "big") + msg)
    k0 = int.from_bytes(aux, "big") % N
    if k0 == 0:
        raise ValueError("nonce is zero")
    r = _mul(k0, G)
    k = k0 if r[1] % 2 == 0 else N - k0
    rx = r[0].to_bytes(32, "big")
    e = int.from_bytes(_tagged_hash("BIP0340/challenge", rx + px + msg), "big") % N
    return px, rx + ((k + e * d) % N).to_bytes(32, "big")


def make_event(seckey: bytes, kind: int, content: str, tags: list[list[str]]) -> dict:
    point = _mul(int.from_bytes(seckey, "big"), G)
    pubkey = point[0].to_bytes(32, "big")
    event = {
        "pubkey": pubkey.hex(),
        "created_at": int(time.time()),
        "kind": kind,
        "tags": tags,
        "content": content,
    }
    serialized = json.dumps(
        [0, event["pubkey"], event["created_at"], event["kind"], event["tags"], event["content"]],
        separators=(",", ":"),
        ensure_ascii=False,
    ).encode()
    event_id = hashlib.sha256(serialized).digest()
    _, sig = schnorr_sign(seckey, event_id)
    event["id"] = event_id.hex()
    event["sig"] = sig.hex()
    return event


def check_event_id(event: dict) -> bool:
    serialized = json.dumps(
        [0, event["pubkey"], event["created_at"], event["kind"], event["tags"], event["content"]],
        separators=(",", ":"),
        ensure_ascii=False,
    ).encode()
    return hashlib.sha256(serialized).hexdigest() == event["id"]


# ── relay checks ────────────────────────────────────────────────────────────
PASS = "\033[1;32mok\033[0m"
FAIL = "\033[1;31mFAIL\033[0m"


async def recv_until(ws, wanted: str, timeout: float = 10.0):
    """Return the first message whose first element is `wanted`."""
    async with asyncio.timeout(timeout):
        while True:
            msg = json.loads(await ws.recv())
            if isinstance(msg, list) and msg and msg[0] == wanted:
                return msg


async def main(url: str) -> int:
    seckey = secrets.token_bytes(32)
    failures = 0

    def report(condition: bool, label: str, detail: str = ""):
        nonlocal failures
        if condition:
            print(f"  {PASS}   {label}")
        else:
            failures += 1
            print(f"  {FAIL} {label}{(' — ' + detail) if detail else ''}")

    print(f"NIP-42 round trip against {url}")
    ssl_ctx = None
    if url.lower().startswith("wss://"):
        # Verify against the bundle CA when it sits next to this script's
        # offline layer (offline/certs/ca.crt); otherwise the system roots.
        ca = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "certs", "ca.crt")
        if os.path.isfile(ca):
            ssl_ctx = ssl.create_default_context(cafile=ca)
        else:
            ssl_ctx = ssl.create_default_context()
    async with websockets.connect(url, open_timeout=10, ssl=ssl_ctx) as ws:
        challenge_msg = await recv_until(ws, "AUTH")
        challenge = challenge_msg[1]
        report(bool(challenge), "AUTH challenge received")

        auth = make_event(
            seckey,
            22242,
            "",
            [["relay", url], ["challenge", challenge]],
        )
        report(check_event_id(auth), "locally signed event id is well formed")
        await ws.send(json.dumps(["AUTH", auth]))
        result = await recv_until(ws, "OK")
        report(bool(result[2]), "AUTH accepted", str(result[3:]))

        note = make_event(
            seckey,
            1,
            f"buzz offline smoke test {int(time.time())}",
            [["t", "offline-smoke"]],
        )
        await ws.send(json.dumps(["EVENT", note]))
        published = await recv_until(ws, "OK")
        accepted = bool(published[2])
        report(accepted, "event publish accepted", str(published[3:]))

        if accepted:
            await ws.send(json.dumps(["REQ", "smoke", {"ids": [note["id"]]}]))
            stored = await recv_until(ws, "EVENT", timeout=10)
            report(stored[2].get("id") == note["id"], "published event read back by id")
            await ws.send(json.dumps(["CLOSE", "smoke"]))
        else:
            print("  ---- write path restricted (closed relay); read path follows")
            await ws.send(json.dumps(["REQ", "smoke", {"kinds": [0], "limit": 1}]))
            eose = await recv_until(ws, "EOSE", timeout=10)
            report(bool(eose), "REQ answered with EOSE")

    print()
    if failures:
        print(f"\033[1;31m{failures} check(s) failed\033[0m")
        return 1
    print("\033[1;32mnip42 round trip passed\033[0m")
    return 0


if __name__ == "__main__":
    target = sys.argv[1] if len(sys.argv) > 1 else os.environ.get("RELAY_URL", "wss://127.0.0.1:40009")
    if target.lower().startswith("https://"):
        target = "wss://" + target[len("https://"):]
    elif target.lower().startswith("http://"):
        target = "ws://" + target[len("http://"):]
    sys.exit(asyncio.run(main(target)))
