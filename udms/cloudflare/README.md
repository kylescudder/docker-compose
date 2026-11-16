# UDMS remote access

The dedicated `forge-udms` Cloudflare Tunnel runs as `udms-cloudflared` in the
Colima Docker context. It reaches the existing applications over `udms_default`.
No router port forwarding is required. Keep Colima and the stack running on Forge.

Listarr is a **proposed addition**, not a provisioned public service. Its desired
route is recorded in `ingress.json`, but DNS and remotely managed tunnel changes
have not been applied. See [Listarr configuration and rollout](../LISTARR.md).
Keep `listarr.thescudders.org` outside the blanket Access application: browsing
and feed export are public, and direct Radarr creation uses optional Clerk with
a server-side user allowlist. Its default feed origin is internal (`listarr:3211`)
so Radarr never needs an interactive proxy login.

The public URLs are:

- https://sonarr.thescudders.org
- https://radarr.thescudders.org
- https://prowlarr.thescudders.org
- https://bazarr.thescudders.org
- https://readarr.thescudders.org
- https://lidarr.thescudders.org
- https://qbittorrent.thescudders.org
- https://sabnzbd.thescudders.org
- https://portainer.thescudders.org
- https://dozzle.thescudders.org
- https://emby.thescudders.org
- https://watch.thescudders.org
- https://sortarr.thescudders.org
- https://trailarr.thescudders.org

Each hostname has a proxied CNAME to
`b0a22ef6-b482-4a51-ac9b-b6506705085d.cfargotunnel.com`.
`ingress.json` records the desired remotely managed ingress configuration, including
the pending Listarr addition. Its final rule
returns 404 for unmatched hostnames.

The `Forge UDMS arr stack` Access application
(`8e0f7e0d-502a-4f61-8b18-95cf301894b2`) covers all fourteen hostnames with the existing
`Kyle only` email allowlist and a 12-hour session. Sign in through Cloudflare
Access first, then use each application's existing login where enabled.
App URLs, app authentication, and existing integrations retain their settings.

Sonarr, Radarr and Prowlarr only accept hosts listed in `AllowedHosts` in their
`config.xml`, so each public hostname was appended there (backups are saved as
`config.xml.pre-cloudflare` in each app's appdata directory). Without that, the apps
answer `400 Invalid Hostname`. The routes pass the public Host through unchanged so the
apps' login redirects point at the public URL; Cloudflare upgrades their `http://`
redirect to HTTPS.

Portainer and Dozzle were joined to the `udms_default` network (Portainer's compose file
gained `default`) so the tunnel can reach `portainer:9000` and `dozzle:8080`. Portainer
controls Docker on this machine, so keep its own login enabled behind Access.

Both `watch.thescudders.org` and `emby.thescudders.org` reach Emby at `emby:8096`
behind Access, so the Emby phone and TV apps
cannot sign in through this hostname; use the browser, or a private network for the apps.
Heavy video streaming through Cloudflare's proxy is against their terms.

Sortarr (`compose/udms/sortarr.yml`) is behind Access like the rest while Kyle is its only
user, then its own Better Auth sign-in for an allowlist of members
(`SORTARR_AUTH_ALLOWED_EMAILS`). Better Auth is designed to be its only gate, so when
someone else needs access, remove `sortarr.thescudders.org` from the Access application
and restore its entry in `APP_GATED` in `verify-cloudflare.py`. It publishes no host port,
reaches Radarr directly at `radarr:7878`, keeps its accounts in `sortarr-db`, and only
accepts searches whose Origin is `https://sortarr.thescudders.org`. The one-shot
`sortarr-migrate` container applies database migrations with the owner role and exits
before `sortarr` starts. Their connection strings live in `.env` as `SORTARR_DATABASE_URL`
(runtime role) and `SORTARR_MIGRATE_DATABASE_URL` (owner role), each built from the
matching `SORTARR_DB_*_PASSWORD` variable, so no credential URL appears in the repo.

qBittorrent and SABnzbd share Gluetun's network namespace. Their tunnel origins
use `gluetun:8081` and `gluetun:8080`, respectively. SABnzbd refuses non-local clients by default, so `inet_exposure` was raised from 0 to 4
(web interface) and the public hostname added to its `host_whitelist`. SABnzbd also has
its own username and password, so it needs two logins (Access, then SABnzbd). The
original `sabnzbd.ini` is saved as `sabnzbd.ini.pre-cloudflare`. Its public hostname
remains protected by Access. No downloader restart or
download queue change is needed for these routes.

Trailarr (`compose/udms/trailarr.yml`) is reached at `trailarr:7889` behind Access, then its
own login (user `admin`; password in the 1Password Forge vault item `Trailarr - Forge`).

## Credentials and operation

The tunnel token is stored outside this repository at
`$DOCKERDIR/appdata/cloudflared-udms/token`, with mode 0600 and a private parent
directory. Compose mounts it read-only. The container runs without Linux
capabilities and with a read-only root filesystem. Do not commit this token.

The provisioning API token remains in the Forge 1Password vault item
`Cloudflare API Key - Forge`. It is not needed by the running connector.
To recover a missing tunnel token, retrieve the dedicated tunnel's token through
Cloudflare's API or dashboard and restore the private file before starting Compose.

From the `udms` directory:

```sh
docker --context colima compose config --quiet
docker --context colima compose up -d --no-deps cloudflared
docker --context colima compose logs --tail 50 cloudflared
docker --context colima exec sonarr curl --fail http://cloudflared:2000/ready
```

The connector uses `restart: unless-stopped`. Its readiness and metrics endpoint
is available only inside the Docker network on port 2000.

## Verification

From the repository root:

```sh
python3 udms/verify-cloudflare.py
```

This performs three live HTTPS assertions per Access host: the home page, an
API path, and an invalid session cookie must all redirect to Cloudflare Access.
Hosts listed in `APP_GATED` (none today) get the app's own sign-in gate checked instead.
Listarr is explicitly listed in `PUBLIC_APPS`; it must serve public HTML, health
JSON and the exact anonymous `/api/feed?ids=438631` response. These checks will fail
until the proposed service and route are deployed. An Access redirect fails these
public checks. For the other hosts, unexpected public access fails verification.
TLS failures and edge errors fail verification for all hosts.
It does not prove that a signed-in user can use an app or that the app is healthy.

During initial provisioning, five origins responded locally. Lidarr was already
unavailable on port 8686; its DNS and Access route are configured, but the app
itself must become healthy before it can serve requests.
