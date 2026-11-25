#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Canary: does Quackback's newest release still build with our overlay, boot
# the way the quipfeedback Flux app runs it, and survive a relocation?
# Pushes NOTHING.
#
#   deploy/local/canary.sh                          # newest upstream release
#   CANARY_VERSION=v0.16.1 deploy/local/canary.sh   # a specific one
#   deploy/local/canary.sh --down                   # remove the rehearsal stack
#
# Runs weekly in CI (.gitlab-ci.yml) and works the same on a workstation.
#   1. Ask GitHub for the newest release; use ghcr.io/quackbackio/quackback:<version>.
#   2. Point deploy/app/Dockerfile at it in THIS checkout only and build with
#      NO_PUSH, so build-and-push.sh's asserts run (our Bun, the user, the app
#      bundle, the CA bundle).
#   3. Boot deploy/local with that app image and the postgres image the
#      deployed spec pins.
#   4. From inside the app: /api/health/ready says ok, with db, migrations and
#      workers all ok.
#   5. Relocation drill -- the path a Flux relocation takes. Wait for a dump of
#      the MIGRATED schema, destroy the postgres volume, start postgres again:
#      restore-on-boot must restore that dump, with the same tables, and the
#      app must come back ready.
# A boot on an empty database proves the release starts and migrates from
# scratch; it says nothing about migrating our real data. That stays the
# upgrade's own step (README: Operate -> Upgrades).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
DC=(docker compose -f deploy/local/compose.yaml)
log() { echo "==> $*"; }
die() { echo "FATAL: $*" >&2; exit 1; }

if [ "${1:-}" = "--down" ]; then
    # compose refuses to parse the file without the rehearsal secrets, so only
    # tear down a stack that up.sh actually started.
    [ -s deploy/local/.env ] || { log "no rehearsal .env -- nothing to remove"; exit 0; }
    "${DC[@]}" down -v --remove-orphans
    exit 0
fi

# Dump often, so a dump of the migrated schema exists within a minute. Every
# compose call below sees it, including the drill's restart of postgres.
export DUMP_INTERVAL_SECONDS=30

# 1. Newest upstream release.
if [ -z "${CANARY_VERSION:-}" ]; then
    CANARY_VERSION="$(curl -fsS --max-time 20 -A feedback-canary -H 'Accept: application/vnd.github+json' \
        https://api.github.com/repos/QuackbackIO/quackback/releases/latest \
        | python3 -c 'import json,sys; print(json.load(sys.stdin)["tag_name"])')" \
        || die "could not read QuackbackIO/quackback's latest release from GitHub"
