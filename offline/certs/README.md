# TLS certificates for the offline relay

Buzz desktop 1.0.0 only accepts `wss://` (or `https://`) community addresses —
`ws://` is rejected by the app. So this bundle terminates TLS with **caddy**
(published on `OFFLINE_TLS_PORT`, default **40009**) in front of the plain-HTTP
relay, using a **private CA** created on the server — no public domain or
Let's Encrypt needed.

## Files

| file | where it belongs | committed? |
|---|---|---|
| `install-ca.bat` | copy to each **Windows client** next to `ca.crt` | yes (shipped in the bundle) |
| `uninstall-ca.bat` | same, for decommissioning | yes |
| `ca.crt` | server: here; client: installed into the OS root store | **no** (generated, distributed by hand) |
| `ca.key` | **server only, never copy anywhere** | no |
| `server.crt` / `server.key` | server: here (compose mounts this dir read-only into caddy) | no |

## Server side — issue the certificates once

```bash
cd offline
sudo ./scripts/make-ca.sh --host <server-ip> --port 40009
# first `install.sh` run does this automatically if certs/ is empty
```

`make-ca.sh` creates `ca.crt`/`ca.key` (10y) and `server.crt`/`server.key`
(825d, SAN = the exact host clients type: `IP:…` for an IP, `DNS:…` for a
name; the port is not part of a certificate). It reuses an existing CA, so
re-running it only re-issues the leaf.

Then point the deployment at the TLS address (this also rebinds the
`communities` row so existing data follows):

```bash
sudo ./scripts/set-address.sh --host <server-ip> --port 40009
# .env: OFFLINE_TLS=1, OFFLINE_TLS_PORT=40009, RELAY_URL=wss://<server-ip>:40009
```

## Client side — trust the CA once per machine

The app verifies wss with the **OS root store**, so the CA root must be
installed there once:

- **Windows:** copy `ca.crt` and `install-ca.bat` to the PC, right-click
  `install-ca.bat` → **Run as administrator** (one click; it runs
  `certutil -addstore -f Root ca.crt`). Remove later with `uninstall-ca.bat`.
- **macOS:** `sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ca.crt`
- **Linux:** `sudo cp ca.crt /usr/local/share/ca-certificates/buzz-offline-ca.crt && sudo update-ca-certificates`

`ca.crt` is a public certificate — safe to email/copy. `ca.key` must never
leave the server.

Then in the Buzz desktop app: **Add community → `wss://<server-ip>:40009`**.

## Browser

`https://<server-ip>:40009/invite/<code>` works in a browser once the CA is
installed (otherwise the browser shows its own certificate warning — accept it
or install the CA as above).
