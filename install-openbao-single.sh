#!/usr/bin/env bash
# install-openbao-single.sh – Einstiegspunkt: Server für OpenBao Training auf DigitalOcean
# Ziel: Server mit nginx + Let's Encrypt bereitstellen (OpenBao folgt im nächsten Schritt)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# =============================================================
# Schritt 1 – .env laden und validieren
# =============================================================
if [[ ! -f "$SCRIPT_DIR/.env" ]]; then
  echo "FEHLER: .env nicht gefunden."
  echo "       Bitte .env.example kopieren und ausfüllen:"
  echo "       cp .env.example .env && nano .env"
  exit 1
fi

# shellcheck source=/dev/null
source "$SCRIPT_DIR/.env"

[[ -z "${DIGITALOCEAN_ACCESS_TOKEN:-}" || "$DIGITALOCEAN_ACCESS_TOKEN" == "ENTER_YOUR_DO_TOKEN" ]] \
  && { echo "FEHLER: DIGITALOCEAN_ACCESS_TOKEN nicht gesetzt (siehe .env)"; exit 1; }
[[ -z "${USER_PASSWORD:-}" || "$USER_PASSWORD" == "ENTER_YOUR_PASSWORD" ]] \
  && { echo "FEHLER: USER_PASSWORD nicht gesetzt (siehe .env)"; exit 1; }

# =============================================================
# Name-Modus (wenn $1 mit Buchstaben a-z beginnt → direkter Name als Subdomain/Nutzer)
# =============================================================
if [[ -n "${1:-}" && "${1:-}" =~ ^[a-z] ]]; then
  export DEPLOY_USER="$1"
  export TRAINING_USER_OVERRIDE="$1"
fi

# =============================================================
# Multi-Server-Modus (wenn $1 eine Zahl ist)
# =============================================================
if [[ -n "${1:-}" && "${1:-}" =~ ^[0-9]+$ ]]; then
  DEPLOY_COUNT="$1"

  echo "╔══════════════════════════════════════════════════╗"
  echo "║    OpenBao Training – Multi-Server-Setup         ║"
  echo "╚══════════════════════════════════════════════════╝"
  echo ""
  echo "  Anzahl Server : $DEPLOY_COUNT (tln1 … tln${DEPLOY_COUNT})"
  echo "  Logs          : /tmp/deploy-tln<N>.log"
  echo ""

  declare -A JOB_PIDS

  for i in $(seq 1 "$DEPLOY_COUNT"); do
    TLN_USER="tln${i}"
    LOG_FILE="/tmp/deploy-${TLN_USER}.log"
    echo "  Starte $TLN_USER → $LOG_FILE"
    AUTO_MODE=1 DEPLOY_USER="$TLN_USER" TRAINING_USER_OVERRIDE="$TLN_USER" \
      bash "$0" > "$LOG_FILE" 2>&1 &
    JOB_PIDS[$TLN_USER]=$!
  done

  echo ""
  echo "Alle $DEPLOY_COUNT Deployments gestartet – warte auf Abschluss..."
  echo ""

  declare -A JOB_STATUS
  OVERALL_EXIT=0
  for i in $(seq 1 "$DEPLOY_COUNT"); do
    TLN_USER="tln${i}"
    PID="${JOB_PIDS[$TLN_USER]}"
    if wait "$PID" 2>/dev/null; then
      JOB_STATUS[$TLN_USER]="ok"
    else
      JOB_STATUS[$TLN_USER]="fail"
      OVERALL_EXIT=1
    fi
  done

  echo "══════════════════════════════════════════════════"
  echo "         DEPLOYMENT-ÜBERSICHT"
  echo "══════════════════════════════════════════════════"
  for i in $(seq 1 "$DEPLOY_COUNT"); do
    TLN_USER="tln${i}"
    DOMAIN_TLN="openbao.${TLN_USER}.do.t3isp.de"
    LOG_FILE="/tmp/deploy-${TLN_USER}.log"
    if [[ "${JOB_STATUS[$TLN_USER]}" == "ok" ]]; then
      echo "  $TLN_USER  ✓  https://$DOMAIN_TLN"
    else
      echo "  $TLN_USER  ✗  FAILED – siehe $LOG_FILE"
    fi
  done
  echo "══════════════════════════════════════════════════"

  exit $OVERALL_EXIT
fi

