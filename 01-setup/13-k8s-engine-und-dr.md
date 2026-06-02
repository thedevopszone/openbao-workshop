# Kubernetes Secrets Engine & Disaster Recovery

**Summary**:

Zwei eigenständige K8s-Themen zum Abschluss: die **`kubernetes` Secrets Engine** — OpenBao **erzeugt** kurzlebige Kubernetes-ServiceAccount-Tokens on demand (nicht zu verwechseln mit der k8s-*Auth* aus `9-agent-und-k8s-auth.md`) — und **Disaster Recovery**: einen Raft-Snapshot in ein **frisches** Helm-Release zurückspielen. Voraussetzung: laufender Cluster, Admin-Login, Snapshot-Grundlagen aus `8-operations.md`.

---

## Teil 1 — `kubernetes` Secrets Engine

### Auth vs. Engine — die Richtung

Leicht zu verwechseln, weil beide „kubernetes" heißen:

| | **`kubernetes` Auth** (Kap. 9) | **`kubernetes` Secrets Engine** (hier) |
| ----------- | ----------------------------------- | ------------------------------------------- |
| Richtung | Pod **→** OpenBao | OpenBao **→** Kubernetes |
| Frage | „Darf dieser Pod rein?" | „Gib mir Zugang **zu** einem Cluster" |
| Liefert | Token für OpenBao | **K8s-ServiceAccount-Token** (kurzlebig) |
| Use-Case | App holt Secrets | CI/Tool braucht temporären kubectl-Zugang |

Die Engine erzeugt **pro Anfrage** einen ServiceAccount (oder nutzt einen bestehenden) samt RoleBinding und gibt ein **ablaufendes** Token zurück — danach wird alles wieder aufgeräumt. Das ist „dynamische Secrets" (vgl. `7-dynamic-secrets.md`), nur für den Kubernetes-Zugang selbst.

### Einrichten

> **Zuerst RBAC geben.** Die Engine legt pro Anfrage einen ServiceAccount + (Cluster)Role + (Cluster)RoleBinding an. OpenBaos eigener ServiceAccount (Default `openbao/openbao` aus dem Helm-Chart) darf das standardmäßig **nicht** — sonst quittiert `bao write kubernetes/creds/...` mit `HTTP 500 … is forbidden`. Einmalig die nötigen Rechte vergeben (`files/13-k8s-engine-und-dr/openbao-rbac.yaml`):
>
> ```bash
> kubectl apply -f files/13-k8s-engine-und-dr/openbao-rbac.yaml
> ```

```bash
bao secrets enable kubernetes

# Wie OpenBao den Ziel-Cluster erreicht. Läuft OpenBao IM Cluster,
# kann es das eigene ServiceAccount + die in-cluster-API nutzen:
bao write kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc:443"

# Rolle: erzeugt einen SA + RoleBinding in den erlaubten Namespaces
bao write kubernetes/roles/ci-deployer \
  allowed_kubernetes_namespaces="default" \
  token_default_ttl="1h" \
  token_max_ttl="4h" \
  kubernetes_role_type="Role" \
  generated_role_rules='rules:
  - apiGroups: ["apps",""]
    resources: ["deployments","pods"]
    verbs: ["get","list","watch","update","patch"]'
```

### Credentials abrufen

```bash
bao write kubernetes/creds/ci-deployer kubernetes_namespace=default
```

```
Key                  Value
---                  -----
lease_id             kubernetes/creds/ci-deployer/AbC...
lease_duration       1h
service_account_name v-token-ci-deployer-...
service_account_token eyJhbGciOi...        # echtes, kurzlebiges K8s-Token
```

Damit kann ein CI-Job z. B. `kubectl` gegen den Cluster ausführen — das Token (und der dahinterliegende SA/RoleBinding) verfällt nach der TTL oder per `bao lease revoke <lease_id>`.

> **OpenBao-Hinweis:** Voraussetzung ist, dass OpenBaos eigener ServiceAccount die nötigen Rechte hat, SAs/RoleBindings anzulegen (TokenRequest + RBAC). Gegen eure Cluster-Rechte testen.

---

## Teil 2 — Disaster Recovery: Snapshot zurückspielen

`8-operations.md` zeigt `snapshot save`. Der Ernstfall ist der **Restore in ein frisches Release** — z. B. nach einem zerstörten Cluster oder PVC-Verlust.

