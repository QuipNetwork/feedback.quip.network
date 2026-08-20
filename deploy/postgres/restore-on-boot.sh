#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Restore the newest pg_dump from S3 into a freshly-initialised cluster.
#
# The stock postgres entrypoint runs /docker-entrypoint-initdb.d/* only when
# PGDATA was empty, which on Flux means exactly one thing: this is a fresh
# volume after a hard redeploy or a relocation. So this script IS the
# "did we lose the disk" branch -- no empty-check of our own is needed.
#
# FAIL-CLOSED. If S3 is configured and a dump exists but the restore fails,
# exit non-zero and take the container down. A Quackback that comes up on an
# empty schema would let the app run its migrations and present an empty board
# as though nothing had happened, and the next dump would then overwrite the
# good backup with the empty one. Losing the board loudly beats losing it
# quietly.
set -euo pipefail

log() { printf '[restore-on-boot] %s\n' "$*" >&2; }

# shellcheck source=lib/s3-snapshot.sh
source /usr/local/lib/s3-snapshot.sh

if ! s3_configured; then
    log "S3 not configured (S3_ENDPOINT/S3_BUCKET/S3_ACCESS_KEY/S3_SECRET_KEY) -- starting empty."
    log "This is correct ONLY for a first-ever deploy. If this instance previously had data, stop now."
    exit 0
fi

PREFIX="${S3_PREFIX:-feedback-pg/}"

# ⚠ Bound every S3 call. Against an unreachable endpoint the AWS CLI retries
# with long connect timeouts, and because this script runs INSIDE the postgres
# entrypoint's init phase, a hang here wedges the whole container mid-init
# rather than failing it. Measured: unbounded, an unroutable S3_ENDPOINT hung
# the listing indefinitely instead of failing closed. Retries are bounded here
# and the call itself is wrapped in `timeout` below.
export AWS_RETRY_MODE=standard
export AWS_MAX_ATTEMPTS=3
S3_CALL_TIMEOUT="${S3_CALL_TIMEOUT:-120}"

# Keys are <prefix>dump-<utc-ts>.dump, so the UTC timestamp leads and "newest"
# is a lexical sort. Same reasoning as the bootnode snapshot layout: never
# parse a filename to find the latest.
#
# s3_list is a shell function, so `timeout` needs a fresh shell to call it in.
keys="$(timeout "$S3_CALL_TIMEOUT" bash -c '
    source /usr/local/lib/s3-snapshot.sh
    s3_list "$1"
' _ "$PREFIX")" || {
    rc=$?
    if [ "$rc" -eq 124 ]; then
        log "FATAL: listing s3://${S3_BUCKET}/${PREFIX} timed out after ${S3_CALL_TIMEOUT}s -- refusing to start empty."
    else
        log "FATAL: could not list s3://${S3_BUCKET}/${PREFIX} (rc=${rc}) -- refusing to start empty."
    fi
    log "A listing failure is indistinguishable from an empty bucket at the data layer, so we fail closed:"
    log "coming up on an empty schema would let the app migrate, serve an empty board as though nothing"
    log "had happened, and then overwrite the good backup with the empty one on the next dump."
    exit 1
}

newest="$(printf '%s\n' "$keys" | grep -E 'dump-.*\.dump$' | sort | tail -1 || true)"

if [ -z "$newest" ]; then
    log "no dump under s3://${S3_BUCKET}/${PREFIX} -- first-ever deploy, starting empty."
    exit 0
fi

log "restoring newest dump: ${newest}"
tmp="$(mktemp /tmp/restore.XXXXXX.dump)"
trap 'rm -f "$tmp"' EXIT

s3_get "$newest" "$tmp" || { log "FATAL: download failed for ${newest}"; exit 1; }
[ -s "$tmp" ] || { log "FATAL: downloaded dump is empty: ${newest}"; exit 1; }

# --exit-on-error so a partial restore is a failure, not a warning. The
# cluster is brand new, so there is nothing to clean and no --clean needed.
pg_restore \
    --username "$POSTGRES_USER" \
    --dbname "$POSTGRES_DB" \
    --no-owner --no-privileges \
    --exit-on-error \
    "$tmp" || { log "FATAL: pg_restore failed for ${newest}"; exit 1; }

tables="$(psql -tAX --username "$POSTGRES_USER" --dbname "$POSTGRES_DB" \
    -c "select count(*) from information_schema.tables where table_schema='public';")"

# Assert the positive. "pg_restore exited 0" is not the same claim as "the
# schema is here"; a dump of an empty database restores cleanly.
if [ "${tables:-0}" -lt 1 ]; then
    log "FATAL: restore reported success but public schema has ${tables:-0} tables."
    exit 1
fi

log "restored ${newest} -- ${tables} tables in public schema."
