# PRD: OpenBao Single-Node Deployment auf DigitalOcean

## Ziel

Self-service Deployment eines OpenBao Servers auf DigitalOcean per einzigem Kommando:

```bash
./install-openbao-single.sh
```

Nach erfolgreichem Durchlauf ist OpenBao erreichbar unter `https://openbao.<USER>.do.t3isp.de`
mit gültigem Let's Encrypt Zertifikat und vollständig initialisierten Unsealing.

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
USER_PASSWORD=sicheresPasswort          # OpenBao Root-Passwort / Init-Passwort
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
   nginx (SSL-Terminierung)
      │  - Let's Encrypt Zertifikat via Certbot (webroot)
      │  - HTTP → HTTPS Redirect
      │  - Phase 1: HTTP-only (für Certbot Challenge)
      │  - Phase 2: HTTPS mit proxy_pass → OpenBao
      │
      ▼
OpenBao (127.0.0.1:8200)
      │  - tls_disable = 1 (TLS macht nginx)
      │  - Storage: File-Backend (/opt/openbao/data)
      │  - Initialisierung: 1 Key Share, Threshold 1 (Single-Node)
      │
   Docker (docker-compose)
      ├── openbao   – OpenBao Server
      ├── nginx     – Reverse Proxy + SSL-Terminierung
      └── certbot   – Let's Encrypt Renewal (alle 12h)
```

### Warum nginx vor OpenBao?

- Certbot webroot-Challenge läuft unabhängig von OpenBao
- Automatische Zertifikatserneuerung funktioniert auch bei OpenBao-Restarts
- HTTP → HTTPS Redirect sauber in nginx
- OpenBao muss kein eigenes TLS verwalten (`tls_disable = 1`)
- Konsistentes Pattern zu anderen Trainings-Deployments

---

## Ablauf `cloud-init.sh`

Das Script läuft als `user-data` auf dem Droplet und schreibt seinen Fortschritt nach `/root/install-status.txt`. Erst wenn dort `[DONE]` steht, gilt das Deployment als erfolgreich.

### Phasen

**Phase 0 – Pre-Flight Checks**
- `DIGITALOCEAN_ACCESS_TOKEN` und `USER_PASSWORD` gesetzt und nicht Platzhalter
- Root-Check

**Phase 1 – System vorbereiten**
- Nutzer `11trainingdo` anlegen, SSH-Passwort-Authentifizierung aktivieren
- Pakete installieren: `docker.io`, `docker-compose`, `curl`, `wget`, `dnsutils`, `ufw`
- `doctl` installieren und API-Token validieren

**Phase 2 – IP & DNS**
- Droplet-IP via Metadata-API (`169.254.169.254`)
- A-Record in `do.t3isp.de` erstellen oder aktualisieren (via doctl)
- DNS-Propagation abwarten: max. 5 Minuten, prüft Google DNS (`8.8.8.8`) und DigitalOcean Nameserver

**Phase 3 – Firewall**
- `ufw` Regeln: 22, 80, 443 freigeben
- Regeln zuerst setzen, dann `ufw enable`

**Phase 4 – Verzeichnisstruktur**
```
/opt/openbao/
├── docker-compose.yml
├── config/
│   └── openbao.hcl
├── data/          # OpenBao File-Storage
├── nginx/
│   ├── nginx.conf
│   └── html/      # Custom Error Pages
└── certbot/
    ├── conf/      # Let's Encrypt Certs
    └── www/       # ACME Challenge Webroot
```

**Phase 5 – docker-compose.yml erstellen**

Services:
- `openbao`: Image `openbao/openbao:latest`, Port `127.0.0.1:8200:8200`, IPC_LOCK Capability
- `nginx`: Image `nginx:1.27-alpine`, Ports `80:80` und `443:443`
- `certbot`: Image `certbot/certbot:v3.0.1`, Renewal alle 12h

**Phase 6 – OpenBao Konfiguration (`openbao.hcl`)**

```hcl
storage "file" {
  path = "/vault/data"
}

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = 1
}

