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

Gebraucht werden: **Docker**, **k3d**, **kubectl**, **helm**, die `**bao`-CLI** und **OpenTofu**. (Alle Installationswege extern verifiziert am 2026-05-29.)

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

> **CLI-Falle (gilt überall):** Die `bao`-CLI verbindet sich über `**VAULT_ADDR`/`VAULT_TOKEN`**, nicht über `BAO_ADDR`/`BAO_TOKEN` (Vault-Kompatibilität, extern verifiziert: `openbao.org/docs/commands`). Ausführlich erklärt in [[docker]] (Gotcha gemischte Präfixe). Wir nutzen daher durchgehend `VAULT_`*.

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

Erwartet: drei Nodes `Ready` und eine Default-StorageClass `**local-path**` (k3s bringt den local-path-Provisioner mit — die Raft-PVCs binden damit out-of-the-box).

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
> Fällt ein **zweiter** Node aus, ist das Quorum verloren und der Cluster nimmt keine Schreibvorgänge mehr an (Raft ist CP — Konsistenz vor Verfügbarkeit.

---

## Teil 4 — Ingress

k3d Cluster starten

```bash
k3d cluster create openbao --servers 1 --agents 2 \
    --port "80:80@loadbalancer" \
    --port "443:443@loadbalancer"
```

 values-ingress.yml

```bash
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

          retry_join {
            leader_api_addr = "http://openbao-0.openbao-internal:8200"
          }
          retry_join {
            leader_api_addr = "http://openbao-1.openbao-internal:8200"
          }
          retry_join {
            leader_api_addr = "http://openbao-2.openbao-internal:8200"
          }
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

```bash
helm upgrade openbao openbao/openbao -n openbao -f values-ingress.yml
```

OpenBao Helm Chart mit Ingress

Das OpenBao-Chart ist ein Fork des Vault-Charts, die Ingress-Struktur ist identisch. values.yaml:

  server:

```
# Für lokales Testen ohne TLS/Storage – dev mode

dev:

  enabled: true

ingress:

  enabled: true

  ingressClassName: traefik

  # Traefik annotations bei Bedarf, z.B. für websocket/timeout

  annotations: {}

  hosts:

    - host: bao.[localhost](http://localhost)

      paths:

        - /

  # für lokales http kein tls-Block nötig

  tls: []

# OpenBao API lauscht auf 8200 – das Chart setzt das Service-Target passen
```

export VAULT_ADDR=[http://bao.localhost:8080](http://bao.localhost:8080)

  curl $VAULT_ADDR/v1/sys/health

# oder UI im Browser: [http://bao.localhost:8080/ui](http://bao.localhost:8080/ui)

  Falls bao.[localhost](http://localhost) nicht automatisch auf 127.0.0.1 auflöst, in /etc/hosts ergänzen:

  127.0.0.1 bao.[localhost](http://localhost)

Zertifikat

1. cert-manager installieren
  helm repo add jetstack [https://charts.jetstack.io](https://charts.jetstack.io)
  helm repo update
  helm install cert-manager jetstack/cert-manager  
    --namespace cert-manager --create-namespace  
    --set crds.enabled=true
  Prüfen, dass die Pods laufen:
  kubectl get pods -n cert-manager
  1. Cloudflare API-Token erstellen
    Cloudflare-Dashboard → My Profile → API Tokens → Create Token. Nutze die Vorlage „Edit zone DNS" mit diesen Rechten:
    Zone → DNS → Edit
    Zone → Zone → Read
    Beschränkt auf deine Zone [softxpert.de](http://softxpert.de)
    nn das Token als Secret anlegen (im selben Namespace wie OpenBao, z. B. openbao):
    bectl create secret generic cloudflare-api-token-secret  
    --namespace  
    --from-literal=api-token=
    inweis: Bei ClusterIssuer sucht cert-manager das API-Token-Secret standardmäßig im cert-manager-Namespace. Lege es daher entweder dort an, oder verwende einen namespace-gebundenen Issuer. Am
    einfachsten: das Secret zusätzlich im cert-manager-Namespace anlegen.
  2. ClusterIssuer anwenden
    bectl apply -f cert-manager-cloudflare.yaml
    atus prüfen (sollte Ready=True werden):
    bectl get clusterissuer letsencrypt-prod -o wide
  3. Helm-Werte ausrollen
    lm upgrade openbao openbao/openbao  
    -n  
    -f values-ingress.yml
    rt-manager erkennt die Annotation [cert-manager.io/cluster-issuer](http://cert-manager.io/cluster-issuer) am Ingress, fordert das Zertifikat per DNS-01 an und legt das Secret openbao-tls an. Beobachten:
    bectl get certificate -n 
    bectl describe certificate openbao-tls -n

Bevor du startest — 3 Dinge anpassen

1. Domain ersetzen: In values-ingress.yml und in cert-manager-cloudflare.yaml (dnsZones) deine echte öffentliche Domain statt [openbao.intern.softxpert.de](http://openbao.intern.softxpert.de) / [softxpert.de](http://softxpert.de) eintragen.
2. DNS-Record: Ein A/CNAME-Record für [openbao.intern.softxpert.de](http://openbao.intern.softxpert.de) muss in Cloudflare existieren und auf deinen Ingress/LoadBalancer zeigen — auch wenn nur intern erreichbar. (Für DNS-01 selbst ist nur
  die Zone wichtig, aber Clients müssen den Namen ja auflösen.)
3. Erst mit Staging testen: Bei Tests letsencrypt-staging als Issuer nutzen (Let's Encrypt Prod hat strenge Rate-Limits). Wenn alles grün ist, auf letsencrypt-prod umstellen.
  Wichtig zur Architektur
  TLS endet weiterhin am Traefik-Ingress. Intern läuft OpenBao unverändert über HTTP (tls_disable = 1). Client→Ingress ist verschlüsselt und vertraut, Ingress→Pod ist clusterintern HTTP. Das ist für die
  meisten Setups genau richtig — sag Bescheid, falls du echtes End-to-End-TLS bis in die Pods brauchst, das ist ein deutlich größerer Umbau (Vault/OpenBao-Listener auf TLS, Cert-Verteilung an alle Pods,
  Backend-Scheme https am Ingress).

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

- `**retry_join**` je Node — die Follower **joinen jetzt automatisch** beim Start (Muster aus [[k8s-ha-setup]] TLS-Beispiel / [[compose-cluster]]). Kein manuelles `raft join` mehr.
- `**seal "transit"`** mit `address`/`mount_path`/`key_name`; der **Token** kommt über die Umgebungsvariable `**VAULT_TOKEN`** (vom Transit-Seal als Auth genutzt — extern verifiziert: `openbao.org/docs/configuration/seal/transit`).

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

OpenBao ist **API-kompatibel zu Vault**, daher konfiguriert man es mit dem Standard-Provider `**hashicorp/vault`** — kein eigener Provider nötig (extern verifiziert; ein dedizierter OpenBao-Provider ist in Diskussion, aber `hashicorp/vault` ist der dokumentierte Weg). Wir richten eine KV-Engine, eine Policy, die **userpass**-Auth-Methode und einen **Benutzer** ein, damit sich Teilnehmer:innen gleich einloggen können.

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

DNS

Es sind also zwei Schritte nötig: (1) Host-Port zu Traefik durchreichen, (2) Ingress-Objekt anlegen.

```bash
Schritt 1 — Host-Port zu Traefik durchreichen

  k3d kann den LoadBalancer eines bestehenden Clusters um Ports erweitern:

  k3d cluster edit openbao \
    --port-add "80:80@loadbalancer" \
    --port-add "443:443@loadbalancer"

  ⚠️ Das rekreiert den serverlb-Container (kurze Unterbrechung des LB, auch der API-Port wird neu gebunden). Die k3s-Nodes/Daten bleiben unangetastet. Falls Port 80/443 auf der VM schon belegt ist, nehmen
  wir stattdessen z.B. 8080:80 / 8443:443.

  Schritt 2 — Ingress für die GUI

  # openbao-ui-ingress.yaml
  apiVersion: networking.k8s.io/v1
  kind: Ingress
  metadata:
    name: openbao-ui
    namespace: openbao
  spec:
    ingressClassName: traefik
    rules:
      - host: openbao.172.16.0.13.nip.io   # nip.io löst automatisch auf die VM-IP auf
        http:
          paths:
            - path: /
              pathType: Prefix
              backend:
                service:
                  name: openbao-ui
                  port:
                    number: 8200

  


kubectl apply -f openbao-ui-ingress.yaml

Danach erreichbar unter http://openbao.172.16.0.13.nip.io/.
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
export VAULT_ADDR=http://127.0.0.1:18200
export VAULT_TOKEN=<your-root/dev-token>


tofu init
tofu plan
tofu apply



Apply complete — 5 added, 0 changed, 0 destroyed, against the k3d cluster (127.0.0.1:18200), not the dev server.

  Created:
  - vault_mount.kv — KV-v2 store at kv/ ("Workshop KV store")
  - vault_policy.workshop_read — read/list on kv/data/workshop/*
  - vault_auth_backend.userpass — userpass auth
  - vault_generic_endpoint.workshop_user — the workshop user
  - vault_kv_secret_v2.demo — secret at kv/workshop/hello
```

Prüfen:

```bash
BAO_ADDR="$VAULT_ADDR" BAO_TOKEN="$VAULT_TOKEN"

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

> Den Root-Token nur fürs Setup nutzen; danach mit der userpass-Identität und [[policies|Policies]] arbeiten.

### CLI verbinden

```bash
export VAULT_ADDR="http://127.0.0.1:18200"

# als Workshop-User einloggen
bao login -method=userpass username=workshop
# Passwort: workshop123

# Ausloggen
bao token revoke -self

export VAULT_ADDR=http://127.0.0.1:18200
export VAULT_TOKEN=$(bao login -method=userpass -token-only username=workshop password=workshop123)

bao kv get kv/workshop/hello      # erlaubt
bao secrets list                  # 403 — Policy lässt es nicht zu (gewollt)

```

Der Token landet nach dem Login in `~/.vault-token`; weitere `bao`-Befehle finden ihn automatisch ([[docker]], [[commands-cli]]).

---

## Wenn du wieder echten Root brauchst

Da der Cluster Auto-Unseal über transit nutzt, gibt es statt Unseal-Keys Recovery-Keys (3 von 5). Damit lässt sich ein neuer Root-Token erzeugen:

```
???

Was nötig war (und warum es nicht direkt ging): OpenBao v2.5.4 hat die generate-root-Endpoints standardmäßig deaktiviert (seit v2.5.3, Listener-Parameter disable_unauthed_generate_root_endpoints = true).
  Deshalb kam anfangs 405 unsupported operation. Ablauf:

  1. ConfigMap openbao-config temporär gepatcht → disable_unauthed_generate_root_endpoints = false im listener "tcp"-Block
  2. Rolling-Restart der 3 Raft-Pods (Standbys zuerst, aktiver zuletzt; Transit-Auto-Unseal hat sie automatisch entsiegelt)
  3. generate-root: init mit OTP → deine 3 Recovery-Keys (Threshold 3/5) eingegeben → encoded Token mit OTP dekodiert
  4. Config wieder zurückgesetzt und erneut durchgerollt → Endpoint ist wieder gesperrt (405 bestätigt)

  Hinweise:
  - Der vorherige Root-Token (auth/token/root/h9…) war um 04:50 Uhr revoked worden — daher war keiner mehr verfügbar.
  - ⚠️ Die ConfigMap-Änderung war ein direkter kubectl-Patch, kein Helm-Update. Der nächste helm upgrade überschreibt sie ohnehin mit dem (sicheren) Default — kein Drift-Risiko in die unsichere Richtung.
  - Empfehlung für den Workshop: aus diesem Root-Token einen kurzlebigen Token oder einen mit minimaler Policy ableiten und den Root-Token danach wieder revoken.

  Sources: Seal/Unseal – Recovery Keys · tcp listener (disable_unauthed_generate_root_endpoints) · operator generate-root
  
```

## Postgresql mit rotierenen Passwort

```bash
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
helm repo add openbao-secrets-operator https://openbao.github.io/openbao-secrets-operator
helm repo update openbao-secrets-operator

helm search repo openbao-secrets-operator

helm upgrade --install external-secrets external-secrets/external-secrets \
     -n external-secrets --create-namespace \
     --set installCRDs=true \
     --wait --timeout 180s 2>&1 | tail -15
```

## Aufräumen

```bash
# OpenBao-Releases entfernen
helm uninstall openbao -n openbao
helm uninstall openbao-transit -n transit

# OpenTofu-Ressourcen (optional, vor dem Cluster-Löschen)
tofu destroy

# kompletter Reset: k3d-Cluster löschen
k3d cluster delete openbao
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
- `**raft join` schlägt fehl** — Pod 0 muss zuerst initialisiert **und** entsiegelt sein, sonst gibt es keinen Leader.
- **Auto-Unseal-Pods bleiben sealed** — Token-Secret falsch (`openbao-transit-token`), Unsealer nicht ready, oder Transit-Key/Mount-Pfad stimmt nicht. Logs: `kubectl -n openbao logs openbao-0`.
- **CLI ignoriert die Adresse** — `BAO_ADDR` statt `VAULT_ADDR` gesetzt (siehe Gotcha oben, [[docker]]).
- `**tofu apply` 403/connection refused** — Port-Forward läuft nicht, oder `VAULT_TOKEN` fehlt/abgelaufen.
- **Dev-Unsealer neu gestartet** → Transit-Key verloren → HA-Cluster nicht mehr auto-unsealbar. Im Workshop einfach Teil 4 neu durchlaufen; produktiv Unsealer persistent halten.