# =============================================================
# Schritt 2 – Konfiguration
# =============================================================
# DEPLOY_USER kann per Env gesetzt werden (Multi-Server-Modus)
DROPLET_USER="${DEPLOY_USER:-${USER:-$(whoami)}}"
# TRAINING_USER: Linux-User auf dem Server (tln<N> im Multi-Server-Modus, sonst 11trainingdo)
TRAINING_USER="${TRAINING_USER_OVERRIDE:-11trainingdo}"
HOSTNAME="openbao-${DROPLET_USER}"
DOMAIN="openbao.${DROPLET_USER}.do.t3isp.de"
REGION="fra1"
SIZE="s-2vcpu-4gb"
IMAGE="ubuntu-24-04-x64"
SSH_KEY_PATH="${HOME}/.ssh/id_ed25519_nopass"

echo "╔══════════════════════════════════════════════════╗"
echo "║    OpenBao Training – Server-Setup               ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""
echo "  Hostname : $HOSTNAME"
echo "  Domain   : $DOMAIN"
echo "  Region   : $REGION / $SIZE"
echo ""

# =============================================================
# Schritt 3 – doctl installieren / prüfen
# =============================================================
if ! command -v doctl &>/dev/null; then
  echo "Installiere doctl..."
  DOCTL_VERSION="1.151.0"
  curl -sL "https://github.com/digitalocean/doctl/releases/download/v${DOCTL_VERSION}/doctl-${DOCTL_VERSION}-linux-amd64.tar.gz" \
    | tar -xz -C /usr/local/bin
fi

doctl auth init --access-token "$DIGITALOCEAN_ACCESS_TOKEN" --no-context >/dev/null 2>&1 || true
doctl account get >/dev/null \
  || { echo "FEHLER: doctl Authentifizierung fehlgeschlagen"; exit 1; }

echo "doctl authentifiziert."

# =============================================================
# Schritt 4 – SSH Key prüfen
# =============================================================
if [[ ! -f "${SSH_KEY_PATH}.pub" ]]; then
  echo "FEHLER: SSH Public Key nicht gefunden: ${SSH_KEY_PATH}.pub"
  exit 1
fi

SSH_KEY_FINGERPRINT=$(ssh-keygen -E md5 -lf "${SSH_KEY_PATH}.pub" | awk '{print $2}' | sed 's/^MD5://')
SSH_KEY_ID=$(doctl compute ssh-key list --format FingerPrint,ID --no-header \
  | awk -v fp="$SSH_KEY_FINGERPRINT" '$1 == fp {print $2}' | head -1 || true)

if [[ -z "$SSH_KEY_ID" ]]; then
  echo "FEHLER: SSH-Key $SSH_KEY_FINGERPRINT nicht in DigitalOcean gefunden"
  echo "       Bitte Key unter https://cloud.digitalocean.com/account/security hinterlegen"
  exit 1
fi

echo "SSH Key gefunden (ID: $SSH_KEY_ID)"

# =============================================================
# Schritt 5 – Bestehendes Droplet prüfen
# =============================================================
EXISTING_ID=$(doctl compute droplet list --format Name,ID --no-header \
  | awk -v h="$HOSTNAME" '$1 == h {print $2}' | head -1 || true)

if [[ -n "$EXISTING_ID" ]]; then
  echo ""
  echo "Droplet '$HOSTNAME' (ID: $EXISTING_ID) existiert bereits."
  if [[ "${AUTO_MODE:-0}" == "1" ]]; then
    echo "AUTO_MODE: Lösche bestehendes Droplet automatisch..."
    CONFIRM="y"
  else
    read -rp "Neu erstellen (löschen + neu)? [y/N] " CONFIRM
  fi
  if [[ "${CONFIRM,,}" == "y" ]]; then
    echo "Lösche bestehendes Droplet..."
    doctl compute droplet delete "$EXISTING_ID" --force
    echo "Warte 10 Sekunden..."
    sleep 10
  else
    echo "Abgebrochen."
    exit 0
  fi
fi

# =============================================================
# Schritt 6 – cloud-init.sh vorbereiten (Platzhalter ersetzen)
# =============================================================
CLOUD_INIT_SRC="$SCRIPT_DIR/cloud-init.sh"
[[ ! -f "$CLOUD_INIT_SRC" ]] && { echo "FEHLER: cloud-init.sh nicht gefunden"; exit 1; }

# CERTBOT_STAGING=1 in .env → Staging-CA verwenden (kein Rate Limit, aber kein vertrauenswürdiges Zertifikat)
CERTBOT_STAGING_VALUE="false"
[[ "${CERTBOT_STAGING:-0}" == "1" ]] && CERTBOT_STAGING_VALUE="true"

CLOUD_INIT_CONTENT=$(sed \
  -e "s|__DIGITALOCEAN_ACCESS_TOKEN__|${DIGITALOCEAN_ACCESS_TOKEN}|g" \
  -e "s|__USER_PASSWORD__|${USER_PASSWORD}|g" \
  -e "s|__DOMAIN__|${DOMAIN}|g" \
  -e "s|__CERTBOT_STAGING__|${CERTBOT_STAGING_VALUE}|g" \
  -e "s|__TRAINING_USER__|${TRAINING_USER}|g" \
  "$CLOUD_INIT_SRC")

