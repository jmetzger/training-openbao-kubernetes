#!/usr/bin/env bash
# cloud-init.sh – läuft als user-data auf dem DigitalOcean Droplet
# Platzhalter werden per sed durch install-openbao-single.sh ersetzt
set -uo pipefail

# --- Platzhalter (werden per sed ersetzt) ---
DIGITALOCEAN_ACCESS_TOKEN="__DIGITALOCEAN_ACCESS_TOKEN__"
USER_PASSWORD="__USER_PASSWORD__"
DOMAIN="__DOMAIN__"

# --- Konstanten ---
BASE_DOMAIN="do.t3isp.de"
EMAIL="j.metzger@t3company.de"
STATUS_FILE="/root/install-status.txt"
CREDENTIALS_FILE="/root/openbao-credentials.txt"
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

# Nutzer anlegen
useradd -m -s /bin/bash 11trainingdo 2>/dev/null || true
echo "11trainingdo:${USER_PASSWORD}" | chpasswd

# SSH Passwort-Auth aktivieren
sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
systemctl restart sshd

# Pakete
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq
apt-get install -y -qq docker.io docker-compose curl wget dnsutils ufw python3

# Docker starten
systemctl enable docker
systemctl start docker

# doctl installieren
DOCTL_VERSION="1.110.0"
curl -sL "https://github.com/digitalocean/doctl/releases/download/v${DOCTL_VERSION}/doctl-${DOCTL_VERSION}-linux-amd64.tar.gz" \
  | tar -xz -C /usr/local/bin

# doctl authentifizieren
doctl auth init --access-token "$DIGITALOCEAN_ACCESS_TOKEN" || fail "doctl auth fehlgeschlagen"

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
# Phase 4 – Verzeichnisstruktur
# =============================================================
log "=== Phase 4: Verzeichnisstruktur ==="

mkdir -p /opt/openbao/{config,data,nginx/html,certbot/{conf,www}}

log "Phase 4 OK"

# =============================================================
# Phase 5 – docker-compose.yml
# =============================================================
log "=== Phase 5: docker-compose.yml ==="

cat > /opt/openbao/docker-compose.yml <<'COMPOSE_EOF'
version: '3.8'

services:
  openbao:
    image: openbao/openbao:latest
    container_name: openbao
    restart: unless-stopped
    ports:
      - "127.0.0.1:8200:8200"
    cap_add:
      - IPC_LOCK
    volumes:
      - ./config:/vault/config
      - ./data:/vault/data
    command: server -config=/vault/config/openbao.hcl

  nginx:
    image: nginx:1.27-alpine
    container_name: nginx
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
    volumes:
      - ./nginx/nginx.conf:/etc/nginx/nginx.conf:ro
      - ./nginx/html:/usr/share/nginx/html:ro
      - ./certbot/conf:/etc/letsencrypt:ro
      - ./certbot/www:/var/www/certbot:ro
    depends_on:
      - openbao

  certbot:
    image: certbot/certbot:v3.0.1
    container_name: certbot
    restart: unless-stopped
    volumes:
      - ./certbot/conf:/etc/letsencrypt
      - ./certbot/www:/var/www/certbot
    entrypoint: "/bin/sh -c 'trap exit TERM; while :; do certbot renew; sleep 12h & wait $${!}; done;'"
COMPOSE_EOF

log "Phase 5 OK"

# =============================================================
# Phase 6 – OpenBao Konfiguration
# =============================================================
log "=== Phase 6: OpenBao Konfiguration ==="

cat > /opt/openbao/config/openbao.hcl <<'HCL_EOF'
storage "file" {
  path = "/vault/data"
}

listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = 1
}

ui = true
HCL_EOF

log "Phase 6 OK"

# =============================================================
# Phase 7 – nginx Phase 1 (HTTP-only) + Container starten
# =============================================================
log "=== Phase 7: nginx Phase 1 (HTTP-only) ==="

cat > /opt/openbao/nginx/nginx.conf <<NGINX_EOF
events {
  worker_connections 1024;
}

http {
  server {
    listen 80;
    server_name ${DOMAIN};

    location /.well-known/acme-challenge/ {
      root /var/www/certbot;
    }

    location / {
      proxy_pass         http://openbao:8200;
      proxy_set_header   Host \$host;
      proxy_set_header   X-Real-IP \$remote_addr;
      proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
      proxy_set_header   X-Forwarded-Proto \$scheme;
    }
  }
}
NGINX_EOF

cd /opt/openbao
docker-compose up -d openbao nginx

