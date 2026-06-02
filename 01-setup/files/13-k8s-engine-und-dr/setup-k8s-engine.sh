#!/usr/bin/env bash
# setup-k8s-engine.sh — kubernetes Secrets Engine: OpenBao erzeugt
# kurzlebige K8s-ServiceAccount-Tokens on demand.
# Begleitend zu 13-k8s-engine-und-dr.md. Als Admin/Root ausführen.
#
# NICHT verwechseln mit der kubernetes-AUTH (9-agent-und-k8s-auth.md):
#   Auth   = Pod -> OpenBao    | Engine = OpenBao -> Kubernetes
#
# Voraussetzung: VAULT_ADDR + VAULT_TOKEN gesetzt, Server unsealed.
# OpenBaos ServiceAccount muss SAs/RoleBindings anlegen dürfen (RBAC + TokenRequest).
set -euo pipefail

NS="${NS:-default}"

echo "==> kubernetes Secrets Engine aktivieren + konfigurieren"
bao secrets enable kubernetes 2>/dev/null || echo "   kubernetes-engine bereits aktiv"
bao write kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc:443"

echo "==> Rolle 'ci-deployer' (erzeugt SA + RoleBinding in ${NS})"
bao write kubernetes/roles/ci-deployer \
  allowed_kubernetes_namespaces="${NS}" \
  token_default_ttl="1h" \
  token_max_ttl="4h" \
  kubernetes_role_type="Role" \
  generated_role_rules='rules:
  - apiGroups: ["apps",""]
    resources: ["deployments","pods"]
    verbs: ["get","list","watch","update","patch"]'

cat <<EOF

Fertig. Kurzlebiges K8s-Token abrufen (jedes Mal neuer SA):
  bao write kubernetes/creds/ci-deployer kubernetes_namespace=${NS}

Vorzeitig zurückziehen:
  bao lease revoke <lease_id>
EOF
