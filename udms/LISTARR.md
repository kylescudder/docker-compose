# Listarr on UDMS

[Authoritative configuration](https://github.com/kylescudder/listarr/blob/main/README.md)
(and [image build](https://github.com/kylescudder/listarr/blob/main/Dockerfile)).
This integration is independent of Listarr's UI redesign.

`compose/udms/listarr.yml` runs the published Bun/TanStack Start image on the default
UDMS bridge, at `listarr:3211`. It follows Sortarr's UID/GID, resource limits and
read-only filesystem pattern. There is no host port, media mount, database or
migration container. Drafts live in browser local storage; exported URLs contain
immutable movie IDs. The Bun healthcheck calls `/api/health`; its JSON includes the
image revision. Health does not prove TMDB, Clerk or Radarr connectivity.

## Host configuration

Use the existing ignored `udms/.env` on Forge, with its existing private permissions
and secret-management process. Do not commit credentials or print a fully rendered
Compose configuration with real secrets. `TMDB_READ_TOKEN` is a TMDB **API Read
Access Token**, not Trailarr's v3 `TMDB_API_KEY`. It is passed only to the server;
never prefix it with `VITE_`, add it to a URL, or bake it into the client.

Add the following values to that host file (placeholders below are not credentials):

```dotenv
LISTARR_TMDB_READ_TOKEN=<TMDB API Read Access Token>
LISTARR_APP_ORIGIN=https://listarr.thescudders.org
LISTARR_FEED_ORIGIN=http://listarr:3211
LISTARR_IMAGE_TAG=main
```

Only the token is needed for browsing/search and URL export. Origins and image tag
above are the Compose defaults. `APP_ORIGIN` must be the exact browser origin,
without a trailing slash or path. `FEED_ORIGIN` must be reachable **from Radarr**;
the default bypasses Cloudflare Access on the shared Docker network. Copied list
URLs use this internal origin too; paste them into Radarr, not a browser outside
Docker. For an external Radarr, use an origin it can resolve and reach and keep
`/api/feed` outside interactive proxy authentication. Existing import lists retain
their exported URLs when this setting changes.

Direct **Create list in Radarr** additionally requires:

```dotenv
LISTARR_CLERK_SECRET_KEY=<Clerk server secret>
LISTARR_RADARR_ALLOWED_USER_IDS=<comma-separated Clerk user IDs>
LISTARR_RADARR_URL=http://radarr:7878
RADARR_API_KEY=<existing shared UDMS Radarr API key>
LISTARR_RADARR_QUALITY_PROFILE_ID=<existing positive profile ID>
LISTARR_RADARR_ROOT_FOLDER=<existing root folder path as seen by Radarr>
```

`RADARR_API_KEY` reuses Sortarr's host variable. The other Listarr settings are
namespaced to avoid collisions. `LISTARR_CLERK_JWT_KEY` can hold a trusted PEM
verification key instead of the Clerk secret. Use a quoted multiline dotenv value
for a PEM. An empty allowlist denies everyone. Browsing and feed export do not
require any Clerk/Radarr credentials, and Listarr can start while Radarr is down.

The public `VITE_CLERK_PUBLISHABLE_KEY` is **build-time only**: configure it in the
Listarr repository's image-build workflow before publishing the selected image.
Setting it in this stack's runtime environment cannot enable the client. Confirm
the image was built for the matching Clerk instance before enabling direct creation.
The root folder is Radarr's existing path (for example under `/data`), not a new
mount in Listarr. Direct creation registers an enabled import list with Search on
Add off; Radarr's later sync/monitoring/RSS behavior can still add or download films.

## Proposed tunnel route

`cloudflare/ingress.json` includes the proposed
`listarr.thescudders.org` → `http://listarr:3211` route. This file does not provision
the remotely managed tunnel. DNS, ingress and any Access changes require a
separately authorized rollout. Do not add Listarr to the existing blanket
`Forge UDMS arr stack` Access application: browsing/search/export are intentionally
public, while direct creation is authorized by Clerk and the server allowlist.
Check for wildcard Access policies as well. If a proxy gate is introduced later,
explicitly exempt `/api/feed` from interactive login. Apply edge rate limiting to
public search to protect the shared TMDB quota.

## Validation and authorized rollout

Offline validation from the repository root (no daemon or secrets needed):

```sh
HOSTNAME=udms DOCKERDIR=/tmp/udms-validation TZ=Europe/London PUID=501 PGID=20 \
  docker compose --env-file /dev/null -f udms/docker-compose.yml config --quiet
python3 -m unittest discover -s udms -p 'test_*.py'
```

Unrelated unset-secret warnings are expected with the empty env file. Use
`config --quiet` with the real host environment to avoid disclosing interpolated
secrets. After explicit deployment authorization, configure the host secrets,
review the resolved image, and start **only** Listarr from the `udms` directory:

```sh
docker --context colima compose config --quiet
docker --context colima compose pull listarr
docker --context colima compose up -d --no-deps listarr
docker --context colima compose ps listarr
docker --context colima exec listarr bun -e 'console.log(await (await fetch("http://127.0.0.1:3211/api/health")).json())'
docker --context colima exec radarr curl --fail 'http://listarr:3211/api/feed?ids=438631'
```

Expect a healthy container, the selected image revision, and `[{"id":438631}]`
from Radarr without cookies or credentials. After authorized DNS/tunnel publication,
run `python3 udms/verify-cloudflare.py --report /tmp/listarr-cloudflare-report.json`.
It checks public HTML, health JSON and the exact anonymous feed, while preserving
the other hosts' Access checks. It does not create or sync a real Radarr list.
Verify TMDB search, real Clerk sign-in, allowed/denied creation and Radarr persistence
separately during an authorized integration test. No UI change is made in this repo.

For rollback, set `LISTARR_IMAGE_TAG=sha-<full previously checked commit>` in the
private host `.env`, then repeat the Listarr-only pull/up commands after deployment
authorization. Keep the image's baked revision; do not override `LISTARR_REVISION`.
Do not restart Radarr, the rest of UDMS or the tunnel just to update Listarr.
