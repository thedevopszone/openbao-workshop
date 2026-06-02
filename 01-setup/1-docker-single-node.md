# OpenBao in Docker

**Summary**: 

Wie man OpenBao zum Testen und Lernen mit Docker Compose startet — als schneller Dev-Mode (auto-initialisiert, auto-unsealed, fester Root-Token) oder als persistenter Single-Node-Server mit File-Storage, der echte Initialisierung, Unseal und Login durchläuft. Inklusive UI-/CLI-Login und dem Vergeben eines DNS-Namens.

---

## Wann Docker — und welcher Modus

Docker ist ideal, um OpenBao **zum Lernen oder Testen** in Minuten lokal zu starten.  
Für echte Produktion auf VMs oder Kubernetes.

Es gibt zwei grundverschiedene Betriebsarten. Der Unterschied ist wichtig, weil er bestimmt, ob du überhaupt initialisieren und unsealen musst:


|                   | **Dev-Mode** (Variante A) | **Persistenter Server** (Variante B)   |
| ----------------- | ------------------------- | -------------------------------------- |
| Storage           | nur RAM (in-memory)       | Platte file/raft                       |
| Initialisierung   | **automatisch**           | **manuell** (`bao operator init`)      |
| Unseal            | **automatisch**           | **manuell** (`bao operator unseal`)    |
| Root-Token        | fest vorgebbar            | wird bei Init erzeugt                  |
| Daten nach `down` | **weg**                   | bleiben (Volume)                       |
| TLS               | aus                       | aus (Test) bzw. an (siehe DNS)         |
| Eignung           | erste Schritte, Demos     | realistisches Üben, Init/Unseal lernen |


## Voraussetzungen

- Docker mit Compose-Plugin (`docker compose version`).
- Optional die `bao`-CLI auf dem Host. Alternativ die CLI im Container über `docker compose exec` nutzen — dann brauchst du nichts lokal zu installieren.

## Das Image

OpenBao veröffentlicht vorgebaute Images (Alpine-basiert) in drei Registries:

- `docker.io/openbao/openbao` (= `openbao/openbao`)
- `ghcr.io/openbao/openbao`
- `quay.io/openbao/openbao`

Für RHEL-UBI-basierte Images jeweils mit Suffix `-ubi` (z. B. `openbao/openbao-ubi`). Der Entrypoint nutzt `dumb-init` für sauberes Signal-Handling; übergebene Argumente werden an die `bao`-CLI weitergereicht (extern verifiziert: Docker Hub).

---

## Variante A — Dev-Mode (schnellster Einstieg)

`docker-compose.yml`:

```yaml
services:
  openbao:
    image: openbao/openbao:latest
    container_name: openbao-dev
    ports:
      - "8200:8200"
    environment:
      # Setzt den Root-Token auf einen festen Wert (sonst zufällig, im Log)
      BAO_DEV_ROOT_TOKEN_ID: "dev-only-token"
      # Default ist bereits 0.0.0.0:8200 — hier nur zur Verdeutlichung
      BAO_DEV_LISTEN_ADDRESS: "0.0.0.0:8200"
    cap_add:
      - IPC_LOCK
```

Was hier passiert (extern verifiziert: Docker Hub): Das Image startet ohne weiteres Kommando automatisch im Dev-Mode — äquivalent zu `bao server -dev -dev-root-token-id <wert>`. `BAO_DEV_ROOT_TOKEN_ID` und `BAO_DEV_LISTEN_ADDRESS` steuern Token und Adresse. `IPC_LOCK` erlaubt dem Prozess, Speicher per `mlock` gegen Auslagerung zu sperren.

> **Nie in Produktion.** Der Dev-Server hält alles im RAM, ist unverschlüsselt erreichbar und vergibt vollen Root-Zugriff für einen bekannten Token (source: `raw/docs/get-started/developer-qs.md`). Beim Stoppen sind alle Secrets weg.

Start:

```bash
docker compose up -d
```

OpenBao lauscht jetzt per HTTP auf **Port 8200**.

**Aufruf im Browser**:

```
http://localhost:8200/ui

oder
http://<IP>:8200/ui
```

Login in der UI: Methode **Token**, Token: `dev-only-token`