### Der entscheidende Punkt: Keys gehören zum Snapshot

Ein Snapshot enthält die **verschlüsselten** Daten **und** den Barrier-Key-Stand des Quell-Clusters — **nicht** die Unseal-/Recovery-Keys. Nach einem `restore` läuft der Cluster mit dem **Seal des Snapshots**. Konsequenz:

- **Shamir:** Nach dem Restore brauchst du die **Unseal-Keys von damals** (zum Snapshot passend), nicht die des neuen Clusters.
- **Auto-Unseal (Transit/KMS):** Funktioniert **nur**, wenn derselbe Transit-Key/dasselbe KMS noch erreichbar ist. Deshalb den Unsealer/KMS getrennt sichern.

### Restore-Ablauf in K8s

```bash
# 1) frisches Release deployen (NICHT die alten PVCs wiederverwenden)
helm install openbao openbao/openbao -n openbao -f values-autounseal.yaml
kubectl -n openbao get pods -w

# 2) den neuen Cluster initialisieren + (auto-)unsealen, damit ein Leader existiert
kubectl -n openbao exec -ti openbao-0 -- bao operator init \
  -recovery-shares=1 -recovery-threshold=1     # temporär; wird vom Restore überschrieben
# -> den ausgegebenen Initial Root Token merken (für den Restore-Aufruf unten)

# 3) Snapshot in den Pod kopieren und mit -force zurückspielen.
#    Restore braucht einen Token; im frischen Pod ist keiner gecacht -> explizit mitgeben:
kubectl -n openbao cp ./bao.snap openbao-0:/tmp/bao.snap
kubectl -n openbao exec -ti openbao-0 -- \
  sh -c 'VAULT_TOKEN=<root-token-aus-Schritt-2> bao operator raft snapshot restore -force /tmp/bao.snap'
```

> `-force` ist nötig, weil der Snapshot-Cluster eine **andere Cluster-Identität** hat als das frische Release. Nach dem Restore gelten wieder die **alten** Daten *und* der **alte** Seal:
> - Mit Auto-Unseal über **denselben** Transit-Key entsiegeln sich die Pods automatisch.
> - Ist der Transit-Key weg, brauchst du die alten Recovery-Keys (`operator generate-root`/rekey-Flow, siehe `3-kubernetes.md`).

### Verifizieren

```bash
kubectl -n openbao exec -ti openbao-0 -- bao status              # Sealed false
kubectl -n openbao exec -ti openbao-0 -- bao operator raft list-peers
kubectl -n openbao exec -ti openbao-0 -- bao kv get kv/workshop/hello   # alte Daten zurück?
```

> **DR vorher üben.** Genau wie in `8-operations.md`: ein Restore, den man nie durchgespielt hat, ist kein DR-Plan. Snapshot + zugehörige Keys/Transit-Zugang **getrennt** und **gemeinsam auffindbar** aufbewahren.

---

## Spickzettel

```bash
# kubernetes Secrets Engine (OpenBao -> Kubernetes)
bao secrets enable kubernetes
bao write kubernetes/config kubernetes_host="https://kubernetes.default.svc:443"
bao write kubernetes/roles/ci-deployer allowed_kubernetes_namespaces="default" \
  token_default_ttl=1h generated_role_rules='...'
bao write kubernetes/creds/ci-deployer kubernetes_namespace=default   # kurzlebiges SA-Token

# Disaster Recovery
bao operator raft snapshot save bao.snap                 # vorher, regelmäßig (8-operations.md)
helm install openbao ... -f values-autounseal.yaml       # frisches Release
bao operator init -recovery-shares=1 -recovery-threshold=1   # Root-Token merken
VAULT_TOKEN=<root-token> bao operator raft snapshot restore -force /tmp/bao.snap  # alte Daten + alter Seal zurück
```

> Fertige Dateien: `files/13-k8s-engine-und-dr/` — `setup-k8s-engine.sh` und `restore.sh` (DR-Restore-Ablauf).

---

## Roter Faden

1. `9-agent-und-k8s-auth.md` — k8s-*Auth* (Pod → OpenBao).
2. `7-dynamic-secrets.md` — dynamische Secrets allgemein (Leases/TTL).
3. **Dieses Kapitel** — k8s-*Engine* (OpenBao → K8s) und der DR-Restore, der die ganze Reihe absichert.