# =============================================================
# Schritt 7 – Droplet erstellen
# =============================================================
echo ""
echo "Erstelle Droplet '$HOSTNAME'..."
DROPLET_ID=$(doctl compute droplet create "$HOSTNAME" \
  --region "$REGION" \
  --size "$SIZE" \
  --image "$IMAGE" \
  --ssh-keys "$SSH_KEY_ID" \
  --user-data "$CLOUD_INIT_CONTENT" \
  --wait \
  --format ID \
  --no-header)

echo "Droplet erstellt (ID: $DROPLET_ID)"

# IP ermitteln
sleep 5
DROPLET_IP=$(doctl compute droplet get "$DROPLET_ID" --format PublicIPv4 --no-header)
echo "Droplet IP: $DROPLET_IP"

# =============================================================
# Schritt 8 – SSH abwarten (max. 5 Minuten)
# =============================================================
echo ""
echo "Warte auf SSH-Zugang..."
SSH_READY=false
for i in $(seq 1 30); do
  if nc -z -w 5 "$DROPLET_IP" 22 2>/dev/null; then
    SSH_READY=true
    echo "SSH erreichbar."
    break
  fi
  echo "  [$i/30] Warte auf SSH..."
  sleep 10
done

$SSH_READY || { echo "FEHLER: SSH nicht erreichbar nach 5 Minuten"; exit 1; }

# =============================================================
# Schritt 9 – Polling /root/install-status.txt (max. 15 Minuten)
# =============================================================
echo ""
echo "Warte auf cloud-init Abschluss (max. 15 Minuten)..."
INSTALL_DONE=false

for i in $(seq 1 30); do
  STATUS=$(ssh -i "$SSH_KEY_PATH" \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=10 \
    -o BatchMode=yes \
    root@"$DROPLET_IP" \
    "tail -1 /root/install-status.txt 2>/dev/null" 2>/dev/null || true)

  if [[ "$STATUS" == *"[DONE]"* ]]; then
    INSTALL_DONE=true
    echo "Installation abgeschlossen!"
    break
  elif [[ "$STATUS" == *"[FAILED]"* ]]; then
    echo ""
    echo "FEHLER: Installation fehlgeschlagen! Logs:"
    ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no root@"$DROPLET_IP" \
      "cat /root/install-status.txt" 2>/dev/null || true
    echo ""
    echo "Droplet bleibt für manuelle Analyse erhalten (ID: $DROPLET_ID, IP: $DROPLET_IP)"
    exit 1
  fi

  echo "  [$i/30] Status: ${STATUS:-'(noch kein Eintrag)'}"
  sleep 30
done

if ! $INSTALL_DONE; then
  echo ""
  echo "FEHLER: Timeout nach 15 Minuten. Letzte Logs:"
  ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no root@"$DROPLET_IP" \
    "tail -30 /root/install-status.txt" 2>/dev/null || true
  echo ""
  echo "Droplet bleibt für manuelle Analyse erhalten (ID: $DROPLET_ID, IP: $DROPLET_IP)"
  exit 1
fi

# =============================================================
# Schritt 10 – Tests
# =============================================================
echo ""
echo "=== Tests ==="
[[ "$CERTBOT_STAGING_VALUE" == "true" ]] && echo "  (STAGING-MODE: SSL-Tests mit -k da Staging-CA nicht vertrauenswürdig)"
ERRORS=0

# curl SSL-Flag: in Staging-Mode -k verwenden (Staging-CA nicht vertrauenswürdig)
SSL_FLAGS=""
[[ "$CERTBOT_STAGING_VALUE" == "true" ]] && SSL_FLAGS="-k"

# Test 1: DNS Resolution
echo -n "[1] DNS Resolution... "
RESOLVED=$(dig +short "$DOMAIN" @8.8.8.8 2>/dev/null | head -1 || true)
if [[ "$RESOLVED" == "$DROPLET_IP" ]]; then
  echo "OK ($RESOLVED)"
else
  echo "FEHLER (erwartet: $DROPLET_IP, erhalten: '${RESOLVED:-leer}')"
  ERRORS=$((ERRORS + 1))
fi

# Test 2: HTTP → HTTPS Redirect
echo -n "[2] HTTP -> HTTPS Redirect... "
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  --max-time 10 "http://${DOMAIN}/" 2>/dev/null || true)
if [[ "$HTTP_CODE" =~ ^30[12]$ ]]; then
  echo "OK (HTTP $HTTP_CODE)"
else
  echo "FEHLER (HTTP $HTTP_CODE)"
  ERRORS=$((ERRORS + 1))
