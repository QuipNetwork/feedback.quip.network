#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Build and push the Quackback app image, then print the exact repotag to
# paste into deploy/flux/feedback-app-spec.json.
#
# The sibling of deploy/postgres/build-and-push.sh, with the same release path
# and the same rules -- read that script's header too.
#
#   ./deploy/app/build-and-push.sh              # build + push + print repotag
#   NO_PUSH=1 ./deploy/app/build-and-push.sh    # build only
#   PUSH_ONLY=1 ./deploy/app/build-and-push.sh  # push the tag NO_PUSH built
#
# ⚠ Test the NO_PUSH image, then push THAT tag with PUSH_ONLY. Do not rebuild in
# between: with the containerd image store every build makes a new image ID,
# even fully cached, so a rebuild ships something you have not tested.
#
# ⚠ Never push a tag twice. FluxOS resolves the remote digest by TAG and
# soft-redeploys whenever it changes, so a re-pointed tag redeploys production
# on the next 6-hourly pass. Tags carry the commit, so a new commit is a new
# tag.
set -euo pipefail

REGISTRY="${REGISTRY:-registry.gitlab.com}"
REPO="${REPO:-quip.network/feedback.quip.network}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# What the Dockerfile pins. The assertions below check the built image matches.
QUACKBACK_VERSION="0.13.2"
BUN_VERSION="1.4.4"

cd "$HERE"
SHA="$(git rev-parse --short HEAD)"
DIRTY=""
git diff --quiet HEAD -- . ../trust-store || DIRTY="-dirty"
TAG="${TAG:-quackback-${QUACKBACK_VERSION}-bun${BUN_VERSION}-${SHA}${DIRTY}-amd64}"
IMAGE="${REGISTRY}/${REPO}:${TAG}"

if [ -n "$DIRTY" ]; then
    echo "⚠ working tree is dirty -- tagging '${TAG}'. Commit before a real release." >&2
fi

if [ -n "${PUSH_ONLY:-}" ]; then
    docker image inspect "$IMAGE" >/dev/null 2>&1 \
        || { echo "FATAL: PUSH_ONLY set but ${IMAGE} is not built locally" >&2; exit 1; }
    echo "==> PUSH_ONLY set -- re-checking the local ${IMAGE}, not rebuilding"
else
    echo "==> building ${IMAGE}"
    docker build \
        --platform linux/amd64 \
        --provenance=false \
        --sbom=false \
        --build-context trust-store=../trust-store \
        -t "$IMAGE" \
        .
fi

arch="$(docker image inspect "$IMAGE" --format '{{.Architecture}}/{{.Os}}')"
[ "$arch" = "amd64/linux" ] || { echo "FATAL: built ${arch}, expected amd64/linux" >&2; exit 1; }

# The whole point of the image: the fixed runtime and bundle, on upstream's
# unchanged app. `bun --version` also proves the copied binary loads on this
# base's musl and libstdc++.
docker run --rm --entrypoint sh -e WANT_BUN="$BUN_VERSION" "$IMAGE" -c '
    set -e
    [ "$(id -un)" = "quackback" ] || { echo "FATAL: runs as $(id -un), expected quackback"; exit 1; }
    v="$(bun --version)"
    [ "$v" = "$WANT_BUN" ] || { echo "FATAL: bun $v, expected $WANT_BUN"; exit 1; }
    # `node --version` prints the Node version bun emulates, so ask for bun.
    v="$(node -e "console.log(process.versions.bun)" 2>/dev/null || true)"
    [ "$v" = "$WANT_BUN" ] || { echo "FATAL: node fallback runs bun $v, expected $WANT_BUN"; exit 1; }
    [ -x ./docker-entrypoint.sh ] || { echo "FATAL: upstream entrypoint missing"; exit 1; }
    [ -f .output/server/index.mjs ] && [ -f migrate.mjs ] || { echo "FATAL: app bundle missing"; exit 1; }
    for marker in 58Byr+iuL+FBVIcUqEqy 3M/vg4aijJRPn2jymJBG; do
        ! grep -qF -e "$marker" /etc/ssl/certs/ca-certificates.crt || { echo "FATAL: bundle holds $marker"; exit 1; }
    done
' || exit 1
echo "    ok: amd64, user quackback, bun ${BUN_VERSION} (and node fallback), upstream app + entrypoint, fixed bundle"

if [ -n "${NO_PUSH:-}" ]; then
    echo "==> NO_PUSH set -- stopping before push"
    exit 0
fi

echo "==> pushing"
docker push "$IMAGE"

# Read the digest back from the registry -- see the postgres script for why
# neither `docker image inspect` nor `imagetools inspect --format` will do.
DIGEST="$(docker buildx imagetools inspect "$IMAGE" | awk '/^Digest:/{print $2; exit}')"
case "$DIGEST" in
    sha256:????????????????????????????????????????????????????????????????) ;;
    *) echo "FATAL: could not read a sha256 manifest digest (got: '${DIGEST}')" >&2; exit 1 ;;
esac

anon="$(curl -fsS "https://gitlab.com/jwt/auth?service=container_registry&scope=repository:${REPO}:pull" \
        | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')"
code="$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer ${anon}" \
        -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
        -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
        -H 'Accept: application/vnd.oci.image.index.v1+json' \
        "https://${REGISTRY}/v2/${REPO}/manifests/${DIGEST}")"
if [ "$code" = "200" ]; then
    echo "    ok: anonymous pull by digest returns 200 -- repoauth can stay empty"
else
    echo "⚠ WARNING: anonymous pull by digest returned ${code}, not 200." >&2
    echo "  The image is NOT publicly pullable, so a spec with repoauth=\"\" will fail" >&2
    echo "  to deploy. Either make ${REPO} public, or set repoauth in the spec." >&2
fi

echo
echo "repotag for deploy/flux/feedback-app-spec.json (app component):"
echo
echo "  ${IMAGE}@${DIGEST}"
echo
echo "(tag AND digest, both -- Flux rejects a bare repo@sha256: form)"
