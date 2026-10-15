#!/usr/bin/env bash
# Tars up the whole nexus-data volume.
#
# Nexus has to be stopped for this. The DB and the blobs live in the same
# volume and if you copy them while it's running they can end up out of sync.
# It's only down for about a minute. If you can't afford that, use the
# nightly H2 backup task + snapshots, or move to postgres.
#
# usage: scripts/backup.sh [output-dir]   (default ./backups)
#        KEEP=7 scripts/backup.sh         (how many old backups to keep)

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
require docker

OUT_DIR="$(realpath -m "${1:-${ROOT_DIR}/backups}")"
KEEP="${KEEP:-7}"
STAMP="$(date +%Y%m%d-%H%M%S)"
ARCHIVE="nexus-data-${STAMP}.tar.gz"

mkdir -p "$OUT_DIR"
compose() { docker compose --project-directory "$ROOT_DIR" "$@"; }

log "Stopping Nexus for a consistent snapshot"
compose stop nexus >/dev/null
trap 'log "Starting Nexus"; compose start nexus >/dev/null' EXIT

log "Archiving volume nexus-data -> ${OUT_DIR}/${ARCHIVE}"
docker run --rm \
  -v nexus-data:/data:ro \
  -v "${OUT_DIR}:/backup" \
  alpine:3.22 tar -czf "/backup/${ARCHIVE}" -C /data .
ok "Backup written ($(du -h "${OUT_DIR}/${ARCHIVE}" | cut -f1))"

# delete older backups, keep only the newest $KEEP
mapfile -t old < <(find "$OUT_DIR" -maxdepth 1 -name 'nexus-data-*.tar.gz' -printf '%T@ %p\n' \
  | sort -rn | tail -n +"$((KEEP + 1))" | cut -d' ' -f2-)
if (( ${#old[@]} )); then
  rm -f "${old[@]}"
  ok "Pruned ${#old[@]} old backup(s)"
fi
