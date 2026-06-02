# Secrets in der CLI — Engines aktivieren, schreiben, lesen

**Summary**:

Wie man in OpenBao über die `bao`-CLI eine **Secrets Engine aktiviert** und dann **Secrets schreibt, liest, auflistet und löscht**. Schwerpunkt ist die **KV-Engine** (Key/Value) — der einfachste und häufigste Einstieg — mit dem wichtigen Unterschied zwischen **KV v1** (einfach) und **KV v2** (versioniert). Voraussetzung: ein laufender, entsiegelter Server und ein eingeloggter Client (siehe `1-docker-single-node.md`).

---

## Voraussetzungen

Bevor irgendetwas geschrieben wird, muss die CLI wissen, **wohin** sie sich verbindet und **mit welchem Token**. Das sind dieselben `VAULT_`*-Variablen wie beim Login (Vault-kompatibel, siehe `1-docker-single-node.md`):

```bash
export VAULT_ADDR="http://127.0.0.1:8200"
export VAULT_TOKEN="dev-only-token"   # oder: bao login <token>

bao status      # Sealed false ?
bao token lookup
```

> Alle folgenden Befehle setzen voraus, dass `bao status` **`Sealed false`** zeigt und der Token genug Rechte hat. Mit dem Root-Token aus Init/Dev-Mode klappt alles; im echten Betrieb steuern [Policies](6-auth-und-policies.md) den Zugriff pro Pfad.

---

## Schritt 1 — Welche Engines gibt es schon?

Jede Secrets Engine hängt an einem **Pfad** (Mount). Was aktuell gemountet ist, zeigt:

```bash
bao secrets list
```

```
Path          Type         Accessor              Description
----          ----         --------              -----------
cubbyhole/    cubbyhole    cubbyhole_xxxxxxxx    per-token private secret storage
identity/     identity     identity_xxxxxxxx     identity store
sys/          system       system_xxxxxxxx       system endpoints used for control, policy and debugging
```

Das sind die **eingebauten** Mounts. Eine eigene Engine für Key/Value-Secrets müssen wir erst aktivieren.

> **Engine = Plugin an einem Pfad.** Derselbe Engine-Typ kann **mehrfach** an verschiedenen Pfaden laufen (z. B. `kv/` fürs Team A, `app-secrets/` fürs Team B). Der Pfad ist später Teil jeder Adresse beim Lesen/Schreiben und damit auch die Einheit, auf die [Policies](6-auth-und-policies.md) greifen.

---

## Schritt 2 — Eine Secrets Engine aktivieren (`secrets enable`)

Allgemeine Form:

```bash
bao secrets enable [-path=<pfad>] <typ>
```

- `<typ>` ist die Engine (z. B. `kv`, `pki`, `database`, `transit`, `ssh` …).
- `-path=` ist optional; ohne Angabe wird der Pfad **gleich dem Typ** (`bao secrets enable kv` → Mount unter `kv/`).

### KV-Engine aktivieren

Für reine „schreib mir einen Wert hin und gib ihn wieder"-Secrets nimmt man die **KV-Engine**. Es gibt zwei Versionen:

| | **KV v1** | **KV v2** |
| --------------------- | ----------------------- | ------------------------------------------ |
| Versionierung | nein | ja (Historie, Rollback) |
| Soft-Delete / Undelete| nein | ja |
| Befehle | `bao kv get/put` | `bao kv get/put` (gleich) |
| API-Pfad intern | `<mount>/<key>` | `<mount>/data/<key>` (zusätzliche Ebene) |
| Eignung | simpel, weniger Overhead| Standard, Empfehlung |

**KV v2 aktivieren** (empfohlen):

```bash
bao secrets enable -path=secret kv-v2
```

**oder KV v1**, wenn keine Versionierung gewünscht ist:

```bash
bao secrets enable -path=kv kv
```

> **Dev-Mode:** Dort ist unter `secret/` bereits eine **KV v2** vormontiert — `secrets enable` entfällt, du kannst direkt schreiben. Bei einem persistenten Server (Variante B) musst du die Engine wie oben einmalig aktivieren.

Prüfen:

```bash
bao secrets list
# secret/   kv   ...   (version: 2)
```

---

## Schritt 3 — Secrets schreiben (`kv put`)

Ein Secret ist eine Menge von **Key=Value-Paaren** unter einem Pfad. Mehrere Felder auf einmal:

```bash
bao kv put secret/db/myapp username="appuser" password="s3cr3t!" host="db.internal"
```

