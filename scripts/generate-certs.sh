#!/usr/bin/env bash
# Makes a small self-signed CA and uses it to sign a cert for NEXUS_HOST.
# Good enough for local/dev. On a real server just drop your own
# server.crt / server.key (letsencrypt etc.) into certs/ instead.
#
# usage: scripts/generate-certs.sh [--force]

# shellcheck source=scripts/lib.sh
source "$(dirname "$0")/lib.sh"
load_env
require openssl

CERT_DIR="${ROOT_DIR}/certs"
HOST="${NEXUS_HOST:-localhost}"
DAYS="${CERT_DAYS:-825}"

if [[ -f "${CERT_DIR}/server.crt" && "${1:-}" != "--force" ]]; then
  ok "Certificates already exist in certs/ (use --force to regenerate)"
  exit 0
fi

mkdir -p "$CERT_DIR"
umask 077

log "Creating private CA"
openssl req -x509 -newkey rsa:4096 -sha256 -nodes -days 3650 \
  -subj "/CN=Nexus Local CA" \
  -keyout "${CERT_DIR}/ca.key" -out "${CERT_DIR}/ca.crt" 2>/dev/null

log "Issuing server certificate for ${HOST}"
openssl req -newkey rsa:2048 -sha256 -nodes \
  -subj "/CN=${HOST}" \
  -keyout "${CERT_DIR}/server.key" -out "${CERT_DIR}/server.csr" 2>/dev/null

cat > "${CERT_DIR}/server.ext" <<EOF
basicConstraints = CA:FALSE
keyUsage = digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth
subjectAltName = DNS:${HOST}, DNS:localhost, IP:127.0.0.1
EOF

openssl x509 -req -sha256 -days "$DAYS" \
  -in "${CERT_DIR}/server.csr" -CA "${CERT_DIR}/ca.crt" -CAkey "${CERT_DIR}/ca.key" \
  -CAcreateserial -extfile "${CERT_DIR}/server.ext" \
  -out "${CERT_DIR}/server.crt" 2>/dev/null

rm -f "${CERT_DIR}/server.csr" "${CERT_DIR}/server.ext" "${CERT_DIR}/ca.srl"
# nginx worker runs as a different user so it needs to read server.key.
# ca.key is only needed for signing, keep it locked down
chmod 644 "${CERT_DIR}/server.crt" "${CERT_DIR}/ca.crt" "${CERT_DIR}/server.key"
chmod 600 "${CERT_DIR}/ca.key"

ok "Wrote certs/ca.crt, certs/server.crt, certs/server.key"
cat <<EOF

To make Docker trust this registry on a client machine (not needed for localhost):
  sudo mkdir -p /etc/docker/certs.d/${HOST}:${REGISTRY_PUSH_PORT:-5000} /etc/docker/certs.d/${HOST}:${REGISTRY_PULL_PORT:-5001}
  sudo cp certs/ca.crt /etc/docker/certs.d/${HOST}:${REGISTRY_PUSH_PORT:-5000}/ca.crt
  sudo cp certs/ca.crt /etc/docker/certs.d/${HOST}:${REGISTRY_PULL_PORT:-5001}/ca.crt
EOF
