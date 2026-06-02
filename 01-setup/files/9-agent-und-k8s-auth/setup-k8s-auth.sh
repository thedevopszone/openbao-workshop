#!/usr/bin/env bash
# setup-k8s-auth.sh — native Kubernetes-Auth-Methode einrichten.
# Begleitend zu 9-agent-und-k8s-auth.md. Als Admin/Root ausführen,
# während OpenBao IM Cluster läuft (Port-Forward oder exec).
#
# Voraussetzung: VAULT_ADDR + VAULT_TOKEN gesetzt, Server unsealed,
# Policy "workshop-read" existiert (siehe files/6-auth-und-policies).
set -euo pipefail

SA_NAME="${SA_NAME:-demo-app}"
SA_NS="${SA_NS:-default}"

echo "==> kubernetes-Auth aktivieren"
bao auth enable kubernetes 2>/dev/null || echo "   kubernetes bereits aktiv"

# OpenBao validiert vorgelegte ServiceAccount-JWTs über die TokenReview-API.
# In-cluster reicht die interne API-Adresse; der OpenBao-ServiceAccount
# braucht 'system:auth-delegator' (im Helm-Chart i. d. R. gesetzt).
echo "==> kubernetes-Auth konfigurieren"
bao write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc:443"

echo "==> Rolle ${SA_NS}/${SA_NAME} -> Policy workshop-read"
bao write auth/kubernetes/role/demo-app \
  bound_service_account_names="${SA_NAME}" \
  bound_service_account_namespaces="${SA_NS}" \
  token_policies="workshop-read" \
  token_ttl=1h

cat <<EOF

Fertig. Test aus einem Pod mit ServiceAccount ${SA_NAME}:
  JWT=\$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
  bao write auth/kubernetes/login role=demo-app jwt="\$JWT"

Danach: agent-configmap.yaml + demo-app-agent.yaml ausrollen.
EOF
