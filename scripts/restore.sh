#!/usr/bin/env bash
# Puts a backup from backup.sh back into the nexus-data volume.
# Careful: this wipes whatever is in nexus right now, that's why it asks first.
#
# usage: scripts/restore.sh backups/nexus-data-YYYYmmdd-HHMMSS.tar.gz

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
require docker

ARCHIVE="${1:?Usage: $0 <backup.tar.gz>}"
[[ -f "$ARCHIVE" ]] || die "No such file: $ARCHIVE"
ARCHIVE="$(realpath "$ARCHIVE")"

compose() { docker compose --project-directory "$ROOT_DIR" "$@"; }

read -r -p "This will REPLACE all data in volume nexus-data. Type 'restore' to continue: " answer
[[ "$answer" == "restore" ]] || die "Aborted"

log "Stopping stack"
compose stop >/dev/null

log "Restoring ${ARCHIVE}"
docker run --rm \
  -v nexus-data:/data \
  -v "$(dirname "$ARCHIVE"):/backup:ro" \
  alpine:3.22 sh -c "find /data -mindepth 1 -delete && tar -xzf '/backup/$(basename "$ARCHIVE")' -C /data && chown -R 200:200 /data"
ok "Volume restored"

log "Starting stack"
compose up -d >/dev/null
ok "Done — Nexus will be available once its healthcheck passes"
