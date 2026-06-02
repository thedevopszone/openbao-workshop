# Kubernetes-Auth & OpenBao Agent — Secrets ohne statischen Token

**Summary**:

Wie Pods sich **mit ihrer eigenen Identität** (ServiceAccount) bei OpenBao authentifizieren — statt einen statischen Token als Kubernetes-Secret zu hinterlegen, wie es das ESO-Beispiel im k8s-Teil tut. Zwei Wege, Secrets dann in die App zu bringen: der **OpenBao Agent** als Sidecar (Auto-Auth + Templating, App bleibt unverändert) und der Vergleich zu **ESO**. Voraussetzung: laufender OpenBao in k8s (siehe `3-kubernetes.md`), Auth/Policy-Grundlagen aus `6-auth-und-policies.md`.

---

## Das Problem mit dem statischen Token

Im k8s-Teil (`3-kubernetes.md`) bekommt der External Secrets Operator einen **langlebigen Token** als Kubernetes-Secret hinterlegt. Das funktioniert, hat aber zwei Schwächen:

- Der Token **liegt im Cluster** (etcd) und muss selbst rotiert/geschützt werden — ein Secret, um an Secrets zu kommen.
- Er ist **nicht an eine Identität gebunden**: Wer ihn hat, ist „der ESO-Token", egal welcher Pod.

Die saubere Lösung: Pods authentifizieren sich mit dem **ServiceAccount-JWT**, das Kubernetes ihnen ohnehin gibt. Kein vorab verteilter Token, automatische Bindung an `namespace` + `serviceaccount`.

```
Pod (ServiceAccount-JWT)  ──login──▶  OpenBao
                                       │ prüft JWT bei der K8s-API
                                       │ mappt SA -> Rolle -> Policies
                          ◀──Token────┘ kurzlebig, an die Identität gebunden
```

---

## Teil 1 — Kubernetes-Auth-Methode aktivieren

Einmalig als Admin (Token mit den Rechten aus `6-auth-und-policies.md`):

```bash
bao auth enable kubernetes
```

OpenBao muss die **Kubernetes-API erreichen**, um vorgelegte JWTs zu prüfen. Läuft OpenBao *im* Cluster, reicht die in-cluster-Adresse:

```bash
bao write auth/kubernetes/config \
  kubernetes_host="https://kubernetes.default.svc:443"
```

> Moderne Cluster (k3d/k3s, K8s ≥ 1.21) nutzen kurzlebige, projizierte ServiceAccount-Tokens. OpenBao validiert sie über die **TokenReview-API** — dafür braucht der OpenBao-ServiceAccount das Recht `system:auth-delegator` (im Helm-Chart i. d. R. schon gesetzt). Kein langlebiger Reviewer-Token nötig.

### Rolle: ServiceAccount → Policy

Eine Rolle bindet einen oder mehrere **ServiceAccounts in Namespaces** an Policies:

```bash
bao write auth/kubernetes/role/demo-app \
  bound_service_account_names="demo-app" \
  bound_service_account_namespaces="default" \
  token_policies="workshop-read" \
  token_ttl=1h
```

Heißt: Nur Pods mit dem ServiceAccount `demo-app` im Namespace `default` dürfen sich als Rolle `demo-app` einloggen und bekommen die Policy `workshop-read` (read auf `kv/data/workshop/*`).

### Test aus einem Pod

```bash
# JWT, das Kubernetes dem Pod gemountet hat
JWT=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)

bao write auth/kubernetes/login role=demo-app jwt="$JWT"
# -> client_token mit Policy workshop-read
```

Damit ist der statische Token überflüssig — die Identität kommt vom Cluster.

---

## Teil 2 — OpenBao Agent: Secrets in die App, ohne Code-Änderung

Die App soll sich gar nicht um Login, Token-Renewal und API-Aufrufe kümmern. Der **OpenBao Agent** läuft als **Sidecar** daneben und erledigt zwei Dinge:

1. **Auto-Auth** — loggt sich automatisch per kubernetes-Auth ein und hält den Token frisch (renew/re-login).
2. **Templating** — rendert Secrets in eine Datei, die die App einfach liest.

```
┌─ Pod ─────────────────────────────────────┐
│  [bao agent sidecar] ──auth/read──▶ OpenBao│
│        │ schreibt                          │
│        ▼                                    │
│   /vault/secrets/config   ◀── liest ── [App]│
└────────────────────────────────────────────┘
```

### Agent-Konfiguration

```hcl
# agent.hcl
auto_auth {
  method "kubernetes" {
    mount_path = "auth/kubernetes"
    config = {
      role = "demo-app"
    }
  }

  sink "file" {
    config = { path = "/vault/secrets/.token" }
  }
}

# rendert ein Secret in eine Datei, die die App liest
template {
  destination = "/vault/secrets/config.env"
  contents    = <<-EOT
    DB_USER={{ with secret "kv/data/workshop/hello" }}{{ .Data.data.message }}{{ end }}
  EOT
}
```

