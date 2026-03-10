#!/usr/bin/env bash
# destroy-openbao-single.sh – Löscht Droplets für OpenBao Training (DNS-Records bleiben erhalten)
#
# Aufruf:
#   ./destroy-openbao-single.sh           # löscht openbao-$USER
#   ./destroy-openbao-single.sh 5         # löscht openbao-tln1 … openbao-tln5
#   ./destroy-openbao-single.sh alice     # löscht openbao-alice (Name beginnt mit a-z → kein Zähler)
#   ./destroy-openbao-single.sh all       # löscht ALLE Droplets mit Prefix "openbao-"
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BASE_DOMAIN="do.t3isp.de"

# =============================================================
# .env laden
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

# =============================================================
# doctl installieren / prüfen
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

# =============================================================
# Ziel-Droplets ermitteln
# =============================================================
ARG="${1:-}"

declare -a TARGET_NAMES=()

if [[ "$ARG" == "all" ]]; then
  # Alle Droplets mit Prefix "openbao-"
  mapfile -t TARGET_NAMES < <(
    doctl compute droplet list --format Name --no-header \
    | grep '^openbao-' || true
  )
  if [[ ${#TARGET_NAMES[@]} -eq 0 ]]; then
    echo "Keine Droplets mit Prefix 'openbao-' gefunden."
    exit 0
  fi
elif [[ "$ARG" =~ ^[0-9]+$ ]]; then
  # tln1 … tln<N>
  for i in $(seq 1 "$ARG"); do
    TARGET_NAMES+=("openbao-tln${i}")
  done
elif [[ "$ARG" =~ ^[a-z] ]]; then
  # Direkter Name (z.B. alice → openbao-alice)
  TARGET_NAMES=("openbao-${ARG}")
else
  # Standard: openbao-$USER
  DROPLET_USER="${USER:-$(whoami)}"
  TARGET_NAMES=("openbao-${DROPLET_USER}")
fi

# =============================================================
# Bestätigung
# =============================================================
echo ""
echo "Folgende Droplets werden gelöscht:"
for name in "${TARGET_NAMES[@]}"; do
  DOMAIN_LABEL="${name#openbao-}"
  echo "  - $name  (DNS: openbao.${DOMAIN_LABEL}.${BASE_DOMAIN})"
done
echo ""
read -rp "Wirklich löschen? [y/N] " CONFIRM
if [[ "${CONFIRM,,}" != "y" ]]; then
  echo "Abgebrochen."
  exit 0
fi

# =============================================================
# Löschen – parallel
# =============================================================
declare -A DELETE_PIDS
declare -A DELETE_STATUS

delete_one() {
  local droplet_name="$1"
  local user_label="${droplet_name#openbao-}"
  local result_file="/tmp/destroy-${user_label}.result"

  # Droplet suchen
  local droplet_id
  droplet_id=$(doctl compute droplet list --format Name,ID --no-header \
    | awk -v h="$droplet_name" '$1 == h {print $2}' | head -1 || true)

  if [[ -z "$droplet_id" ]]; then
    echo "NOT_FOUND" > "$result_file"
    return 0
  fi

  local errors=0

  # Droplet löschen
  if doctl compute droplet delete "$droplet_id" --force 2>/dev/null; then
    echo "droplet_ok" >> "$result_file"
  else
    echo "droplet_err" >> "$result_file"
    errors=$((errors + 1))
  fi

  # DNS-Records werden NICHT gelöscht (laut PRD)

  if [[ $errors -eq 0 ]]; then
    echo "SUCCESS" >> "$result_file"
  else
    echo "ERROR" >> "$result_file"
  fi
}

echo ""
echo "Lösche Droplets..."

# Temporäre Result-Dateien leeren
for name in "${TARGET_NAMES[@]}"; do
  user_label="${name#openbao-}"
  rm -f "/tmp/destroy-${user_label}.result"
done

# Parallel starten
for name in "${TARGET_NAMES[@]}"; do
  user_label="${name#openbao-}"
  delete_one "$name" &
  DELETE_PIDS[$name]=$!
done

# Auf alle Jobs warten
for name in "${TARGET_NAMES[@]}"; do
  user_label="${name#openbao-}"
  wait "${DELETE_PIDS[$name]}" 2>/dev/null || true
  RESULT_FILE="/tmp/destroy-${user_label}.result"
  if [[ -f "$RESULT_FILE" ]]; then
    DELETE_STATUS[$name]=$(cat "$RESULT_FILE")
  else
    DELETE_STATUS[$name]="ERROR"
  fi
done

# =============================================================
# Übersicht ausgeben
# =============================================================
echo ""
echo "══════════════════════════════════════════════════"
echo "         DESTROY-ÜBERSICHT"
echo "══════════════════════════════════════════════════"

OVERALL_EXIT=0

for name in "${TARGET_NAMES[@]}"; do
  user_label="${name#openbao-}"
  status="${DELETE_STATUS[$name]}"

  if echo "$status" | grep -q "NOT_FOUND"; then
    echo "  $user_label  ✗  Droplet nicht gefunden (bereits gelöscht?)"
  elif echo "$status" | grep -q "SUCCESS"; then
    echo "  $user_label  ✓  Droplet gelöscht"
  else
    echo "  $user_label  ✗  Fehler beim Löschen – Logs: /tmp/destroy-${user_label}.result"
    OVERALL_EXIT=1
  fi
done

echo "══════════════════════════════════════════════════"

exit $OVERALL_EXIT
