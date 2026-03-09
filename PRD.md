# PRD: OpenBao Single-Node Deployment auf DigitalOcean

**Status: IN ARBEIT**

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
| **Image** | `ubuntu-22-04-x64` |
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
- Certbot via `certbot --nginx` für `openbao.<USER>.do.t3isp.de`
- Zertifikat validieren: `/etc/letsencrypt/live/<DOMAIN>/fullchain.pem` muss existieren
- Automatische Erneuerung via systemd-Timer (`certbot.timer` ist nach certbot-Installation aktiv)

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

## Offene Punkte / Entscheidungen

| Punkt | Entscheidung |
|---|---|
| Droplet nach Tests löschen? | Interaktive Frage am Ende des Scripts |