- `secret` = der Mount-Pfad der Engine (oben aktiviert).
- `db/myapp` = beliebig tiefer Pfad für dieses Secret („wie ein Ordnerbaum").
- danach beliebig viele `feld=wert`-Paare.

Bei KV v2 quittiert OpenBao mit Versions-Metadaten:

```
==== Secret Path ====
secret/data/db/myapp

======= Metadata =======
Key                Value
---                -----
created_time       2026-06-02T10:00:00Z
version            1
```

### Werte nicht im Klartext / in der History

Damit Passwörter nicht in der Shell-History oder in `ps` landen:

```bash
# aus einer Datei
bao kv put secret/db/myapp password=@password.txt

# interaktiv von stdin (Wert wird nicht angezeigt)
read -s PW
bao kv put secret/db/myapp password="$PW"

# komplettes JSON von stdin
echo '{"username":"appuser","password":"s3cr3t!"}' | bao kv put secret/db/myapp -
```

> `feld=@datei` liest den Wert **aus der Datei**, `feld=-` bzw. `-` als letztes Argument liest **von stdin**. So taucht das Geheimnis nicht als Kommandozeilen-Argument auf (extern verifiziert: `openbao.org/docs/commands/kv/put`).

### Bestehendes Secret ändern: `put` vs. `patch`

- `bao kv put …` **ersetzt** das komplette Secret (Felder, die du nicht mitgibst, verschwinden) und legt bei v2 eine **neue Version** an.
- `bao kv patch …` **ändert nur** die angegebenen Felder, der Rest bleibt (nur KV v2):

```bash
bao kv patch secret/db/myapp password="neuesPasswort"
# username/host bleiben erhalten, version -> 2
```

---

## Schritt 4 — Secrets lesen (`kv get`)

```bash
bao kv get secret/db/myapp
```

```
==== Data ====
Key         Value
---         -----
host        db.internal
password    s3cr3t!
username    appuser
```

**Nur ein einzelnes Feld** (ideal fürs Scripting):

```bash
bao kv get -field=password secret/db/myapp
```

**Als JSON** (z. B. um mit `jq` weiterzuverarbeiten):

```bash
bao kv get -format=json secret/db/myapp | jq -r '.data.data.password'
```

> Beachte bei **KV v2** die doppelte `.data.data`-Ebene im JSON: außen die OpenBao-Antwort, innen die eigentlichen Secret-Felder. Bei **KV v1** ist es nur `.data`.

### Versionen lesen und zurückrollen (nur KV v2)

```bash
bao kv get -version=1 secret/db/myapp     # alte Version anzeigen
bao kv metadata get secret/db/myapp       # alle Versionen + Metadaten
bao kv rollback -version=1 secret/db/myapp # Inhalt von v1 als neue Version schreiben
```

---

## Schritt 5 — Auflisten und Löschen

**Pfade auflisten** (zeigt Schlüssel/„Unterordner" unter einem Pfad, nicht die Werte):

```bash
bao kv list secret/
bao kv list secret/db/
```

**Löschen:**

```bash
# KV v2: Soft-Delete der neuesten Version (wiederherstellbar)
bao kv delete secret/db/myapp
bao kv undelete -versions=2 secret/db/myapp   # rückgängig

# KV v2: bestimmte Versionen endgültig vernichten
bao kv destroy -versions=1,2 secret/db/myapp

# Secret inkl. aller Versionen + Metadaten komplett entfernen
bao kv metadata delete secret/db/myapp
```

Bei **KV v1** gibt es nur ein hartes `bao kv delete secret/db/myapp` — kein Undelete.

---

## Engine wieder deaktivieren

Entfernt den Mount **und alle darunter liegenden Secrets** unwiderruflich:

```bash
bao secrets disable secret/
```

> Vorsicht: `disable` löscht den kompletten Pfad. Im Zweifel vorher `bao kv list`/`metadata get` zur Kontrolle.

---

## Spickzettel

```bash
# Engine
bao secrets list                                  # was ist gemountet?
bao secrets enable -path=secret kv-v2             # KV v2 aktivieren
bao secrets disable secret/                        # Engine + Daten entfernen

# Schreiben
bao kv put   secret/db/myapp user="u" password="p" # ersetzt (neue Version)
bao kv patch secret/db/myapp password="p2"          # nur dieses Feld (v2)

# Lesen
bao kv get   secret/db/myapp                        # alle Felder
bao kv get -field=password secret/db/myapp          # ein Feld
bao kv get -format=json    secret/db/myapp          # JSON für jq
bao kv get -version=1      secret/db/myapp           # alte Version (v2)

# Verwalten
bao kv list     secret/                             # Pfade auflisten
bao kv metadata get secret/db/myapp                 # Versionen/Metadaten
bao kv delete   secret/db/myapp                      # Soft-Delete (v2)
bao kv destroy -versions=1 secret/db/myapp           # Version endgültig weg
```

---

## Über KV hinaus

KV speichert **statische** Secrets, die du selbst hinterlegst. OpenBaos eigentliche Stärke sind **dynamische** Engines, die Credentials **on demand** erzeugen und automatisch ablaufen lassen — denselben `secrets enable`-Mechanismus, nur ein anderer Typ:

- `database` — kurzlebige DB-Logins (siehe Postgres-Beispiel unter `files/3-kubernetes/postgres/`).
- `pki` — Zertifikate ausstellen.
- `transit` — Encryption-as-a-Service (ver-/entschlüsseln, ohne den Key herauszugeben).
- `ssh` — signierte SSH-Zertifikate.

Wer den Zugriff auf einzelne Pfade einschränken will (statt überall Root), arbeitet ab hier mit [Auth-Methoden und Policies](6-auth-und-policies.md) statt mit dem Root-Token.