# Warten bis OpenBao bereit ist
log "Warte auf OpenBao Health-Check..."
OPENBAO_READY=false
for i in $(seq 1 30); do
  STATUS_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
    http://127.0.0.1:8200/v1/sys/health 2>/dev/null || true)
  # 501 = not initialized, 200 = ok, 429/472/473/503 = other states
  if [[ "$STATUS_CODE" =~ ^(200|429|472|473|501|503)$ ]]; then
    OPENBAO_READY=true
    log "OpenBao antwortet (HTTP $STATUS_CODE)"
    break
  fi
  log "Versuch $i/30: OpenBao HTTP $STATUS_CODE"
  sleep 5
done

$OPENBAO_READY || fail "OpenBao nicht bereit nach 150 Sekunden"

log "Phase 7 OK"

# =============================================================
# Phase 8 – OpenBao initialisieren
# =============================================================
log "=== Phase 8: OpenBao initialisieren ==="

INIT_OUTPUT=$(docker exec openbao bao operator init \
  -key-shares=1 \
  -key-threshold=1 \
  -format=json) || fail "bao operator init fehlgeschlagen"

UNSEAL_KEY=$(echo "$INIT_OUTPUT" | python3 -c \
  "import sys,json; d=json.load(sys.stdin); print(d['unseal_keys_b64'][0])")
ROOT_TOKEN=$(echo "$INIT_OUTPUT" | python3 -c \
  "import sys,json; d=json.load(sys.stdin); print(d['root_token'])")

[[ -z "$UNSEAL_KEY" ]] && fail "Unseal Key nicht gefunden"
[[ -z "$ROOT_TOKEN" ]] && fail "Root Token nicht gefunden"

cat > "$CREDENTIALS_FILE" <<CREDS_EOF
UNSEAL_KEY=${UNSEAL_KEY}
ROOT_TOKEN=${ROOT_TOKEN}
DOMAIN=${DOMAIN}
CREDS_EOF
chmod 600 "$CREDENTIALS_FILE"

docker exec openbao bao operator unseal "$UNSEAL_KEY" \
  || fail "Unseal fehlgeschlagen"

log "OpenBao initialisiert und unsealed"
log "Phase 8 OK"

# =============================================================
# Phase 9 – Let's Encrypt Zertifikat
# =============================================================
log "=== Phase 9: Let's Encrypt Zertifikat ==="

docker run --rm \
  -v /opt/openbao/certbot/conf:/etc/letsencrypt \
  -v /opt/openbao/certbot/www:/var/www/certbot \
  certbot/certbot:v3.0.1 certonly \
  --webroot \
  --webroot-path=/var/www/certbot \
  --email "$EMAIL" \
  --agree-tos \
  --no-eff-email \
  -d "$DOMAIN" \
  || fail "Certbot fehlgeschlagen"

[[ -f "/opt/openbao/certbot/conf/live/${DOMAIN}/fullchain.pem" ]] \
  || fail "Zertifikat nicht gefunden"

log "Let's Encrypt Zertifikat ausgestellt"
log "Phase 9 OK"

# =============================================================
# Phase 10 – nginx Phase 2 (HTTPS)
# =============================================================
log "=== Phase 10: nginx Phase 2 (HTTPS) ==="

cat > /opt/openbao/nginx/nginx.conf <<NGINX_EOF
events {
  worker_connections 1024;
}

http {
  server {
    listen 80;
    server_name ${DOMAIN};

    location /.well-known/acme-challenge/ {
      root /var/www/certbot;
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

    location / {
      proxy_pass         http://openbao:8200;
      proxy_set_header   Host \$host;
      proxy_set_header   X-Real-IP \$remote_addr;
      proxy_set_header   X-Forwarded-For \$proxy_add_x_forwarded_for;
      proxy_set_header   X-Forwarded-Proto https;
    }
  }
}
NGINX_EOF

cd /opt/openbao
docker-compose restart nginx
docker-compose up -d certbot

log "Phase 10 OK"

# =============================================================
# Phase 11 – Finale Tests
# =============================================================
log "=== Phase 11: Finale Tests ==="

sleep 5

HEALTH_RESPONSE=$(curl -s "https://${DOMAIN}/v1/sys/health" 2>/dev/null || true)

if echo "$HEALTH_RESPONSE" | python3 -c \
    "import sys,json; d=json.load(sys.stdin); assert d.get('initialized') and not d.get('sealed')" \
    2>/dev/null; then
  log "OpenBao Health OK: initialized=true, sealed=false"
else
  log "WARNUNG: Health-Antwort: $HEALTH_RESPONSE"
fi

log "Credentials gespeichert in $CREDENTIALS_FILE"
log "Phase 11 OK"

# =============================================================
# Phase 12 – Status [DONE]
# =============================================================
log "=== Phase 12: Fertig ==="

END_TIME=$(date +%s)
DURATION=$((END_TIME - START_TIME))
log "Gesamtlaufzeit: ${DURATION} Sekunden"
echo "[DONE]" >> "$STATUS_FILE"
