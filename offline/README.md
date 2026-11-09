# Offline Buzz relay bundle

A self-contained, air-gapped Buzz relay: one tarball of Docker images, one
compose file, plain HTTP, no internet, no TLS, no reverse proxy.

This directory is a **layer above upstream**. It never patches relay source; it
consumes the published `ghcr.io/block/buzz` image and pins it by digest. When
upstream moves, only `images.lock` changes — there is nothing to rebase.

| # | Requirement | How it is met |
|---|---|---|
| 1 | Run fully offline | Every image ships as a `docker save` tarball; compose sets `pull_policy: never`; Postgres/Redis/object storage/git are local; push gateway, GIF search, NIP-FI and mesh are explicitly off; data services sit on a Docker `internal` network with no gateway |
| 2 | Reachable at `http://<server-ip>` | Relay port 3000 is published on host port 80; the relay serves the web UI and the WebSocket on that one port |
| 3 | HTTP, not HTTPS | No TLS terminator at all — see [Why no Caddy](#why-no-caddy). `RELAY_URL` is `ws://…`, which makes the relay mint `http://` media and invite URLs |
| 4 | Survives upstream updates | Images are vendored by digest; the overlay is this directory plus one workflow file, both of which upstream never touches |
| 5 | Images as files on a GitHub Release | `.github/workflows/offline-bundle.yml` runs `docker save` and publishes `*-linux-<arch>.tar.gz` + `SHA256SUMS-<arch>` as release assets |
| 6 | Auto-release when images change | Daily digest check; a release is cut only when a digest actually moved (or `force` on a manual run) |

## Architecture

```
                     host port 80
                          │
              ┌───────────▼────────────┐
              │ relay (buzz image)     │  web UI + WebSocket + REST on :3000
              │  RELAY_URL=ws://<host> │  health router on :8080 (loopback only)
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
  offline/images/            relay, postgres, redis, silo, mc `docker save`
                             tarballs + images-<arch>.json/.txt + SHA256SUMS-<arch>
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
sudo ./scripts/install.sh --host 166.103.175.321 --port 80
```

Nothing has to be moved around: the archive already puts the image tarballs in
`offline/images/`, which is where `install.sh` looks.

`install.sh` verifies checksums, loads the images, generates `.env` (relay key,
HMAC secret, database/Redis/S3 credentials), starts the stack, waits for
`/_readiness` and runs `verify.sh`.

Then point a client at `ws://166.103.175.321` — **type `ws://` explicitly**; the
Buzz client assumes `wss://` for a bare host.

### What `http://<host>` actually serves

| path | response |
|---|---|
| `/` (plain GET) | the relay's NIP-11 document (JSON): NIPs, limits, relay pubkey |
| `/` (WebSocket upgrade) | the relay protocol |
| `/invite/<code>` | the Buzz web bundle — this is what an invite link opens |
| `/assets/*`, `/media/*`, `/query`, … | bundle assets, media, HTTP query API |

The relay does not serve the full app at `/`; upstream serves the SPA only on
invite landing paths. So an invite link (`http://<host>/invite/<code>`) is the
browser entry point, and the desktop app pointed at `ws://<host>` is the normal
client. If you want the app itself at `/`, that needs a small static front end
in front of the relay — say the word and it can be added as an optional service.

## Changing the address

The address is configuration, not a rebuild:

```bash
./scripts/install.sh --host 10.0.0.7              # same port
./scripts/install.sh --host buzz.example.lan --port 8080
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
is safe.

## Upgrading

```bash
# drop the new release assets into ./images, then
./scripts/install.sh --host <same-as-before>
```

Existing secrets and volumes are preserved; only the image tags and
`OFFLINE_RELEASE` move. `--force` regenerates `.env` and is destructive: it
changes the relay identity.

## Why no Caddy

Caddy in the upstream compose bundle exists to terminate TLS and get a Let's
Encrypt certificate. With `http://` there is nothing to terminate: the relay
already serves the app and the WebSocket on the same origin, so publishing port
80 straight to the relay is the whole deployment. Add a proxy only if you
later want a domain and HTTPS (`wss://`) — that is a separate decision, and
`RELAY_URL` plus `OFFLINE_HTTP_PORT` are the knobs it needs.

### What plain HTTP costs you

Everything Nostr-native works: identity, signing, NIP-42 auth, relay traffic,
media, git over HTTP. What breaks is browser **secure-context** surface in the
web UI served over `http://`:

- microphone/camera (huddle audio, media capture) is blocked by the browser
- service worker / PWA install, `navigator.clipboard`, WebCrypto in some paths
- mobile push (off by default here anyway)

The desktop app is not affected by those browser rules, so the recommended
client for an HTTP deployment is the desktop build pointed at `ws://<host>`.

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
