# Operations Runbook

Day-2 procedures for the Nexus Docker registry.

## Health

| Check | Command |
|-------|---------|
| Container status | `make ps` |
| Nexus writable | `curl --cacert certs/ca.crt https://localhost:8443/service/rest/v1/status/writable` |
| Full system check (admin) | `curl --cacert certs/ca.crt -u admin:$PW https://localhost:8443/service/rest/v1/status/check` |
| Logs | `make logs` |

`status/check` reports blob store quota, file descriptors, heap, and thread pool state — wire it into your monitoring.

## Upgrading Nexus

1. `make backup`
2. Read the [release notes](https://help.sonatype.com/en/release-notes.html) for any migration steps.
3. Bump `NEXUS_VERSION` in `.env` (and in `.env.example` so CI tests it).
4. `docker compose pull nexus && docker compose up -d`
5. `make bootstrap && make smoke-test`

Rollback: restore the backup taken in step 1 and pin the previous version. Nexus does not support in-place downgrades.

## Rotating credentials

- **Admin:** change `NEXUS_ADMIN_PASSWORD` in the UI (or via API), then update `.env`.
- **CI account:** change `CI_PASSWORD` in `.env` and run `make bootstrap`. The script resets the password, so update CI secrets in the same change.

## Rotating TLS certificates

```bash
cp new.crt certs/server.crt && cp new.key certs/server.key
docker compose exec nginx nginx -s reload
```

## Disk space

Image layers live in the `docker-blobs` blob store. Space is reclaimed in two steps:

1. **Soft delete** — `Docker - Delete unused manifests and images` and `Docker - Purge unused cached images` mark blobs deleted (nightly).
2. **Hard delete** — `Admin - Compact blob store` removes them from disk (Sunday 03:00).

To free space immediately, run both tasks from **Admin → System → Tasks**.

## Backup and restore

| What | How | Downtime |
|------|-----|----------|
| Full volume (blobs + DB) | `make backup` | ~1 min |
| DB only | nightly `Admin - Backup H2 database` task → `/nexus-data/backup` | none |

Restore: `make restore FILE=backups/nexus-data-<stamp>.tar.gz`

Test a restore on a separate host at least once per quarter.

## Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| `413 Request Entity Too Large` on push | Proxy body limit | Already `client_max_body_size 0`; check any upstream load balancer |
| `unauthorized` on push with correct password | Docker Bearer Token realm off | `make bootstrap` |
| `x509: certificate signed by unknown authority` | Client doesn't trust the CA | Copy `certs/ca.crt` to `/etc/docker/certs.d/<host>:<port>/ca.crt` |
| Push of existing tag fails | `allow_once` write policy (intentional) | Push a new tag; only `latest` may be redeployed |
| Nexus restarts / OOM | Heap + direct memory exceed limit | Raise `NEXUS_MEMORY_LIMIT` or lower `NEXUS_HEAP` |
| Proxy pulls fail | Docker Hub rate limit / outage | Add Docker Hub credentials to `docker-proxy` (UI → Repository → HTTP Authentication) |
