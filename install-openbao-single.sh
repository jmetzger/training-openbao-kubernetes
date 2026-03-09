#!/usr/bin/env bash
# install-openbao-single.sh – Einstiegspunkt: OpenBao Single-Node auf DigitalOcean
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
# Schritt 2 – Konfiguration
# =============================================================
DROPLET_USER="${USER:-$(whoami)}"
HOSTNAME="openbao-${DROPLET_USER}"
DOMAIN="openbao.${DROPLET_USER}.do.t3isp.de"
REGION="fra1"
SIZE="s-2vcpu-4gb"
IMAGE="ubuntu-22-04-x64"
SSH_KEY_PATH="${HOME}/.ssh/id_ed25519_nopass"

echo "╔══════════════════════════════════════════════════╗"
echo "║    OpenBao Single-Node Deployment                ║"
echo "╚══════════════════════════════════════════════════╝"
echo ""
echo "  Hostname : $HOSTNAME"
echo "  Domain   : $DOMAIN"
echo "  Region   : $REGION / $SIZE"
echo ""

# =============================================================
# Schritt 2 – doctl installieren / prüfen
# =============================================================
if ! command -v doctl &>/dev/null; then
  echo "Installiere doctl..."
  DOCTL_VERSION="1.110.0"
  curl -sL "https://github.com/digitalocean/doctl/releases/download/v${DOCTL_VERSION}/doctl-${DOCTL_VERSION}-linux-amd64.tar.gz" \
    | tar -xz -C /usr/local/bin
fi

doctl auth init --access-token "$DIGITALOCEAN_ACCESS_TOKEN" --no-context >/dev/null 2>&1 || true
doctl account get >/dev/null \
  || { echo "FEHLER: doctl Authentifizierung fehlgeschlagen"; exit 1; }

echo "doctl authentifiziert."

# =============================================================
# Schritt 3 – SSH Key prüfen
# =============================================================
if [[ ! -f "${SSH_KEY_PATH}.pub" ]]; then
  echo "FEHLER: SSH Public Key nicht gefunden: ${SSH_KEY_PATH}.pub"
  exit 1
fi

SSH_KEY_FINGERPRINT=$(ssh-keygen -lf "${SSH_KEY_PATH}.pub" | awk '{print $2}')
SSH_KEY_ID=$(doctl compute ssh-key list --format FingerPrint,ID --no-header \
  | awk -v fp="$SSH_KEY_FINGERPRINT" '$1 == fp {print $2}' | head -1 || true)

if [[ -z "$SSH_KEY_ID" ]]; then
  echo "FEHLER: SSH-Key $SSH_KEY_FINGERPRINT nicht in DigitalOcean gefunden"
  echo "       Bitte Key unter https://cloud.digitalocean.com/account/security hinterlegen"
  exit 1
fi

echo "SSH Key gefunden (ID: $SSH_KEY_ID)"

# =============================================================
# Schritt 4 – Bestehendes Droplet prüfen
# =============================================================
EXISTING_ID=$(doctl compute droplet list --format Name,ID --no-header \
  | awk -v h="$HOSTNAME" '$1 == h {print $2}' | head -1 || true)

if [[ -n "$EXISTING_ID" ]]; then
  echo ""
  echo "Droplet '$HOSTNAME' (ID: $EXISTING_ID) existiert bereits."
  read -rp "Neu erstellen (löschen + neu)? [y/N] " CONFIRM
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
# Schritt 5 – cloud-init.sh vorbereiten (Platzhalter ersetzen)
# =============================================================
CLOUD_INIT_SRC="$SCRIPT_DIR/cloud-init.sh"
[[ ! -f "$CLOUD_INIT_SRC" ]] && { echo "FEHLER: cloud-init.sh nicht gefunden"; exit 1; }

CLOUD_INIT_TMP=$(mktemp /tmp/cloud-init-XXXXXX.sh)
# shellcheck disable=SC2064
trap "rm -f '$CLOUD_INIT_TMP'" EXIT

sed \
  -e "s|__DIGITALOCEAN_ACCESS_TOKEN__|${DIGITALOCEAN_ACCESS_TOKEN}|g" \
  -e "s|__USER_PASSWORD__|${USER_PASSWORD}|g" \
  -e "s|__DOMAIN__|${DOMAIN}|g" \
  "$CLOUD_INIT_SRC" > "$CLOUD_INIT_TMP"

# =============================================================
# Schritt 6 – Droplet erstellen
# =============================================================
echo ""
echo "Erstelle Droplet '$HOSTNAME'..."
DROPLET_ID=$(doctl compute droplet create "$HOSTNAME" \
  --region "$REGION" \
  --size "$SIZE" \
  --image "$IMAGE" \
  --ssh-keys "$SSH_KEY_ID" \
  --user-data-file "$CLOUD_INIT_TMP" \
  --wait \
  --format ID \
  --no-header)

