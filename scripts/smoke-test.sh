#!/usr/bin/env bash
# Quick check that the registry really works, not just that containers are up.
# Builds a tiny image, pushes it, checks nexus sees it, deletes it locally,
# pulls it back, and pulls something from docker hub through the cache.
# Also checks the security bits (can't overwrite tags, CI user isn't admin).

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
load_env
require docker curl jq

HOST="${NEXUS_HOST:-localhost}"
PUSH="${HOST}:${REGISTRY_PUSH_PORT:-5000}"
PULL="${HOST}:${REGISTRY_PULL_PORT:-5001}"
NEXUS_URL="${NEXUS_URL:-https://${HOST}:${NEXUS_UI_PORT:-8443}}"
export NEXUS_AUTH="${CI_USERNAME:-ci-pusher}:${CI_PASSWORD:?Set CI_PASSWORD in .env}"
TAG="${SMOKE_TAG:-$(date +%Y%m%d%H%M%S)}"
IMAGE="hello-nexus"
UPSTREAM_IMAGE="${SMOKE_UPSTREAM_IMAGE:-library/busybox:1.37}"

log "Logging in to ${PUSH} and ${PULL} as ${CI_USERNAME:-ci-pusher}"
for registry in "$PUSH" "$PULL"; do
  printf '%s' "$CI_PASSWORD" \
    | docker login "$registry" -u "${CI_USERNAME:-ci-pusher}" --password-stdin >/dev/null 2>&1 \
    || die "docker login to ${registry} failed"
done
ok "Authenticated"

log "Building ${IMAGE}:${TAG}"
docker build -q -t "${PUSH}/${IMAGE}:${TAG}" "${ROOT_DIR}/examples/hello-nexus" >/dev/null
ok "Built"

log "Pushing to docker-hosted (${PUSH})"
docker push -q "${PUSH}/${IMAGE}:${TAG}" >/dev/null
ok "Pushed ${PUSH}/${IMAGE}:${TAG}"

log "Verifying component via REST API"
# search index lags a couple of seconds behind the push, so retry a bit
for _ in $(seq 1 15); do
  api_or_die GET "/service/rest/v1/search?repository=docker-hosted&name=${IMAGE}&version=${TAG}"
  [[ "$(jq '.items | length' <<<"$API_BODY")" -ge 1 ]] && break
  sleep 2
done
[[ "$(jq '.items | length' <<<"$API_BODY")" -ge 1 ]] || die "Image not found in docker-hosted"
ok "Found in docker-hosted"

log "Removing local copy and pulling back through docker-group (${PULL})"
docker image rm -f "${PUSH}/${IMAGE}:${TAG}" >/dev/null
docker pull -q "${PULL}/${IMAGE}:${TAG}" >/dev/null
docker run --rm "${PULL}/${IMAGE}:${TAG}" | grep -q "Hello from Nexus" || die "Container output mismatch"
ok "Pulled and ran ${PULL}/${IMAGE}:${TAG}"

log "Pulling ${UPSTREAM_IMAGE} from Docker Hub via docker-proxy cache"
docker pull -q "${PULL}/${UPSTREAM_IMAGE}" >/dev/null
ok "Pulled ${PULL}/${UPSTREAM_IMAGE}"

log "Verifying allow_once write policy (re-push of an existing tag must fail)"
docker tag "${PULL}/${UPSTREAM_IMAGE}" "${PUSH}/${IMAGE}:${TAG}"
if docker push -q "${PUSH}/${IMAGE}:${TAG}" >/dev/null 2>&1; then
  die "Overwriting an immutable tag succeeded — write policy is not enforced"
fi
ok "Immutable tags enforced"

log "Verifying least privilege (CI account must not reach admin APIs)"
if api GET /service/rest/v1/security/users; then
  die "CI account can list users — role is over-privileged"
fi
ok "Admin API denied for CI account (HTTP ${API_CODE})"

docker image rm -f "${PULL}/${IMAGE}:${TAG}" "${PUSH}/${IMAGE}:${TAG}" "${PULL}/${UPSTREAM_IMAGE}" >/dev/null 2>&1 || true
echo
ok "All smoke tests passed"
