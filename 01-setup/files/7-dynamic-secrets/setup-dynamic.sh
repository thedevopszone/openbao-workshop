#!/usr/bin/env bash
# setup-dynamic.sh — Transit, dynamische DB-Credentials und PKI einrichten.
# Begleitend zu 7-dynamic-secrets.md. Als Admin/Root ausführen.
#
# Voraussetzung: VAULT_ADDR + VAULT_TOKEN gesetzt, Server unsealed.
# Für den DB-Teil: erreichbare Postgres-Instanz (siehe
# files/3-kubernetes/postgres/docker-compose.yml). Passe PG_* unten an.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PG_HOST="${PG_HOST:-host.k3d.internal:5432}"
PG_DB="${PG_DB:-appdb}"
PG_USER="${PG_USER:-postgres}"
PG_PASS="${PG_PASS:-changeme}"

echo "==> Transit (Encryption as a Service)"
bao secrets enable transit 2>/dev/null || echo "   transit bereits aktiv"
bao write -f transit/keys/orders
bao policy write transit-app "$DIR/policies/transit-app.hcl"

echo "==> Database (dynamische Credentials)"
bao secrets enable database 2>/dev/null || echo "   database bereits aktiv"
bao write database/config/postgres \
  plugin_name=postgresql-database-plugin \
  allowed_roles="app-dynamic" \
  connection_url="postgresql://{{username}}:{{password}}@${PG_HOST}/${PG_DB}?sslmode=disable" \
  username="${PG_USER}" \
  password="${PG_PASS}"

bao write database/roles/app-dynamic \
  db_name=postgres \
  default_ttl=1h \
  max_ttl=24h \
  creation_statements="CREATE ROLE \"{{name}}\" WITH LOGIN PASSWORD '{{password}}' VALID UNTIL '{{expiration}}'; GRANT SELECT ON ALL TABLES IN SCHEMA public TO \"{{name}}\";"

bao policy write db-dynamic-read "$DIR/policies/db-dynamic-read.hcl"

echo "==> PKI (eigene CA)"
bao secrets enable pki 2>/dev/null || echo "   pki bereits aktiv"
bao secrets tune -max-lease-ttl=87600h pki
bao write -field=certificate pki/root/generate/internal \
  common_name="workshop.local" ttl=87600h > "$DIR/ca.crt"
bao write pki/config/urls \
  issuing_certificates="${VAULT_ADDR}/v1/pki/ca" \
  crl_distribution_points="${VAULT_ADDR}/v1/pki/crl"
bao write pki/roles/web \
  allowed_domains="workshop.local" \
  allow_subdomains=true \
  max_ttl=72h
bao policy write pki-issue "$DIR/policies/pki-issue.hcl"

cat <<'EOF'

Fertig. Test:
  # Transit
  CT=$(bao write -field=ciphertext transit/encrypt/orders plaintext=$(echo -n "geheim" | base64))
  bao write -field=plaintext transit/decrypt/orders ciphertext="$CT" | base64 -d

  # Dynamische DB-Credentials (jedes Mal andere!)
  bao read database/creds/app-dynamic

  # Zertifikat ausstellen
  bao write pki/issue/web common_name="app.workshop.local" ttl=24h
EOF
