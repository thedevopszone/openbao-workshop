# Workshop — OpenBao auf k3d mit Helm, OpenTofu & Auto-Unseal

**Summary**: Vollständiger, von Hand nachvollziehbarer Workshop-Ablauf: lokal mit **k3d** einen 3-Node-Kubernetes-Cluster bauen, **OpenBao** per **Helm** im HA-/[[raft|Raft]]-Modus deployen, [[seal-unseal|initialisieren & unsealen]] (erst manuell mit Shamir zum Verstehen, dann **Auto-Unseal per Transit**), den Cluster mit **OpenTofu** konfigurieren und sich schließlich in der eigenen **GUI** und per **CLI** einloggen. Mit Tool-Installation für macOS und Ubuntu.

---

## Was dieser Workshop zeigt

Jede:r Teilnehmer:in baut auf dem **eigenen Laptop** denselben Stack und durchläuft:

1. **k3d** — ein 3-Node-Kubernetes-Cluster in Docker (drei schedulebare Nodes, damit drei OpenBao-Pods sich verteilen können).
2. **Helm** — OpenBao im **HA-Modus mit Integrated Raft**, drei Replicas.
3. **Init & Unseal** — zuerst **manuell** mit Shamir-Shares, damit man Raft-Join und „jeder Node einzeln" begreift.
4. **Raft verstehen** — `raft list-peers`, Leader-Wahl, Ausfall-Demo.
5. **Auto-Unseal** — derselbe Cluster, aber mit **Transit-Auto-Unseal**: ein zweiter OpenBao entsiegelt die Cluster-Nodes automatisch.
6. **OpenTofu** — den laufenden OpenBao deklarativ konfigurieren (Secrets-Engine, Policy, Auth-Methode, Benutzer, ein Secret).
7. **Login** — in der **GUI** im Browser und per **CLI** verbinden.

> Dies ist ein **Lern-/Workshop-Setup auf einem Host** — drei Container teilen sich Kernel und Disk. Es zeigt das *Cluster-Protokoll*, nicht echte Verfügbarkeit. Für Produktion siehe [[k8s-ha-setup]], [[deployment-vm-vs-k8s]]. Verwandt: [[compose-cluster]] (derselbe Raft-Cluster ohne Kubernetes, nur mit Docker Compose).

## Architektur-Überblick

```
  Laptop (Docker)
  └── k3d-Cluster "openbao"  (1 server + 2 agents = 3 schedulebare Nodes)
        │
        ├── Namespace "transit"
        │     └── openbao-transit-0   ← Unsealer (Transit Secrets Engine)
        │
        └── Namespace "openbao"
              ├── openbao-0  (Raft leader)   ┐
              ├── openbao-1  (Raft follower)  ├─ HA, seal "transit" → unsealer
              └── openbao-2  (Raft follower) ┘
                    ▲
                    │  kubectl port-forward 8200
                    │
              GUI (Browser :8200/ui)  +  CLI (VAULT_ADDR)  +  OpenTofu (vault-Provider)
```

---

## Teil 0 — Werkzeuge installieren

Gebraucht werden: **Docker**, **k3d**, **kubectl**, **helm**, die **`bao`-CLI** und **OpenTofu**. (Alle Installationswege extern verifiziert am 2026-05-29.)

### macOS (Homebrew)

```bash
# Docker-Runtime (eine der beiden Varianten):
brew install --cask docker            # Docker Desktop (GUI), danach einmal starten
# ODER schlanker, ohne Desktop:
# brew install colima docker && colima start

# CLIs:
brew install k3d kubectl helm opentofu openbao
```

`brew install openbao` liefert die `bao`-CLI (extern verifiziert: `formulae.brew.sh/formula/openbao`).

### Ubuntu (22.04 / 24.04)

```bash
# --- Docker ---
sudo apt-get update
sudo apt-get install -y ca-certificates curl
curl -fsSL https://get.docker.com | sudo sh
sudo usermod -aG docker "$USER"        # danach neu einloggen, damit docker ohne sudo läuft

# --- kubectl ---
curl -LO "https://dl.k8s.io/release/$(curl -L -s https://dl.k8s.io/release/stable.txt)/bin/linux/amd64/kubectl"
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl

# --- helm ---
curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# --- k3d ---
curl -s https://raw.githubusercontent.com/k3d-io/k3d/main/install.sh | bash

# --- OpenTofu ---
curl -fsSL https://get.opentofu.org/install-opentofu.sh -o install-opentofu.sh
chmod +x install-opentofu.sh
sudo apt install unzip -y
./install-opentofu.sh --install-method standalone
rm install-opentofu.sh

# --- OpenBao CLI (.deb von den Releases) ---
cd /tmp
wget https://github.com/openbao/openbao/releases/download/v2.5.4/openbao_2.5.4_linux_amd64.deb
sudo apt install -y ./openbao_2.5.4_linux_amd64.deb
which bao
bao version
```

(OpenBao-`.deb`-Installationsweg extern verifiziert: `openbao.org/docs/install`. Alternativ Snap: `sudo snap install openbao`.)

### Installation prüfen

```bash
docker version
k3d version
kubectl version --client
helm version
tofu version
bao version
```

