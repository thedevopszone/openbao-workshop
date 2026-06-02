# OpenBao Auto-Unseal mit SoftHSMv2 (PKCS#11)

**Summary**:

Wie man OpenBao so einrichtet, dass es seinen Master-Key über ein HSM via **PKCS#11** schützt und sich **beim Neustart automatisch unsealt** — ohne manuelle Unseal-Keys. Als HSM dient hier **SoftHSMv2**, ein reines Software-HSM zum Lernen und Testen. Durchgespielt auf einem Ubuntu-Host mit dem offiziellen **HSM-Build** von OpenBao und einem systemd-Dienst.

---

## Warum überhaupt — und was ist hier anders

Bisher kennst du zwei Unseal-Wege:

- **Shamir** (Standard): Bei jedem Start musst du manuell mit 3 von 5 Key-Shares unsealen ([[seal-unseal]]). Pro Node, nach jedem Neustart — operativ untragbar.
- **Transit**: Ein zweiter OpenBao („Unsealer") hält den Unseal-Key, die Nodes self-unsealen darüber (siehe `3-kubernetes.md`).

**PKCS#11/HSM** ist der dritte, produktionsnahe Weg: Der Root-Key wird mit einem Schlüssel **im HSM** verschlüsselt. Beim Start holt sich OpenBao den entschlüsselten Key direkt vom HSM und unsealt sich selbst. Der HSM-Key verlässt das HSM nie (`never extractable`). In Produktion ist das ein echtes HSM (Thales, Utimaco, YubiHSM, Cloud-KMS …); zum Üben nehmen wir **SoftHSMv2**.

> **Wichtig — der Standard-`bao` kann das nicht.** PKCS#11 erfordert einen **CGO-Build** von OpenBao (»HSM-Distribution«). Das normale Binary (`/usr/bin/bao`, statisch gelinkt) kennt `seal "pkcs11"` nicht. Wir brauchen das Artefakt mit Suffix `+hsm`.

### Shamir vs. Auto-Unseal: Was passiert mit den Keys?

Mit Auto-Unseal gibt es **keine Unseal-Keys** mehr. `bao operator init` liefert stattdessen **Recovery Keys**. Die unsealen *nicht*, sondern autorisieren nur privilegierte Operationen (z. B. `operator generate-root`, Rekey, Seal). Das Unsealen erledigt das HSM.

---

## Voraussetzungen

- Ubuntu-Host mit `sudo`, `curl`, `tar`.
- Freier Port `8200` auf dem Host.
- Internetzugang zu `github.com` (für das HSM-Binary).

Alle fertigen Beispieldateien liegen unter `files/4-soft-HSM/` (`config.hcl`, `softhsm2.conf`, `openbao-hsm.service`).

---

## 1. SoftHSMv2 + Tools installieren

```bash
sudo apt-get update
sudo apt-get install -y softhsm2 opensc
softhsm2-util --version            # 2.6.1
ls -l /usr/lib/softhsm/libsofthsm2.so
```

`softhsm2` bringt die PKCS#11-Library (`libsofthsm2.so`), `opensc` das `pkcs11-tool` zum Key-Erzeugen.

## 2. User, Verzeichnisse und SoftHSM-Config

Wir betreiben alles unter einem dedizierten System-User `openbao` mit eigenem Token-Store — damit der spätere systemd-Dienst sauber zugreifen kann.

```bash
sudo useradd --system --home-dir /opt/openbao --shell /usr/sbin/nologin openbao
sudo mkdir -p /opt/openbao/config /opt/openbao/data /opt/openbao/softhsm/tokens
```

`/opt/openbao/softhsm/softhsm2.conf`:

```ini
directories.tokendir = /opt/openbao/softhsm/tokens
objectstore.backend = file
log.level = INFO
```

```bash
sudo chown -R openbao:openbao /opt/openbao
```

> Diese Config wird später per Umgebungsvariable `SOFTHSM2_CONF` referenziert. Ohne sie sucht SoftHSM im Default-Pfad (`/var/lib/softhsm/tokens`) und der Dienst findet den Token nicht.

## 3. Token/Slot initialisieren

```bash
export SOFTHSM2_CONF=/opt/openbao/softhsm/softhsm2.conf

sudo -u openbao env SOFTHSM2_CONF=$SOFTHSM2_CONF \
  softhsm2-util --init-token --free --label "OpenBao" --so-pin 1234 --pin 4321
```

`--free` nimmt den ersten freien Slot. SoftHSM vergibt dabei eine **zufällige Slot-Nummer** (z. B. `758856120`) — deshalb adressieren wir den Token später über `token_label = "OpenBao"`, nicht über die Slot-Nummer.

```bash
sudo -u openbao env SOFTHSM2_CONF=$SOFTHSM2_CONF softhsm2-util --show-slots
```

> **PINs `1234`/`4321` sind reine Demo-Werte.** `--so-pin` ist die Security-Officer-PIN (Token-Verwaltung), `--pin` die User-PIN (Key-Nutzung). In Produktion lange, geheime PINs verwenden und **nicht** in die Config schreiben (siehe Sicherheitshinweise).

## 4. Schlüssel im SoftHSM erzeugen

OpenBao verlangt, dass das Key-Material **vor** der Initialisierung im HSM existiert. Für SoftHSMv2 nehmen wir ein **RSA-Schlüsselpaar** (Mechanismus RSA-OAEP) — AES-GCM ist mit SoftHSMv2 problematisch.

```bash
sudo -u openbao env SOFTHSM2_CONF=$SOFTHSM2_CONF \
  pkcs11-tool --module /usr/lib/softhsm/libsofthsm2.so \
  --token-label "OpenBao" --pin 4321 \
  --keypairgen --key-type rsa:4096 --label "bao-root-key-rsa"

# Verifizieren
sudo -u openbao env SOFTHSM2_CONF=$SOFTHSM2_CONF \
  pkcs11-tool --module /usr/lib/softhsm/libsofthsm2.so \
  --token-label "OpenBao" --pin 4321 --list-objects
```

Der private Key wird `sensitive, never extractable` angelegt — er kann das HSM nicht verlassen. Genau das ist der Sinn der Übung.

## 5. HSM-fähiges OpenBao-Binary holen

Wir laden das offizielle `+hsm`-Artefakt und legen es **getrennt** vom Standard-`bao` ab (`/usr/local/bin/bao-hsm`), damit `/usr/bin/bao` unangetastet bleibt.

```bash
curl -fSL -o /tmp/bao-hsm.tgz \
  https://github.com/openbao/openbao/releases/download/v2.5.4/bao-hsm_2.5.4_Linux_x86_64.tar.gz
tar -xzf /tmp/bao-hsm.tgz -C /tmp
sudo install -m 0755 /tmp/bao /usr/local/bin/bao-hsm

/usr/local/bin/bao-hsm version
# → OpenBao v2.5.4+hsm ... (cgo)        ← "+hsm" und "(cgo)" bestätigen PKCS#11-Support
file /usr/local/bin/bao-hsm
# → ... dynamically linked ...          ← im Gegensatz zum statischen /usr/bin/bao
```

> **CLI vs. Server.** Für Client-Befehle (`bao status`, `bao operator init`, `bao kv …`) genügt das normale `/usr/bin/bao`. Nur der **Server** muss das `bao-hsm`-Binary sein.

## 6. OpenBao-Config mit `seal "pkcs11"`

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

> **`rsa_oaep_hash = "sha1"`** ist hier bewusst gesetzt. SoftHSMv2 lehnt RSA-OAEP mit SHA-256 ab — der Init bricht sonst mit `CKR_ARGUMENTS_BAD` ab (siehe Troubleshooting). Ein echtes HSM unterstützt i. d. R. SHA-256.
>
> Alternativ statt `pin` in der Datei die Umgebungsvariable `BAO_HSM_PIN` setzen (ebenso `BAO_HSM_LIB`, `BAO_HSM_TOKEN_LABEL`, `BAO_HSM_KEY_LABEL`, `BAO_HSM_MECHANISM`, `BAO_HSM_RSA_OAEP_HASH`).

## 7. systemd-Dienst

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

## 8. OpenBao initialisieren

```bash
export BAO_ADDR=http://127.0.0.1:8200

bao status
# Seal Type pkcs11 · Recovery Seal Type shamir · Initialized false · Sealed true

bao operator init
```

Ausgabe (Beispiel — **deine Werte sind anders, sicher aufbewahren**):

```
Recovery Key 1: 2Tnwym…
…
Recovery Key 5: CzsBHH…
Initial Root Token: s.OQQX04No…

Recovery key initialized with 5 key shares and a key threshold of 3.
```

Beachte: **Recovery Keys**, keine Unseal-Keys. Direkt danach:

```bash
bao status
# Initialized true · Sealed false      ← bereits automatisch unsealt über das HSM
```

## 9. Auto-Unseal beim Neustart nachweisen

```bash
sudo systemctl restart openbao-hsm      # bzw. echter Reboot
sleep 4
bao status
# Sealed false — OHNE manuelles Unseal

sudo journalctl -u openbao-hsm | grep -i unseal
# ... core: stored unseal keys supported, attempting fetch
# ... core: vault is unsealed
# ... core: unsealed with stored key
```

Das ist der Kern: Nach jedem Neustart unsealt sich OpenBao selbst, solange es das HSM (Token + Key + PIN) erreicht.

---

## Troubleshooting

| Symptom | Ursache / Lösung |
| --- | --- |
| `failed to pkcs11 DecryptInit: CKR_ARGUMENTS_BAD` beim Init | `rsa_oaep_hash` auf `sha1` stellen (SoftHSMv2 kann kein OAEP-SHA256). **Achtung:** lief der Init bereits halb durch (`Initialized true`), Dienst stoppen, `/opt/openbao/data/*` leeren, neu starten, neu initialisieren. |
| `CKR_TOKEN_NOT_PRESENT` / Token nicht gefunden | `SOFTHSM2_CONF` zeigt nicht auf die richtige Config bzw. fehlt im systemd-Unit. Token-Store-Pfad und Owner (`openbao`) prüfen. |
| `CKR_PIN_INCORRECT` | User-PIN in `config.hcl` (`pin`) ≠ bei `--init-token` gesetzte `--pin`. |
| `Seal Type` ist `shamir` statt `pkcs11` | Es läuft das Standard-`bao` statt `bao-hsm`. `bao-hsm version` muss `+hsm (cgo)` zeigen. |
| Dienst startet, bleibt aber `Sealed true` | HSM nicht erreichbar (Token/Key/PIN). `journalctl -u openbao-hsm` und `pkcs11-tool --list-objects` prüfen. |

## Sicherheitshinweise (Workshop ≠ Produktion)

- **SoftHSMv2 ist kein echtes HSM** — der „geschützte" Key liegt als Datei auf derselben Platte. Nur zum Lernen/Testen.
- PINs (`1234`/`4321`) sind öffentlich bekannt. Produktiv: lange Secrets, `pin` aus der Config nehmen und über `BAO_HSM_PIN` aus einem sicheren Quelle (z. B. systemd-`LoadCredential`) einspeisen.
- TLS ist hier deaktiviert (`tls_disable = true`) — für echten Betrieb einschalten (vgl. DNS-/TLS-Abschnitt in `1-docker-single-node.md`).
- Recovery Keys + Root Token sind hochsensibel — getrennt und sicher verwahren.
- Geht das HSM/der Key verloren, lässt sich OpenBao **nicht mehr** unsealen. Backup-/Recovery-Strategie für das Key-Material einplanen.

## Aufräumen

```bash
sudo systemctl disable --now openbao-hsm
sudo rm -f /etc/systemd/system/openbao-hsm.service && sudo systemctl daemon-reload
sudo rm -rf /opt/openbao/data/* /opt/openbao/softhsm/tokens/*
# optional: sudo rm -f /usr/local/bin/bao-hsm
```
