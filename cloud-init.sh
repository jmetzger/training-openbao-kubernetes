#!/usr/bin/env bash
# cloud-init.sh – läuft als user-data auf dem DigitalOcean Droplet
# Platzhalter werden per sed durch install-openbao-single.sh ersetzt
# Ziel: Server mit nginx + Let's Encrypt bereitstellen (OpenBao folgt im nächsten Schritt)
set -uo pipefail

# cloud-init setzt HOME nicht – doctl benötigt es für Config-Verzeichnis
export HOME=/root

# --- Platzhalter (werden per sed ersetzt) ---
DIGITALOCEAN_ACCESS_TOKEN="__DIGITALOCEAN_ACCESS_TOKEN__"
USER_PASSWORD="__USER_PASSWORD__"
DOMAIN="__DOMAIN__"
CERTBOT_STAGING="__CERTBOT_STAGING__"
TRAINING_USER="__TRAINING_USER__"

# --- Konstanten ---
BASE_DOMAIN="do.t3isp.de"
EMAIL="j.metzger@t3company.de"
STATUS_FILE="/root/install-status.txt"
START_TIME=$(date +%s)

# --- Logging ---
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$STATUS_FILE"
}

fail() {
  log "FEHLER: $*"
  echo "[FAILED]" >> "$STATUS_FILE"
  exit 1
}

# =============================================================
# Phase 0 – Pre-Flight Checks
# =============================================================
log "=== Phase 0: Pre-Flight Checks ==="

[[ "$DIGITALOCEAN_ACCESS_TOKEN" == __*__ ]] && fail "DIGITALOCEAN_ACCESS_TOKEN nicht ersetzt"
[[ -z "$DIGITALOCEAN_ACCESS_TOKEN" ]] && fail "DIGITALOCEAN_ACCESS_TOKEN leer"
[[ "$USER_PASSWORD" == __*__ ]] && fail "USER_PASSWORD nicht ersetzt"
[[ -z "$USER_PASSWORD" ]] && fail "USER_PASSWORD leer"
[[ "$EUID" -ne 0 ]] && fail "Muss als root ausgeführt werden"

log "Phase 0 OK"

# =============================================================
# Phase 1 – System vorbereiten
# =============================================================
log "=== Phase 1: System vorbereiten ==="

# Nutzer anlegen (Platzhalter wird per sed durch install-openbao-single.sh ersetzt)
useradd -m -s /bin/bash __TRAINING_USER__ 2>/dev/null || true
echo "__TRAINING_USER__:${USER_PASSWORD}" | chpasswd

# SSH Passwort-Auth aktivieren (Ubuntu 22.04 + 24.04 kompatibel)
# BUG-001/BUG-004: Drop-in-Dateien mit PasswordAuthentication no überschreiben
for conf_file in /etc/ssh/sshd_config.d/*.conf; do
  [[ -f "$conf_file" ]] && \
    sed -i 's/^PasswordAuthentication[[:space:]].*/PasswordAuthentication yes/' "$conf_file"
done
# Auch Hauptkonfiguration patchen (kommentierte und aktive Zeilen)
sed -i 's/^#\?[[:space:]]*PasswordAuthentication[[:space:]].*/PasswordAuthentication yes/' /etc/ssh/sshd_config
# Explizite Override-Datei (10 = niedrigste Nummer → zuerst gelesen)
echo 'PasswordAuthentication yes' > /etc/ssh/sshd_config.d/10-training.conf
# Ubuntu 24.04: ssh.service; Ubuntu 22.04: sshd.service
systemctl restart ssh 2>/dev/null || systemctl restart sshd

# Pakete
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq nginx certbot python3-certbot-nginx curl wget dnsutils ufw

# nginx und doctl: doctl installieren
DOCTL_VERSION="1.151.0"
curl -sL "https://github.com/digitalocean/doctl/releases/download/v${DOCTL_VERSION}/doctl-${DOCTL_VERSION}-linux-amd64.tar.gz" \
  | tar -xz -C /usr/local/bin

# doctl authentifizieren via Env-Variable
export DIGITALOCEAN_ACCESS_TOKEN
doctl account get >/dev/null 2>&1 || fail "doctl API Token ungültig"

log "Phase 1 OK"

# =============================================================
# Phase 2 – IP & DNS
# =============================================================
log "=== Phase 2: IP & DNS ==="

