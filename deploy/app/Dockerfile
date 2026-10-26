# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Quackback for Flux: upstream's image with a trust store that does not accept
# the forged eMudhra chain.
#
# Upstream's 0.13.2 image trusts that chain twice over:
#
#   - Bun 1.3.11 verifies TLS against its own compiled-in root list, not a
#     file on disk, and that list holds emSign ECC Root CA - G3. Bun 1.4.4
#     drops it.
#   - The Alpine 3.22 bundle (ca-certificates-bundle 20250911-r0) holds the
#     same root. 20261020-r0 drops it.
#
# This container sends the Proton SMTP login over STARTTLS and the Storj
# uploads key over HTTPS, so either copy would let a forged certificate read
# the mail login or the attachments.
#
# ⚠ No upstream release fixes this yet: v0.14.1 and main both build on
# oven/bun:1.4.0. When one does, upgrade to it and drop this file.
#
# ⚠ The app stays 0.13.2. Only the runtime under it moves, so there are no new
# migrations. The Bun binary is copied from oven/bun's Alpine 3.24 image onto
# this Alpine 3.22 base; it links only musl, libstdc++ and libgcc_s, and runs
# against this base's copies (musl resolves every symbol at load, so a missing
# one fails at the first `bun --version`, which build-and-push.sh checks).
# `bunx` and the node fallback are symlinks to /usr/local/bin/bun, so they
# follow.
FROM oven/bun:1.4.4-alpine@sha256:4cf82f5686b196504fe119db3fcd9185b191f82ece82c40680e597228ec6070a AS bun

FROM ghcr.io/quackbackio/quackback:0.13.2@sha256:63660c1b32f2b841fb99e2502622b602cd08f49d2250c75fdac7aae1c7c2c151

USER root

# An upgrade that finds nothing newer exits 0, so the assert checks the file
# itself and refuses the build if it still holds either root.
COPY --from=trust-store assert-fixed-bundle.sh /tmp/assert-fixed-bundle.sh
RUN apk add --no-cache --upgrade ca-certificates-bundle \
 && sh /tmp/assert-fixed-bundle.sh /etc/ssl/certs/ca-certificates.crt \
 && rm /tmp/assert-fixed-bundle.sh

COPY --from=bun /usr/local/bin/bun /usr/local/bin/bun

# Entrypoint, working directory and environment are upstream's, unchanged.
USER quackback
