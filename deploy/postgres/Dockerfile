# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Postgres for Quackback on Flux.
#
# Upstream builds its own postgres:18 image to add pg_cron + pgvector. We build
# from stock pgvector instead and drop pg_cron.
#
# ⚠ The reason is NOT "Flux cannot build" -- we build and push this image
# ourselves either way, and upstream's own Dockerfile builds in ~6s. The reason
# is that upstream's pg_cron wiring is broken with their own documented
# POSTGRES_USER:
#
#   - pg_cron is UNUSED: 0 references across the 126 shipped migrations and 0
#     in app source; migrate.mjs creates only `vector`. Their docs mark it
#     "(optional)".
#   - pg_cron is also ACTIVELY BROKEN upstream. Measured on their exact image +
#     command + init script with their documented POSTGRES_USER=quackback:
#     exit=3, `FATAL: database "quackback" does not exist` (cron.database_name
#     is dialled before the DB exists) and `ERROR: role "postgres" does not
#     exist` (init-pgcron.sql GRANTs to a role that only exists when
#     POSTGRES_USER is left at the default). Isolated across four configs: it
#     fails only with pg_cron on. Dropping it is what makes this boot.
#   - pgvector IS required: 4 vector columns (posts, feedback_signals,
#     feedback_suggestions, kb_articles), and migrate.mjs creates the extension
#     itself at startup.
#   - PG18, matching upstream's stated requirement.
#
# What this image adds over stock is durability, and that part IS forced by
# Flux -- proven from FluxOS source, not inferred. A relocation hands the app a
# freshly fallocate'd + mke2fs'd volume (appUninstaller.js rm -rf on the losing
# node, advancedWorkflows.js:533,551 on the winning one); at instances:1 the
# Syncthing peer list filters out self, so there is no peer to pull from; and
# nothing in the install path restores a backup. So Postgres here is a cache of
# an off-box dump: restore-on-boot into a fresh volume, and a periodic pg_dump
# pushed to S3 (Storj). Same shape as the bootnode restore-on-fresh-PVC path,
# and it reuses that repo's s3-snapshot.sh verbatim.
#
# ⚠ A SOFT redeploy does NOT wipe the volume -- only an `hdd` change or a v8
# component add/remove/rename does. Routine upgrades (repotag, env) are safe.
#
# ⚠ Mount the volume at /var/lib/postgresql, NOT /var/lib/postgresql/data.
# PG18 moved PGDATA to /var/lib/postgresql/18/docker and the entrypoint
# hard-refuses to start if it finds a mount at the legacy path.
FROM pgvector/pgvector:pg18@sha256:2ba9ca5f2e7daa0f0e7723cba1ee9167bab54efd3640516a44ac1a928dd67e7a

# ⚠ This container holds the Storj database key, so its trust store must not
# accept the forged eMudhra chain. Two copies have to be fixed:
#
#   - The OS bundle. ca-certificates 20250419~deb12u1 holds both emSign ECC
#     Root CA - G3 and AAA Certificate Services (which cross-signed the bad
#     intermediates). The fixed 20250419~deb12u2 comes from bookworm-security,
#     which the base image's sources already list, so naming the package here
#     picks it up. The assert refuses the build if the file still holds
#     either root -- apt exits 0 when there is nothing newer to install.
#   - aws-cli's own. Debian's awscli 2.9.19 verifies with botocore's
#     cacert.pem, not the OS bundle, and that file still trusts AAA.
#     AWS_CA_BUNDLE points it at the fixed bundle. The restore hook and the
#     dump loop both inherit it.
COPY --from=trust-store assert-fixed-bundle.sh /tmp/assert-fixed-bundle.sh
RUN apt-get update \
    && apt-get install -y --no-install-recommends awscli ca-certificates \
    && rm -rf /var/lib/apt/lists/* \
    && sh /tmp/assert-fixed-bundle.sh /etc/ssl/certs/ca-certificates.crt \
    && rm /tmp/assert-fixed-bundle.sh
ENV AWS_CA_BUNDLE=/etc/ssl/certs/ca-certificates.crt

# Store-agnostic S3 helpers, vendored BYTE-IDENTICAL from
# bootnodes.quip.network/lib/ so the two stay one file, not a fork. Functions
# only -- sourcing has no side effects. We use six of them (s3_configured,
# s3_list, s3_get, s3_put, s3_object_ok, s3_prune); the substrate half
# (restore_from_snapshot and the snapshot_* key builders) is deliberately dead
# here. Do not trim it -- a trimmed copy forks a shared, tested lib to save
# nothing at runtime.
COPY lib/s3-snapshot.sh /usr/local/lib/s3-snapshot.sh

# Runs ONLY when PGDATA is empty, which is exactly "fresh volume". The stock
# postgres entrypoint executes initdb.d scripts against a temporary local
# server before opening the real listener, so a restore lands before any
# client can connect.
COPY restore-on-boot.sh /docker-entrypoint-initdb.d/10-restore-on-boot.sh

COPY dump-loop.sh /usr/local/bin/dump-loop.sh
COPY entrypoint.sh /usr/local/bin/quip-entrypoint.sh
RUN chmod +x /docker-entrypoint-initdb.d/10-restore-on-boot.sh \
             /usr/local/bin/dump-loop.sh \
             /usr/local/bin/quip-entrypoint.sh

ENTRYPOINT ["/usr/local/bin/quip-entrypoint.sh"]
CMD ["postgres", "-c", "max_connections=200"]
