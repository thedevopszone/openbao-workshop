#!/usr/bin/env bash
# setup-pki-certmanager.sh — OpenBao-Seite für cert-manager als PKI-Issuer.
# Begleitend zu 11-pki-cert-manager.md. Als Admin/Root ausführen.
#
# Voraussetzung: VAULT_ADDR + VAULT_TOKEN gesetzt, Server unsealed,
# PKI aktiviert + Rolle "web" (siehe files/7-dynamic-secrets/setup-dynamic.sh),
# kubernetes-Auth aktiv (siehe files/9-agent-und-k8s-auth/).
set -euo pipefail

echo "==> Policy: cert-manager darf über pki/sign/web signieren"
bao policy write certmanager - <<'EOF'
path "pki/sign/web" {
  capabilities = ["create", "update"]
}
EOF

echo "==> kubernetes-Auth-Rolle für cert-managers ServiceAccount"
bao write auth/kubernetes/role/certmanager \
  bound_service_account_names="cert-manager" \
  bound_service_account_namespaces="cert-manager" \
  token_policies="certmanager" \
  token_ttl=20m

cat <<'EOF'

Fertig. Weiter auf der cert-manager-Seite:
  kubectl apply -f vault-issuer.yaml      # ClusterIssuer -> pki/sign/web
  kubectl apply -f certificate.yaml       # Certificate -> Secret web-tls (auto-renew)
  kubectl get clusterissuer,certificate -A
EOF