CLI gegen den Dev-Server (vom Host, vorher `bao` installieren):

```bash
# Installiere bao cli
Mac => brew install openbao
Rhel => dnf install -y epel-release
        dnf install -y openbao

Linux => 
cd /tmp
wget https://github.com/openbao/openbao/releases/download/v2.5.4/openbao_2.5.4_linux_amd64.deb
sudo apt install -y ./openbao_2.5.4_linux_amd64.deb
which bao
bao version

export VAULT_ADDR="http://127.0.0.1:8200"
export VAULT_TOKEN="dev-only-token"
bao status
bao secrets list
```

Damit bist du fertig — Init und Unseal entfallen im Dev-Mode. Wer das echte Init/Unseal-Erlebnis will, nimmt Variante B.

---

## Variante B — Persistenter Single-Node mit File-Storage

Diese Variante speichert verschlüsselt auf Platte und durchläuft denselben Lebenszyklus wie ein echter Server: **Init → Unseal → Login**.

### 1. Konfigurationsdatei

Lege `./config/config.hcl` an:

```hcl
ui = true

storage "file" {
  path = "/openbao/file"
}

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = "true"   # NUR für lokalen Test — siehe Abschnitt DNS/TLS
}

api_addr = "http://127.0.0.1:8200"
```

Felder (Referenz: [[configuration]]):

- `ui = true` — schaltet die Web-UI auf dem Listener frei.
- `storage "file"` — einfacher Datei-Backend, schreibt nach `/openbao/file` (im Container, extern verifiziert: Docker Hub erwartet genau diesen Pfad für das File-Plugin). **`file` kann kein HA** — für Mehrknoten/Produktion auf [[raft]] wechseln (siehe [[storage]], [[high-availability]]).
- `listener "tcp"` mit `tls_disable` — bewusst nur für den lokalen Test; im DNS-Abschnitt wird TLS aktiviert.
- `api_addr` — Adresse, unter der Clients diesen Node erreichen; landet in Redirects (wichtig hinter Reverse Proxy / [[load-balancing]]).

### 2. Compose-Datei

`docker-compose.yml`:

```yaml
services:
  openbao:
    image: openbao/openbao:latest
    container_name: openbao
    environment:
      BAO_ADDR: "http://127.0.0.1:8200"
    ports:
      - "8200:8200"
    cap_add:
      - IPC_LOCK
    volumes:
      - ./config:/openbao/config:ro
      - openbao-file:/openbao/file
      - openbao-logs:/openbao/logs
    command: server
    restart: unless-stopped

volumes:
  openbao-file:
  openbao-logs:
```

Erklärung (Container-Pfade extern verifiziert: Docker Hub):

- `command: server` — startet `bao server`. Das Image liest standardmäßig **das ganze Verzeichnis** `/openbao/config` (alle `.hcl`/`.json` alphabetisch, Referenz: [[configuration]]); explizit wäre das `server -config=/openbao/config`.
- `./config:/openbao/config:ro` — deine Konfig read-only eingehängt.
- Named Volume `openbao-file` → `/openbao/file` — hier liegen die verschlüsselten Daten und überleben `docker compose down`.
- `openbao-logs` → `/openbao/logs` — für persistente [Audit](6-auth-und-policies.md)-Logs (optional, aber empfohlen).
- `IPC_LOCK` — erlaubt `mlock`. Alternativ in der Konfig `disable_mlock = true` setzen (dann ist die Capability verzichtbar).

Start:

```bash
docker compose up -d
docker compose logs -f openbao   # zeigt: "core: security barrier not initialized"

export BAO_ADDR='http://127.0.0.1:8200' # Da sonst versucht wird über https zu connecten

bao status

Key                Value
---                -----
Seal Type          shamir
Initialized        false # Noch nicht initialisiert, keine Unseal Keys
Sealed             true  # Verschlüsselt, muss noch unsealed werden
Total Shares       0
Threshold          0
Unseal Progress    0/0
Unseal Nonce       n/a
Version            2.5.4
Build Date         2026-05-20T16:08:53Z
Storage Type       file # Nur file, kein Raft
HA Enabled         false # HA nur bei Raft
```

## Initialisierung

