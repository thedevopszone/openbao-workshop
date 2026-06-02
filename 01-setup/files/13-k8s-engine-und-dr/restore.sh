#!/usr/bin/env bash
# restore.sh — Disaster Recovery: Raft-Snapshot in ein FRISCHES Release zurückspielen.
# Begleitend zu 13-k8s-engine-und-dr.md.
#
# WICHTIG: Der Snapshot enthält die verschlüsselten Daten UND den Seal-Stand des
# Quell-Clusters — NICHT die Unseal-/Recovery-Keys. Nach dem Restore gilt der ALTE
# Seal:
#   - Auto-Unseal (Transit/KMS): nur mit DEMSELBEN Key erreichbar -> entsiegelt sich selbst.
#   - Shamir: mit den ALTEN Unseal-Keys (zum Snapshot passend) unsealen.
#
# Aufruf:  ./restore.sh ./bao.snap
set -euo pipefail

SNAP="${1:?Pfad zum Snapshot angeben: ./restore.sh ./bao.snap}"
NS="${NS:-openbao}"
POD="${POD:-openbao-0}"

# Snapshot-Restore braucht einen privilegierten Token. Im frisch initialisierten
# Cluster gibt es noch keinen gecachten ~/.vault-token, also VAULT_TOKEN explizit
# setzen (Root-Token aus Schritt 2) — sonst: "permission denied".
: "${VAULT_TOKEN:?Bitte VAULT_TOKEN auf den Root-Token des frischen Clusters setzen (aus 'bao operator init' in Schritt 2)}"

echo "==> 1) Frisches Release muss bereits deployed sein (NICHT alte PVCs wiederverwenden)."
echo "       helm install openbao openbao/openbao -n ${NS} -f values-autounseal.yaml"
echo

echo "==> 2) Neuen Cluster initialisieren (temporär; wird vom Restore überschrieben)"
echo "       kubectl -n ${NS} exec -ti ${POD} -- bao operator init -recovery-shares=1 -recovery-threshold=1"
echo "       (Root-Token davon als VAULT_TOKEN exportieren, dann dieses Skript erneut aufrufen)"
echo

echo "==> 3) Snapshot in den Pod kopieren"
kubectl -n "${NS}" cp "${SNAP}" "${POD}:/tmp/bao.snap"

echo "==> 4) Restore mit -force (andere Cluster-Identität als das frische Release)"
kubectl -n "${NS}" exec -ti "${POD}" -- \
  sh -c "VAULT_TOKEN=${VAULT_TOKEN} bao operator raft snapshot restore -force /tmp/bao.snap"

echo "==> 5) Verifizieren"
kubectl -n "${NS}" exec -ti "${POD}" -- bao status
kubectl -n "${NS}" exec -ti "${POD}" -- bao operator raft list-peers || true

cat <<'EOF'

Hinweis: Zeigt status weiterhin "Sealed true", ist der zum Snapshot passende
Seal nicht erreichbar (Transit-Key weg / falsche Unseal-Keys). Dann den alten
Transit-Unsealer bereitstellen bzw. mit den alten Recovery-Keys arbeiten
(generate-root/rekey, siehe 3-kubernetes.md).
EOF
