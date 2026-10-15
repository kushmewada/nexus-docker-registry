#!/usr/bin/env bash
# Sets up nexus as a docker registry using only the REST API, so there's
# nothing to click through in the UI.
#
# You can run it as many times as you want. Anything missing gets created and
# anything that already exists gets updated to match the config/ files.
# See main() at the bottom for the order things happen in.

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
load_env
require curl jq docker

: "${NEXUS_ADMIN_PASSWORD:?Set NEXUS_ADMIN_PASSWORD in .env}"
: "${CI_PASSWORD:?Set CI_PASSWORD in .env}"
CI_USERNAME="${CI_USERNAME:-ci-pusher}"
ANONYMOUS_PULL="${ANONYMOUS_PULL:-false}"
CLEANUP_UNUSED_DAYS="${CLEANUP_UNUSED_DAYS:-90}"
NEXUS_URL="${NEXUS_URL:-https://${NEXUS_HOST:-localhost}:${NEXUS_UI_PORT:-8443}}"
REPO_DIR="${ROOT_DIR}/config/repositories"
BLOB_STORE="docker-blobs"
CLEANUP_POLICY="docker-unused-images"
CI_ROLE="docker-ci"

compose() { docker compose --project-directory "$ROOT_DIR" "$@"; }

# first boot takes a minute or two, so just poll until nexus can accept writes
wait_for_nexus() {
  local timeout="${WAIT_TIMEOUT:-600}" elapsed=0
  log "Waiting for Nexus at ${NEXUS_URL} (timeout ${timeout}s)"
  until nexus_curl -fo /dev/null "${NEXUS_URL}/service/rest/v1/status/writable" 2>/dev/null; do
    (( elapsed >= timeout )) && die "Nexus did not become ready within ${timeout}s"
    sleep 5; elapsed=$((elapsed + 5))
  done
  ok "Nexus is up and writable"
}

# On first start nexus writes a random admin password to admin.password.
# We swap it for the one from .env and delete the file. On later runs the
# file is gone so we just log in with the .env password.
configure_admin() {
  local initial
  initial="$(compose exec -T nexus cat /nexus-data/admin.password 2>/dev/null || true)"

  if [[ -n "$initial" ]]; then
    log "Rotating generated admin password"
    export NEXUS_AUTH="admin:${initial}"
    api_or_die PUT /service/rest/v1/security/users/admin/change-password \
      "$NEXUS_ADMIN_PASSWORD" text/plain
    compose exec -T nexus rm -f /nexus-data/admin.password
    ok "Admin password rotated (generated password file removed)"
  fi

  export NEXUS_AUTH="admin:${NEXUS_ADMIN_PASSWORD}"
  api GET /service/rest/v1/status/check \
    || die "Cannot authenticate as admin (HTTP ${API_CODE}). Is NEXUS_ADMIN_PASSWORD correct?"
}

# newer community edition (3.77+) won't fully work until the EULA is accepted.
# the POST has to send back the exact disclaimer text it gave us, so reuse it
accept_eula() {
  if ! api GET /service/rest/v1/system/eula; then
    warn "EULA endpoint not available (HTTP ${API_CODE}); skipping"
    return
  fi
  if [[ "$(jq -r '.accepted' <<<"$API_BODY")" == "true" ]]; then
    ok "Community Edition EULA already accepted"
    return
  fi
  api_or_die POST /service/rest/v1/system/eula "$(jq -c '.accepted = true' <<<"$API_BODY")"
  ok "Community Edition EULA accepted"
}

# docker login doesn't work without the DockerToken realm turned on
configure_realms() {
  api_or_die GET /service/rest/v1/security/realms/active
  local realms
  realms="$(jq -c 'if index("DockerToken") then . else . + ["DockerToken"] end' <<<"$API_BODY")"
  api_or_die PUT /service/rest/v1/security/realms/active "$realms"
  ok "Active realms: $(jq -r 'join(", ")' <<<"$realms")"
}

# off by default, flip ANONYMOUS_PULL in .env if you want open pulls
configure_anonymous() {
  local body
  body="$(jq -nc --argjson enabled "$ANONYMOUS_PULL" \
    '{enabled: $enabled, userId: "anonymous", realmName: "NexusAuthorizingRealm"}')"
  api_or_die PUT /service/rest/v1/security/anonymous "$body"
  ok "Anonymous access enabled=${ANONYMOUS_PULL}"
}

# separate blob store for docker so it's easy to see how much space images use
# (and to move it to S3 later if needed)
configure_blob_store() {
  if api GET "/service/rest/v1/blobstores/file/${BLOB_STORE}"; then
    ok "Blob store '${BLOB_STORE}' exists"
    return
  fi
  api_or_die POST /service/rest/v1/blobstores/file \
    "$(jq -nc --arg n "$BLOB_STORE" '{name: $n, path: $n}')"
  ok "Created blob store '${BLOB_STORE}'"
}

# Cleanup policies are a Pro-only API, CE just gives 404. That's fine, the
# scheduled tasks below do the cleanup instead. Kept here so it works on Pro.
HAVE_CLEANUP_POLICY=false
configure_cleanup_policy() {
  local body method=POST path=/service/rest/v1/cleanup-policies
  body="$(jq -nc --arg n "$CLEANUP_POLICY" --argjson d "$CLEANUP_UNUSED_DAYS" '{
    name: $n,
    format: "docker",
    notes: "Remove images not downloaded for \($d) days",
    criteriaLastDownloaded: $d
  }')"

  if api GET "${path}/${CLEANUP_POLICY}"; then
    method=PUT path="${path}/${CLEANUP_POLICY}"
  fi
  if api "$method" "$path" "$body"; then
    HAVE_CLEANUP_POLICY=true
    ok "Cleanup policy '${CLEANUP_POLICY}' (unused > ${CLEANUP_UNUSED_DAYS}d)"
  else
    warn "Cleanup policy API requires Nexus Pro (HTTP ${API_CODE}); relying on scheduled tasks instead"
  fi
}