echo "Droplet erstellt (ID: $DROPLET_ID)"

# IP ermitteln
sleep 5
DROPLET_IP=$(doctl compute droplet get "$DROPLET_ID" --format PublicIPv4 --no-header)
echo "Droplet IP: $DROPLET_IP"

# =============================================================
# Schritt 7 – SSH abwarten (max. 5 Minuten)
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
# Schritt 8 – Polling /root/install-status.txt (max. 15 Minuten)
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
# Schritt 9 – Tests
# =============================================================
echo ""
echo "=== Tests ==="
ERRORS=0

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

# Test 3+4: HTTPS erreichbar + SSL gültig
echo -n "[3+4] HTTPS + SSL... "
HTTPS_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  --max-time 10 "https://${DOMAIN}/" 2>/dev/null || true)
if [[ "$HTTPS_CODE" =~ ^(200|307|473)$ ]]; then
  echo "OK (HTTP $HTTPS_CODE)"
else
  echo "FEHLER (HTTP $HTTPS_CODE)"
  ERRORS=$((ERRORS + 1))
fi

# Test 5: OpenBao Health API
echo -n "[5] OpenBao Health API... "
HEALTH=$(curl -s --max-time 10 "https://${DOMAIN}/v1/sys/health" 2>/dev/null || true)
if echo "$HEALTH" | python3 -c \
    "import sys,json; d=json.load(sys.stdin); assert d.get('initialized') and not d.get('sealed')" \
    2>/dev/null; then
  echo "OK (initialized=true, sealed=false)"
else
  echo "FEHLER: $HEALTH"
  ERRORS=$((ERRORS + 1))
fi

# Test 6: OpenBao UI
echo -n "[6] OpenBao UI... "
UI_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  --max-time 10 "https://${DOMAIN}/ui/" 2>/dev/null || true)
if [[ "$UI_CODE" == "200" ]]; then
  echo "OK"
else
  echo "FEHLER (HTTP $UI_CODE)"
  ERRORS=$((ERRORS + 1))
fi

# Test 7: Docker Container
echo -n "[7] Docker Container... "
CONTAINERS=$(ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no \
  root@"$DROPLET_IP" \
  "cd /opt/openbao && docker-compose ps --services --filter 'status=running'" \
  2>/dev/null || true)
if echo "$CONTAINERS" | grep -q "openbao" && echo "$CONTAINERS" | grep -q "nginx"; then
  echo "OK"
else
  echo "WARNUNG: Nicht alle Container laufen ($CONTAINERS)"
fi

# =============================================================
# Schritt 10 – Credentials ausgeben
# =============================================================
CREDENTIALS=$(ssh -i "$SSH_KEY_PATH" -o StrictHostKeyChecking=no \
  root@"$DROPLET_IP" \
  "cat /root/openbao-credentials.txt" 2>/dev/null || true)

ROOT_TOKEN=$(echo "$CREDENTIALS" | awk -F= '/ROOT_TOKEN/ {print $2}')
UNSEAL_KEY=$(echo "$CREDENTIALS" | awk -F= '/UNSEAL_KEY/ {print $2}')

echo ""
echo "═══════════════════════════════════════════════════"
echo "         OPENBAO INSTALLATION - CREDENTIALS"
echo "═══════════════════════════════════════════════════"
echo ""
echo "  URL:           https://${DOMAIN}/ui/"
echo "  Droplet IP:    $DROPLET_IP"
echo ""
echo "  ROOT TOKEN:    $ROOT_TOKEN"
echo "  UNSEAL KEY:    $UNSEAL_KEY"
echo ""
echo "  Credentials gespeichert in: /root/openbao-credentials.txt (chmod 600)"
echo ""
echo "  DOCKER BEFEHLE:"
echo "     Status:   cd /opt/openbao && docker-compose ps"
echo "     Logs:     docker-compose logs -f openbao"
echo "     Restart:  docker-compose restart"
echo "     Unseal:   docker exec openbao bao operator unseal $UNSEAL_KEY"
echo ""
echo "  SSL ERNEUERUNG:"
echo "     Automatisch alle 12h via Certbot Container"
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
echo ""
read -rp "Droplet jetzt löschen? [y/N] " DELETE_CONFIRM
if [[ "${DELETE_CONFIRM,,}" == "y" ]]; then
  doctl compute droplet delete "$DROPLET_ID" --force
  echo "Droplet gelöscht."
fi

echo ""
echo "Deployment erfolgreich abgeschlossen!"