> **CLI-Falle (gilt überall):** Die `bao`-CLI verbindet sich über **`VAULT_ADDR`**/**`VAULT_TOKEN`**, nicht über `BAO_ADDR`/`BAO_TOKEN` (Vault-Kompatibilität, extern verifiziert: `openbao.org/docs/commands`). Ausführlich erklärt in [[docker]] (Gotcha gemischte Präfixe). Wir nutzen daher durchgehend `VAULT_`*.

---

## Teil 1 — k3d-Cluster (3 Nodes) erstellen

```bash
k3d cluster create openbao --servers 1 --agents 2 \
    --port "80:80@loadbalancer" \
    --port "443:443@loadbalancer"
```

Das ergibt **drei Nodes** (1 Server + 2 Agents). In k3s/k3d ist auch der Server-Node **schedulebar** (kein Control-Plane-Taint wie bei kubeadm), es stehen also drei Nodes für Pods bereit (extern verifiziert: `k3d.io`). Genau das brauchen die drei OpenBao-Pods, denn das Helm-Chart verteilt sie per **Pod-Anti-Affinity** auf verschiedene Nodes ([[k8s-ha-setup]]).

Prüfen:

```bash
kubectl get nodes
kubectl get storageclass
```

Erwartet: drei Nodes `Ready` und eine Default-StorageClass **`local-path`** (k3s bringt den local-path-Provisioner mit — die Raft-PVCs binden damit out-of-the-box).

> k3d setzt automatisch den kubectl-Kontext auf den neuen Cluster. Falls nicht: `kubectl config use-context k3d-openbao`.

---

## Teil 2 — OpenBao per Helm deployen (HA + Raft, manuelles Unseal)

In diesem Teil deployen wir **ohne** Auto-Unseal, damit der Init-/Unseal-/Join-Ablauf sichtbar wird. Auto-Unseal folgt in Teil 4.

### 2.1 Helm-Repo hinzufügen

```bash
helm repo add openbao https://openbao.github.io/openbao-helm
helm repo update
helm search repo openbao/openbao
```

(Repo-URL aus [[k8s-ha-setup]], `raw/docs/platform/k8s/helm/terraform.md`.)

### 2.2 Werte-Datei

`values-ha.yaml`:

```yaml
server:
  ha:
    enabled: true
    replicas: 3
    raft:
      enabled: true
      setNodeId: true      # node_id je Pod automatisch setzen
ui:
  enabled: true            # erzeugt den Service "openbao-ui" + schaltet die UI frei
```

Mehr braucht es nicht: Das Chart bringt für `server.ha.raft.config` bereits einen sinnvollen Default mit (extern verifiziert: `openbao-helm/charts/openbao/values.yaml`):

```hcl
ui = true

listener "tcp" {
  tls_disable     = 1
  address         = "[::]:8200"
  cluster_address = "[::]:8201"
}

storage "raft" {
  path = "/openbao/data"
}

service_registration "kubernetes" {}
```

Das ist genau das Muster aus [[compose-cluster]] und [[raft]]: API-Port 8200, Cluster-Port 8201, `storage "raft"`. `tls_disable = 1` ist hier nur fürs Lernen — produktiv TLS ([[k8s-ha-setup]] Abschnitt TLS, [[load-balancing]]).

### 2.3 Installieren

```bash
kubectl create namespace openbao
helm install openbao openbao/openbao -n openbao -f values-ha.yaml

kubectl -n openbao get pods -w
```

### 2.4 Cluster initialisieren (nur Pod 0)

```bash
kubectl -n openbao exec -ti openbao-0 -- bao operator init

Unseal Key 1: lsPn0Ieg8i5V2TaMqVr65E5IrGIfH2VTBB6ONxYuyIYF
Unseal Key 2: fMB4Ncd5JZ0INFIrUgdvzEWlDWbA7kCvkcvrGOYcDipH
Unseal Key 3: tCTh+MNk4hGfp+/iil1m0piHlkcsGnlBC86Y/QvL4Vqk
Unseal Key 4: Fwty+sj52HSgK0BMCBy/NIU8mmKCmvQeiESKuLY9aUhD
Unseal Key 5: TqYEcFMTfgMTry6Biv4/aTQLtAWYSBd2CtWuXlVPj1Nu

Initial Root Token: s.FGRoutLJ0vf87OWaehbciaQI
```

Du erhältst **5 Unseal-Key-Shares**, **Threshold 3** und den **Initial Root Token** ([[seal-unseal]]). **Genau einmal sichtbar — sicher notieren.** Diese Keys brauchst du gleich für *jeden* Node.

### 2.5 Pod 0 entsiegeln

```bash
kubectl -n openbao exec -ti openbao-0 -- bao operator unseal   # Key 1
kubectl -n openbao exec -ti openbao-0 -- bao operator unseal   # Key 2
kubectl -n openbao exec -ti openbao-0 -- bao operator unseal   # Key 3
```

Nach dem dritten Share ist `openbao-0` **Leader** eines Ein-Node-Raft-Clusters und wird `1/1 Ready`.

### 2.6 Follower joinen & entsiegeln

Jeder Follower joint über den **headless Service** `openbao-internal` und wird **einzeln** mit denselben Keys entsiegelt ([[k8s-ha-setup]], `raw/docs/platform/k8s/helm/examples/ha-with-raft.md`):

```bash
kubectl -n openbao exec -ti openbao-1 -- bao operator raft join http://openbao-0.openbao-internal:8200
kubectl -n openbao exec -ti openbao-1 -- bao operator unseal   # 3× dieselben Keys

kubectl -n openbao exec -ti openbao-2 -- bao operator raft join http://openbao-0.openbao-internal:8200
kubectl -n openbao exec -ti openbao-2 -- bao operator unseal   # 3× dieselben Keys
```

> **Warum dieselben Keys?** Der Join überträgt die Cluster-Zertifikate per verschlüsseltem Challenge/Answer — **alle Nodes müssen denselben Seal teilen** ([[raft]], [[seal-unseal]]). Bei Shamir heißt das: identische Unseal-Keys. Genau diese Reibung beseitigt Auto-Unseal in Teil 4.

### 2.7 Verifizieren

```bash
kubectl -n openbao exec -ti openbao-0 -- bao status

kubectl -n openbao exec -ti openbao-0 -- bao login
kubectl -n openbao exec -ti openbao-0 -- bao operator raft list-peers
```

Erwartet (source: `raw/docs/platform/k8s/helm/examples/ha-with-raft.md`):

```
Node          Address                            State       Voter
----          -------                            -----       -----
openbao-0     openbao-0.openbao-internal:8201    leader      true
openbao-1     openbao-1.openbao-internal:8201    follower    true
openbao-2     openbao-2.openbao-internal:8201    follower    true
```

---

## Teil 3 — Raft verstehen (Demo)

Kurzfassung der Mechanik: Aus den drei gleichberechtigten Nodes wird per Wahl **ein Leader** bestimmt; nur er nimmt Schreibvorgänge an und repliziert sie. Eine Änderung gilt erst, wenn eine **Mehrheit (Quorum = 2 von 3)** sie bestätigt hat. Daraus folgt die **Failure Tolerance 1**: ein Node darf ausfallen.

**Live-Demo — Leader killen und Failover sehen:**

```bash
# aktuellen Leader anzeigen
kubectl -n openbao exec -ti openbao-0 -- bao status | grep -i "HA Mode"

# Leader-Pod löschen
kubectl -n openbao delete pod openbao-0

# auf einem überlebenden Node: neuer Leader wurde gewählt, Cluster läuft weiter
kubectl -n openbao exec -ti openbao-1 -- bao operator raft list-peers
kubectl -n openbao exec -ti openbao-1 -- bao status
```

Der gelöschte Pod wird vom StatefulSet neu gestartet — kommt aber als **sealed** zurück und muss (in diesem Shamir-Setup) **erneut entsiegelt** werden:

```bash
kubectl -n openbao exec -ti openbao-0 -- bao operator unseal   # 3×
```

> **Das ist der Aha-Moment für Auto-Unseal:** Jeder Pod-Neustart erzwingt manuelles Unseal. In Kubernetes ist das untragbar — deshalb Teil 4.
>
> Fällt ein **zweiter** Node aus, ist das Quorum verloren und der Cluster nimmt keine Schreibvorgänge mehr an (Raft ist CP — Konsistenz vor Verfügbarkeit).

---

## Ingress (optional)

> Nicht Teil des Kern-Ablaufs (Teile 0–6). Dieser Abschnitt zeigt, wie man die OpenBao-UI über einen **Traefik-Ingress** statt per `port-forward` erreichbar macht — erst ohne, dann mit TLS per cert-manager.

### Voraussetzung: LB-Ports

Der k3d-Cluster aus Teil 1 wurde bereits mit gemappten LoadBalancer-Ports `80`/`443` erstellt. Fehlen sie, lassen sie sich nachträglich ergänzen:

```bash
k3d cluster edit openbao \
  --port-add "80:80@loadbalancer" \
  --port-add "443:443@loadbalancer"
```

> ⚠️ Das rekreiert den `serverlb`-Container (kurze LB-Unterbrechung, auch der API-Port wird neu gebunden). Die k3s-Nodes/Daten bleiben unangetastet. Ist Port 80/443 auf dem Host belegt, stattdessen z. B. `8080:80`/`8443:443` nehmen.

### Variante A — Ingress ohne TLS (dev)

`values-ingress.yml` — wie `values-ha.yaml`, zusätzlich der `ingress`-Block:

```yaml
server:
  ha:
    enabled: true
    replicas: 3
    raft:
      enabled: true
      setNodeId: true      # node_id je Pod automatisch setzen
      config: |
        ui = true

        listener "tcp" {
          tls_disable     = 1
          address         = "[::]:8200"
          cluster_address = "[::]:8201"
        }

        storage "raft" {
          path = "/openbao/data"

          retry_join { leader_api_addr = "http://openbao-0.openbao-internal:8200" }
          retry_join { leader_api_addr = "http://openbao-1.openbao-internal:8200" }
          retry_join { leader_api_addr = "http://openbao-2.openbao-internal:8200" }
        }

        service_registration "kubernetes" {}

  # API-Adresse muss bei tls_disable auf http stehen
  extraEnvironmentVars:
    BAO_ADDR: http://127.0.0.1:8200

  ingress:
    enabled: true
    ingressClassName: traefik
    activeService: true          # Ingress zeigt auf den aktiven (Leader-)Pod
    hosts:
      - host: openbao.local
        paths: []
    tls: []                      # kein TLS am Ingress (dev)

ui:
  enabled: true
```

Ausrollen:

```bash
helm upgrade openbao openbao/openbao -n openbao -f values-ingress.yml
```

Löst `openbao.local` nicht automatisch auf `127.0.0.1` auf, in `/etc/hosts` ergänzen:

```bash
echo "127.0.0.1 openbao.local" | sudo tee -a /etc/hosts
```

Test:

```bash
export VAULT_ADDR=http://openbao.local
curl $VAULT_ADDR/v1/sys/health
# oder UI im Browser: http://openbao.local/ui
```

### Variante B — TLS am Ingress (cert-manager + Cloudflare DNS-01)

Für ein echtes Zertifikat von Let's Encrypt per **DNS-01-Challenge** über Cloudflare.

**1. cert-manager installieren:**

```bash
helm repo add jetstack https://charts.jetstack.io
helm repo update
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --set crds.enabled=true

kubectl get pods -n cert-manager   # alle Ready?
```

**2. Cloudflare API-Token erstellen** (Dashboard → My Profile → API Tokens → Create Token, Vorlage „Edit zone DNS"):

- `Zone → DNS → Edit`
- `Zone → Zone → Read`
- beschränkt auf deine Zone (z. B. `softxpert.de`)

Token als Secret anlegen — cert-manager sucht es bei einem `ClusterIssuer` standardmäßig im **`cert-manager`-Namespace**:

```bash
kubectl create secret generic cloudflare-api-token-secret \
  --namespace cert-manager \
  --from-literal=api-token=<DEIN_TOKEN>
```

**3. ClusterIssuer anlegen** (`cert-manager-cloudflare.yaml`):

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: letsencrypt-prod
spec:
  acme:
    server: https://acme-v02.api.letsencrypt.org/directory
    email: you@example.com
    privateKeySecretRef:
      name: letsencrypt-prod
    solvers:
      - dns01:
          cloudflare:
            apiTokenSecretRef:
              name: cloudflare-api-token-secret
              key: api-token
        selector:
          dnsZones:
            - "softxpert.de"
```

```bash
kubectl apply -f cert-manager-cloudflare.yaml
kubectl get clusterissuer letsencrypt-prod -o wide   # Ready=True?
```

**4. Ingress mit TLS** — in `values-ingress.yml` den `ingress`-Block erweitern:

```yaml
  ingress:
    enabled: true
    ingressClassName: traefik
    activeService: true
    annotations:
      cert-manager.io/cluster-issuer: letsencrypt-prod
    hosts:
      - host: openbao.intern.softxpert.de
        paths: []
    tls:
      - secretName: openbao-tls
        hosts:
          - openbao.intern.softxpert.de
```

```bash
helm upgrade openbao openbao/openbao -n openbao -f values-ingress.yml

# cert-manager fordert das Zertifikat per DNS-01 an und legt openbao-tls an:
kubectl get certificate -n openbao
kubectl describe certificate openbao-tls -n openbao
```

#### Bevor du startest — 3 Dinge anpassen

1. **Domain ersetzen:** in `values-ingress.yml` und in `cert-manager-cloudflare.yaml` (`dnsZones`) deine echte öffentliche Domain statt `openbao.intern.softxpert.de` / `softxpert.de` eintragen.
2. **DNS-Record:** ein A/CNAME-Record für deinen Host muss in Cloudflare existieren und auf den Ingress/LoadBalancer zeigen — Clients müssen den Namen auflösen können.
3. **Erst mit Staging testen:** zunächst `letsencrypt-staging` als Issuer nutzen (Prod hat strenge Rate-Limits); wenn alles grün ist, auf `letsencrypt-prod` umstellen.

> **Architektur:** TLS endet am Traefik-Ingress. Intern läuft OpenBao unverändert über HTTP (`tls_disable = 1`): Client→Ingress ist verschlüsselt, Ingress→Pod ist clusterintern HTTP. Für die meisten Setups genau richtig. Echtes End-to-End-TLS bis in die Pods ist ein deutlich größerer Umbau (OpenBao-Listener auf TLS, Cert-Verteilung an alle Pods, Backend-Scheme `https` am Ingress).

## Teil 4 — Auto-Unseal mit Transit

Idee: Ein **zweiter, eigenständiger OpenBao** („Unsealer") stellt über seine **Transit Secrets Engine** einen Verschlüsselungs-Key bereit. Die HA-Cluster-Nodes bekommen eine `seal "transit"`-Stanza und fragen beim Start den Unsealer, ihren Root-Key zu entschlüsseln — **sie entsiegeln sich selbst**, extern verifiziert: `openbao.org/docs/configuration/seal/transit`).

> **Seal-Typ wechseln = frisch aufsetzen.** Von Shamir auf Transit zu migrieren geht zwar (`bao operator unseal -migrate`), ist aber Fortgeschrittenen-Stoff. Für den Workshop bauen wir den HA-Cluster aus Teil 2 ab und neu auf:
>
> ```bash
> helm uninstall openbao -n openbao
> kubectl -n openbao delete pvc --all      # Raft-Daten löschen → frischer Start
> ```

### 4.1 Unsealer deployen (Dev-Mode)

```bash
kubectl create namespace transit
helm install openbao-transit openbao/openbao -n transit \
  --set "server.dev.enabled=true" \
  --set "server.dev.devRootToken=root"
kubectl -n transit get pods -w   # warten bis 1/1 Ready
```

Der Dev-Mode ist **auto-initialisiert/auto-unsealed** mit festem Root-Token `root` ([[docker]]).

> **Achtung Lab-Charakter:** Der Dev-Unsealer hält alles **im RAM**. Stirbt er, ist der Transit-Key weg und die HA-Nodes können nicht mehr auto-unsealen (dann braucht es die Recovery-Keys). Produktiv ist der Unsealer ein **persistenter** OpenBao oder ein **Cloud-KMS**.

### 4.2 Transit-Key + Policy + Token anlegen

```bash
# Transit aktivieren und Unseal-Key erzeugen
kubectl -n transit exec -ti openbao-transit-0 -- sh -c '
  export VAULT_TOKEN=root
  bao secrets enable transit
  bao write -f transit/keys/openbao-unseal
'

# Policy: nur encrypt/decrypt auf genau diesem Key
kubectl -n transit exec -ti openbao-transit-0 -- sh -c '
  export VAULT_TOKEN=root
  cat <<EOF | bao policy write autounseal -
path "transit/encrypt/openbao-unseal" { capabilities = ["update"] }
path "transit/decrypt/openbao-unseal" { capabilities = ["update"] }
EOF
'

# kurzlebigen, erneuerbaren Token mit dieser Policy erzeugen
UNSEAL_TOKEN=$(kubectl -n transit exec -ti openbao-transit-0 -- sh -c '
  export VAULT_TOKEN=root
  bao token create -policy=autounseal -orphan -period=24h -field=token
')
echo "Unseal-Token: $UNSEAL_TOKEN"
```

### 4.3 Token als Kubernetes-Secret in den OpenBao-Namespace legen

```bash
kubectl -n openbao create secret generic openbao-transit-token \
  --from-literal=token="$UNSEAL_TOKEN"


# Ich hatte einen Fehler da das Secret falsche Zeichen enthielt
OpenBao rejects any seal token with non-printable characters, hence the CrashLoopBackOff.

  To avoid it next time, sanitize before storing. Any of these work:

  # strip ANSI codes + all control chars when capturing
  UNSEAL_TOKEN=$(... | sed 's/\x1b\[[0-9;]*m//g' | tr -d '[:cntrl:]')

  # or disable color at the source so the token is clean to begin with
  bao token create -field=token   # -field avoids the formatted/colored table

  Then verify the bytes before trusting the secret:
  kubectl -n openbao get secret openbao-transit-token -o jsonpath='{.data.token}' | base64 -d | xxd | tail
  It should end exactly on the last token character — no 1b5b…6d, no trailing 0d/0a.
```

### 4.4 HA-Cluster mit Transit-Seal deployen

`values-autounseal.yaml`:

```yaml
server:
  ha:
    enabled: true
    replicas: 3
    raft:
      enabled: true
      setNodeId: true
      config: |
        ui = true

        listener "tcp" {
          tls_disable     = 1
          address         = "[::]:8200"
          cluster_address = "[::]:8201"
        }

        storage "raft" {
          path = "/openbao/data"

          retry_join { leader_api_addr = "http://openbao-0.openbao-internal:8200" }
          retry_join { leader_api_addr = "http://openbao-1.openbao-internal:8200" }
          retry_join { leader_api_addr = "http://openbao-2.openbao-internal:8200" }
        }

        service_registration "kubernetes" {}

        seal "transit" {
          address    = "http://openbao-transit.transit.svc:8200"
          mount_path = "transit/"
          key_name   = "openbao-unseal"
        }

  # Token für den Transit-Unsealer als VAULT_TOKEN aus dem Secret injizieren
  extraSecretEnvironmentVars:
    - envName: VAULT_TOKEN
      secretName: openbao-transit-token
      secretKey: token

ui:
  enabled: true
```

Zwei Erweiterungen gegenüber Teil 2 (beide aus den verifizierten Quellen):

- **`retry_join`** je Node — die Follower **joinen jetzt automatisch** beim Start (Muster aus [[k8s-ha-setup]] TLS-Beispiel / [[compose-cluster]]). Kein manuelles `raft join` mehr.
- **`seal "transit"`** mit `address`/`mount_path`/`key_name`; der **Token** kommt über die Umgebungsvariable **`VAULT_TOKEN`** (vom Transit-Seal als Auth genutzt — extern verifiziert: `openbao.org/docs/configuration/seal/transit`).

Deployen:

```bash
helm install openbao openbao/openbao -n openbao -f values-autounseal.yaml
kubectl -n openbao get pods -w
```

### 4.5 Nur noch initialisieren — Unseal passiert automatisch

Mit Auto-Unseal entfällt das Shamir-Unseal; stattdessen gibt es **Recovery-Keys**:

```bash
kubectl -n openbao exec -ti openbao-0 -- bao operator init \
  -recovery-shares=5 -recovery-threshold=3
```

Jetzt **ohne weiteres Zutun zusehen**: `openbao-0` entsiegelt sich automatisch, wird Leader; `openbao-1`/`-2` entsiegeln sich automatisch, joinen per `retry_join` und werden Follower. Nach kurzer Zeit:

```bash
kubectl -n openbao get pods

kubectl -n openbao exec -ti openbao-0 -- bao login                                  # alle 1/1 Ready
kubectl -n openbao exec -ti openbao-0 -- bao operator raft list-peers
```

**Der Beweis:** Einen Pod löschen — er kommt **von selbst entsiegelt** zurück, kein manuelles Unseal mehr:

```bash
kubectl -n openbao delete pod openbao-1
kubectl -n openbao get pods -w        # openbao-1 wird wieder 1/1 Ready, ganz ohne Eingriff
```

Das ist der Kontrast zu Teil 3 — genau das macht Auto-Unseal in Kubernetes praktisch verpflichtend ([[kubernetes-platform]], [[raft]]).

---

## Teil 5 — Konfiguration mit OpenTofu

OpenBao ist **API-kompatibel zu Vault**, daher konfiguriert man es mit dem Standard-Provider **`hashicorp/vault`** — kein eigener Provider nötig (extern verifiziert; ein dedizierter OpenBao-Provider ist in Diskussion, aber `hashicorp/vault` ist der dokumentierte Weg). Wir richten eine KV-Engine, eine Policy, die **userpass**-Auth-Methode und einen **Benutzer** ein, damit sich Teilnehmer:innen gleich einloggen können.

### 5.1 Zugang per Port-Forward öffnen

In einem **eigenen Terminal** offen lassen:

```bash
kubectl -n openbao port-forward svc/openbao 8200:8200
http://localhost:8200

# Oder wenn in vm
kubectl -n openbao port-forward --address 0.0.0.0 svc/openbao 8200:8200
http://172.16.0.13:8200/
```

Dann im Arbeits-Terminal:

```bash
export VAULT_ADDR="http://127.0.0.1:8200"
export VAULT_TOKEN="<Initial Root Token aus 4.5>"
```

### 5.1b Alternative: Zugang per Ingress (statt Port-Forward)

Statt `port-forward` kann die UI dauerhaft über einen Ingress erreichbar sein — praktisch auf einer VM. Voraussetzung sind die LB-Ports 80/443 (siehe Abschnitt „Ingress (optional)"):

```bash
k3d cluster edit openbao \
  --port-add "80:80@loadbalancer" \
  --port-add "443:443@loadbalancer"
```

> ⚠️ Rekreiert den `serverlb`-Container (kurze LB-Unterbrechung, auch der API-Port wird neu gebunden). Ist Port 80/443 auf der VM belegt, z. B. `8080:80`/`8443:443` nehmen.

Ingress-Objekt für die UI — `nip.io` löst den Hostnamen automatisch auf die VM-IP auf:

```yaml
# openbao-ui-ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: openbao-ui
  namespace: openbao
spec:
  ingressClassName: traefik
  rules:
    - host: openbao.172.16.0.13.nip.io   # VM-IP einsetzen
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: openbao-ui
                port:
                  number: 8200
```

```bash
kubectl apply -f openbao-ui-ingress.yaml
# danach erreichbar unter http://openbao.172.16.0.13.nip.io/
```

### 5.2 OpenTofu-Projekt

`main.tf`:

```hcl
terraform {
  required_providers {
    vault = {
      source  = "hashicorp/vault"
      version = "~> 4.0"
    }
  }
}

# Adresse & Token kommen aus VAULT_ADDR / VAULT_TOKEN (oben exportiert)
provider "vault" {}

# 1) KV-v2-Secrets-Engine unter "kv/"
resource "vault_mount" "kv" {
  path        = "kv"
  type        = "kv-v2"
  description = "Workshop KV store"
}

# 2) Policy: Leserechte auf kv/data/workshop/*
resource "vault_policy" "workshop_read" {
  name   = "workshop-read"
  policy = <<-EOT
    path "kv/data/workshop/*" {
      capabilities = ["read", "list"]
    }
  EOT
}

# 3) userpass-Auth-Methode
resource "vault_auth_backend" "userpass" {
  type = "userpass"
}

# 4) Benutzer "workshop" mit der Policy oben
resource "vault_generic_endpoint" "workshop_user" {
  depends_on           = [vault_auth_backend.userpass]
  path                 = "auth/userpass/users/workshop"
  ignore_absent_fields = true

  data_json = jsonencode({
    password = "workshop123"
    policies = ["workshop-read"]
  })
}

# 5) ein Beispiel-Secret
resource "vault_kv_secret_v2" "demo" {
  mount = vault_mount.kv.path
  name  = "workshop/hello"
  data_json = jsonencode({
    message = "OpenBao Workshop läuft!"
  })
}
```

(Provider-Quelle `hashicorp/vault ~> 4.0` und die Ressourcen-Typen `vault_mount`, `vault_policy`, `vault_auth_backend`, `vault_kv_secret_v2` extern verifiziert am 2026-05-29 gegen die OpenTofu-Registry / OpenBao-OpenTofu-Integrationsdoku.)

### 5.3 Anwenden

```bash

#export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=<your-root/dev-token>

unset VAULT_CACERT
kubectl -n openbao port-forward svc/openbao-active 8200:8200 > /tmp/bao-pf.log 2>&1

tofu init
tofu plan
tofu apply



Apply complete — 5 added, 0 changed, 0 destroyed, against the k3d cluster (127.0.0.1:8200), not the dev server.

  Created:
  - vault_mount.kv — KV-v2 store at kv/ ("Workshop KV store")
  - vault_policy.workshop_read — read/list on kv/data/workshop/*
  - vault_auth_backend.userpass — userpass auth
  - vault_generic_endpoint.workshop_user — the workshop user
  - vault_kv_secret_v2.demo — secret at kv/workshop/hello
```

Prüfen:

```bash
# VAULT_ADDR / VAULT_TOKEN sind bereits gesetzt (siehe oben)
bao secrets list
bao kv get kv/workshop/hello
bao auth list
```

---

## Teil 6 — Login: GUI & CLI

### GUI im Browser

```
http://openbao.172.16.0.13.nip.io/
```

- **Als Admin:** Methode **Token**, den Initial Root Token eintragen.
- **Als Workshop-User:** Methode **Username** (userpass), Benutzer `workshop`, Passwort `workshop123` (aus OpenTofu). Diese:r User sieht laut Policy nur `kv/workshop/`*.

> Den Root-Token nur fürs Setup nutzen; danach mit der userpass-Identität und [Policies](6-auth-und-policies.md) arbeiten.

### CLI verbinden

```bash
export VAULT_ADDR="http://127.0.0.1:8200"

# als Workshop-User einloggen
bao login -method=userpass username=workshop
# Passwort: workshop123

# Ausloggen
bao token revoke -self

export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=$(bao login -method=userpass -token-only username=workshop password=workshop123)

bao kv get kv/workshop/hello      # erlaubt
bao secrets list                  # 403 — Policy lässt es nicht zu (gewollt)

```

Der Token landet nach dem Login in `~/.vault-token`; weitere `bao`-Befehle finden ihn automatisch ([[docker]], [[commands-cli]]).

---

## Wenn du wieder echten Root brauchst

Da der Cluster Auto-Unseal über transit nutzt, gibt es statt Unseal-Keys Recovery-Keys (3 von 5). Damit lässt sich ein neuer Root-Token erzeugen:

> Hintergrund: OpenBao **v2.5.4** hat die `generate-root`-Endpoints standardmäßig deaktiviert (seit v2.5.3, Listener-Parameter `disable_unauthed_generate_root_endpoints = true`). Ohne Anpassung kommt `405 unsupported operation`.

Ablauf, um trotzdem einen neuen Root-Token zu erzeugen:

1. ConfigMap `openbao-config` temporär patchen → `disable_unauthed_generate_root_endpoints = false` im `listener "tcp"`-Block.
2. Rolling-Restart der 3 Raft-Pods (Standbys zuerst, aktiver zuletzt; Transit-Auto-Unseal entsiegelt sie automatisch).
3. `bao operator generate-root`: init mit OTP → die 3 Recovery-Keys (Threshold 3/5) eingeben → encoded Token mit OTP dekodieren.
4. Config zurücksetzen und erneut durchrollen → Endpoint ist wieder gesperrt (405 bestätigt).

> **Hinweise:**
> - Die ConfigMap-Änderung ist ein direkter `kubectl`-Patch, kein Helm-Update — der nächste `helm upgrade` überschreibt sie ohnehin mit dem sicheren Default (kein Drift in die unsichere Richtung).
> - Empfehlung: aus dem neuen Root-Token einen kurzlebigen oder minimal berechtigten Token ableiten und den Root-Token danach wieder `revoke`n.
>
> Quellen: Seal/Unseal – Recovery Keys · tcp listener (`disable_unauthed_generate_root_endpoints`) · `operator generate-root`.

## PostgreSQL mit rotierendem Passwort

`files/3-kubernetes/postgres/docker-compose.yml`:

```yaml
services:
  postgres:
    image: postgres:16
    container_name: postgres
    restart: unless-stopped
    environment:
      POSTGRES_USER: postgres
      POSTGRES_PASSWORD: changeme
      POSTGRES_DB: appdb
    ports:
      - "5432:5432"
    volumes:
      - postgres_data:/var/lib/postgresql/data

volumes:
  postgres_data:


```

Verbinden lokal:

```
sudo apt-get update -qq && sudo apt-get install -y postgresql-client-16

psql -h localhost -p 5432 -U postgres -d appdb

Passwort: changeme

Typische täglich rotierbare Secrets:

1. Dynamische App-User
   OpenBao erstellt z. B. täglich neue temporäre User wie app-daily-xxxx mit TTL 24h.
2. Read-only User
   Für Reporting, Backups, Monitoring oder BI.
3. Write/App User
   Für Anwendungen mit SELECT, INSERT, UPDATE, DELETE.
4. Migration-/CI-User
   Kurzlebige User für GitLab CI/CD, Flyway, Liquibase oder Schema-Migrationen.
5. Static Role Password Rotation
   Ein fester PostgreSQL-User bleibt bestehen, aber OpenBao rotiert dessen Passwort regelmäßig
```

## OpenBao Secrets Operator

In Kubernetes können Pods Secrets über Kubernetes Secrets konsumieren, z. B. mit dem OpenBao Secrets Operator

```
helm repo add external-secrets https://charts.external-secrets.io

#helm install external-secrets external-secrets/external-secrets \
#    -n external-secrets --create-namespace



helm upgrade --install external-secrets external-secrets/external-secrets \
     -n external-secrets --create-namespace \
     --set installCRDs=true \
     --wait --timeout 180s 2>&1 | tail -15
```

### Postgres-Passwort alle 24 h rotieren (Database Secrets Engine)

Der Operator oben **liefert** Secrets nach Kubernetes — **erzeugt/rotiert** werden sie in OpenBao. Für Postgres macht das die **Database Secrets Engine**. Wir nutzen eine **Static Role**: ein **bereits bestehender** Postgres-User bleibt erhalten, OpenBao **rotiert nur sein Passwort** (Muster 5 aus der Liste oben). Das ist der Unterschied zu *Dynamic Roles*, die bei jedem Abruf einen neuen Wegwerf-User mit TTL anlegen.

> **Static vs. Dynamic:** Static Role = fester User, rotierendes Passwort (gut für Apps mit fester DB-Identität). Dynamic Role = OpenBao legt pro Abruf einen neuen User an. Die Aufgabe hier — „erst einen User anlegen, dessen Passwort rotiert wird" — ist also genau eine **Static Role**.

#### Schritt 1 — den zu rotierenden User zuerst in Postgres anlegen

Static Roles rotieren nur, sie **erstellen** keinen User. Also legen wir ihn einmal selbst an. Das Start-Passwort ist egal — OpenBao überschreibt es bei der ersten Rotation sofort:

```bash
psql -h localhost -p 5432 -U postgres -d appdb        # Passwort: changeme

CREATE ROLE app_user WITH LOGIN PASSWORD 'init-changeme';
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO app_user;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO app_user;
\q
```

Der **Connection-User**, mit dem sich OpenBao verbindet, muss fremde Passwörter ändern dürfen. Für den Workshop nehmen wir den `postgres`-Superuser aus der [docker-compose](#postgresql-mit-rotierendem-passwort) oben; produktiv ein dedizierter Rotations-User mit minimalen Rechten.

#### Schritt 2 — Erreichbarkeit: Postgres aus dem k3d-Cluster

Postgres läuft per Docker Compose auf dem **Host** (Port 5432). Die OpenBao-Pods im k3d-Cluster erreichen den Host über **`host.k3d.internal`** — k3d spiegelt diesen Namen automatisch in den Cluster (extern verifiziert: `k3d.io`, host-aliases). Genau das steht als Default `postgres_host` in `database.tf`.

#### Schritt 3 — Engine, Connection & Static Role per OpenTofu anlegen

Die Datei `terraform/database.tf` liegt **neben `main.tf`** im selben Projekt und wird vom selben `tofu apply` mit erfasst. Kern der Datei:

```hcl
# 1) Database-Secrets-Engine unter "database/"
resource "vault_mount" "database" {
  path = "database"
  type = "database"
}

# 2) Verbindung zur Postgres-Instanz (Connection-User = Superuser)
resource "vault_database_secret_backend_connection" "postgres" {
  backend       = vault_mount.database.path
  name          = "postgres"
  allowed_roles = ["app-static"]

  postgresql {
    connection_url = "postgresql://{{username}}:{{password}}@host.k3d.internal:5432/appdb?sslmode=disable"
    username       = "postgres"
    password       = "changeme"
  }
}

# 3) Static Role: rotiert app_user alle 86400 s = 24 h
resource "vault_database_secret_backend_static_role" "app" {
  backend             = vault_mount.database.path
  name                = "app-static"
  db_name             = vault_database_secret_backend_connection.postgres.name
  username            = "app_user"
  rotation_period     = 86400
  rotation_statements = ["ALTER USER \"{{name}}\" WITH PASSWORD '{{password}}';"]
}
```

Anwenden (Port-Forward wie in Teil 5 muss laufen):

```bash
unset VAULT_CACERT
export VAULT_ADDR=http://127.0.0.1:8200
export VAULT_TOKEN=<root>

kubectl port-forward -n openbao svc/openbao-active 8200:8200

tofu plan
tofu apply

bao read database/static-creds/app-static

Nächste sinnvolle Checks, falls du weitermachen willst:

  - Passwort wirklich in Postgres gesetzt? Test-Login mit dem obigen Passwort:
  PGPASSWORD='CREd-MDstbNKQJ4GG696' psql -h localhost -U app_user -d appdb -c '\conninfo'
  - Manuelle Rotation antesten (statt 24 h warten):
  bao write -f database/rotate-role/app-static
  bao read database/static-creds/app-static
  - Danach sollte password ein anderer Wert und last_vault_rotation neuer sein.
  - ESO/Demo-App: prüfen, dass der Secrets Operator dieses Passwort in ein K8s-Secret synct (eso-postgres.yaml / demo-app.yaml).
```

(Ressourcen-Typen `vault_mount` (type `database`), `vault_database_secret_backend_connection` und `vault_database_secret_backend_static_role` mit `rotation_period`/`rotation_statements` extern verifiziert gegen die OpenTofu-Registry `hashicorp/vault`.)

#### Schritt 4 — Rotation prüfen

```bash
# aktuelles (bereits rotiertes) Passwort lesen
bao read database/static-creds/app-static
```

Erwartet ungefähr:

```
Key                    Value
---                    -----
last_vault_rotation    2026-06-01T12:00:00Z
password               A1b2C3d4...              # von OpenBao gesetzt, nicht init-changeme
rotation_period        86400
ttl                    86399                    # zählt bis zur nächsten Rotation herunter
username               app_user
```

Sofort von Hand rotieren (zum Vorführen, statt 24 h zu warten):

```bash
bao write -f database/rotate-role/app-static
bao read database/static-creds/app-static       # password hat sich geändert
```

Login mit dem rotierten Passwort gegenchecken:

```bash
PGPASSWORD=$(bao read -field=password database/static-creds/app-static) \
  psql -h localhost -p 5432 -U app_user -d appdb -c '\conninfo'
```

#### Schritt 5 — das rotierte Passwort nach Kubernetes liefern (ESO)

Jetzt schließt sich der Kreis zum Operator: ESO liest die Static-Creds aus OpenBao und schreibt sie in ein Kubernetes-`Secret`, das die App mountet. Über `refreshInterval` holt ESO regelmäßig das **aktuelle** Passwort:

`files/3-kubernetes/postgres/eso-postgres.yaml`:

```yaml
# eso-postgres.yaml
apiVersion: external-secrets.io/v1
kind: ClusterSecretStore
metadata:
  name: openbao
spec:
  provider:
    vault:
      server: "http://openbao.openbao.svc:8200"
      path: "database"            # Mount der DB-Engine
      version: v1                 # static-creds ist KV-v1-artig, kein /data/-Pfad
      auth:
        tokenSecretRef:
          name: openbao-token
          namespace: external-secrets
          key: token
---
apiVersion: external-secrets.io/v1
kind: ExternalSecret
metadata:
  name: app-db
  namespace: default
spec:
  refreshInterval: 1h            # kürzer als rotation_period (24 h)!
  secretStoreRef:
    name: openbao
    kind: ClusterSecretStore
  target:
    name: app-db                 # so heißt das erzeugte k8s-Secret
  data:
    - secretKey: username
      remoteRef:
        key: static-creds/app-static
        property: username
    - secretKey: password
      remoteRef:
        key: static-creds/app-static
        property: password
```

```bash
# Token für ESO (mind. Policy db-app-read aus database.tf)
kubectl -n external-secrets create secret generic openbao-token \
  --from-literal=token="$VAULT_TOKEN"

kubectl apply -f eso-postgres.yaml
kubectl get externalsecret app-db
kubectl get secret app-db -o jsonpath='{.data.password}' | base64 -d
```

> **Achtung Rotation:** Mit Static Roles ändert sich das DB-Passwort **serverseitig**. Ohne ESO (oder App-Neustart/Re-Read) hält deine App weiter das alte Passwort und fliegt nach der Rotation raus. `refreshInterval` muss daher **kürzer** sein als die `rotation_period`.

#### Schritt 6 — Demo-App, die das `app-db`-Secret mountet

Eine kleine App beweist den ganzen Kreis: Sie konsumiert das von ESO gepflegte `app-db`-Secret und verbindet sich damit gegen Postgres. Wir mounten das Secret **doppelt** — als Env-Variablen (`secretKeyRef`) **und** als Volume (Dateien unter `/etc/db-creds/`) — weil sich beide bei einer Rotation unterschiedlich verhalten:

`files/3-kubernetes/postgres/demo-app.yaml`:

```yaml
# demo-app.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: demo-app
  namespace: default
spec:
  replicas: 1
  selector:
    matchLabels: { app: demo-app }
  template:
    metadata:
      labels: { app: demo-app }
    spec:
      containers:
        - name: demo
          image: postgres:16            # bringt psql mit
          command: ["/bin/sh", "-c"]
          args:
            - |
              while true; do
                # Passwort bei JEDEM Versuch frisch aus dem gemounteten Volume lesen,
                # damit die App die Rotation ohne Neustart mitbekommt.
                export PGUSER="$(cat /etc/db-creds/username)"
                export PGPASSWORD="$(cat /etc/db-creds/password)"
                echo "[demo] verbinde als $PGUSER ..."
                psql -h "$PGHOST" -d "$PGDATABASE" -c 'SELECT now();' \
                  || echo "[demo] Login fehlgeschlagen"
                sleep 30
              done
          env:
            - name: PGHOST
              value: host.k3d.internal   # Postgres läuft auf dem Docker-Host
            - name: PGDATABASE
              value: appdb
            # zusätzlich als Env injiziert (Demonstration secretKeyRef):
            - name: APP_DB_USER
              valueFrom:
                secretKeyRef:
                  name: app-db
                  key: username
            - name: APP_DB_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: app-db
                  key: password
          volumeMounts:
            - name: db-creds
              mountPath: /etc/db-creds
              readOnly: true
      volumes:
        - name: db-creds
          secret:
            secretName: app-db           # von ESO erzeugt (Schritt 5)
```

```bash
kubectl apply -f demo-app.yaml
kubectl logs -l app=demo-app -f          # alle 30 s ein erfolgreicher SELECT now();

# das gemountete Secret als Dateien im Pod:
kubectl exec deploy/demo-app -- ls /etc/db-creds
kubectl exec deploy/demo-app -- cat /etc/db-creds/username
```

**Rotation live sehen** — Passwort in OpenBao rotieren und zusehen, wie die App ohne Neustart weiterläuft:

```bash
bao write -f database/rotate-role/app-static     # neues Passwort serverseitig
# ESO holt es beim nächsten refreshInterval -> kubelet synct das Volume (~1 min)
kubectl logs -l app=demo-app -f                  # SELECT läuft weiter durch
```

> **Warum Volume statt Env?** Kubelet aktualisiert **gemountete Secret-Volumes automatisch** (Verzögerung ~1 min), sobald ESO das `app-db`-Secret neu schreibt. **Env-Variablen per `secretKeyRef` werden dagegen nur beim Pod-Start gesetzt** und bleiben danach eingefroren (`APP_DB_PASSWORD` zeigt also das alte Passwort, bis der Pod neu startet). Deshalb liest die Demo das Passwort bei jedem Versuch frisch aus `/etc/db-creds/` — genau das ist das Muster für rotierende Secrets. Wer zwingend Env braucht, koppelt einen Reloader (z. B. `stakater/Reloader`) dazu, der den Pod bei Secret-Änderung neu rollt.

## Aufräumen

```bash
# Demo-App + ESO-Objekte entfernen
kubectl delete -f files/3-kubernetes/postgres/demo-app.yaml
kubectl delete -f files/3-kubernetes/postgres/eso-postgres.yaml

# OpenBao-Releases entfernen
helm uninstall openbao -n openbao
helm uninstall openbao-transit -n transit

# OpenTofu-Ressourcen (optional, vor dem Cluster-Löschen)
tofu destroy

# kompletter Reset: k3d-Cluster löschen
k3d cluster delete openbao

# Postgres-Demo-DB stoppen und Daten-Volume entfernen (-v)
docker compose -f files/3-kubernetes/postgres/docker-compose.yml down -v
```

---

## Vorschlag für den Workshop-Ablauf (≈ 2–2,5 h)


| Block | Inhalt                                                      | Dauer  |
| ----- | ----------------------------------------------------------- | ------ |
| 0     | Tools installieren (vorab als Hausaufgabe!)                 | —      |
| 1     | k3d-Cluster bauen, Nodes/StorageClass prüfen                | 10 min |
| 2     | Helm-Deploy, **manuell** init/unseal/join                   | 30 min |
| 3     | Raft erklären + Leader-Failover-Demo                        | 20 min |
| 4     | Transit-Unsealer, Redeploy mit Auto-Unseal, Pod-Kill-Beweis | 35 min |
| 5     | OpenTofu: Engine/Policy/User/Secret                         | 25 min |
| 6     | GUI- und CLI-Login (alle gleichzeitig)                      | 15 min |
| —     | Aufräumen / Q&A                                             | 15 min |


> **Tipp:** Teil 0 unbedingt vorab erledigen lassen — Tool-Installation frisst sonst die halbe Session. Eine kurze „prüfe deine Installation"-Checkliste (Teil 0, letzter Block) vorab verschicken.

## Häufige Stolperfallen

- **Pods bleiben `0/1 Ready`** — normal, solange sealed. Erst nach Unseal (Teil 2) bzw. Auto-Unseal (Teil 4) werden sie ready.
- **Pods bleiben `Pending`** — die Anti-Affinity verlangt drei Nodes. Cluster wirklich mit `--agents 2` (= 3 Nodes) gebaut? `kubectl get nodes`.
- **`raft join` schlägt fehl** — Pod 0 muss zuerst initialisiert **und** entsiegelt sein, sonst gibt es keinen Leader. Außerdem muss der **joinende** Pod selbst schon laufen: direkt nach `Running` ist die lokale API evtl. noch nicht gebunden (`connect: connection refused` auf `127.0.0.1:8200`) — dann kurz warten (z. B. `kubectl -n openbao exec openbao-1 -- bao status` bis es antwortet) und `raft join` erneut ausführen.
- **Auto-Unseal-Pods bleiben sealed** — Token-Secret falsch (`openbao-transit-token`), Unsealer nicht ready, oder Transit-Key/Mount-Pfad stimmt nicht. Logs: `kubectl -n openbao logs openbao-0`.
- **CLI ignoriert die Adresse** — `BAO_ADDR` statt `VAULT_ADDR` gesetzt (siehe Gotcha oben, [[docker]]).
- **`tofu apply` 403/connection refused** — Port-Forward läuft nicht, oder `VAULT_TOKEN` fehlt/abgelaufen.
- **Dev-Unsealer neu gestartet** → Transit-Key verloren → HA-Cluster nicht mehr auto-unsealbar. Im Workshop einfach Teil 4 neu durchlaufen; produktiv Unsealer persistent halten.

