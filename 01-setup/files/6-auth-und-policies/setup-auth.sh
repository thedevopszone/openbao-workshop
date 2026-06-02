#!/usr/bin/env bash
# setup-auth.sh — Auth-Methoden + Policies + Beispiel-Identitäten einrichten.
# Begleitend zu 6-auth-und-policies.md. Als Admin/Root ausführen.
#
# Voraussetzung: VAULT_ADDR + VAULT_TOKEN gesetzt, Server unsealed,
# eine KV-v2-Engine unter "kv/" (siehe 5-secrets-cli.md / OpenTofu-Setup).
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "==> Policies schreiben"
bao policy write workshop-read  "$DIR/policies/workshop-read.hcl"
bao policy write workshop-write "$DIR/policies/workshop-write.hcl"

echo "==> userpass (Login für Menschen)"
bao auth enable userpass 2>/dev/null || echo "   userpass bereits aktiv"
bao write auth/userpass/users/workshop \
  password="workshop123" \
  policies="workshop-read"

echo "==> AppRole (Login für Maschinen/CI)"
bao auth enable approle 2>/dev/null || echo "   approle bereits aktiv"
bao write auth/approle/role/ci \
  token_policies="workshop-read" \
  token_ttl=1h \
  token_max_ttl=4h \
  secret_id_ttl=10m

echo "==> RoleID (statisch, darf in die App-Config):"
bao read -field=role_id auth/approle/role/ci/role-id

echo "==> Audit-Device"
# Ab OpenBao v2.5 ist das Anlegen von Audit-Devices über die API/CLI
# standardmäßig deaktiviert ("use declarative, config-based audit device
# management instead"). Empfohlen: audit-Stanza in der Server-config.hcl
# (siehe 6-auth-und-policies.md, Teil 5). Nur wenn die config.hcl
# unsafe_allow_api_audit_creation = true setzt, klappt der CLI-Weg:
if bao audit enable file file_path=/openbao/logs/audit.log 2>/dev/null; then
  echo "   audit-file via API aktiviert"
elif bao audit list 2>/dev/null | grep -q file; then
  echo "   audit-file bereits aktiv (vermutlich deklarativ via config)"
else
  echo "   HINWEIS: Audit nicht über die API aktivierbar — deklarativ in"
  echo "            config.hcl konfigurieren (Teil 5) oder"
  echo "            unsafe_allow_api_audit_creation = true setzen."
fi

cat <<'EOF'

Fertig. Test:
  bao login -method=userpass username=workshop          # Passwort: workshop123
  bao kv get  kv/workshop/hello                         # erlaubt (read)
  bao kv put  kv/workshop/hello x=y                      # permission denied

  # SecretID frisch erzeugen und damit als CI einloggen:
  SID=$(bao write -f -field=secret_id auth/approle/role/ci/secret-id)
  RID=$(bao read  -field=role_id        auth/approle/role/ci/role-id)
  bao write auth/approle/login role_id="$RID" secret_id="$SID"
EOF
