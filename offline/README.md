# Offline Buzz relay bundle

A self-contained, air-gapped Buzz relay: one tarball of Docker images, one
compose file, TLS at the edge (caddy + a private CA issued on the server), no
internet. Plain HTTP (`ws://`) remains available as a legacy option.

This directory is a **layer above upstream**. It never patches relay source; it
consumes the published `ghcr.io/block/buzz` image and pins it by digest. When
upstream moves, only `images.lock` changes — there is nothing to rebase.

| # | Requirement | How it is met |
|---|---|---|
| 1 | Run fully offline | Every image ships as a `docker save` tarball; compose sets `pull_policy: never`; Postgres/Redis/object storage/git are local; push gateway, GIF search, NIP-FI and mesh are explicitly off; data services sit on a Docker `internal` network with no gateway |
| 2 | Reachable at `wss://<server-ip>:40009` | Caddy (TLS terminator, `tls` compose profile) publishes the public port and proxies to the relay; the relay serves web + WebSocket on :3000 internally |
| 3 | TLS with a private CA | `scripts/make-ca.sh` issues the CA + a leaf whose SAN is the exact host clients type (IP or DNS) — no public domain or Let's Encrypt needed. Clients trust `ca.crt` once per machine (Windows: `certs/install-ca.bat`). `RELAY_URL` is `wss://…`, so the relay mints `https://` media and invite URLs. `install.sh --no-tls` keeps the legacy plain-HTTP `ws://` deployment |
| 4 | Survives upstream updates | Images are vendored by digest; the overlay is this directory plus one workflow file, both of which upstream never touches |
| 5 | Images as files on a GitHub Release | `.github/workflows/offline-bundle.yml` runs `docker save` and publishes `*-linux-<arch>.tar.gz` + `SHA256SUMS-<arch>` as release assets |
| 6 | Auto-release when images change | Daily digest check; a release is cut only when a digest actually moved (or `force` on a manual run) |

## Architecture

```
                host port 40009 (wss/https)
                          │
              ┌───────────▼────────────┐
              │ caddy  (tls profile)   │  terminates TLS with certs/server.{crt,key}
              └───────┬────────────────┘
              ┌───────────▼────────────┐
              │ relay (buzz image)     │  web UI + WebSocket + REST on :3000 (plain HTTP inside)
              │  RELAY_URL=wss://<host>:40009 │  health router on :8080 (loopback only)
              └───────┬────────────────┘
        internal network (no gateway)
      ┌───────────┬───┴───────┬──────────────┐
  postgres      redis      silo (s3)     /data/git volume
```

**Nothing in the stack needs an internet route, and nothing may use one.**

- The dependency plane (Postgres, Redis, object store) is on an `internal`
  network with no gateway: it has no route out, by construction.
- The relay needs a non-internal network because Docker only publishes ports
  for containers attached to one. That network is created with
  `enable_ip_masquerade=false`, so the relay's outbound packets carry an
  unroutable `10.42.250.0/24` source — it accepts inbound connections on the
  published port and cannot get a reply from anything outside. Treat that as
  defense in depth, not a guarantee: packets still leave the interface.
- For a hard guarantee on a host that does have an internet route, block it at
  the host firewall:

  ```bash
  sudo scripts/lockdown.sh apply     # DOCKER-USER: drop egress, keep replies
  scripts/lockdown.sh status
  ```

  The rules sit in `DOCKER-USER`, survive `docker compose down/up`, and are
  installed as a systemd unit so they come back after a reboot. On a genuinely
  air-gapped host they are belt-and-braces: `verify.sh` already passes because
  the probe has no route.

Every run of `verify.sh` asserts this both ways: each container must fail to
reach `1.1.1.1:443`, **and** the published port must still answer HTTP 200 from
outside the container.

## Getting a bundle

**From the release** (normal path). Each architecture is published as **one
archive**, so there is a single file to carry to the offline host:

```
buzz-offline-amd64-<release>.tar.gz          everything below, in one file
buzz-offline-amd64-<release>.tar.gz.sha256   its checksum

  QUICKSTART.md              step-by-step install, in Korean
  offline/                   this layer: compose, scripts, README
  offline/images/            relay, postgres, redis, silo, mc, caddy `docker save`
                             tarballs + images-<arch>.json/.txt + SHA256SUMS-<arch>
  offline/certs/             install-ca.bat / uninstall-ca.bat / README
                             (the CA itself is generated on the server and is
                             NOT in the archive)
  docker-debs/               (amd64 only) Docker Engine + compose .debs, the
                             iptables/nftables closure, install.sh
```