ui = true
```

**Phase 7 – nginx Phase 1 (HTTP-only)**
- Konfiguration: nur `listen 80`, ACME-Challenge-Location, Proxy zu OpenBao
- Container starten: `openbao` und `nginx`
- Warten bis OpenBao bereit ist (Health-Check gegen `127.0.0.1:8200/v1/sys/health`)

**Phase 8 – OpenBao initialisieren**
- `docker exec openbao bao operator init -key-shares=1 -key-threshold=1`
- Unseal Key und Root Token in `/root/openbao-credentials.txt` speichern (`chmod 600`)
- Unseal: `docker exec openbao bao operator unseal <UNSEAL_KEY>`
- Root Token im Container als Env-Variable für Health-Checks setzen

**Phase 9 – Let's Encrypt Zertifikat**
- Certbot via `docker run` (webroot-Methode) für `openbao.<USER>.do.t3isp.de`
- Zertifikat validieren: `certbot/conf/live/<DOMAIN>/fullchain.pem` muss existieren

**Phase 10 – nginx Phase 2 (HTTPS)**
- nginx.conf mit HTTPS-Block ersetzen:
  - HTTP → HTTPS Redirect
  - SSL mit `fullchain.pem` / `privkey.pem`
  - TLSv1.2 + TLSv1.3
  - `proxy_pass http://openbao:8200`
- `docker-compose restart nginx`
- Certbot Renewal-Container starten

**Phase 11 – Finale Tests**
- HTTPS erreichbar (`curl -s https://<DOMAIN>/v1/sys/health`)
- OpenBao Status: `initialized=true`, `sealed=false`
- Credentials-Datei ausgeben

**Phase 12 – Status `[DONE]`**
- In `/root/install-status.txt` schreiben
- Laufzeit ausgeben

---

## Ablauf `install-openbao-single.sh` (lokal)

Das Script kombiniert Deployment und Test in einem Durchlauf. Grundlage ist das Muster aus `deploy-test.sh` des Checkmk-Projekts.

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

`bao apply` bzw. das Droplet-Create gilt erst als erfolgreich, wenn `/root/install-status.txt` den Eintrag `[DONE]` enthält. Das Skript **pollt aktiv** und wartet – es geht nicht weiter bevor cloud-init abgeschlossen ist.

---

## Testplan

Alle Tests werden nach cloud-init `[DONE]` ausgeführt:

| # | Test | Erwartung |
|---|---|---|
| 1 | DNS Resolution | `openbao.<USER>.do.t3isp.de` → Droplet-IP |
| 2 | HTTP → HTTPS Redirect | HTTP 301/302 |
| 3 | HTTPS erreichbar | HTTP 200 |
| 4 | SSL Zertifikat gültig | `curl` ohne `-k` erfolgreich |
| 5 | OpenBao Health API | `GET /v1/sys/health` → `initialized=true, sealed=false` |
| 6 | OpenBao UI erreichbar | `GET /ui/` → HTTP 200 |
| 7 | Docker Container laufen | `openbao`, `nginx`, `certbot` alle `Up` |

Bei Fehler: Logs ausgeben, Droplet **bleibt bestehen** für manuelle Analyse.

---

## Credentials-Ausgabe

Nach erfolgreichem Deployment wird ausgegeben:

```
═══════════════════════════════════════════════════
         OPENBAO INSTALLATION - CREDENTIALS
═══════════════════════════════════════════════════

🌐 URL:           https://openbao.<USER>.do.t3isp.de/ui/
🖥️  Droplet IP:   <IP>

🔑 ROOT TOKEN:    <root-token>
🔓 UNSEAL KEY:    <unseal-key>

⚠️  Credentials gespeichert in: /root/openbao-credentials.txt (chmod 600)

🐳 DOCKER BEFEHLE:
   Status:   cd /opt/openbao && docker-compose ps
   Logs:     docker-compose logs -f openbao
   Restart:  docker-compose restart
   Unseal:   docker exec openbao bao operator unseal <UNSEAL_KEY>

🔄 SSL ERNEUERUNG:
   Automatisch alle 12h via Certbot Container

═══════════════════════════════════════════════════
```

---

## Nicht im Scope (Single-Node)

- HA-Cluster / Raft-Storage (separates Deployment)
- Kubernetes-Integration
- Auto-Unseal (KMS)
- LDAP / OIDC Auth
- Policies und Secrets vorkonfigurieren

---

## Offene Punkte / Entscheidungen

| Punkt | Entscheidung |
|---|---|
| OpenBao Storage Backend | File-Backend (ausreichend für Single-Node Training) |
| Key Shares beim Init | 1 Share, Threshold 1 (vereinfacht für Training) |
| OpenBao Version | `latest` – oder fixe Version im `.env` pinnen? |
| Droplet nach Tests löschen? | Interaktive Frage am Ende des Scripts |
