#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Periodic pg_dump -> S3. Runs beside postgres in the same container, started
# by quip-entrypoint.sh once the server is accepting connections.
#
# Deliberately best-effort per iteration: a transient S3 blip must not kill
# Postgres. The loop logs and retries on the next tick. The fail-closed half
# of this design lives in restore-on-boot.sh, which is where getting it wrong
# actually loses data.
set -uo pipefail

log() { printf '[dump-loop] %s\n' "$*" >&2; }

# shellcheck source=lib/s3-snapshot.sh
source /usr/local/lib/s3-snapshot.sh

INTERVAL="${DUMP_INTERVAL_SECONDS:-3600}"
PREFIX="${S3_PREFIX:-feedback-pg/}"
KEEP="${DUMP_KEEP:-48}"

if ! s3_configured; then
    log "S3 not configured -- no dumps will be taken. Postgres data is then only as durable as this Flux volume, which does not survive a relocation."
    exit 0
fi

log "dumping every ${INTERVAL}s to s3://${S3_BUCKET}/${PREFIX} (keeping ${KEEP})"

# ⚠ Dump immediately on the first pass, then sleep between ticks. Sleeping first
# left the window between deploy and the first tick entirely unprotected -- a
# relocation in that window has no dump to restore from at all, and a relocation
# is exactly the event this exists for.
#
# The sleep stays at the TOP of the loop, gated by first_pass, rather than moving
# to the bottom: the failure branches below use `continue`, which would skip a
# trailing sleep and spin the loop.
first_pass=1

while :; do
    if [ "$first_pass" -eq 1 ]; then
        first_pass=0
    else
        sleep "$INTERVAL"
    fi

    ts="$(date -u +%Y%m%dT%H%M%SZ)"
    key="${PREFIX}dump-${ts}.dump"
    tmp="$(mktemp /tmp/dump.XXXXXX.dump)"

    if ! pg_dump -Fc --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" --file "$tmp"; then
        log "pg_dump failed -- skipping this tick"
        rm -f "$tmp"; continue
    fi

    # Never publish an empty or truncated dump: it would sort newest and become
    # what restore-on-boot picks up after the next relocation.
    if ! pg_restore --list "$tmp" >/dev/null 2>&1; then
        log "dump failed its own pg_restore --list check -- refusing to publish"
        rm -f "$tmp"; continue
    fi

    # s3_put is KEY then FILE, not the other way round.
    if s3_put "$key" "$tmp"; then
        # Prune only on a HEAD-confirmed object. s3_put returning 0 is not proof
        # the object landed at full size, and pruning on an unconfirmed upload is
        # how you age out the last good dump. This is what s3_object_ok is for.
        if s3_object_ok "$key"; then
            log "published ${key} ($(stat -c%s "$tmp") bytes)"
            s3_prune "$PREFIX" "$KEEP" || log "prune failed (non-fatal)"
        else
            log "upload reported success but ${key} does not HEAD as non-empty -- NOT pruning"
        fi
    else
        log "upload failed for ${key} -- retrying next tick"
    fi

    rm -f "$tmp"
done