DROPLET_IP=$(curl -s --retry 3 http://169.254.169.254/metadata/v1/interfaces/public/0/ipv4/address)
[[ -z "$DROPLET_IP" ]] && fail "Konnte Droplet-IP nicht ermitteln"
log "Droplet IP: $DROPLET_IP"

# Record-Name innerhalb der Base-Domain (z.B. "openbao.jmetzger")
RECORD_NAME="${DOMAIN%.${BASE_DOMAIN}}"

# Bestehenden A-Record suchen
RECORD_ID=$(doctl compute domain records list "$BASE_DOMAIN" \
  --format ID,Type,Name --no-header 2>/dev/null \
  | awk -v n="$RECORD_NAME" '$2 == "A" && $3 == n {print $1}' | head -1 || true)

if [[ -n "$RECORD_ID" ]]; then
  doctl compute domain records update "$BASE_DOMAIN" \
    --record-id "$RECORD_ID" --record-data "$DROPLET_IP" \
    || fail "DNS-Update fehlgeschlagen"
  log "A-Record aktualisiert (ID: $RECORD_ID)"
else
  doctl compute domain records create "$BASE_DOMAIN" \
    --record-type A \
    --record-name "$RECORD_NAME" \
    --record-data "$DROPLET_IP" \
    --record-ttl 60 \
    || fail "DNS-Create fehlgeschlagen"
  log "A-Record erstellt: $RECORD_NAME.$BASE_DOMAIN -> $DROPLET_IP"
fi

# DNS-Propagation abwarten (max. 5 Minuten)
log "Warte auf DNS-Propagation..."
DNS_OK=false
for i in $(seq 1 30); do
  RESOLVED=$(dig +short "$DOMAIN" @8.8.8.8 2>/dev/null | head -1 || true)
  if [[ "$RESOLVED" == "$DROPLET_IP" ]]; then
    DNS_OK=true
    log "DNS propagiert: $DOMAIN -> $DROPLET_IP"
    break
  fi
  log "Versuch $i/30: $DOMAIN -> '${RESOLVED:-keine Antwort}'"
  sleep 10
done

$DNS_OK || log "WARNUNG: DNS noch nicht propagiert – fahre trotzdem fort"

log "Phase 2 OK"

# =============================================================
# Phase 3 – Firewall
# =============================================================
log "=== Phase 3: Firewall ==="

ufw allow 22/tcp
ufw allow 80/tcp
ufw allow 443/tcp
echo "y" | ufw enable

log "Phase 3 OK"

# =============================================================
# Phase 4 – nginx HTTP-only konfigurieren
# =============================================================
log "=== Phase 4: nginx HTTP-only ==="

cat > /etc/nginx/sites-available/openbao <<NGINX_EOF
server {
    listen 80;
    server_name ${DOMAIN};

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}
NGINX_EOF

ln -sf /etc/nginx/sites-available/openbao /etc/nginx/sites-enabled/openbao
rm -f /etc/nginx/sites-enabled/default

nginx -t || fail "nginx Konfiguration ungültig"
systemctl enable nginx
systemctl restart nginx

log "Phase 4 OK"

# =============================================================
# Phase 5 – Let's Encrypt Zertifikat
# =============================================================
log "=== Phase 5: Let's Encrypt Zertifikat ==="

# BUG-003: Vor Certbot auf vollständige DNS-Propagation warten (max. 10 Minuten)
log "Warte auf vollständige DNS-Propagation für $DOMAIN (max. 10 Minuten)..."
DNS_READY=false
for i in $(seq 1 60); do
  RESOLVED=$(dig +short "$DOMAIN" @8.8.8.8 2>/dev/null | head -1 || true)
  if [[ "$RESOLVED" == "$DROPLET_IP" ]]; then
    DNS_READY=true
    log "DNS bereit: $DOMAIN -> $DROPLET_IP (nach ${i}x10s)"
    break
  fi
  log "DNS-Wait $i/60: $DOMAIN -> '${RESOLVED:-keine Antwort}'"
  sleep 10
done
$DNS_READY || log "WARNUNG: DNS nach 10 Minuten noch nicht vollständig propagiert – starte Certbot trotzdem"

# BUG-006: Vor Certbot prüfen ob nginx auf Port 80 antwortet
log "Prüfe nginx Port 80..."
NGINX_HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  --max-time 10 "http://${DOMAIN}/.well-known/acme-challenge/test" 2>/dev/null || true)
log "nginx Port 80 Antwort: HTTP $NGINX_HTTP_CODE"
if [[ "$NGINX_HTTP_CODE" == "000" ]]; then
  log "WARNUNG: nginx antwortet nicht auf Port 80 – warte 15s und prüfe erneut"
  sleep 15
  nginx -t && systemctl restart nginx || fail "nginx Start fehlgeschlagen"
  sleep 5
