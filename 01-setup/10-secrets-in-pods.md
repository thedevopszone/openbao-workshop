# Secrets in Pods — Injector, CSI & Operator-Landschaft

**Summary**:

Vier Wege, OpenBao-Secrets in Kubernetes-Pods zu bringen, und wann man welchen nimmt: **Agent Injector** (Sidecar automatisch per Annotation), **CSI Secrets Store Driver** (Secret als Volume über CSI), **External Secrets Operator (ESO)** und **Vault Secrets Operator (VSO)** (beide CRD-basiert, schreiben K8s-`Secret`s). Baut auf der nativen `kubernetes`-Auth aus `9-agent-und-k8s-auth.md` auf.

---

## Die vier Wege im Überblick

In `3-kubernetes.md` kam **ESO** zum Einsatz, in `9-agent-und-k8s-auth.md` ein **manuell** gebauter Agent-Sidecar. Das ist nur die halbe Landschaft. Die gängigste Methode (Injector) und die CSI-Variante fehlen noch.

| | **Agent Injector** | **CSI Driver** | **ESO** | **VSO** |
| --------------------- | -------------------------- | ------------------------- | ------------------------- | ------------------------- |
| Secret landet als | Datei im Pod (tmpfs) | Datei im Pod (CSV-Volume) | K8s-`Secret` (etcd) | K8s-`Secret` (etcd) |
| Mechanismus | injizierter Sidecar | CSI-Volume-Mount | Controller (Polling) | Controller (CRDs) |
| Konfiguration | **Pod-Annotationen** | `SecretProviderClass` | `ExternalSecret` | `VaultStaticSecret` u. a. |
| Auth | nativ `kubernetes` | nativ `kubernetes` | Token/k8s | nativ `kubernetes` |
| In etcd? | nein | nein (optional sync) | ja | ja |
| Dynamische Secrets | stark (Lease-Renewal) | ok | über `refreshInterval` | stark (eigene Renewal) |
| Stärke | App unverändert, kein etcd | kein etcd, K8s-nativ | multi-backend (nicht nur OpenBao) | OpenBao-nativ, CRD-getrieben |

> **Faustregel:** Brauchst du ein echtes K8s-`Secret` (für `imagePullSecrets`, Env, Tools die nur Secrets lesen) → **ESO/VSO**. Willst du nichts in etcd und die App liest eine Datei → **Injector** oder **CSI**. Injector ist am verbreitetsten, weil App-transparent.

---

## Weg 1 — Agent Injector (Sidecar automatisch per Annotation)

Statt den Sidecar wie in Kapitel 9 selbst ins Deployment zu schreiben, übernimmt das ein **Mutating Webhook**: Du annotierst nur den Pod, der Injector fügt Init- + Sidecar-Container automatisch ein und rendert die Secrets nach `/vault/secrets/`.

### Injector aktivieren

Der Injector steckt im OpenBao-Helm-Chart (Fork des Vault-Charts):

```bash
helm upgrade openbao openbao/openbao -n openbao \
  --reuse-values \
  --set injector.enabled=true

kubectl -n openbao get pods -l app.kubernetes.io/name=openbao-agent-injector
```

### Pod annotieren

Voraussetzung: eine `kubernetes`-Auth-Rolle (siehe `9-agent-und-k8s-auth.md`), hier `demo-app` mit Policy `workshop-read`.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: web
  namespace: default
spec:
  replicas: 1
  selector: { matchLabels: { app: web } }
  template:
    metadata:
      labels: { app: web }
      annotations:
        vault.hashicorp.com/agent-inject: "true"
        vault.hashicorp.com/role: "demo-app"
        # ein Secret nach /vault/secrets/config rendern:
        vault.hashicorp.com/agent-inject-secret-config: "kv/data/workshop/hello"
        vault.hashicorp.com/agent-inject-template-config: |
          {{- with secret "kv/data/workshop/hello" -}}
          APP_MESSAGE={{ .Data.data.message }}
          {{- end -}}
    spec:
      serviceAccountName: demo-app      # Identität für kubernetes-Auth
      containers:
        - name: web
          image: busybox:1.36
          command: ["/bin/sh","-c","cat /vault/secrets/config; sleep 3600"]
```

Der Injector erkennt die Annotationen, fügt den Agent ein, dieser loggt sich per `demo-app`-Rolle ein und schreibt `/vault/secrets/config`. Die App liest nur die Datei — **keine** Sidecar-YAML, **kein** Token im Cluster.

> **Hinweis zu den Annotationen:** Das OpenBao-Chart ist ein Vault-Chart-Fork, daher tragen die Annotationen den Präfix `vault.hashicorp.com/...`. Gegen eure konkrete Chart-Version verifizieren. Weitere nützliche: `agent-inject-status: update` (re-render bei Änderung), `agent-pre-populate-only: "true"` (nur Init-Container, kein dauerhafter Sidecar).

---

## Weg 2 — CSI Secrets Store Driver

Der **Secrets Store CSI Driver** (kubernetes-sigs) mountet Secrets als Volume; der **Vault-Provider** spricht dabei OpenBao an (API-kompatibel).

### Treiber + Provider installieren

```bash
helm repo add secrets-store-csi-driver \
  https://kubernetes-sigs.github.io/secrets-store-csi-driver/charts
