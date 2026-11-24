# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Quackback for Flux: upstream's image with a trust store that does not accept
# the forged eMudhra chain.
#
# Upstream's 0.16.0 image trusts that chain twice over, as 0.13.2 did:
#
#   - Bun 1.4.0 verifies TLS against its own compiled-in root list, not a
#     file on disk, and that list holds emSign ECC Root CA - G3. Bun 1.4.4
#     drops it.
#   - The Alpine 3.22 bundle (ca-certificates-bundle 20260611-r0) holds the
#     same root. 20261020-r0 drops it.
#
# This container sends the Proton SMTP login over STARTTLS and the Storj
# uploads key over HTTPS, so either copy would let a forged certificate read
# the mail login or the attachments.
#
# ⚠ No upstream release fixes this yet: v0.16.0 still builds on
# oven/bun:1.4.0-alpine. When one does, upgrade to it and drop this file.
#
# Bun stays 1.4.4: 1.4.5's only security fix is in HTTP/3, which this app
# does not serve (FDM speaks HTTP/1.1 to it).
#
# The Bun binary is copied from oven/bun's Alpine 3.24 image onto this Alpine
# 3.22 base; it links only musl, libstdc++ and libgcc_s, and runs against this
# base's copies (musl resolves every symbol at load, so a missing one fails at
# the first `bun --version`, which build-and-push.sh checks). `bunx` and the
# node fallback are symlinks to /usr/local/bin/bun, so they follow.
FROM oven/bun:1.4.4-alpine@sha256:4cf82f5686b196504fe119db3fcd9185b191f82ece82c40680e597228ec6070a AS bun

FROM ghcr.io/quackbackio/quackback:0.16.0@sha256:587399d5ca4322e4ed3028ce80a86ddb7fcab585d1e0437f18900e52b1458c2b

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
