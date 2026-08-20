#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-or-later
#
# Build and push the Quackback Postgres image, then print the exact repotag to
# paste into deploy/flux/feedback-app-spec.json.
#
# This repo has NO CI, so this is the whole release path -- keep it runnable by
# hand and keep it honest about what it produced.
#
#   ./deploy/postgres/build-and-push.sh            # build + push + print repotag
#   NO_PUSH=1 ./deploy/postgres/build-and-push.sh  # build only
#
# Requires: docker login registry.gitlab.com  (PAT with write_registry; the
# glab OAuth token does NOT work for the registry -- API scope only).
#
# ⚠ amd64 ONLY. Flux runs our images on amd64; a manifest list buys nothing here
# and costs a resolution step, so we build a single-arch image on purpose.
# ⚠ --provenance/--sbom off. Buildx otherwise pushes an OCI index with
# attestation manifests, and Flux wants a plain image it can pin by digest.
set -euo pipefail

REGISTRY="${REGISTRY:-registry.gitlab.com}"
REPO="${REPO:-quip.network/feedback.quip.network}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

cd "$HERE"
SHA="$(git rev-parse --short HEAD)"
DIRTY=""
git diff --quiet HEAD -- . || DIRTY="-dirty"
TAG="${TAG:-pg18-${SHA}${DIRTY}-amd64}"
IMAGE="${REGISTRY}/${REPO}:${TAG}"

if [ -n "$DIRTY" ]; then
    echo "⚠ working tree is dirty -- tagging '${TAG}'. Commit before a real release." >&2
fi

echo "==> building ${IMAGE}"
docker build \
    --platform linux/amd64 \
    --provenance=false \
    --sbom=false \
    -t "$IMAGE" \
    .

# Assert the positive: a wrong-arch image would deploy and then crash-loop on a
# Flux node, which is a slow and confusing way to find this out.
arch="$(docker image inspect "$IMAGE" --format '{{.Architecture}}/{{.Os}}')"
[ "$arch" = "amd64/linux" ] || { echo "FATAL: built ${arch}, expected amd64/linux" >&2; exit 1; }

# The whole point of the image: PG18 layout + pgvector + our restore hook. If any
# of these regress, the spec's mount path or the restore path is silently wrong.
docker run --rm --entrypoint sh "$IMAGE" -c '
    set -e
    [ "$PGDATA" = "/var/lib/postgresql/18/docker" ] || { echo "FATAL: PGDATA=$PGDATA"; exit 1; }
    [ -x /docker-entrypoint-initdb.d/10-restore-on-boot.sh ] || { echo "FATAL: restore hook missing"; exit 1; }
    [ -x /usr/local/bin/dump-loop.sh ] || { echo "FATAL: dump loop missing"; exit 1; }
    command -v aws >/dev/null || { echo "FATAL: awscli missing"; exit 1; }
' || exit 1
echo "    ok: amd64, PGDATA=/var/lib/postgresql/18/docker, restore hook + dump loop + awscli present"

if [ -n "${NO_PUSH:-}" ]; then
    echo "==> NO_PUSH set -- stopping before push"
    exit 0
fi

echo "==> pushing"
docker push "$IMAGE"

# ⚠ Read the digest back FROM THE REGISTRY. What `docker image inspect .Id`
# returns varies by image store (with containerd it is the manifest digest; with
# the classic store it is the *config* digest, which Flux would reject as a
# nonexistent manifest). The registry is the only authority, so ask it.
#
# ⚠ Do NOT use `imagetools inspect --format`. buildx silently IGNORES the flag on
# some versions -- including the one this was written against -- and prints the
# full human report instead, which then lands in the spec as garbage. Parse the
# report and assert the shape.
DIGEST="$(docker buildx imagetools inspect "$IMAGE" | awk '/^Digest:/{print $2; exit}')"
case "$DIGEST" in
    sha256:????????????????????????????????????????????????????????????????) ;;
    *) echo "FATAL: could not read a sha256 manifest digest (got: '${DIGEST}')" >&2; exit 1 ;;
esac

# The spec sets repoauth="" for this image, which is a claim that anyone can pull
# it. Verify rather than assume: if the project ever flips to private, the deploy
# fails at pull time on a node, which is a slow way to discover a one-word change
# in a GitLab settings page.
anon="$(curl -fsS "https://gitlab.com/jwt/auth?service=container_registry&scope=repository:${REPO}:pull" \
        | sed -n 's/.*"token":"\([^"]*\)".*/\1/p')"
code="$(curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer ${anon}" \
        -H 'Accept: application/vnd.docker.distribution.manifest.v2+json' \
        "https://${REGISTRY}/v2/${REPO}/manifests/${DIGEST}")"
if [ "$code" = "200" ]; then
    echo "    ok: anonymous pull by digest returns 200 -- repoauth can stay empty"
else
    echo "⚠ WARNING: anonymous pull by digest returned ${code}, not 200." >&2
    echo "  The image is NOT publicly pullable, so a spec with repoauth=\"\" will fail" >&2
    echo "  to deploy. Either make ${REPO} public, or set repoauth in the spec." >&2
fi

echo
echo "repotag for deploy/flux/feedback-app-spec.json (postgres component):"
echo
echo "  ${IMAGE}@${DIGEST}"
echo
# ⚠ Flux rejects a bare repo@sha256: reference -- it wants repo:TAG@sha256:DIGEST.
echo "(tag AND digest, both -- Flux rejects a bare repo@sha256: form)"
