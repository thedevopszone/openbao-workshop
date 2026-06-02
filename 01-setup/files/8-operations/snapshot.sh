#!/usr/bin/env bash
# snapshot.sh — Raft-Snapshot ziehen und mit Zeitstempel ablegen.
# Begleitend zu 8-operations.md. Funktioniert gegen einen erreichbaren
# OpenBao (VAULT_ADDR/VAULT_TOKEN) oder per docker compose exec.
#
# Beispiele:
#   ./snapshot.sh                          # direkt gegen VAULT_ADDR
#   MODE=docker SVC=bao-1 ./snapshot.sh    # via docker compose exec
set -euo pipefail

OUT_DIR="${OUT_DIR:-./snapshots}"
MODE="${MODE:-direct}"          # direct | docker
SVC="${SVC:-bao-1}"             # Compose-Service im docker-Modus
STAMP="$(date +%Y-%m-%dT%H-%M-%S)"
FILE="bao-${STAMP}.snap"

mkdir -p "$OUT_DIR"

case "$MODE" in
  direct)
    bao operator raft snapshot save "$OUT_DIR/$FILE"
    ;;
  docker)
    # Hinweis: snapshot braucht einen privilegierten Token. Entweder vorher
    # einmal im Container einloggen (docker compose exec -it "$SVC" bao login)
    # oder VAULT_TOKEN unten mit '-e VAULT_TOKEN=...' an exec übergeben.
    docker compose exec -T "$SVC" sh -c \
      'BAO_ADDR=http://127.0.0.1:8200 bao operator raft snapshot save /tmp/bao.snap'
    docker compose cp "$SVC:/tmp/bao.snap" "$OUT_DIR/$FILE"
    docker compose exec -T "$SVC" rm -f /tmp/bao.snap
    ;;
  *)
    echo "Unbekannter MODE: $MODE (direct|docker)" >&2; exit 1 ;;
esac

echo "Snapshot: $OUT_DIR/$FILE"

# Nur die letzten N Snapshots behalten (einfache Rotation)
KEEP="${KEEP:-7}"
ls -1t "$OUT_DIR"/bao-*.snap 2>/dev/null | tail -n +$((KEEP + 1)) | xargs -r rm -f

cat <<EOF

Restore (überschreibt den kompletten Cluster-Zustand!):
  bao operator raft snapshot restore $OUT_DIR/$FILE

Hinweis: Der Snapshot enthält NICHT die Unseal-/Recovery-Keys.
Zum Restore in einen frischen Cluster brauchst du die zum Snapshot
passenden Keys (siehe 8-operations.md).
EOF