Beim ersten Start ist der Server **uninitialisiert und sealed**. Initialisieren (einmalig) erzeugt den Verschlüsselungs-Barrier, die Unseal-Key-Shares und den initialen Root-Token (Referenz: [[commands-cli]], [[seal-unseal]]).

CLI im Container ausführen — so brauchst du `bao` nicht auf dem Host:

```bash
bao operator init

```

> Falls `bao` im Container die Adresse nicht findet, voranstellen:
> `docker compose exec openbao sh -c 'VAULT_ADDR=http://127.0.0.1:8200 bao operator init'`

Standardmäßig bekommst du **5 Unseal-Key-Shares** und einen **Threshold von 3** sowie den **Initial Root Token**:

```
Unseal Key 1: TXcB0LxkJrcPQUZhxufnvocMJDzxE0WRvtnlWO9p/ED0
Unseal Key 2: GEOFpPw9JQz+K+naI+9PPkcdxUNH+24tKqhj3Xxkk21l
Unseal Key 3: khgey07Vy8OzuFsZu3pAxzaBsTY8/tuFLmjWpFuaQATJ
Unseal Key 4: XVdCI3eTl+NY92q3kYAAKyS4Qff2pBLWCvoB75dYkNxD
Unseal Key 5: dDL9CHXPyXamdGe+kKL/Y/opEzFL9fWr2H84P9ijiINs

Initial Root Token: s.o13X7rIQgo6tmeBh2yXHW4gF
```

> **Diese Ausgabe erscheint genau einmal.** Sicher speichern (am besten Shares auf verschiedene Personen/Tresore verteilt). Ohne genügend Unseal-Keys sind die Daten unwiederbringlich verschlüsselt; mit dem Root-Token hat man Vollzugriff. Für Produktion lieber Auto-Unseal per KMS statt Shamir-Shares.
>
> Andere Aufteilung: `bao operator init -key-shares=1 -key-threshold=1` (nur Test) 

## Unseal

Der Node ist jetzt initialisiert, aber noch **sealed**. Je drei **verschiedene** Shares freischalten (Threshold = 3). `bao operator unseal` fragt interaktiv nach einem Share; dreimal mit unterschiedlichen Keys ausführen:

```bash
bao operator unseal   # Key 1 eingeben
bao operator unseal   # Key 2 eingeben
bao operator unseal   # Key 3 eingeben
```

Nach dem dritten Share zeigt `Sealed false`. Prüfen:

```bash
bao status
```

> Jeder Node muss **einzeln** entsiegelt werden; Unseal propagiert nicht im Cluster ([[seal-unseal]]). Nach jedem Neustart des Containers ist erneutes Unseal nötig — das ist der Hauptgrund, in Produktion Auto-Unseal zu verwenden.

## Login in die GUI

UI im Browser öffnen:

```
http://localhost:8200/ui
```

Auth-Methode **Token** wählen, den **Initial Root Token** aus der Init-Ausgabe eintragen, einloggen. Danach lassen sich Secrets Engines Auth-Methoden und Policies per Klick verwalten.

> Den Root-Token nur für das initiale Setup nutzen. Danach eine reguläre Auth-Methode (z. B. userpass/OIDC) und policies einrichten und mit eingeschränkten tokens arbeiten.

## Login in der CLI

Zwei Wege.

**A) Vom Host** (CLI lokal installiert) — OpenBao nutzt für die Verbindung die `VAULT_`*-Env-Vars (Vault-kompatibel; extern verifiziert: `openbao.org/docs/commands/`):

```bash
Mac => brew install openbao
Rhel => dnf install -y epel-release
        dnf install -y openbao

Linux => curl -LO https://github.com/openbao/openbao/releases/latest/download/bao_linux_amd64
         chmod +x bao_linux_amd64
         sudo mv bao_linux_amd64 /usr/local/bin/bao
         bao version 

export VAULT_ADDR="http://127.0.0.1:8200"
bao login                 # fragt interaktiv nach dem Token
# oder nicht-interaktiv:
bao login <Initial-Root-Token>
bao token lookup
```

Der Token wird danach im Token-Helper unter `~/.vault-token` abgelegt. Weitere `bao`-Befehle finden ihn automatisch.

**B) Im Container:**

```bash
docker compose exec openbao sh -c 'VAULT_ADDR=http://127.0.0.1:8200 bao login <Initial-Root-Token>'
```