fi
[[ "$CANARY_VERSION" =~ ^v?[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "unexpected release tag '${CANARY_VERSION}'"
VERSION="${CANARY_VERSION#v}"
BASE="ghcr.io/quackbackio/quackback:${VERSION}"
PINNED="$(sed -n 's|^FROM \(ghcr.io/quackbackio/quackback:[^@ ]*\).*|\1|p' deploy/app/Dockerfile)"
[ -n "$PINNED" ] || die "no 'FROM ghcr.io/quackbackio/quackback:' line in deploy/app/Dockerfile"
log "newest upstream: ${BASE}   deployed pin: ${PINNED}"

# 2. Build our overlay on it. The Dockerfile edit stays in this checkout; CI
# throws the checkout away, and on a workstation `git checkout deploy/app` undoes it.
sed -i "s|^FROM ghcr.io/quackbackio/quackback:[^ ]*|FROM ${BASE}|" deploy/app/Dockerfile
grep -qxF "FROM ${BASE}" deploy/app/Dockerfile || die "could not point deploy/app/Dockerfile at ${BASE}"
TAG="quackback-${VERSION}-canary-amd64"
NO_PUSH=1 TAG="$TAG" deploy/app/build-and-push.sh
APP_IMAGE="registry.gitlab.com/quip.network/feedback.quip.network:${TAG}"

# 3. Boot it next to the deployed postgres (up.sh's default).
APP_IMAGE="$APP_IMAGE" deploy/local/up.sh

ctr() { "${DC[@]}" ps -q "$1"; }
psql_count() {
    "${DC[@]}" exec -T fluxpostgres_quipfeedback sh -c \
        'PGPASSWORD="$POSTGRES_PASSWORD" psql -h 127.0.0.1 -U "$POSTGRES_USER" -d "$POSTGRES_DB" -tAXc "select count(*) from information_schema.tables where table_schema = '"'public'"'"' \
        2>/dev/null | tr -dc '0-9'
}
dumps() {
    "${DC[@]}" exec -T fluxpostgres_quipfeedback bash -c \
        'source /usr/local/lib/s3-snapshot.sh && s3_list "$S3_PREFIX"' 2>/dev/null \
        | grep -oE 'dump-[0-9]{8}T[0-9]{6}Z\.dump' | sort -u
}

# 4. Ready, from inside the app (the edge's port is loopback-only on whatever
# host runs the daemon, so don't go through it).
wait_ready() {
    local what="$1" deadline=$((SECONDS + 900)) out=""
    log "waiting for /api/health/ready (${what})"
    while :; do
        out="$("${DC[@]}" exec -T fluxapp_quipfeedback wget -qO- http://127.0.0.1:3000/api/health/ready 2>/dev/null)" \
            && [ -n "$out" ] && break
        if [ "$SECONDS" -gt "$deadline" ]; then
            "${DC[@]}" logs --tail 60 fluxapp_quipfeedback fluxpostgres_quipfeedback || true
            die "the app was not ready within 15 minutes (${what})"
        fi
        sleep 10
    done
    READY="$out" python3 - <<'PY' || die "/api/health/ready check failed (${what})"
import json, os, sys
try:
    d = json.loads(os.environ["READY"])
except ValueError:
    sys.exit(f"  FAIL  /api/health/ready did not return JSON: {os.environ['READY'][:200]!r}")
checks, bad = d.get("checks") or {}, []
ok = d.get("status") == "ok"
print(f"  {'PASS' if ok else 'FAIL'}  status = {d.get('status')!r}")
bad += [] if ok else ["status"]
for name in ("db", "migrations", "workers"):
    ok = (checks.get(name) or {}).get("ok") is True
    print(f"  {'PASS' if ok else 'FAIL'}  checks.{name}.ok")
    bad += [] if ok else [name]
sys.exit(1 if bad else 0)
PY
}
wait_ready "first boot, empty database"

# 5. Relocation drill.
tables="$(psql_count)"
[ "${tables:-0}" -gt 0 ] || die "the migrated database has no public tables (${tables:-none})"
since="$(date -u +%Y%m%dT%H%M%SZ)"
log "migrated schema: ${tables} public tables; waiting for a dump taken after ${since}"
deadline=$((SECONDS + 300)) dump=""
until dump="$(dumps | awk -v t="dump-${since}" '$0 > t' | tail -1)" && [ -n "$dump" ]; do
    [ "$SECONDS" -lt "$deadline" ] || { "${DC[@]}" logs --tail 40 fluxpostgres_quipfeedback || true; die "no dump after ${since} within 5 minutes"; }
    sleep 10
done
echo "  PASS  dump of the migrated schema published: ${dump}"

log "relocation: destroying the postgres volume and starting postgres again"
"${DC[@]}" rm -sf fluxpostgres_quipfeedback >/dev/null
docker volume rm feedback-rehearsal_pgdata >/dev/null
"${DC[@]}" up -d fluxpostgres_quipfeedback >/dev/null 2>&1
deadline=$((SECONDS + 300))
until docker logs "$(ctr fluxpostgres_quipfeedback)" 2>&1 | grep -q 'restoring newest dump'; do
    [ "$SECONDS" -lt "$deadline" ] || { "${DC[@]}" logs --tail 60 fluxpostgres_quipfeedback || true; die "postgres did not restore within 5 minutes"; }
    sleep 5
done
restored="$(docker logs "$(ctr fluxpostgres_quipfeedback)" 2>&1 | sed -n 's/.*restoring newest dump: //p' | tail -1)"
echo "  PASS  restore-on-boot restored ${restored##*/}"
wait_ready "after the relocation"
after="$(psql_count)"
[ "$after" = "$tables" ] || die "restored ${after:-no} public tables, the migrated schema had ${tables}"
echo "  PASS  restored schema has the same ${after} public tables"

log "canary PASSED: Quackback ${VERSION} on our overlay boots, migrates and survives a relocation against the deployed postgres"
