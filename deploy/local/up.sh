#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Start the local rehearsal of the quipfeedback Flux app.
#
#   deploy/local/up.sh                          # newest locally built app image
#   APP_IMAGE=... PG_IMAGE=... deploy/local/up.sh
#
# PG_IMAGE defaults to the postgres repotag the deployed spec pins. Then:
# http://localhost:3000 for the board, mail at `docker compose ... logs mailpit`.
# Wipe everything: docker compose -f deploy/local/compose.yaml down -v
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_IMG="registry.gitlab.com/quip.network/feedback.quip.network"
cd "$HERE"

newest_app() {
    docker images "$REPO_IMG" --format '{{.CreatedAt}}\t{{.Repository}}:{{.Tag}}' \
        | grep -F ':quackback-' | sort -r | head -1 | cut -f2
}
spec_pg() {
    python3 -c 'import json,sys; s=json.load(open(sys.argv[1])); print(next(c["repotag"] for c in s["compose"] if c["name"] == "postgres"))' \
        ../flux/feedback-app-spec.json
}
APP_IMAGE="${APP_IMAGE:-$(newest_app)}"
PG_IMAGE="${PG_IMAGE:-$(spec_pg)}"
[ -n "$APP_IMAGE" ] || { echo "FATAL: build first: NO_PUSH=1 deploy/app/build-and-push.sh" >&2; exit 1; }
[ -n "$PG_IMAGE" ] || { echo "FATAL: no postgres repotag in deploy/flux/feedback-app-spec.json" >&2; exit 1; }
export APP_IMAGE PG_IMAGE

# Rehearsal secrets: random, local, gitignored, and stable across restarts so a
# relocation drill restores into the same database password -- as on Flux.
# Hex only: base64's / and + would break DATABASE_URL.
if [ ! -s .env ]; then
    (umask 077
    {
        echo "SECRET_KEY=$(openssl rand -hex 32)"
        echo "PG_PASSWORD=$(openssl rand -hex 24)"
        echo "MINIO_USER=rehearsal"
        echo "MINIO_PASSWORD=$(openssl rand -hex 24)"
    } > .env)
    echo "==> wrote rehearsal secrets to deploy/local/.env"
fi

# Record the images in .env too, so plain `docker compose logs|ps|down` work.
sed -i -e '/^APP_IMAGE=/d' -e '/^PG_IMAGE=/d' .env
printf 'APP_IMAGE=%s\nPG_IMAGE=%s\n' "$APP_IMAGE" "$PG_IMAGE" >> .env

echo "==> app:      ${APP_IMAGE}"
echo "==> postgres: ${PG_IMAGE}"
docker compose -f compose.yaml up -d "$@"
echo
echo "Board: http://localhost:3000"
