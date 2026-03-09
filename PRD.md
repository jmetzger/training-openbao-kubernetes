# PRD: OpenBao Single-Node Deployment auf DigitalOcean

**Status: IN BEARBEITUNG**

## Ziel

Self-service Deployment eines Servers auf DigitalOcean per einzigem Kommando:

```bash
./install-openbao-single.sh
```

Nach erfolgreichem Durchlauf ist der Server erreichbar unter `https://openbao.<USER>.do.t3isp.de`
mit gültigem Let's Encrypt Zertifikat. **OpenBao wird in diesem Schritt nicht installiert** – das erfolgt im nächsten Schritt des Trainings.

---

## Dateien im Repository

```
.
├── .env                        # Nicht committen – vom Nutzer lokal anlegen
├── .env.example                # Vorlage mit allen benötigten Variablen
├── install-openbao-single.sh   # Einstiegspunkt: alles in einem Skript
├── cloud-init.sh               # Wird auf dem Droplet als user-data ausgeführt
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
- Nutzer `11trainingdo` anlegen, SSH-Passwort-Authentifizierung aktivieren
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
- A-Record `openbao.<USER>.do.t3isp.de` → Droplet-IP in `do.t3isp.de` erstellen oder aktualisieren (via `doctl compute domain records`)
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

---

## Offene Punkte / Entscheidungen

| Punkt | Entscheidung |
|---|---|
| Droplet nach Tests löschen? | Interaktive Frage am Ende des Scripts |
