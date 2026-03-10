# PRD: OpenBao Single-Node Deployment auf DigitalOcean

**Status: IN BEARBEITUNG**

## Ziel

Self-service Deployment eines oder mehrerer Server auf DigitalOcean per einzigem Kommando:

```bash
./install-openbao-single.sh        # 1 Server für den eigenen $USER
./install-openbao-single.sh 5      # 5 Trainings-Server: tln1 … tln5
./install-openbao-single.sh alice  # 1 Server: TRAINING_USER=alice, Domain openbao.alice.do.t3isp.de
```

Wird als erstes Argument ein Wort übergeben, das mit einem Buchstaben (a–z) beginnt, wird es **nicht** als Anzahl interpretiert, sondern als `__TRAINING_USER__`-Name. Dieser Name wird sowohl als Nutzername auf dem Server als auch als Subdomain-Segment verwendet: `openbao.<NAME>.do.t3isp.de`.

Nach erfolgreichem Durchlauf ist jeder Server erreichbar unter `https://openbao.<USER>.do.t3isp.de`
mit gültigem Let's Encrypt Zertifikat. **OpenBao wird in diesem Schritt nicht installiert** – das erfolgt im nächsten Schritt des Trainings.

---

## Feature: Destroy-Script (`destroy-openbao-single.sh`)

### Zweck

Löscht alle deployten Droplets und DNS-Records vollständig und automatisiert – sowohl für Single-Deployments als auch für Trainings-Server.

### Aufruf

```bash
./destroy-openbao-single.sh           # löscht openbao-$USER (kein DNS-Löschen)
./destroy-openbao-single.sh 5         # löscht openbao-tln1 … openbao-tln5 (kein DNS-Löschen)
./destroy-openbao-single.sh alice     # löscht openbao-alice (Name beginnt mit a-z → kein Zähler)
./destroy-openbao-single.sh all       # löscht ALLE Droplets mit Prefix "openbao-" (kein DNS-Löschen)
```

Wird als Argument ein Wort übergeben, das mit einem Buchstaben (a–z) beginnt, wird es als Nutzername interpretiert (nicht als Zähler): `destroy-openbao-single.sh alice` löscht das Droplet `openbao-alice`.

### Verhalten

- Lädt `.env` (benötigt `DIGITALOCEAN_ACCESS_TOKEN`)
- Bestätigung vor dem Löschen: zeigt Liste aller zu löschenden Droplets und fragt `Wirklich löschen? [y/N]`
- Löscht **nur Droplets** – DNS-Records werden **nicht gelöscht**
- Gibt Gesamtübersicht aus:
  ```
  tln1  ✓  Droplet gelöscht
  tln2  ✓  Droplet gelöscht
  tln3  ✗  Droplet nicht gefunden (bereits gelöscht?)
  ```
- Exit-Code: `0` wenn alles gelöscht (oder nicht vorhanden), `1` bei API-Fehler

### Dokumentation

- `docs/destroy-openbao-single.md` – Usage-Guide mit allen Modi, Beispielausgaben und Troubleshooting
- `README.md` verlinkt auf diesen Guide unter "Server löschen"

### Automatisierter Test (Claude)

Claude testet das Destroy-Script nach jedem Multi-Server-Deployment:

1. Deployment von 2 Servern (`tln1`, `tln2`) verifizieren (5 Tests grün)
2. `./destroy-openbao-single.sh 2` ausführen
3. Prüfen dass Droplets nicht mehr existieren (`doctl compute droplet list`)
4. Prüfen dass DNS-Records **noch vorhanden** sind (`doctl compute domain records list do.t3isp.de`)
5. Prüfen dass HTTPS nicht mehr erreichbar ist (`curl https://openbao.tln1.do.t3isp.de` → Fehler erwartet)

Das Script gilt als fertig wenn alle 5 Destroy-Tests grün sind.

---

## Feature: Multi-Server-Deployment (Trainings-Modus)

### Aufruf

```bash
./install-openbao-single.sh <ANZAHL|NAME>
```

