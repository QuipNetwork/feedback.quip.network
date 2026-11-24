# feedback.quip.network

Public feedback board, upvotes, roadmap and changelog for Quip Network — a self-hosted
[Quackback][qb] deployment running on [Flux][flux], with object storage on [Storj][storj].

Live at **https://feedback.quip.network**.

[qb]: https://github.com/QuackbackIO/quackback
[flux]: https://runonflux.io
[storj]: https://storj.io

## Architecture

Upstream's `docker-compose.prod.yml` translated to two Flux components:

| Component | Image | Purpose |
|---|---|---|
| `app` | built from `deploy/app/` | Upstream's Quackback image with a fixed CA bundle and Bun runtime. Web and background jobs; runs database migrations at startup. |
| `postgres` | built from `deploy/postgres/` | PostgreSQL 18 with pgvector, wrapped with a dump loop and a restore-on-boot hook. |

Since Quackback 0.14, background jobs run on Postgres, so there is no Redis or Dragonfly component.

Upstream's bundled object storage is dropped; `S3_*` points at Storj instead, using two
buckets — one for user uploads, one for database dumps.

A Flux volume does not survive relocation to another node, so the `postgres` component dumps to
Storj on a fixed interval and restores the most recent dump whenever it starts on an empty volume.

## Repository layout

    deploy/flux/feedback-app-spec.json   Flux v8 app specification; secrets are placeholders
    deploy/app/                          App image: upstream Quackback on a fixed trust store
    deploy/postgres/                     Postgres image: Dockerfile, entrypoint, dump loop, restore hook
    deploy/trust-store/                  Build-time check that a CA bundle has dropped the eMudhra roots

## Prerequisites

- Docker with `buildx`
- A GitLab personal access token with `write_registry`
- A Storj account with two buckets and an access key for each
- A funded Flux account
- An SMTP account for transactional mail

## Build

Both images are built and pushed by hand; this repository has no CI.

```bash
docker login registry.gitlab.com
NO_PUSH=1 ./deploy/app/build-and-push.sh        # build, then test the local image
PUSH_ONLY=1 ./deploy/app/build-and-push.sh      # push that same image
NO_PUSH=1 ./deploy/postgres/build-and-push.sh
PUSH_ONLY=1 ./deploy/postgres/build-and-push.sh
```

Each script builds `linux/amd64`, checks the image, pushes to
`registry.gitlab.com/quip.network/feedback.quip.network` and prints the digest-pinned repotag to
paste into the specification. Push the image you tested rather than rebuilding it, and never push a
tag twice: Flux redeploys whenever a tag's digest changes.

The `app` image is upstream's, with two changes: the Alpine CA bundle is upgraded, and the Bun
runtime is replaced with a release whose built-in root list no longer trusts the eMudhra roots.
Both builds refuse a CA bundle that still holds them. Drop the `app` image once an upstream
release ships on a fixed Bun.

## Deploy

1. **Fill the specification.** Copy `deploy/flux/feedback-app-spec.json` to `feedback.filled.json`
   (gitignored) and replace every placeholder: the Postgres password, `SECRET_KEY`, the Storj keys
   and the SMTP token. Generate passwords with `openssl rand -hex 24` — base64 emits `/` and `+`,
   which break `DATABASE_URL`.

   ```bash
   grep -n '<[A-Za-z0-9-]*>' deploy/flux/feedback.filled.json   # must print nothing
   ```

   The check matches `<placeholder>` rather than a bare `<`, because `EMAIL_FROM` contains one.

2. **Register** at [cloud.runonflux.com](https://cloud.runonflux.com) → Register New App. Paste the
   filled JSON into the Components tab and enable Enterprise in the General tab at submit time; the
   specification carries secrets and Enterprise is what encrypts it.

3. **Point DNS** at the app: `CNAME feedback.quip.network → quipfeedback.app.runonflux.io`. Flux's
   FDM issues and renews the TLS certificate for the custom domain.

## Configuration

Set on the `app` component. Flux caps a component at 20 environment variables; this deployment uses
17.

| Variable | Notes |
|---|---|
| `BASE_URL` | Public URL of the board |
| `DATABASE_URL` | The password is interpolated in, so it must be URL-safe |
| `SECRET_KEY` | `openssl rand -hex 32`. It also encrypts the OAuth and integration credentials stored in the database, so it must never change |
| `TRUSTED_PROXY_HOPS` | `1`. FDM appends the client address to `X-Forwarded-For`, and Quackback takes it from there for rate limits and session IPs. At `0` every visitor shares one rate-limit bucket, sign-in included |
| `S3_*` | Storj gateway, the uploads bucket and its key |
| `EMAIL_SMTP_*`, `EMAIL_FROM` | Transactional mail — password resets, invitations, notifications |
| `DISABLE_TELEMETRY` | Turns off upstream's anonymous usage ping |

OAuth provider credentials are **not** environment variables. Quackback stores them encrypted in the
database; configure them under Admin → Settings → Security.

The `postgres` component takes `POSTGRES_*`, the Storj database-bucket keys, `S3_PREFIX`,
`DUMP_INTERVAL_SECONDS` and `DUMP_KEEP`.

## Operate

- **Upgrades** are a `repotag` change. Confirm a fresh dump has published, then bump the tag and
  digest and update the specification. Migrations run on boot, so read the release notes and upgrade
  one version at a time.
  - Migrations are not reversible. A rollback is the previous image plus a restore of the last
    pre-upgrade dump onto an empty volume.
  - Removing or adding a component makes Flux charge a small update fee and reinstall the app.
    Postgres then restores the newest dump, so anything written after that dump is lost.
  - After an upgrade, look at the rendered portal, not only its status codes. The 0.16 header
    change hid the whole header behind one of our custom CSS rules.
- **Health:** `/api/health/ready` (0.16 and later) checks the database. `/api/health` answers 200
  even when the database is unreachable.
- **Custom CSS** lives in the database: Admin → Settings → Portal → Customise → Advanced CSS. Edit
  it there, not in SQL, because the app serves it from a cache. Publishing from that editor moves
  theme colours, fonts and radius into its own Colours and Font settings.
- **Environment changes** need a Soft Reinstall rather than a Restart. Both preserve the volume.
- **Never edit `hdd` on a live app** — it forces a hard redeploy, which wipes the volume.
- **Backups** run inside the `postgres` component to Storj, governed by `DUMP_INTERVAL_SECONDS` and
  `DUMP_KEEP`.
- **Moderation.** Anonymous posts, and comments from outside the team, are held for review at
  `/admin/moderation`.

## License

AGPL-3.0. See [LICENSE](LICENSE).
