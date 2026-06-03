# OpenBao Auto-Unseal mit HSM (PKCS#11) in Kubernetes

**Summary**:

Das **Produktionsziel**: OpenBao läuft in **Kubernetes** und schützt seinen Master-Key über ein **Hardware-HSM** via **PKCS#11** — beim Pod-Restart unsealt es sich automatisch, ohne manuelle Unseal-Keys. Genau das stellen wir hier nach: OpenBao per **k3d + Helm** im HA-/[[raft|Raft]]-Modus, Auto-Unseal über ein PKCS#11-HSM. Als HSM dient **SoftHSMv2** (apt-install auf dem Host) — der Stellvertreter für das spätere echte HSM. Aufbauend auf der Kubernetes-Mechanik aus `3-kubernetes.md` und dem PKCS#11-Wissen aus der systemd-Variante (am Ende dieses Kapitels).

---

## Warum überhaupt — und was ist hier anders

Du kennst inzwischen drei Unseal-Wege:

- **Shamir** (Standard): Bei jedem Start manuell mit 3 von 5 Key-Shares unsealen ([[seal-unseal]]). Pro Pod, nach jedem Neustart — in Kubernetes untragbar (siehe `3-kubernetes.md`, Teil 3).
- **Transit**: Ein zweiter OpenBao („Unsealer") entsiegelt die Nodes automatisch (`3-kubernetes.md`, Teil 4).
- **PKCS#11/HSM**: Der Root-Key wird mit einem Schlüssel **im HSM** verschlüsselt. Beim Start holt OpenBao den entschlüsselten Key direkt vom HSM und unsealt sich selbst. Der HSM-Key verlässt das HSM nie (`never extractable`).

**Dieses Kapitel** bringt den HSM-Weg dorthin, wo er in Produktion meistens hingehört: **nach Kubernetes**. In echtem Betrieb ist das HSM ein echtes Gerät bzw. ein Netzwerk-/Cloud-HSM (Thales Luna, AWS CloudHSM, Azure Managed HSM, YubiHSM …), und jeder OpenBao-Pod erreicht es über die **PKCS#11-Client-Library des Herstellers**. Zum Üben ersetzen wir genau diese Library durch **SoftHSMv2**.

> **Wichtig — der Standard-`openbao`-Container kann das nicht.** PKCS#11 erfordert einen **CGO-Build** von OpenBao. Das Standard-Image `openbao/openbao` (statisch, Alpine/musl) kennt `seal "pkcs11"` nicht. Wir brauchen das offizielle HSM-Image **`openbao/openbao-hsm-ubi`** (RHEL UBI/**glibc**, cgo, pkcs11).

> **PKCS#11 ist kein Netzwerkprotokoll.** `libsofthsm2.so` wird **im Pod-Prozess** geladen und liest die Token-**Dateien lokal**. Damit ein Pod die Host-SoftHSM nutzen kann, muss (a) im Container das HSM-Binary **und** die PKCS#11-Library liegen und (b) der Host-Token-Store in den Pod **gemountet** werden. Genau das bauen wir hier — und am Ende steht ein ehrlicher Kasten, **wo diese Analogie zum echten Netz-HSM endet**.

### Shamir vs. Auto-Unseal: Was passiert mit den Keys?

Mit Auto-Unseal gibt es **keine Unseal-Keys** mehr. `bao operator init` liefert stattdessen **Recovery Keys**. Die unsealen *nicht*, sondern autorisieren nur privilegierte Operationen (z. B. `operator generate-root`, Rekey, Seal). Das Unsealen erledigt das HSM.

---

## Architektur-Überblick

```
  Host (Ubuntu + Docker)
  ├── SoftHSMv2  (apt install)
  │     └── /opt/openbao/softhsm/tokens   ← Token "OpenBao" + RSA-4096-Key (never extractable)
  │            ▲
  │            │  k3d --volume /opt/openbao/softhsm/tokens:/softhsm/tokens@all   (in alle Nodes)
  │            │
  └── k3d-Cluster "openbao-hsm"
        └── Namespace "openbao"
              ├── openbao-0  (Raft leader)    ┐
              ├── openbao-1  (follower)        ├─ HA/Raft, seal "pkcs11"
              └── openbao-2  (follower)       ┘     │  Image: openbao-hsm-ubi + libsofthsm2.so
                    ▲                               │  liest /softhsm/tokens  (hostPath, read-only)
                    │  kubectl port-forward 8200    └  PIN via K8s-Secret → BAO_HSM_PIN
                    │
              GUI (Browser :8200/ui)  +  CLI (VAULT_ADDR)
```

Kernidee: SoftHSM lebt **einmal auf dem Host**. Der Token-Store wird **read-only** in alle Pods gespiegelt. Nach der Key-Erzeugung schreibt niemand mehr in den Store — Unseal ist nur encrypt/decrypt. Deshalb ist der parallele Zugriff der drei Pods unkritisch: read-only-Mount, alle Pods teilen denselben Host-Kernel.

---

## Voraussetzungen

- Ubuntu-Host mit `sudo`, **Docker**, **k3d**, **kubectl**, **helm** und der **`bao`-CLI** (Installationswege siehe `3-kubernetes.md`, Teil 0).
- Freie Ports und Internetzugang zu `github.com` / Docker-Registries (für HSM-Image und SoftHSM-Pakete).

> **CLI-Falle (gilt überall):** Die `bao`-CLI verbindet sich über **`VAULT_ADDR`**/**`VAULT_TOKEN`**, nicht über `BAO_ADDR`/`BAO_TOKEN` (Vault-Kompatibilität). Wir nutzen durchgehend `VAULT_`*.

---

## Teil 1 — SoftHSMv2 auf dem Host (Token + Key)

Diese Schritte sind identisch zur systemd-Variante (unten) — der Token-Store ist die gemeinsame Basis, die wir gleich in die Pods mounten.

### 1.1 SoftHSMv2 + Tools installieren

```bash
sudo apt-get update
sudo apt-get install -y softhsm2 opensc
softhsm2-util --version            # 2.6.1
ls -l /usr/lib/softhsm/libsofthsm2.so
```

`softhsm2` bringt die PKCS#11-Library (`libsofthsm2.so`), `opensc` das `pkcs11-tool` zum Key-Erzeugen.

### 1.2 Verzeichnisse und SoftHSM-Config (Host-Sicht)

```bash
sudo mkdir -p /opt/openbao/softhsm/tokens
```

`/opt/openbao/softhsm/softhsm2.conf` — **für die Token-Erzeugung auf dem Host**:

```ini
directories.tokendir = /opt/openbao/softhsm/tokens
objectstore.backend = file
log.level = INFO
```

> Achtung: Dieser `tokendir` ist der **Host-Pfad**. Im Pod liegt derselbe Token-Store später unter `/softhsm/tokens` — dafür bekommt das Container-Image eine eigene `softhsm2.conf` (Teil 2). Zwei Configs, zwei Blickwinkel auf dieselben Dateien.

### 1.3 Token/Slot initialisieren

```bash
export SOFTHSM2_CONF=/opt/openbao/softhsm/softhsm2.conf

sudo chown -R openbao:openbao /opt/openbao/softhsm/tokens

# 3. Initialize the token as the openbao user (with the correct config)
sudo -u openbao env SOFTHSM2_CONF=/opt/openbao/softhsm/softhsm2.conf \
  softhsm2-util --init-token --free --label "OpenBao" --so-pin 1234 --pin 4321


# 4. Verify
sudo -u openbao env SOFTHSM2_CONF=/opt/openbao/softhsm/softhsm2.conf \
  softhsm2-util --show-slots
```

`--free` nimmt den ersten freien Slot. SoftHSM vergibt eine **zufällige Slot-Nummer** — deshalb adressieren wir den Token später über `token_label = "OpenBao"`, nicht über die Slot-Nummer.

> **PINs `1234`/`4321` sind reine Demo-Werte.** `--so-pin` ist die Security-Officer-PIN (Token-Verwaltung), `--pin` die User-PIN (Key-Nutzung). Die User-PIN brauchen wir gleich als Kubernetes-Secret.

### 1.4 Schlüssel im SoftHSM erzeugen

OpenBao verlangt, dass das Key-Material **vor** der Initialisierung im HSM existiert. Für SoftHSMv2 nehmen wir ein **RSA-Schlüsselpaar** (Mechanismus RSA-OAEP) — AES-GCM ist mit SoftHSMv2 problematisch.

```bash

sudo -u openbao env SOFTHSM2_CONF=/opt/openbao/softhsm/softhsm2.conf \
pkcs11-tool --module /usr/lib/softhsm/libsofthsm2.so \
  --token-label "OpenBao" --pin 4321 \
  --keypairgen --key-type rsa:4096 --label "bao-root-key-rsa"

# Verifizieren
sudo -u openbao env SOFTHSM2_CONF=/opt/openbao/softhsm/softhsm2.conf \
pkcs11-tool --module /usr/lib/softhsm/libsofthsm2.so \
  --token-label "OpenBao" --pin 4321 --list-objects
```

Der private Key wird `sensitive, never extractable` angelegt — er kann das HSM nicht verlassen. Genau das ist der Sinn der Übung.

### 1.5 Token-Store für die Pods lesbar machen

Die Pods laufen unter dem Image-User (nicht root) und mounten den Store **read-only**. Damit sie die Token-Dateien lesen können, machen wir sie welt-lesbar:

```bash
sudo chmod -R a+rX /opt/openbao/softhsm/tokens
```

> Lab-Vereinfachung. Auf einem echten HSM stellt sich diese Frage nicht — dort regelt die HSM-Firmware den Zugriff über die PIN, nicht über Dateirechte.

---

## Teil 2 — HSM-fähiges OpenBao-Image bauen

Das offizielle `openbao/openbao-hsm-ubi` bringt das **cgo/pkcs11-Binary**, aber **nicht** `libsofthsm2.so`. Wir bauen ein schlankes Image darüber, das die SoftHSM-Library und eine Pod-taugliche `softhsm2.conf` enthält.

`files/4-soft-HSM/Dockerfile`:

```dockerfile
FROM openbao/openbao-hsm-ubi:2.5.4
USER root

# SoftHSMv2-Library (PKCS#11) aus EPEL nachinstallieren
RUN microdnf install -y epel-release \
 && microdnf install -y softhsm \
 && microdnf clean all \
 # zeigt den exakten Library-Pfad – DIESEN Wert brauchst du gleich in der seal-Stanza:
 && find / -name 'libsofthsm2.so*' 2>/dev/null

# Pod-Sicht auf den Token-Store: hier liegt er unter /softhsm/tokens (siehe Teil 3/4)
RUN mkdir -p /etc/softhsm \
 && printf 'directories.tokendir = /softhsm/tokens\nobjectstore.backend = file\nlog.level = INFO\n' \
      > /etc/softhsm/softhsm2.conf

USER openbao
```

Bauen und in den k3d-Cluster laden (den Cluster legen wir in Teil 3 an — `k3d image import` braucht ihn):

```bash
docker build -t bao-hsm-softhsm:dev files/4-soft-HSM/

# Der find-Ausgabe im Build-Log den Library-Pfad entnehmen, z. B.
#   /usr/lib64/softhsm/libsofthsm2.so   oder   /usr/lib64/pkcs11/libsofthsm2.so
# -> diesen Pfad in die seal "pkcs11"-Stanza (Teil 4) eintragen.

k3d image import bao-hsm-softhsm:dev -c openbao-hsm    # erst nach Teil 3 ausführbar
```

> **Eine Stelle, die du auf deinem Host bestätigen musst:** ob `softhsm` auf dem UBI-Image via EPEL verfügbar ist und unter welchem Pfad die Library landet. Der `find`-Aufruf im Build gibt beides aus. Schlägt EPEL fehl, ist die Alternative ein Image **`FROM openbao/openbao-hsm`** (Alpine) mit `apk add softhsm2` — dann liegt die Library typischerweise unter `/usr/lib/softhsm/libsofthsm2.so`. Beide Images sind offiziell (extern verifiziert: `hub.docker.com/r/openbao/openbao-hsm-ubi`, `…/openbao-hsm`).

---

## Teil 3 — k3d-Cluster mit gemountetem Token-Store

Der Cluster muss den Host-Token-Store sehen. k3d spiegelt Host-Verzeichnisse mit `--volume … @all` in **alle** Node-Container; ein Pod-`hostPath` greift dann auf den Pfad **innerhalb** des Nodes zu (extern verifiziert: `k3d.io`, Volume-/Node-Filter-Syntax).

```bash
k3d cluster create openbao-hsm --servers 1 --agents 2 \
  --volume /opt/openbao/softhsm/tokens:/softhsm/tokens@all

kubectl get nodes          # 3 Nodes Ready?
kubectl get storageclass   # local-path als Default (für die Raft-PVCs)
```

Jetzt das in Teil 2 gebaute Image laden:

```bash
k3d image import bao-hsm-softhsm:dev -c openbao-hsm
```

> Drei Nodes (1 Server + 2 Agents, alle schedulebar), damit die Pod-Anti-Affinity des Charts die drei OpenBao-Pods verteilen kann — wie in `3-kubernetes.md`, Teil 1. Der `hostPath` `/softhsm/tokens` funktioniert auf jedem Node, weil wir mit `@all` in alle Nodes gemountet haben.

---

## Teil 4 — Helm-Deploy mit `seal "pkcs11"`

### 4.1 PIN als Kubernetes-Secret

Die User-PIN gehört **nicht** in die Config, sondern als Secret in den Cluster — von dort als `BAO_HSM_PIN` in die Pods:

```bash
kubectl create namespace openbao
kubectl -n openbao create secret generic openbao-hsm-pin \
  --from-literal=pin='4321'
```

### 4.2 Helm-Repo + Werte-Datei

```bash
helm repo add openbao https://openbao.github.io/openbao-helm
helm repo update
```

`files/4-soft-HSM/values-hsm-k8s.yaml`:

```yaml
server:
  image:
    repository: bao-hsm-softhsm     # das per k3d image import geladene Custom-Image
    tag: dev
    pullPolicy: IfNotPresent        # lokal vorhandenes Image nutzen, nicht aus Registry ziehen

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

        seal "pkcs11" {
          lib           = "/usr/lib64/softhsm/libsofthsm2.so"   # <-- Pfad aus dem Build (Teil 2)!
          token_label   = "OpenBao"
          key_label     = "bao-root-key-rsa"
          mechanism     = "RSA_PKCS_OAEP"
          rsa_oaep_hash = "sha1"
          # pin NICHT hier — kommt über BAO_HSM_PIN aus dem Secret
        }

  # SoftHSM-Config (Pod-Sicht) ist im Image gebacken: /etc/softhsm/softhsm2.conf
  extraEnvironmentVars:
    SOFTHSM2_CONF: /etc/softhsm/softhsm2.conf

  # PIN aus dem Secret als Umgebungsvariable injizieren
  extraSecretEnvironmentVars:
    - envName: BAO_HSM_PIN
      secretName: openbao-hsm-pin
      secretKey: pin

  # Host-Token-Store read-only in jeden Pod (hostPath zeigt auf den k3d-Node-Mount aus Teil 3)
  volumes:
    - name: softhsm-tokens
      hostPath:
        path: /softhsm/tokens
        type: Directory
  volumeMounts:
    - name: softhsm-tokens
      mountPath: /softhsm/tokens
      readOnly: true

ui:
  enabled: true
```

Drei Erweiterungen gegenüber dem Transit-Setup aus `3-kubernetes.md`:

- **`server.image`** zeigt auf das HSM-fähige Custom-Image (Teil 2), `pullPolicy: IfNotPresent` nutzt das lokal importierte Image.
- **`seal "pkcs11"`** statt `seal "transit"`; die **PIN** kommt über `BAO_HSM_PIN` (extern verifiziert: `openbao.org/docs/configuration/seal/pkcs11` — Env-Vars `BAO_HSM_LIB`, `BAO_HSM_PIN`, `BAO_HSM_TOKEN_LABEL`, `BAO_HSM_KEY_LABEL`, `BAO_HSM_MECHANISM`, `BAO_HSM_RSA_OAEP_HASH`).
- **`volumes`/`volumeMounts`** (rohe k8s-Specs) mounten den Token-Store read-only — das ist „das HSM" aus Pod-Sicht.

> **`rsa_oaep_hash = "sha1"`** ist bewusst gesetzt: SoftHSMv2 lehnt RSA-OAEP mit SHA-256 ab (`CKR_ARGUMENTS_BAD`, siehe Troubleshooting). Ein echtes HSM unterstützt i. d. R. SHA-256.

### 4.3 Installieren

```bash
helm install openbao openbao/openbao -n openbao -f files/4-soft-HSM/values-hsm-k8s.yaml
kubectl -n openbao get pods -w
```

Die Pods kommen zunächst als `0/1 Ready` (uninitialisiert) — das ist normal.

---

## Teil 5 — Nur noch initialisieren — Unseal passiert automatisch

Mit Auto-Unseal entfällt das Shamir-Unseal; stattdessen gibt es **Recovery-Keys**:

```bash
kubectl -n openbao exec -ti openbao-0 -- bao operator init \
  -recovery-shares=5 -recovery-threshold=3
```

Ausgabe (Beispiel — **deine Werte sind anders, sicher aufbewahren**):

```
Recovery Key 1: 2Tnwym…
…
Recovery Key 5: CzsBHH…
Initial Root Token: s.OQQX04No…

Recovery key initialized with 5 key shares and a key threshold of 3.
```

Beachte: **Recovery Keys**, keine Unseal-Keys. Jetzt **ohne weiteres Zutun zusehen**: `openbao-0` entsiegelt sich über das HSM und wird Leader; `openbao-1`/`-2` entsiegeln sich ebenfalls über das HSM, joinen per `retry_join` und werden Follower.

```bash
kubectl -n openbao get pods                                          # nach kurzer Zeit alle 1/1 Ready

kubectl -n openbao exec -ti openbao-0 -- bao status
# Seal Type pkcs11 · Recovery Seal Type shamir · Initialized true · Sealed false

kubectl -n openbao exec -ti openbao-0 -- bao login                   # Initial Root Token
kubectl -n openbao exec -ti openbao-0 -- bao operator raft list-peers
```

### Der Beweis: Pod-Restart unsealt von selbst

```bash
kubectl -n openbao delete pod openbao-1
kubectl -n openbao get pods -w        # openbao-1 kommt wieder 1/1 Ready — ganz ohne Eingriff
```

Der Pod holt sich beim Start den entschlüsselten Root-Key vom HSM (Token + Key + PIN) und unsealt sich selbst. Genau das macht Auto-Unseal in Kubernetes praktisch verpflichtend — der Kontrast zum manuellen Shamir-Unseal aus `3-kubernetes.md`, Teil 3.

```bash
kubectl -n openbao logs openbao-1 | grep -i unseal
# ... core: stored unseal keys supported, attempting fetch
# ... core: vault is unsealed
```

---

## Wo die SoftHSM-Analogie zum echten HSM endet

> Diese Übung modelliert **vier** der fünf wichtigen Prod-Eigenschaften korrekt:
>
> 1. **HSM-fähiges Image** (cgo/pkcs11, `openbao-hsm-ubi`) — wie in Prod.
> 2. **Der Key verlässt das HSM nie** (`never extractable`) — wie in Prod.
> 3. **PIN/Credentials als Kubernetes-Secret**, nicht in der Config — wie in Prod.
> 4. **Auto-Unseal bei Pod-Restart** — wie in Prod.
>
> Was hier **anders** ist als bei einem echten HSM:
>
> - **SoftHSM ist dateibasiert und lokal.** Ein echtes HSM ist ein Gerät bzw. ein **Netzwerk-/Cloud-HSM**, das die Pods über die **Vendor-PKCS#11-Library** *übers Netz* erreichen. Unser `hostPath`-Mount steht stellvertretend für „das HSM ist vom Pod aus erreichbar" — in Wirklichkeit ist es ein Netzwerk-Call, kein Filesystem-Zugriff.
> - **In Prod** nimmst du `openbao/openbao-hsm-ubi` (oder ein Image darüber) **mit der Client-Library deines HSM-Herstellers** statt SoftHSM, zeigst in der `seal "pkcs11"`-Stanza per `lib`/`slot`/`token_label` auf das HSM, lieferst die PIN über ein Secret (oder `LoadCredential`/CSI) — und es gibt **keinen `hostPath`**.
> - **HSM-HA:** Echte HSMs sind selbst geclustert/redundant. Hier teilen sich drei Pods **einen** read-only Token-Store.
>
> **Noch treuere Nachstellung (optional, hier nicht ausgeführt):** SoftHSM zentral betreiben und über das Netz exponieren (z. B. `pkcs11-proxy` oder `p11-kit` remote); die Pods laden eine Proxy-`.so`, die zum „HSM-Server" weiterleitet. Das modelliert die **Netzwerk-Erreichbarkeit** eines echten HSM, ist aber deutlich aufwändiger.

---

## Troubleshooting


| Symptom                                                     | Ursache / Lösung                                                                                                                                                                            |
| ----------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| Pod `CrashLoopBackOff`, Log: `seal "pkcs11" … no such file` | `lib`-Pfad falsch. Den realen Pfad aus dem Build (`find … libsofthsm2.so`) in die `seal`-Stanza eintragen.                                                                                  |
| `failed to pkcs11 DecryptInit: CKR_ARGUMENTS_BAD` beim Init | `rsa_oaep_hash` auf `sha1` stellen (SoftHSMv2 kann kein OAEP-SHA256). Lief der Init schon halb durch, PVCs leeren und neu init: `kubectl -n openbao delete pvc --all`.                      |
| `CKR_TOKEN_NOT_PRESENT` / Token nicht gefunden              | `SOFTHSM2_CONF` im Pod zeigt nicht auf eine Config mit `tokendir = /softhsm/tokens`, oder der k3d-`--volume`-Mount fehlt. `kubectl -n openbao exec openbao-0 -- ls /softhsm/tokens` prüfen. |
| `permission denied` beim Token-Lesen                        | Token-Dateien auf dem Host nicht lesbar für den Pod-User. `sudo chmod -R a+rX /opt/openbao/softhsm/tokens` (Teil 1.5).                                                                      |
| `CKR_PIN_INCORRECT`                                         | `BAO_HSM_PIN`-Secret ≠ bei `--init-token` gesetzte `--pin`. Tipp: Secret ohne Steuerzeichen anlegen (siehe `3-kubernetes.md`, 4.3 — `CrashLoopBackOff` durch `\x1b`/`\n` im Token/PIN).     |
| `Seal Type` ist `shamir` statt `pkcs11`                     | Es läuft das Standard-Image statt `bao-hsm-softhsm`. `server.image`/`tag` prüfen, `k3d image import` gemacht?                                                                               |
| Pod bleibt `0/1 Ready`                                      | Vor `bao operator init` normal. Danach: HSM nicht erreichbar — `kubectl -n openbao logs openbao-0`.                                                                                         |


## Sicherheitshinweise (Workshop ≠ Produktion)

- **SoftHSMv2 ist kein echtes HSM** — der „geschützte" Key liegt als Datei auf der Host-Platte. Nur zum Lernen/Testen. Für Prod: echtes/Cloud-HSM + Vendor-Library (siehe Kasten oben).
- PINs (`1234`/`4321`) sind öffentlich bekannt. Produktiv: lange Secrets, PIN aus sicherer Quelle (`LoadCredential`, CSI-Secrets-Store) statt aus einem statischen K8s-Secret.
- TLS ist hier deaktiviert (`tls_disable = 1`) — für echten Betrieb einschalten (vgl. Ingress-/TLS-Abschnitt in `3-kubernetes.md`).
- Recovery Keys + Root Token sind hochsensibel — getrennt und sicher verwahren.
- Geht das HSM/der Key verloren, lässt sich OpenBao **nicht mehr** unsealen. Backup-/Recovery-Strategie für das Key-Material einplanen.

## Aufräumen

```bash
helm uninstall openbao -n openbao
kubectl -n openbao delete pvc --all
kubectl delete namespace openbao
k3d cluster delete openbao-hsm
# optional auf dem Host: SoftHSM-Token entfernen
# sudo rm -rf /opt/openbao/softhsm/tokens/*
```

---

## Variante ohne Kubernetes — OpenBao als systemd-Dienst auf dem Host

Brauchst du den HSM-Auto-Unseal **ohne** Kubernetes (Einzel-Host, VM), läuft OpenBao direkt als systemd-Dienst gegen dieselbe SoftHSM aus Teil 1. Diese Variante war der ursprüngliche Inhalt dieses Kapitels und bleibt als Referenz erhalten.

### V.1 HSM-fähiges Binary holen

Statt eines Container-Images das `+hsm`-Artefakt herunterladen, **getrennt** vom Standard-`bao`:

```bash
curl -fSL -o /tmp/bao-hsm.tgz \
  https://github.com/openbao/openbao/releases/download/v2.5.4/bao-hsm_2.5.4_Linux_x86_64.tar.gz
tar -xzf /tmp/bao-hsm.tgz -C /tmp
sudo install -m 0755 /tmp/bao /usr/local/bin/bao-hsm

/usr/local/bin/bao-hsm version
# → OpenBao v2.5.4+hsm ... (cgo)        ← "+hsm" und "(cgo)" bestätigen PKCS#11-Support
```

> **CLI vs. Server.** Für Client-Befehle (`bao status`, `bao operator init`, `bao kv …`) genügt das normale `/usr/bin/bao`. Nur der **Server** muss das `bao-hsm`-Binary sein.

### V.2 Dedizierter User + Server-Config

```bash
sudo useradd --system --home-dir /opt/openbao --shell /usr/sbin/nologin openbao
sudo mkdir -p /opt/openbao/config /opt/openbao/data
sudo chown -R openbao:openbao /opt/openbao
```

`/opt/openbao/config/config.hcl`:

```hcl
ui = true
disable_mlock = true

storage "file" {
  path = "/opt/openbao/data"
}

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = "true"
}

seal "pkcs11" {
  lib           = "/usr/lib/softhsm/libsofthsm2.so"
  token_label   = "OpenBao"
  pin           = "4321"
  key_label     = "bao-root-key-rsa"
  mechanism     = "RSA_PKCS_OAEP"
  rsa_oaep_hash = "sha1"
}

api_addr = "http://127.0.0.1:8200"
```

```bash
sudo chown openbao:openbao /opt/openbao/config/config.hcl
```

> Alternativ statt `pin` in der Datei die Umgebungsvariable `BAO_HSM_PIN` setzen (ebenso `BAO_HSM_LIB`, `BAO_HSM_TOKEN_LABEL`, `BAO_HSM_KEY_LABEL`, `BAO_HSM_MECHANISM`, `BAO_HSM_RSA_OAEP_HASH`).

### V.3 systemd-Dienst

`/etc/systemd/system/openbao-hsm.service`:

```ini
[Unit]
Description=OpenBao (HSM/PKCS#11 Auto-Unseal)
Requires=network-online.target
After=network-online.target

[Service]
User=openbao
Group=openbao
Environment=SOFTHSM2_CONF=/opt/openbao/softhsm/softhsm2.conf
ExecStart=/usr/local/bin/bao-hsm server -config=/opt/openbao/config/config.hcl
Restart=on-failure
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now openbao-hsm
sudo systemctl status openbao-hsm
```

> Das `Environment=SOFTHSM2_CONF=…` ist entscheidend — ohne diesen Eintrag findet der Dienst den Token-Store nicht.

### V.4 Initialisieren und Auto-Unseal nachweisen

```bash
export BAO_ADDR=http://127.0.0.1:8200

bao status                       # Seal Type pkcs11 · Initialized false · Sealed true
bao operator init                # liefert Recovery Keys (keine Unseal-Keys)
bao status                       # Initialized true · Sealed false — automatisch unsealt

sudo systemctl restart openbao-hsm
sleep 4
bao status                       # Sealed false — OHNE manuelles Unseal

sudo journalctl -u openbao-hsm | grep -i unseal
# ... core: vault is unsealed
# ... core: unsealed with stored key
```

### Aufräumen (systemd-Variante)

```bash
sudo systemctl disable --now openbao-hsm
sudo rm -f /etc/systemd/system/openbao-hsm.service && sudo systemctl daemon-reload
sudo rm -rf /opt/openbao/data/*
# optional: sudo rm -f /usr/local/bin/bao-hsm
```