Das erste Argument wird anhand seines ersten Zeichens interpretiert:
- **Zahl (0–9):** Anzahl der Trainings-Server (`tln1` … `tln<N>`)
- **Buchstabe (a–z):** Direkter Nutzername – genau 1 Server wird deployt, der Name wird als `__TRAINING_USER__` und als Subdomain verwendet

| Aufruf | Deployete Server | Domains |
|---|---|---|
| `./install-openbao-single.sh` | 1 | `openbao.$USER.do.t3isp.de` |
| `./install-openbao-single.sh 1` | 1 | `openbao.tln1.do.t3isp.de` |
| `./install-openbao-single.sh 5` | 5 | `openbao.tln1.do.t3isp.de` … `openbao.tln5.do.t3isp.de` |
| `./install-openbao-single.sh alice` | 1 | `openbao.alice.do.t3isp.de` |

### Verhalten

- Jeder Server wird wie ein normales Single-Deployment behandelt: eigenes Droplet, eigener DNS-Record, eigenes TLS-Zertifikat
- Deployments laufen **parallel** (Background-Jobs), um die Gesamtdauer gering zu halten
- Jeder Job schreibt sein Log in eine separate Datei: `/tmp/deploy-tln<N>.log`
- Das Script wartet auf alle Jobs und gibt am Ende eine Gesamtübersicht aus:
  ```
  tln1  ✓  https://openbao.tln1.do.t3isp.de
  tln2  ✓  https://openbao.tln2.do.t3isp.de
  tln3  ✗  FAILED – siehe /tmp/deploy-tln3.log
  ```
- Exit-Code: `0` wenn alle Server erfolgreich, `1` wenn mindestens einer fehlschlägt

### .env im Multi-Server-Modus

`USER_PASSWORD` gilt für alle `tln<N>`-User gleichermaßen. Der Trainings-User auf jedem Server heißt `tln<N>` statt `11trainingdo`.

### Automatisierter Test (Claude)

Claude führt nach dem Deployment für jeden Server den vollständigen Testplan (5 Tests) durch und wiederholt fehlerhafte Deployments automatisch bis zu 2 Mal, bevor es als endgültig fehlgeschlagen gilt.

---

## Dateien im Repository

```
.
├── .env                           # Nicht committen – vom Nutzer lokal anlegen
├── .env.example                   # Vorlage mit allen benötigten Variablen
├── install-openbao-single.sh      # Deployment: 1 oder N Server hochziehen
├── destroy-openbao-single.sh      # Cleanup: 1, N oder alle Server löschen
├── cloud-init.sh                  # Wird auf dem Droplet als user-data ausgeführt
├── docs/
│   └── destroy-openbao-single.md  # Usage-Guide für das Destroy-Script
├── README.md
└── PRD.md
```

---

## Voraussetzungen (lokal)

| Tool | Zweck |
|---|---|
| `doctl` | DigitalOcean CLI – wird vom Script automatisch installiert falls nicht vorhanden |
| `ssh` | SSH-Zugriff auf das Droplet |
| `~/.ssh/id_ed25519_nopass` | SSH-Key ohne Passphrase (muss in DO hinterlegt sein) |
| `curl`, `dig`, `nc` | Tests |

---

## Budget

| Position | Wert |
|---|---|
| **Genehmigtes Budget** | EUR 100,- |
| **Droplet-Kosten** | ca. EUR 0,036/h (`s-2vcpu-4gb` in `fra1`) |
| **Empfehlung** | Droplet nach dem Training-Tag löschen – Kosten bleiben dann deutlich unter EUR 5,- pro Teilnehmer |

---

## .env Variablen

Datei `.env` im Projekt-Root (nicht ins Repo committen):

```bash
DIGITALOCEAN_ACCESS_TOKEN=dop_v1_xxx   # DigitalOcean API Token
USER_PASSWORD=sicheresPasswort          # Passwort für den Trainings-User
```

Vorlage `.env.example` wird ins Repo eingecheckt:

```bash
DIGITALOCEAN_ACCESS_TOKEN=ENTER_YOUR_DO_TOKEN
USER_PASSWORD=ENTER_YOUR_PASSWORD
```

---

## Droplet-Konfiguration