helm install csi secrets-store-csi-driver/secrets-store-csi-driver \
  -n kube-system --set syncSecret.enabled=true

# Vault-CSI-Provider (spricht OpenBao)
helm repo add hashicorp https://helm.releases.hashicorp.com
helm install vault-csi hashicorp/vault \
  -n kube-system --set "injector.enabled=false" --set "server.enabled=false" \
  --set "csi.enabled=true"
```

### SecretProviderClass + Pod

```yaml
apiVersion: secrets-store.csi.x-k8s.io/v1
kind: SecretProviderClass
metadata:
  name: openbao-workshop
  namespace: default
spec:
  provider: vault
  parameters:
    vaultAddress: "http://openbao.openbao.svc:8200"
    roleName: "demo-app"                 # kubernetes-Auth-Rolle
    objects: |
      - objectName: "message"
        secretPath: "kv/data/workshop/hello"
        secretKey: "message"
---
apiVersion: v1
kind: Pod
metadata:
  name: csi-demo
  namespace: default
spec:
  serviceAccountName: demo-app
  containers:
    - name: app
      image: busybox:1.36
      command: ["/bin/sh","-c","cat /mnt/secrets/message; sleep 3600"]
      volumeMounts:
        - name: secrets
          mountPath: /mnt/secrets
          readOnly: true
  volumes:
    - name: secrets
      csi:
        driver: secrets-store.csi.k8s.io
        readOnly: true
        volumeAttributes:
          secretProviderClass: openbao-workshop
```

> CSI mountet die Secrets **nur**, solange der Pod läuft (kein etcd-Objekt). Mit `secretObjects` im `SecretProviderClass` kann der Treiber zusätzlich ein K8s-`Secret` synchronisieren — dann aber wieder mit etcd-Spur.

---

## Weg 3 & 4 — ESO vs. VSO (CRD-Operatoren)

Beide laufen als Controller im Cluster und schreiben ein echtes K8s-`Secret`. Unterschied:

- **ESO (External Secrets Operator)** — backend-**agnostisch** (OpenBao, AWS SM, GCP SM, …). Genau das aus `3-kubernetes.md`. Gut, wenn ihr **mehrere** Secret-Backends habt. Auth im Workshop per Token.
- **VSO (Vault Secrets Operator)** — speziell für Vault/OpenBao, **CRD-getrieben**, mit eigenem Lease-Renewal für dynamische Secrets. Authentifiziert sich nativ per `kubernetes`-Auth.

VSO-Beispiel (CRDs `VaultConnection` → `VaultAuth` → `VaultStaticSecret`):

```yaml
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultConnection
metadata: { name: openbao, namespace: default }
spec:
  address: "http://openbao.openbao.svc:8200"
---
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultAuth
metadata: { name: demo-app, namespace: default }
spec:
  vaultConnectionRef: openbao
  method: kubernetes
  mount: kubernetes
  kubernetes:
    role: demo-app
    serviceAccount: demo-app
---
apiVersion: secrets.hashicorp.com/v1beta1
kind: VaultStaticSecret
metadata: { name: app-config, namespace: default }
spec:
  vaultAuthRef: demo-app
  mount: kv
  type: kv-v2
  path: workshop/hello
  destination:
    name: app-config        # erzeugtes K8s-Secret
    create: true
  refreshAfter: 30s
```

> **OpenBao-Hinweis:** VSO ist HashiCorps Operator; gegen OpenBao funktioniert er über die API-Kompatibilität (wie der `hashicorp/vault`-Provider in `3-kubernetes.md`). Gegen eure Versionen testen; ein dedizierter OpenBao-Operator ist in Diskussion.

---

## Spickzettel

```bash
# Agent Injector aktivieren
helm upgrade openbao openbao/openbao -n openbao --reuse-values --set injector.enabled=true
# -> Pod annotieren: vault.hashicorp.com/agent-inject + role + agent-inject-secret-*

# CSI Secrets Store
helm install csi secrets-store-csi-driver/secrets-store-csi-driver -n kube-system
helm install vault-csi hashicorp/vault -n kube-system --set csi.enabled=true \
  --set injector.enabled=false --set server.enabled=false
# -> SecretProviderClass (provider: vault) + Pod-CSI-Volume

# Operatoren: ESO (3-kubernetes.md) backend-agnostisch | VSO OpenBao-nativ (CRDs)
```

> Fertige Dateien: `files/10-secrets-in-pods/` — `injector-deployment.yaml`, `secretproviderclass.yaml` (CSI) und `vso-secrets.yaml`.

---

## Roter Faden

1. `9-agent-und-k8s-auth.md` — native `kubernetes`-Auth + manueller Agent-Sidecar.
2. **Dieses Kapitel** — dieselbe Auth, aber automatisierte Delivery: Injector, CSI, ESO/VSO.
3. Weiter: `11-pki-cert-manager.md` (TLS-Zertifikate für Pods aus OpenBao-PKI), `12-produktion-k8s.md` (Hardening/Upgrades/Monitoring).