fi

# BUG-002/BUG-006: Retry-Schleife (5 Versuche, 60s Pause) + vollständiges Logging
# BUG-007: Staging-Mode via CERTBOT_STAGING=true (kein Rate Limit, aber kein vertrauenswürdiges Zertifikat)
STAGING_FLAG=""
if [[ "$CERTBOT_STAGING" == "true" ]]; then
  STAGING_FLAG="--staging"
  log "STAGING-MODE: Certbot verwendet Let's Encrypt Staging CA (kein Rate Limit, aber kein vertrauenswürdiges Zertifikat)"
fi

CERTBOT_OK=false
for attempt in 1 2 3 4 5; do
  log "Certbot Versuch $attempt/5..."
  # shellcheck disable=SC2086
  if certbot --nginx \
    --non-interactive \
    --agree-tos \
    --email "$EMAIL" \
    --no-eff-email \
    $STAGING_FLAG \
    -d "$DOMAIN" 2>&1 | tee -a "$STATUS_FILE"; then
    CERTBOT_OK=true
    break
  fi
  log "Certbot Versuch $attempt fehlgeschlagen – warte 60s..."
  sleep 60
done

$CERTBOT_OK || fail "Certbot nach 5 Versuchen fehlgeschlagen"

[[ -f "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem" ]] \
  || fail "Zertifikat nicht gefunden"

log "Let's Encrypt Zertifikat ausgestellt"
log "Phase 5 OK"

# =============================================================
# Phase 6 – nginx HTTPS konfigurieren + statische Seite
# =============================================================
log "=== Phase 6: nginx HTTPS ==="

# Statische HTML-Seite erstellen
mkdir -p /var/www/openbao
cat > /var/www/openbao/index.html <<'HTML_EOF'
<!DOCTYPE html>
<html lang="de">
<head>
    <meta charset="UTF-8">
    <title>Server bereit</title>
    <style>
        body { font-family: monospace; max-width: 600px; margin: 100px auto; padding: 20px; }
        h1 { color: #2d7dd2; }
        .status { background: #e8f5e9; border: 1px solid #4caf50; padding: 15px; border-radius: 4px; }
    </style>
</head>
<body>
    <h1>Server bereit</h1>
    <div class="status">
        <p>&#10003; nginx aktiv</p>
        <p>&#10003; Let's Encrypt Zertifikat gültig</p>
        <p>&#10003; HTTPS konfiguriert</p>
    </div>
    <p>OpenBao folgt im nächsten Schritt.</p>
</body>
</html>
HTML_EOF

# nginx HTTPS-Konfiguration
cat > /etc/nginx/sites-available/openbao <<NGINX_EOF
server {
    listen 80;
    server_name ${DOMAIN};

    location /.well-known/acme-challenge/ {
        root /var/www/html;
    }

    location / {
        return 301 https://\$host\$request_uri;
    }
}

server {
    listen 443 ssl;
    server_name ${DOMAIN};

    ssl_certificate     /etc/letsencrypt/live/${DOMAIN}/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/${DOMAIN}/privkey.pem;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         HIGH:!aNULL:!MD5;

    root /var/www/openbao;
    index index.html;

    location / {
        try_files \$uri \$uri/ =404;
    }
}
NGINX_EOF

nginx -t || fail "nginx HTTPS-Konfiguration ungültig"
systemctl reload nginx

log "Phase 6 OK"

# =============================================================
# Phase 7 – Finale Tests
# =============================================================
log "=== Phase 7: Finale Tests ==="

sleep 3

# HTTPS erreichbar
HTTPS_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  --max-time 10 "https://${DOMAIN}/" 2>/dev/null || true)
if [[ "$HTTPS_CODE" == "200" ]]; then
  log "HTTPS OK (HTTP $HTTPS_CODE)"
else
  log "WARNUNG: HTTPS antwortet mit HTTP $HTTPS_CODE"
fi

# nginx aktiv
if systemctl is-active --quiet nginx; then
  log "nginx aktiv"
else
  fail "nginx nicht aktiv"
fi

log "Phase 7 OK"

# =============================================================
# Phase 8 – Status [DONE]
# =============================================================
log "=== Phase 8: Fertig ==="

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
log "Gesamtlaufzeit: ${DURATION} Sekunden"
echo "[DONE]" >> "$STATUS_FILE"