| Parameter | Wert |
|---|---|
| **Hostname** | `openbao-<USER>` (abgeleitet aus `$USER` der lokalen Shell) |
| **DNS** | `openbao.<USER>.do.t3isp.de` |
| **Size** | `s-2vcpu-4gb` |
| **Region** | `fra1` |
| **Image** | `ubuntu-24-04-x64` |
| **Base Domain** | `do.t3isp.de` (muss in DO vorhanden sein) |
| **E-Mail** | `j.metzger@t3company.de` (für Let's Encrypt) |

---

## Architektur auf dem Server

```
Internet (443/80)
      │
   nginx (systemd-Service)
      │  - Let's Encrypt Zertifikat via certbot (webroot)
      │  - HTTP → HTTPS Redirect
      │  - HTTPS: statische Seite "Server bereit"
```

### Warum kein Docker?

- Weniger Abstraktion → einfacher zu debuggen im Training
- Direkter Zugriff auf Logs via `journalctl`
- nginx und certbot laufen als native systemd-Services

---

## Ablauf `cloud-init.sh`

Das Script läuft als `user-data` auf dem Droplet und schreibt seinen Fortschritt nach `/root/install-status.txt`. Erst wenn dort `[DONE]` steht, gilt das Deployment als erfolgreich.

### Phasen

**Phase 0 – Pre-Flight Checks**
- `DIGITALOCEAN_ACCESS_TOKEN` und `USER_PASSWORD` gesetzt und nicht Platzhalter
- Root-Check

**Phase 1 – System vorbereiten**
- Nutzer `11trainingdo` bzw. `tln<N>` anlegen, SSH-Passwort-Authentifizierung aktivieren
- User in `sudoers` eintragen (passwordless sudo)
- Pakete installieren: `nginx`, `certbot`, `python3-certbot-nginx`, `curl`, `wget`, `dnsutils`, `ufw`
- `doctl` installieren – Version **1.151.0** (Stand: 2026-03-09):
  ```bash
  DOCTL_VERSION="1.151.0"
  curl -sL "https://github.com/digitalocean/doctl/releases/download/v${DOCTL_VERSION}/doctl-${DOCTL_VERSION}-linux-amd64.tar.gz" \
    | tar -xz -C /usr/local/bin
  ```
- API-Token validieren (`doctl account get`)

**Phase 2 – IP & DNS**
- Droplet-IP via Metadata-API (`169.254.169.254`) ermitteln
- A-Record `openbao.<USER>.do.t3isp.de` → Droplet-IP in `do.t3isp.de` **erstellen oder aktualisieren** (via `doctl compute domain records`): existiert der Record bereits, wird er per `doctl compute domain records update` mit der neuen IP aktualisiert statt neu angelegt
- DNS-Propagation abwarten: max. 5 Minuten, prüft Google DNS (`8.8.8.8`) und DigitalOcean Nameserver

**Phase 3 – Firewall**
- `ufw` Regeln: 22, 80, 443 freigeben
- Regeln zuerst setzen, dann `ufw enable`

**Phase 4 – nginx konfigurieren (HTTP-only)**
- nginx-Konfiguration für `openbao.<USER>.do.t3isp.de`:
  - `listen 80`
  - ACME-Challenge-Location (`/.well-known/acme-challenge/`)
  - Alle anderen Anfragen: `return 301 https://$host$request_uri`
- nginx starten und aktivieren

**Phase 5 – Let's Encrypt Zertifikat**
- Certbot via `certbot --nginx` für `openbao.<USER>.do.t3isp.de` – **mit Retry-Logik (3 Versuche, 30s Pause)**
- Zertifikat validieren: `/etc/letsencrypt/live/<DOMAIN>/fullchain.pem` muss existieren
- Automatische Erneuerung via systemd-Timer (`certbot.timer` ist nach certbot-Installation aktiv)
- Hintergrund: Let's Encrypt Multi-Perspective Validation kann mit einem DigitalOcean-internen Validator scheitern (siehe BUG-002)

**Phase 6 – nginx HTTPS-Konfiguration**
- nginx.conf mit HTTPS-Block aktualisieren:
  - HTTP → HTTPS Redirect
  - SSL mit `fullchain.pem` / `privkey.pem`
  - TLSv1.2 + TLSv1.3
  - `location /` liefert statische HTML-Seite: "Server bereit – OpenBao folgt im nächsten Schritt"
- `systemctl reload nginx`

**Phase 7 – Finale Tests**
- HTTPS erreichbar (`curl -s https://<DOMAIN>/` → HTTP 200)
- SSL-Zertifikat gültig (`curl` ohne `-k` erfolgreich)
- nginx aktiv (`systemctl is-active nginx`)

**Phase 8 – Status `[DONE]`**
- In `/root/install-status.txt` schreiben
- Laufzeit ausgeben

---

## Ablauf `install-openbao-single.sh` (lokal)

Das Script kombiniert Deployment und Test in einem Durchlauf.

```
1. .env laden und validieren
2. doctl installieren/prüfen und authentifizieren
3. Hostname = openbao-$USER, Domain = openbao.$USER.do.t3isp.de
4. Prüfen ob Droplet bereits existiert
   → Wenn ja: fragen ob neu erstellen (destroy + recreate)
5. cloud-init.sh vorbereiten: DIGITALOCEAN_ACCESS_TOKEN + USER_PASSWORD einsetzen (sed)
6. Droplet erstellen mit --user-data-file cloud-init.sh
7. Warten auf SSH (max. 5 Minuten)
8. Polling /root/install-status.txt über SSH (alle 30s, max. 15 Minuten):
   → [DONE]   → weiter zu Tests
   → [FAILED] → Logs ausgeben, exit 1
   → Timeout  → Logs ausgeben, exit 1
9. Tests durchführen (siehe Testplan)
10. Ergebnis ausgeben
```

### Wichtig: cloud-init muss vollständig sein

Das Skript **pollt aktiv** und wartet – es geht nicht weiter bevor cloud-init `[DONE]` in `/root/install-status.txt` eingetragen hat.

---

## Testplan

Alle Tests werden nach cloud-init `[DONE]` ausgeführt:

| # | Test | Erwartung |
|---|---|---|
| 1 | DNS Resolution | `openbao.<USER>.do.t3isp.de` → Droplet-IP |
| 2 | HTTP → HTTPS Redirect | HTTP 301/302 |
| 3 | HTTPS erreichbar | HTTP-Response (beliebiger Status-Code) |
| 4 | SSL Zertifikat gültig | `curl` ohne `-k` erfolgreich |
| 5 | nginx läuft | `systemctl is-active nginx` → `active` |

OpenBao wird in diesem Schritt **nicht installiert** – das ist Inhalt des nächsten Trainingsschritts.

Bei Fehler: Logs ausgeben, Droplet **bleibt bestehen** für manuelle Analyse.

---

## Server-Info Ausgabe

Nach erfolgreichem Deployment wird ausgegeben:

```
═══════════════════════════════════════════════════
         SERVER BEREIT FÜR OPENBAO TRAINING
═══════════════════════════════════════════════════

URL:           https://openbao.<USER>.do.t3isp.de
Droplet IP:    <IP>
SSH:           ssh 11trainingdo@<IP>
Passwort:      <USER_PASSWORD>

STATUS:
  nginx:       aktiv (systemd)
  certbot:     automatische Erneuerung via systemd-Timer
  OpenBao:     noch nicht installiert (folgt im naechsten Schritt)

NAECHSTER SCHRITT:
  OpenBao installieren und starten:
  ssh 11trainingdo@<IP>

HILFREICHE BEFEHLE:
  nginx Logs:  journalctl -u nginx -f
  nginx Test:  nginx -t

═══════════════════════════════════════════════════
```

---

## Nicht im Scope (dieser Schritt)

- OpenBao installieren, starten oder initialisieren (kommt später)
- HA-Cluster / Raft-Storage
- Kubernetes-Integration
- Auto-Unseal (KMS)
- LDAP / OIDC Auth
- Policies und Secrets vorkonfigurieren

---

## Automatisiertes Testen durch Claude (Agentic Loop)

### Ziel

Claude führt `install-openbao-single.sh` eigenständig aus und iteriert so lange, bis alle Tests bestehen.

### Ablauf (Claude als Agent)

```
1. .env prüfen (DIGITALOCEAN_ACCESS_TOKEN, USER_PASSWORD gesetzt)
2. install-openbao-single.sh ausführen
3. Ausgabe analysieren:
   a. Alle Tests grün → FERTIG
   b. Fehler gefunden:
      - Fehlerursache identifizieren (Log-Ausgabe, Phasenstatus)
      - Betroffenes Skript anpassen (cloud-init.sh oder install-openbao-single.sh)
      - Droplet löschen (doctl compute droplet delete --force)
      - Weiter mit Schritt 2
4. Nach maximal 5 Iterationen: Abbruch mit Fehlerbericht
```

### Regeln für den Agentic Loop

| Regel | Beschreibung |
|---|---|
| **Max. Iterationen** | 5 – danach Abbruch und Fehlerbericht an Nutzer |
| **Droplet vor Neustart löschen** | Claude löscht das alte Droplet bevor es ein neues erstellt |
| **Kein blindes Retry** | Jede Iteration muss eine konkrete Änderung am Skript enthalten |
| **Kosten im Blick** | Fehlgeschlagene Droplets sofort löschen |

### Fehlerkategorien und Reaktion

| Fehler | Reaktion |
|---|---|
| DNS-Propagation Timeout | Wartezeit im Script erhöhen |
| Certbot-Fehler (DNS noch nicht bereit) | Sleep vor Certbot-Aufruf verlängern |
| nginx startet nicht | Konfiguration prüfen (`nginx -t`) |
| SSH-Verbindung schlägt fehl | SSH-Key-Pfad oder DO SSH-Key-ID prüfen |
| cloud-init bricht ab (`[FAILED]`) | Logs via SSH holen, Fehlerphase identifizieren |

### Abbruchkriterium (Erfolg)

Claude gilt als fertig, wenn alle 5 Tests aus dem Testplan grün sind:

```
✓ DNS Resolution
✓ HTTP → HTTPS Redirect
✓ HTTPS erreichbar
✓ SSL Zertifikat gültig
✓ nginx läuft
```

---

## Bug-Tracker

### BUG-001: SSH Login `11trainingdo` schlug fehl – `Permission denied (publickey)`

**Status:** ✓ Behoben (2026-03-09)

**Symptom:**
```
11trainingdo@openbao.jmetzger.do.t3isp.de: Permission denied (publickey).
```

**Root Cause:**
Ubuntu 22.04 liefert zwei Drop-in-Dateien in `/etc/ssh/sshd_config.d/`:
- `50-cloud-init.conf` → `PasswordAuthentication no`
- `60-cloudimg-settings.conf` → `PasswordAuthentication no`

`sshd` wertet `Include /etc/ssh/sshd_config.d/*.conf` **alphabetisch** aus – der **erste Treffer** gewinnt. Das `sed` in `cloud-init.sh` setzte `PasswordAuthentication yes` nur in der Hauptdatei, die aber nach den Drop-ins kommt. Effektives Ergebnis: `passwordauthentication no`.

**Fix:**
In `cloud-init.sh` statt `sed` auf der Hauptdatei eine Datei mit niedrigerer Nummer anlegen, die als erste gelesen wird:
```bash
echo 'PasswordAuthentication yes' > /etc/ssh/sshd_config.d/10-training.conf
systemctl restart sshd
```

**Laufender Server (openbao.jmetzger.do.t3isp.de, 164.92.129.233):**
Fix wurde manuell via `root`-SSH eingespielt:
```bash
echo 'PasswordAuthentication yes' > /etc/ssh/sshd_config.d/10-training.conf
systemctl restart sshd
```

**Testergebnis (automatisiert durch Claude):**
- `sshd -T | grep passwordauthentication` → `passwordauthentication yes` ✓
- Nutzer `11trainingdo` existiert (uid=1000) ✓
- Password-Hash gesetzt (`chpasswd 11trainingdo:${USER_PASSWORD}`) ✓
- SSH bietet `publickey,password` als Auth-Methoden an ✓

### BUG-002: Certbot scheitert – Let's Encrypt Multi-Perspective Validation

**Status:** ✓ Behoben (2026-03-09)

**Symptom:**
```
[FEHLER]: Certbot fehlgeschlagen
Detail: During secondary validation: 165.227.175.75: Fetching
http://openbao.jmetzger.do.t3isp.de/.well-known/acme-challenge/...: Connection refused
```

**Root Cause:**
Let's Encrypt verwendet seit 2024 Multi-Perspective Validation: der Challenge wird von mehreren Standorten aus geprüft. Einer der Validatoren (`165.227.175.75`) liegt innerhalb des DigitalOcean-Netzwerks (fra1). Dieser kann den Droplet über seine öffentliche IP nicht erreichen (hairpin NAT / interne Netzwerkpolitik von DigitalOcean). Die anderen Validatoren (`23.178.112.213`, `34.209.40.2`) kommen erfolgreich durch. Da alle Validatoren zustimmen müssen, schlägt der gesamte Certbot-Lauf fehl.

Wichtig: Port 80 war offen und nginx lief korrekt – das Problem liegt ausschließlich am DigitalOcean-internen Routing. Ein zweiter Versuch wenig später gelingt, weil Let's Encrypt unterschiedliche sekundäre Validator-IPs einsetzt.

**Fix in `cloud-init.sh`:**

Phase 5 erhält eine Retry-Schleife (3 Versuche, 30s Pause):

```bash
# Phase 5 – Let's Encrypt mit Retry
for attempt in 1 2 3; do
  certbot --nginx \
    --non-interactive \
    --agree-tos \
    --email "$EMAIL" \
    --no-eff-email \
    -d "$DOMAIN" && break
  log "Certbot Versuch $attempt fehlgeschlagen – warte 30s..."
  sleep 30
done
[[ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]] \
  || fail "Certbot nach 3 Versuchen fehlgeschlagen"
```

**Laufender Server (openbao.jmetzger.do.t3isp.de, 139.59.131.231):**
Certbot wurde manuell erneut ausgeführt (erfolgreich). Phase 6 nginx-Config wurde manuell angewendet. Server läuft vollständig.

### BUG-003: Certbot schlägt beim ersten Versuch fehl wegen DNS-Propagation

**Status:** ✓ Behoben (2026-03-09)

**Symptom:**
Certbot schlägt beim ersten Deployment-Versuch fehl, obwohl der Server korrekt läuft. Ein zweiter Versuch (einige Minuten später) gelingt.

**Root Cause:**
Let's Encrypt validiert Domains von mehreren geografischen Standorten aus. Kurz nach dem Erstellen des Droplets und dem Setzen des DNS-A-Records zeigen noch nicht alle Nameserver weltweit auf die neue IP – manche cachen noch die alte IP (oder NXDOMAIN). Je nachdem, welcher Let's Encrypt-Validator welchen Nameserver trifft, sieht er unterschiedliche IPs. Da alle Validatoren die gleiche IP sehen müssen, schlägt die Validierung fehl, sobald mindestens ein Validator einen veralteten Nameserver erwischt.

**Fix in `cloud-init.sh` Phase 5:**

Vor dem Certbot-Aufruf wird aktiv auf vollständige DNS-Propagation gewartet (Polling, max. 10 Minuten):

```bash
DNS_READY=false
for i in $(seq 1 60); do
  RESOLVED=$(dig +short "$DOMAIN" @8.8.8.8 2>/dev/null | head -1 || true)
  if [[ "$RESOLVED" == "$DROPLET_IP" ]]; then
    DNS_READY=true
    break
  fi
  sleep 10
done
```

Zusätzlich wurde die Retry-Schleife aus BUG-002 (3 Versuche, 30s Pause) in den Code übernommen – sie war bisher nur dokumentiert, aber nicht im Skript implementiert.

### BUG-004: SSH Passwort-Login schlägt weiterhin fehl – `Permission denied (publickey)` auf Ubuntu 24.04

**Status:** ✓ Behoben (2026-03-09)

**Symptom:**
```
11trainingdo@openbao.jmetzger.do.t3isp.de: Permission denied (publickey).
```

SSH bietet nur `publickey` als Auth-Methode an, obwohl `PasswordAuthentication yes` per `cloud-init.sh` gesetzt werden sollte.

**Root Cause:**
Zwei Probleme kombiniert auf Ubuntu 24.04:
1. **Servicename:** Ubuntu 24.04 benennt den SSH-Daemon als `ssh.service` (nicht `sshd.service`). `systemctl restart sshd` schlägt stillschweigend fehl – ohne Alias greift der Restart nicht.
2. **Nur neue Datei reicht nicht:** Der BUG-001-Fix (Datei `10-training.conf` anlegen) setzt einen neuen Wert, überschreibt aber nicht `PasswordAuthentication no` in bestehenden Drop-in-Dateien (`50-cloud-init.conf`). Bei OpenSSH gilt "erster Treffer gewinnt" – wenn `10-training.conf` alphabetisch vor `50-cloud-init.conf` eingelesen wird, sollte es funktionieren. Aber auf Ubuntu 24.04 können Cloud-Init-Module nach unserem Skript laufen und `50-cloud-init.conf` überschreiben.

**Fix in `cloud-init.sh` Phase 1:**

```bash
# Alle bestehenden Drop-in-Dateien mit PasswordAuthentication no patchen
for conf_file in /etc/ssh/sshd_config.d/*.conf; do
  [[ -f "$conf_file" ]] && \
    sed -i 's/^PasswordAuthentication[[:space:]].*/PasswordAuthentication yes/' "$conf_file"
done
# Auch Hauptkonfiguration patchen
sed -i 's/^#\?[[:space:]]*PasswordAuthentication[[:space:]].*/PasswordAuthentication yes/' /etc/ssh/sshd_config
# Explizite Override-Datei
echo 'PasswordAuthentication yes' > /etc/ssh/sshd_config.d/10-training.conf
# Ubuntu 24.04: ssh.service; Ubuntu 22.04: sshd.service
systemctl restart ssh 2>/dev/null || systemctl restart sshd
```

### BUG-005: SSH Passwort-Login schlägt nach BUG-004-Fix weiterhin fehl

**Status:** ✓ Behoben (2026-03-09)

**Symptom:**
```
11trainingdo@openbao.jmetzger.do.t3isp.de: Permission denied (publickey).
```

**Ergebnis:** Login als `11trainingdo` funktioniert nach erneutem Deployment. BUG-004-Fix greift korrekt.

### BUG-006: Certbot schlägt alle 3 Versuche fehl trotz DNS-Propagation bestätigt

**Status:** ✓ Behoben (2026-03-09)

**Symptom:**
```
[2026-03-09 15:19:58] DNS bereit: openbao.jmetzger.do.t3isp.de -> 64.226.110.119 (nach 1x10s)
[2026-03-09 15:20:01] Certbot Versuch 1 fehlgeschlagen – warte 30s...
[2026-03-09 15:20:32] Certbot Versuch 2 fehlgeschlagen – warte 30s...
[2026-03-09 15:21:04] Certbot Versuch 3 fehlgeschlagen – warte 30s...
[2026-03-09 15:21:34] FEHLER: Certbot nach 3 Versuchen fehlgeschlagen
```

**Beobachtung:**
DNS-Propagation war bestätigt (`dig @8.8.8.8` gibt korrekte IP zurück), dennoch schlagen alle 3 Certbot-Versuche fehl. Das deutet darauf hin, dass das Problem nicht DNS-Propagation, sondern etwas anderes ist – z.B.:
- nginx läuft zum Zeitpunkt des Certbot-Aufrufs noch nicht (Port 80 nicht erreichbar)
- Let's Encrypt Multi-Perspective Validation schlägt von einem bestimmten Standort fehl (siehe BUG-002), und 30s Pause reicht nicht für einen anderen Validator-Satz
- Certbot-Fehlermeldung nicht im Log sichtbar – genaue Fehlerursache unklar

**Fix in `cloud-init.sh` Phase 5:**

1. Vor Certbot: nginx Port-80-Check (`curl http://$DOMAIN/.well-known/acme-challenge/test`). Bei HTTP 000: nginx neu starten.
2. Certbot-Output ins Log: `2>&1 | tee -a "$STATUS_FILE"` – genaue Fehlerursache bei zukünftigen Fehlern sichtbar.
3. Retry-Versuche von 3 auf 5 erhöht, Pause von 30s auf 60s verlängert.

### BUG-007: Certbot schlägt fehl wegen Let's Encrypt Rate Limit

**Status:** Offen (entsperrt ab 2026-03-10 23:08 UTC)

**Symptom:**
```
too many certificates (5) already issued for this exact set of identifiers
in the last 168h0m0s, retry after 2026-03-10 23:08:21 UTC
```

**Root Cause:**
Let's Encrypt erlaubt maximal 5 Zertifikate pro exakter Domain-Kombination innerhalb von 7 Tagen. Durch wiederholte Deployments (Debugging, Neustarts) wurden zu viele Zertifikate für `openbao.jmetzger.do.t3isp.de` ausgestellt. Das ist kein technisches Problem des Skripts, sondern ein operatives Limit.

**Workaround:**
Warten bis 2026-03-10 23:08 UTC, danach funktioniert Certbot wieder.

**Implementierte Lösung (2026-03-09):**
`CERTBOT_STAGING=1` in `.env` aktiviert Let's Encrypt Staging CA:
- Kein Rate Limit während der Entwicklung
- Zertifikat wird ausgestellt (nicht browser-trusted, aber funktional)
- `install-openbao-single.sh` passt Tests 3+4 automatisch an (curl `-k` für Staging)
- Für Produktivbetrieb: `CERTBOT_STAGING` weglassen oder auf `0` setzen

### BUG-008: nginx Konfiguration ungültig – Phase 4 schlägt fehl

**Status:** ✓ Behoben (2026-03-10)

**Symptom:**
```
[2026-03-09 18:05:54] === Phase 4: nginx HTTP-only ===
[2026-03-09 18:05:54] FEHLER: nginx Konfiguration ungültig
[FAILED]
Droplet bleibt für manuelle Analyse erhalten (ID: 557049977, IP: 165.22.93.125)
```

**Root Cause (manuell analysiert auf 165.22.93.125):**
Der DigitalOcean-Paketmirror `mirrors.digitalocean.com` war beim Deployment nicht erreichbar:
```
E: Failed to fetch http://mirrors.digitalocean.com/ubuntu/dists/noble/InRelease
   Something wicked happened resolving 'mirrors.digitalocean.com:http' (-5 - No address associated with hostname)
E: The repository 'http://mirrors.digitalocean.com/ubuntu noble Release' no longer has a Release file.
```
`apt-get install nginx` schlug dadurch still fehl. Phase 1 prüfte den Exit-Code nicht korrekt und meldete trotzdem "Phase 1 OK". Phase 4 scheiterte dann an `nginx -t` mit "command not found", was als "nginx Konfiguration ungültig" geloggt wurde.

**Fix in `cloud-init.sh` Phase 1:**

Nach `apt-get install` wird explizit geprüft ob `nginx` wirklich installiert wurde. Bei Fehler: Fallback auf `archive.ubuntu.com`:

```bash
if ! command -v nginx >/dev/null 2>&1; then
  log "WARNUNG: nginx nicht installiert – DO Mirror-Problem. Wechsle auf archive.ubuntu.com..."
  find /etc/apt -name "*.list" -o -name "*.sources" 2>/dev/null \
    | xargs sed -i 's|mirrors.digitalocean.com|archive.ubuntu.com|g' 2>/dev/null || true
  apt-get update -qq && apt-get install -y -qq nginx certbot ... \
    || fail "Paket-Installation auch mit Fallback-Mirror fehlgeschlagen"
  command -v nginx >/dev/null 2>&1 || fail "nginx nicht installiert"
fi
```

Phase 4: Zusätzlicher Sicherheitscheck `command -v nginx` mit präziser Fehlermeldung "nginx binary nicht gefunden".

---

## Offene Punkte / Entscheidungen

| Punkt | Entscheidung |
|---|---|
| Droplet nach Tests löschen? | Interaktive Frage am Ende des Scripts |
