#!/bin/bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Wraps the stock postgres entrypoint so the dump loop runs beside the server.
#
# Ordering matters and is not obvious: restore-on-boot.sh runs INSIDE the
# stock entrypoint (as a /docker-entrypoint-initdb.d script, against a
# temporary local server, only when PGDATA was empty). So by the time the real
# listener is up, a restore has either succeeded or taken the container down.
# The dump loop therefore never has to reason about restore state -- it just
# waits for the server and starts dumping.
set -euo pipefail

log() { printf '[entrypoint] %s\n' "$*" >&2; }

# Start the dump loop once the server accepts connections. Backgrounded here
# rather than from the loop itself so postgres stays PID 1's direct child and
# keeps its signal handling intact.
# ⚠ Wait for the TCP listener, NOT the default Unix socket. During init the
# stock entrypoint runs a TEMPORARY server with listen_addresses='' (socket
# only) so that initdb.d scripts can run before anything can connect. A socket
# probe therefore goes green while init is still in progress -- and a dump loop
# started there would pg_dump a half-initialised database and publish it as the
# newest object, which is what a later restore-on-boot would then pick up.
# Measured: the socket probe fires during init; the TCP probe does not.
(
    until pg_isready -q -h 127.0.0.1 -p 5432 -U "${POSTGRES_USER}" -d "${POSTGRES_DB}" 2>/dev/null; do
        sleep 5
    done
    log "postgres is accepting TCP connections -- starting dump loop"
    exec /usr/local/bin/dump-loop.sh
) &

exec docker-entrypoint.sh "$@"