fi

# Test 3: HTTPS erreichbar
echo -n "[3] HTTPS erreichbar... "
# shellcheck disable=SC2086
HTTPS_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  --max-time 10 $SSL_FLAGS "https://${DOMAIN}/" 2>/dev/null || true)
if [[ "$HTTPS_CODE" =~ ^[23] ]]; then
  echo "OK (HTTP $HTTPS_CODE)"
else
  echo "FEHLER (HTTP $HTTPS_CODE)"
  ERRORS=$((ERRORS + 1))
fi

# Test 4: SSL Zertifikat gültig (ohne -k bei Produktion, mit -k bei Staging)
echo -n "[4] SSL Zertifikat... "
if [[ "$CERTBOT_STAGING_VALUE" == "true" ]]; then
  # Staging: Zertifikat vorhanden prüfen (via SSH), aber nicht browser-trusted
  CERT_EXISTS=$(ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no \
    root@"$DROPLET_IP" \
    "[[ -f /etc/letsencrypt/live/${DOMAIN}/fullchain.pem ]] && echo yes || echo no" 2>/dev/null || echo "no")
  if [[ "$CERT_EXISTS" == "yes" ]]; then
    echo "OK (Staging-Zertifikat vorhanden – nicht browser-trusted)"
  else
    echo "FEHLER (Zertifikat nicht gefunden)"
    ERRORS=$((ERRORS + 1))
  fi
else
  # Produktion: curl ohne -k – vertrauenswürdiges Zertifikat prüfen
  SSL_RESULT=$(curl -s -o /dev/null -w "%{http_code}" \
    --max-time 10 "https://${DOMAIN}/" 2>/dev/null || echo "FEHLER")
  if [[ "$SSL_RESULT" != "FEHLER" && "$SSL_RESULT" != "000" ]]; then
    echo "OK (vertrauenswürdiges Zertifikat)"
  else
    echo "FEHLER (SSL-Zertifikat ungültig oder nicht erreichbar)"
    ERRORS=$((ERRORS + 1))
  fi
fi

# Test 5: nginx läuft
echo -n "[5] nginx aktiv... "
NGINX_STATUS=$(ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no \
  root@"$DROPLET_IP" \
  "systemctl is-active nginx" 2>/dev/null || true)
if [[ "$NGINX_STATUS" == "active" ]]; then
  echo "OK"
else
  echo "FEHLER (Status: ${NGINX_STATUS:-unbekannt})"
  ERRORS=$((ERRORS + 1))
fi

# =============================================================
# Schritt 11 – Ergebnis ausgeben
# =============================================================
echo ""
echo "═══════════════════════════════════════════════════"
echo "         SERVER BEREIT FUER OPENBAO TRAINING"
echo "═══════════════════════════════════════════════════"
echo ""
echo "  URL:           https://${DOMAIN}"
echo "  Droplet IP:    $DROPLET_IP"
echo "  SSH:           ssh ${TRAINING_USER}@${DROPLET_IP}"
echo "  Passwort:      ${USER_PASSWORD}"
echo ""
echo "  STATUS:"
echo "    nginx:       aktiv (systemd)"
echo "    certbot:     automatische Erneuerung via systemd-Timer"
echo "    OpenBao:     noch nicht installiert (folgt im naechsten Schritt)"
echo ""
echo "  NAECHSTER SCHRITT:"
echo "    OpenBao installieren und starten:"
echo "    ssh ${TRAINING_USER}@${DROPLET_IP}"
echo ""
echo "  HILFREICHE BEFEHLE:"
echo "    nginx Logs:  journalctl -u nginx -f"
echo "    nginx Test:  nginx -t"
echo ""
echo "═══════════════════════════════════════════════════"

if [[ $ERRORS -gt 0 ]]; then
  echo ""
  echo "WARNUNG: $ERRORS Test(s) fehlgeschlagen."
  echo "Droplet bleibt für manuelle Analyse erhalten (ID: $DROPLET_ID, IP: $DROPLET_IP)"
  exit 1
fi

# =============================================================
# Interaktiv: Droplet löschen?
# =============================================================
if [[ "${AUTO_MODE:-0}" != "1" ]]; then
  echo ""
  read -rp "Droplet jetzt löschen? [y/N] " DELETE_CONFIRM
  if [[ "${DELETE_CONFIRM,,}" == "y" ]]; then
    doctl compute droplet delete "$DROPLET_ID" --force
    echo "Droplet gelöscht."
  fi
else
  echo "AUTO_MODE: Droplet bleibt bestehen (ID: $DROPLET_ID, IP: $DROPLET_IP)"
fi

echo ""
echo "Deployment erfolgreich abgeschlossen!"