**Built locally** (needs internet and Docker):

```bash
cd offline
make bundle ARCH=arm64            # or ARCH=amd64, output in ./dist
```

## Install on the offline host

```bash
sha256sum -c buzz-offline-amd64-<release>.tar.gz.sha256
tar -xzf buzz-offline-amd64-<release>.tar.gz
cd buzz-offline-amd64-<release>

sudo docker-debs/install.sh          # only if docker is not installed yet
cd offline
sudo ./scripts/install.sh --host <server-ip> --tls-port 40009
```

Nothing has to be moved around: the archive already puts the image tarballs in
`offline/images/`, which is where `install.sh` looks.

`install.sh` verifies checksums, loads the images (never pulls), issues the
private CA + server certificate into `certs/` (`make-ca.sh`), generates `.env`
(relay key, HMAC secret, database/Redis/S3 credentials), starts the stack with
the `tls` profile, waits for `/_readiness` and runs `verify.sh`.

Clients then use **`wss://<server-ip>:40009`** — Buzz desktop 1.0.0 accepts only
`wss://` or `https://` (a bare host is upgraded to `wss://`; `ws://` is
rejected by the app). Each client PC must trust the relay's CA root **once**:
copy `offline/certs/ca.crt` + `offline/certs/install-ca.bat` to the PC and run
the `.bat` as Administrator (one click). See [TLS and certificates](#tls-and-certificates).

Legacy plain-HTTP deployment: `sudo ./scripts/install.sh --host <server-ip>
--no-tls --port 80`, clients then use `ws://<server-ip>` (older clients only).

### What `https://<host>:<tls-port>` actually serves

| path | response |
|---|---|
| `/` (plain GET) | the relay's NIP-11 document (JSON): NIPs, limits, relay pubkey |
| `/` (WebSocket upgrade) | the relay protocol |
| `/invite/<code>` | the Buzz web bundle — this is what an invite link opens |
| `/assets/*`, `/media/*`, `/query`, … | bundle assets, media, HTTP query API |

The relay does not serve the full app at `/`; upstream serves the SPA only on
invite landing paths. So an invite link (`https://<host>:<tls-port>/invite/<code>`)
is the browser entry point, and the desktop app pointed at
`wss://<host>:<tls-port>` is the normal client. If you want the app itself at
`/`, that needs a small static front end in front of the relay — say the word
and it can be added as an optional service.

## Changing the address

The address is configuration, not a rebuild:

```bash
./scripts/set-address.sh --host 10.0.0.7                  # same wss port
./scripts/set-address.sh --host buzz.example.lan --port 40009
```

This rewrites `OFFLINE_PUBLIC_HOST`, `OFFLINE_HTTP_PORT` and `RELAY_URL` in
`.env` and recreates the relay. Two things must move together:

1. **`RELAY_URL`** — baked into NIP-42 auth challenges, invite links, media URLs
   and git clone URLs. A stale value authenticates nothing even though the
   socket connects.
2. **The `communities` row** — a relay resolves each request to a community by
   `Host` header, and the community host comes from `RELAY_URL`. Restarting with
   a new `RELAY_URL` and no rebind provisions a *new, empty* community and
   leaves every message behind under the old host. `set-address.sh` renames the
   existing row (`UPDATE communities SET host = …`), and because every
   tenant-scoped row hangs off `communities.id`, the data follows the address.

`install.sh --host/--port` delegates to `set-address.sh`, so either entry point
is safe. With TLS on, a host change re-issues the leaf certificate automatically
when the SAN no longer matches (`make-ca.sh` reuses the existing CA, so client
trust is unaffected).

## Upgrading (one step)

```bash
# carry the new release archive + its .sha256 to the server, then:
sudo <설치경로>/offline/scripts/upgrade.sh --bundle buzz-offline-<arch>-<release>.tar.gz
```

`upgrade.sh` verifies the sha256, extracts the new bundle next to the current
install, copies the existing `.env` **and `certs/`** (private CA) into it, and
re-runs the new `install.sh` without `--force`: relay identity, secrets, data
volumes and the CA all survive; only the image tags and `OFFLINE_RELEASE` move.
The old directory is kept until you delete it. `--force` on `install.sh`
regenerates `.env` and is destructive: it changes the relay identity.

## TLS and certificates

Buzz desktop 1.0.0 accepts only `wss://`/`https://` for a community address, so
the bundle terminates TLS with **caddy** (started under the `tls` compose
profile when `OFFLINE_TLS=1`, the default) and a **private CA** — no public
domain, DNS or Let's Encrypt needed on a company server:

```bash
sudo ./scripts/make-ca.sh --host <server-ip> --port 40009   # once; install.sh runs it too
```

- `certs/ca.crt` + `ca.key` — the CA (10y). `ca.key` never leaves the server;
  `ca.crt` is public and is what clients install.
- `certs/server.crt` + `server.key` — the leaf (825d) with SAN = the exact host
  clients type (`IP:` for an IP, `DNS:` for a name; the port is not in the cert).
- Server side: compose mounts `offline/certs` read-only into caddy (`Caddyfile`,
  `tls /certs/server.crt /certs/server.key` — no ACME).
- Client side (once per machine; the app verifies wss with the OS root store):
  - **Windows:** copy `ca.crt` + `certs/install-ca.bat` to the PC, right-click →
    *Run as administrator* (runs `certutil -addstore -f Root ca.crt`).
    `uninstall-ca.bat` removes it again.
  - macOS: `sudo security add-trusted-cert -d -r trustRoot -k /Library/Keychains/System.keychain ca.crt`
  - Linux: `sudo cp ca.crt /usr/local/share/ca-certificates/buzz-offline-ca.crt && sudo update-ca-certificates`
- Then in the app: **Add community → `wss://<server-ip>:40009`**.
- `verify.sh` checks the chain (`openssl verify -CAfile certs/ca.crt`) and the
  SAN (`openssl x509 -checkhost`), plus a live TLS handshake on the published port.

Details: [certs/README.md](certs/README.md).

## Why the CA is not on the GitHub release

The client never downloads certificates from the network; it only uses the OS
trust store. The CA is therefore **issued on the relay server**
(`make-ca.sh`) and `ca.crt` is distributed by hand to each client PC (the
bundle ships only `install-ca.bat`/`uninstall-ca.bat`/`README.md` — never
`ca.key`). Uploading `ca.crt` to the release page is optional convenience only;
nothing depends on it.

## Plain HTTP (legacy, `ws://`) — what it costs

`install.sh --no-tls` publishes the relay's port directly and sets
`RELAY_URL=ws://…`. Everything Nostr-native works: identity, signing, NIP-42
auth, relay traffic, media, git over HTTP. What breaks is browser
**secure-context** surface in the web UI served over `http://`:

- microphone/camera (huddle audio, media capture) is blocked by the browser
- service worker / PWA install, `navigator.clipboard`, WebCrypto in some paths
- mobile push (off by default here anyway)

More importantly, **desktop 1.0.0 rejects `ws://` outright** ("Enter a community
address or invite link."), so plain HTTP is only for older clients. The TLS
default above is the supported path.

## Backup and restore

```bash
./scripts/backup.sh                # database, .env, git volume
./scripts/backup.sh --with-media   # also object-store blobs (can be large)
```

The restore outline is printed at the end of every backup. Volumes are named
`buzz-offline_buzz-{postgres,redis,silo,git}-data`.

## Upstream tracking and the release workflow

`.github/workflows/offline-bundle.yml`:

1. **resolve** — reads `offline/images.lock`, resolves the current registry
   digest of every image (relay follows `upstream_tag`, default `main`), and
   compares. No movement → the run stops here, no release.
2. **package** — one native runner per architecture pulls each image *by
   digest*, `docker save`s it into `*-linux-<arch>.tar.gz`, and tars the
   `offline/` directory itself.
3. **release** — creates `offline-<UTC date>` with every asset, then commits the
   refreshed lock back to the default branch with `[skip ci]`.

Manual runs accept `upstream_tag` (e.g. pin to relay `0.3.0` instead of the
rolling `main`), `arches`, and `force`.

Notes:

- Scheduled workflows are disabled on forks after long inactivity; re-enable
  them in the Actions tab (or dispatch manually) if a fork goes quiet.
- The workflow skips itself inside `block/buzz` unless the repository variable
  `OFFLINE_BUNDLE_IN_CORE` is `true`, so an upstream merge cannot publish
  releases there.
- The relay image tracks upstream's rolling `main` by default. For a stable
  release train set `upstream_tag` to a `relay-v*` semver.

## Verify

```bash
./scripts/verify.sh          # services, health, web UI, WebSocket upgrade
make verify-deep             # NIP-42 auth + publish + read-back (needs python3 + websockets)
```

`verify-nip42.py` signs a real auth event in pure Python and publishes/reads a
test note, so it proves the write path end to end rather than just an open
socket.