> **Gotcha — gemischte Präfixe**: Der **Server** im Container nutzt `BAO_`* (z. B. `BAO_DEV_ROOT_TOKEN_ID`, `BAO_LOCAL_CONFIG`), die **Client-/CLI-Verbindung** dagegen `VAULT_ADDR`/`VAULT_TOKEN` (Vault-Kompatibilität). `BAO_`* ist beim Client nur für Ausgabe-Optionen wie `BAO_FORMAT`, `BAO_LOG_LEVEL` belegt (extern verifiziert: `openbao.org/docs/commands/`). Wer `BAO_ADDR` setzt und sich wundert, warum die CLI weiter `127.0.0.1` ansteuert, ist hier hineingelaufen.

## Setzen eines DNS-Namens

„DNS-Name vergeben" heißt in der Praxis: OpenBao nicht über `localhost` ansprechen, sondern über einen stabilen Hostnamen — meist mit TLS und einem Reverse Proxy davor. Drei Bausteine:

**1. `api_addr` auf den DNS-Namen setzen** (in `config.hcl`). Er steckt in Redirects/Forwarding und darf nicht `127.0.0.1` bleiben, sobald Clients über den Namen kommen (Referenz: [[configuration]], [[load-balancing]]):

```hcl
api_addr = "https://bao.example.com:8200"
```

**2. TLS aktivieren** statt `tls_disable`. Zertifikat + Key ins Config-Volume legen (z. B. `./config/tls/`):

```hcl
listener "tcp" {
  address       = "0.0.0.0:8200"
  tls_cert_file = "/openbao/config/tls/bao.crt"
  tls_key_file  = "/openbao/config/tls/bao.key"
}
```

**3. Namensauflösung herstellen** — je nach Umgebung:

- **Lokaler Test**: Eintrag in `/etc/hosts`, z. B. `127.0.0.1  bao.example.com`. Dann Client auf den Namen zeigen lassen:
  ```bash
  export VAULT_ADDR="https://bao.example.com:8200"
  # bei selbst-signiertem Zertifikat zum Testen:
  export VAULT_CACERT="/pfad/zur/bao.crt"   # statt VAULT_SKIP_VERIFY=true
  ```
- **Echtes Setup**: A/AAAA-Record im DNS auf den Docker-Host, davor ein Reverse Proxy (nginx/Traefik) mit dem DNS-Namen im Zertifikat. Der Proxy stellt eine stabile Adresse her und ist die Grundlage für späteres HA — Details, Health-Check (`/v1/sys/health`) und nginx-/Traefik-Beispiele in [[load-balancing]].

> Hinter einem Reverse Proxy muss `api_addr` exakt der öffentlichen URL entsprechen, sonst brechen Redirects ([[configuration]], [[load-balancing]]).

## Hardening-Hinweise (über den Test hinaus)

- **Swap**: Beim Docker-Image `--memory-swappiness=0` setzen, damit Secrets nicht auf Platte ausgelagert werden (source: `raw/docs/install.md`). In Compose: `mem_swappiness: 0` auf dem Service.
- **`mlock`**: `IPC_LOCK`-Capability geben (oben gesetzt) **oder** `disable_mlock = true` in der Konfig — nicht beides weglassen.
- **TLS**: niemals produktiv mit `tls_disable`.
- **Storage**: `file` ist Single-Node ohne HA. Für mehr als „Testen/Lernen" auf [[raft]] und ein echtes [[deployment-vm-vs-k8s|VM-/K8s-Deployment]] gehen.
- **Auto-Unseal**: manuelles Unseal nach jedem Restart ist im Container besonders lästig — produktiv KMS-basiertes Auto-Unseal ([[seal-unseal]]).
- **Audit**: zwei [Audit](6-auth-und-policies.md)-Devices vorsehen. Ab OpenBao v2.5 werden sie **deklarativ in der Config** angelegt (`audit "file" "name" { options { file_path = "/openbao/logs/audit.log" } }`), nicht mehr per `bao audit enable` (das ist ohne `unsafe_allow_api_audit_creation = true` gesperrt — Details in [6-auth-und-policies.md](6-auth-und-policies.md), Teil 5).