- `auto_auth` mit `method "kubernetes"` → Login per ServiceAccount, ganz ohne hinterlegten Token.
- `template` nutzt **Consul-Template-Syntax**; beachte bei KV v2 wieder die `.Data.data`-Ebene (vgl. `5-secrets-cli.md`).
- Ändert sich das Secret, rendert der Agent die Datei automatisch neu.

### Als Sidecar im Deployment

Kernpunkte eines Pods mit Agent-Sidecar (gekürzt):

```yaml
spec:
  serviceAccountName: demo-app          # die Identität für kubernetes-Auth
  containers:
    - name: app
      image: my-app
      volumeMounts:
        - { name: secrets, mountPath: /vault/secrets }   # liest hier nur Dateien
    - name: bao-agent
      image: openbao/openbao:latest
      args: ["agent", "-config=/etc/bao/agent.hcl"]
      volumeMounts:
        - { name: secrets,    mountPath: /vault/secrets }
        - { name: agent-conf, mountPath: /etc/bao }
  volumes:
    - { name: secrets,    emptyDir: { medium: Memory } }  # tmpfs, nichts auf Platte
    - { name: agent-conf, configMap: { name: bao-agent-config } }
```

> Das `secrets`-Volume als **`emptyDir: { medium: Memory }`** (tmpfs) anlegen — Secrets landen so nur im RAM, nicht auf der Node-Platte. Dasselbe Prinzip wie `mlock` beim Server.

Es gibt zusätzlich den **OpenBao Secrets Operator / Agent Injector** (Mutating Webhook), der den Sidecar per Pod-Annotation **automatisch einfügt** — dann braucht das Deployment den obigen Boilerplate nicht selbst. Für den Workshop reicht der explizite Sidecar, weil man sieht, was passiert.

---

## Teil 3 — Welcher Weg wann? Agent vs. ESO

Beide bringen Secrets in den Pod, mit unterschiedlicher Philosophie:

| | **OpenBao Agent (Sidecar)** | **External Secrets Operator (ESO)** |
| ------------------ | ----------------------------------- | ----------------------------------------- |
| Secret landet als | **Datei** im Pod (tmpfs) | **Kubernetes-Secret** (etcd) |
| Auth | nativ kubernetes (pro Pod) | Token im ClusterSecretStore (`3-kubernetes.md`) |
| Reichweite | nur dieser Pod | clusterweit nutzbar als Secret/Env |
| Dynamische Secrets | stark (Lease-Renewal eingebaut) | über `refreshInterval` (Polling) |
| App-Änderung | keine (liest Datei) | keine (liest Env/Secret) |
| Secret in etcd? | **nein** | ja (verschlüsselbar via KMS) |

> Faustregel: **Agent** für pro-Pod-, kurzlebige/dynamische Secrets ohne Spur in etcd; **ESO** wenn du ohnehin ein natives Kubernetes-Secret brauchst (z. B. für `imagePullSecrets`, oder Tools, die nur Secrets/Env lesen). Beides lässt sich kombinieren.

Konkret für das **Postgres-Rotations-Demo** aus `3-kubernetes.md`: Statt ESO mit statischem Token könntest du dort den Agent mit kubernetes-Auth nehmen und das rotierte Passwort per `template` in `/vault/secrets/db.env` rendern — die Demo-App liest die Datei (Volume-Mount fängt Rotationen automatisch, wie schon beschrieben).

---

## Spickzettel

```bash
# kubernetes-Auth einrichten
bao auth enable kubernetes
bao write auth/kubernetes/config kubernetes_host="https://kubernetes.default.svc:443"
bao write auth/kubernetes/role/demo-app \
  bound_service_account_names="demo-app" \
  bound_service_account_namespaces="default" \
  token_policies="workshop-read" token_ttl=1h

# Login aus dem Pod
JWT=$(cat /var/run/secrets/kubernetes.io/serviceaccount/token)
bao write auth/kubernetes/login role=demo-app jwt="$JWT"

# Agent (Sidecar)
bao agent -config=/etc/bao/agent.hcl
```

> Fertige Dateien: `files/9-agent-und-k8s-auth/` — `setup-k8s-auth.sh` (kubernetes-Auth + Rolle), `agent-configmap.yaml` (Agent-Config) und `demo-app-agent.yaml` (Pod mit Sidecar, tmpfs-Secrets).

---

## Roter Faden

1. `6-auth-und-policies.md` — Auth-Methoden & Policies allgemein.
2. `7-dynamic-secrets.md` — dynamische Secrets, die hier ausgeliefert werden.
3. **Dieses Kapitel** — Pods authentifizieren sich nativ (kubernetes-Auth) und holen Secrets per Agent/ESO, ohne statischen Token.

Damit ist die Integrationsseite rund: vom „Secret manuell als Token hinterlegen" (Einstieg im k8s-Teil) zur identitätsbasierten, automatisch rotierenden Zustellung.