# Scheduled jobs from config/tasks.json. Nexus has no lookup by task name, so
# we list everything and match on name to decide between create and update.
configure_tasks() {
  local existing count i spec name id body
  api_or_die GET /service/rest/v1/tasks
  existing="$API_BODY"
  count="$(jq length "${ROOT_DIR}/config/tasks.json")"

  for ((i = 0; i < count; i++)); do
    spec="$(jq -c --argjson i "$i" '.[$i]' "${ROOT_DIR}/config/tasks.json")"
    name="$(jq -r .name <<<"$spec")"
    body="$(jq -c --arg days "$CLEANUP_UNUSED_DAYS" '{
      name, type, enabled: true, notificationCondition: "FAILURE",
      frequency: {schedule: "cron", cronExpression: .cron},
      properties: (.properties | map_values(if . == "${CLEANUP_UNUSED_DAYS}" then $days else . end))
    }' <<<"$spec")"
    id="$(jq -r --arg n "$name" '.items[] | select(.name == $n) | .id' <<<"$existing" | head -n1)"

    if [[ -n "$id" ]]; then
      api_or_die PUT "/service/rest/v1/tasks/${id}" "$(jq -c 'del(.type)' <<<"$body")"
    else
      api_or_die POST /service/rest/v1/tasks "$body"
    fi
    ok "Task '${name}' ($(jq -r .cron <<<"$spec"))"
  done
}

# create or update one repo from config/repositories/docker-<type>.json.
# drops the cleanup policy reference if we couldn't create the policy (CE)
upsert_repository() {
  local type="$1" file="${REPO_DIR}/docker-$1.json" name body
  name="$(jq -r .name "$file")"
  body="$(jq -c \
    --argjson cleanup "$HAVE_CLEANUP_POLICY" \
    --argjson anon "$ANONYMOUS_PULL" '
      (if $cleanup then . else del(.cleanup) end)
      | (if $anon and .name == "docker-group" then .docker.forceBasicAuth = false else . end)
    ' "$file")"

  if api GET "/service/rest/v1/repositories/docker/${type}/${name}"; then
    api_or_die PUT "/service/rest/v1/repositories/docker/${type}/${name}" "$body"
    ok "Updated repository '${name}'"
  else
    api_or_die POST "/service/rest/v1/repositories/docker/${type}" "$body"
    ok "Created repository '${name}'"
  fi
}

# CI only gets what it needs: push to docker-hosted, pull from docker-group.
# if the token leaks it can't touch anything else in nexus
configure_rbac() {
  local role user
  role="$(jq -nc --arg id "$CI_ROLE" '{
    id: $id,
    name: $id,
    description: "Push to docker-hosted, pull from docker-group",
    privileges: [
      "nx-repository-view-docker-docker-hosted-*",
      "nx-repository-view-docker-docker-group-browse",
      "nx-repository-view-docker-docker-group-read"
    ],
    roles: []
  }')"
  if api GET "/service/rest/v1/security/roles/${CI_ROLE}"; then
    api_or_die PUT "/service/rest/v1/security/roles/${CI_ROLE}" "$role"
  else
    api_or_die POST /service/rest/v1/security/roles "$role"
  fi
  ok "Role '${CI_ROLE}' configured"

  if api GET "/service/rest/v1/security/users?userId=${CI_USERNAME}" \
     && [[ "$(jq --arg u "$CI_USERNAME" 'map(select(.userId == $u)) | length' <<<"$API_BODY")" != 0 ]]; then
    user="$(jq -c --arg u "$CI_USERNAME" --arg r "$CI_ROLE" \
      'map(select(.userId == $u))[0] | .roles = [$r] | .status = "active"' <<<"$API_BODY")"
    api_or_die PUT "/service/rest/v1/security/users/${CI_USERNAME}" "$user"
    api_or_die PUT "/service/rest/v1/security/users/${CI_USERNAME}/change-password" \
      "$CI_PASSWORD" text/plain
    ok "Updated service account '${CI_USERNAME}'"
  else
    user="$(jq -nc --arg u "$CI_USERNAME" --arg p "$CI_PASSWORD" --arg r "$CI_ROLE" '{
      userId: $u, firstName: "CI", lastName: "Pipeline",
      emailAddress: "\($u)@nexus.local", password: $p,
      status: "active", roles: [$r]
    }')"
    api_or_die POST /service/rest/v1/security/users "$user"
    ok "Created service account '${CI_USERNAME}'"
  fi
}

main() {
  wait_for_nexus
  configure_admin
  accept_eula
  configure_realms
  configure_anonymous
  configure_blob_store
  configure_cleanup_policy
  upsert_repository hosted
  upsert_repository proxy
  upsert_repository group
  configure_rbac
  configure_tasks

  local host="${NEXUS_HOST:-localhost}"
  cat <<EOF

$(ok "Nexus is configured")

  UI / API   : ${NEXUS_URL}
  Push       : docker login ${host}:${REGISTRY_PUSH_PORT:-5000}
  Pull       : docker login ${host}:${REGISTRY_PULL_PORT:-5001}
  CI account : ${CI_USERNAME}
EOF
}

main "$@"
