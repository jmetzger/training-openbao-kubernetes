# Übung: SSH Public Keys mit OpenBao verteilen (mit Gruppen)

## Übersicht 

![](/images/public-keys-deploy-linux-openbao.svg)

## Voraussetzung: kv2 muss aktiviert sein 

```
# Falls nicht....
bao secrets enable -path=secret kv-v2
```


## Szenario

Jeder Teilnehmer speichert seinen SSH Public Key in OpenBao. Über **Servergruppen** wird definiert, welche Teilnehmer Zugriff auf welche Server bekommen. Beim Ausrollen eines neuen Servers werden automatisch alle Public Keys der Gruppenmitglieder deployed.

**OpenBao-Server:** `https://openbao.jmetzger.do.t3isp.de:8200`

### Datenmodell

```
secret/ssh/tln1                  ← Public Key von tln1
secret/ssh/tln2                  ← Public Key von tln2
secret/ssh/tln3                  ← Public Key von tln3
secret/ssh-groups/webservers     ← Gruppe: members = "tln1,tln2,tln3"
secret/ssh-groups/dbservers      ← Gruppe: members = "tln1,tln2"
```

---

## Vorbereitung: Login

```bash
export BAO_ADDR="https://openbao.jmetzger.do.t3isp.de:8200"

# passwort findest du hier für diesen user (für das training)
# Ansonsten bitte nich speichern
# cat /tmp/bao.json 
bao login -method=userpass username=admin 
```

---

## 1. SSH-Schlüssel erstellen und in OpenBao speichern

Jeder Teilnehmer:

```
# das muss do anpassen 
TN=1
```

```bash
# Schlüsselpaar erzeugen
ssh-keygen -t ed25519 -C "tln$TN@training" -f ~/.ssh/id_training -N ""
```

```
# Public Key in OpenBao ablegen
bao kv put secret/ssh/tln$TN \
  public_key=@$HOME/.ssh/id_training.pub \
  owner="tln$TN" \
  created="$(date -I)"
```

### Prüfen

```bash
bao kv get -field=public_key secret/ssh/tln$TN
```

---

## 2. Servergruppen anlegen (Trainer)

```bash
# Gruppe "webservers" — alle Teilnehmer
bao kv put secret/ssh-groups/webservers \
  members="tln1,tln2,tln3,tln4,tln5,tln6" \
  description="Alle Webserver"

# Gruppe "dbservers" — nur ausgewählte Teilnehmer
bao kv put secret/ssh-groups/dbservers \
  members="tln1,tln2" \
  description="Datenbank-Server"
```

### Prüfen

```bash
bao kv get secret/ssh-groups/webservers
bao kv get -field=members secret/ssh-groups/webservers
```

---

## 3. Policies

```bash
# Alle dürfen SSH-Keys lesen (für das Bootstrap-Token)
bao policy write ssh-group-readonly - <<'EOF'
path "secret/data/ssh/*" {
  capabilities = ["read"]
}
path "secret/data/ssh-groups/*" {
  capabilities = ["read"]
}
EOF
```

```
# ich muss mir selbst diese policy als admin noch zuweisen,
# cat /tmp/bao.json  <- hier steht auch das root-token 
# das geht nur als root
bao login
# Welche policies habe ich aktuell 
# default 
bao token lookup
# policies hinzufügen
bao write auth/userpass/users/admin policies="default,ssh-group-readonly" 
```

```
# Jetzt wieder als normaler Benutzer anmelden
# cat /tmp/bao.json # hier ist das passwort fürs Training 
bao login -method=userpass username=admin
```

---

## 4. Bootstrap-Token erstellen

Das Token muss genug Uses haben: 1 (Auth) + 1 (Gruppe lesen) + N (Keys der Mitglieder).

```bash
# Beispiel: Gruppe mit 5 Mitgliedern → use-limit = 7 (1 + 1 + 5)
bao token create \
  -policy=ssh-group-readonly \
  -use-limit=8 \
  -ttl=30m \
  -display-name="bootstrap-webserver-neu"
```

---

## 5. Bootstrap-Script: Deployment auf dem Zielrechner

Das Script liest die Mitgliederliste einer Gruppe aus OpenBao und deployed alle zugehörigen Public Keys in die `authorized_keys` des aktuellen Users.

### Schritt für Schritt: Deployment durchführen und testen

**Schritt 1: Per SSH auf den Zielserver verbinden**

```bash
ssh tln<tln-nr>@linux-server.do.t3isp.de
```

**Schritt 2: Bootstrap-Script anlegen**

```bash
cat > bootstrap-ssh.sh << 'SCRIPT'
#!/bin/bash
set -euo pipefail

### --- Konfiguration ---
BAO_ADDR="https://openbao.jmetzger.do.t3isp.de:8200"
: "${BAO_TOKEN:?Fehler: BAO_TOKEN ist nicht gesetzt. Export: export BAO_TOKEN=hvs.xxx}"
GROUP="${1:?Usage: $0 <GRUPPENNAME> [TARGET_USER]}"
TARGET_USER="${2:-$(whoami)}"

### --- Setup ---
export BAO_ADDR

SSH_DIR="/home/${TARGET_USER}/.ssh"
AUTH_KEYS="${SSH_DIR}/authorized_keys"

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"
touch "$AUTH_KEYS"

### --- Gruppenmitglieder aus OpenBao lesen ---
echo "Lese Gruppe: ${GROUP} ..."
MEMBERS=$(bao kv get -field=members "secret/ssh-groups/${GROUP}") || {
  echo "FEHLER: Gruppe '${GROUP}' nicht gefunden!"
  exit 1
}

echo "Mitglieder: ${MEMBERS}"

### --- Keys aller Mitglieder holen ---
ADDED=0
IFS=',' read -ra MEMBER_LIST <<< "$MEMBERS"

for MEMBER in "${MEMBER_LIST[@]}"; do
  MEMBER=$(echo "$MEMBER" | xargs)
  echo "Hole Key von ${MEMBER} ..."

  PUBLIC_KEY=$(bao kv get -field=public_key "secret/ssh/${MEMBER}" 2>/dev/null) || {
    echo "  WARN: Key für ${MEMBER} nicht gefunden, überspringe."
    continue
  }

  if ! grep -qF "$PUBLIC_KEY" "$AUTH_KEYS"; then
    echo "$PUBLIC_KEY" >> "$AUTH_KEYS"
    echo "  -> hinzugefügt"
    ((ADDED++))
  else
    echo "  -> bereits vorhanden"
  fi
done

chmod 600 "$AUTH_KEYS"

echo ""
echo "Fertig. ${ADDED} neue Keys hinzugefügt."
echo "Gesamt: $(grep -c '' "$AUTH_KEYS") Key(s) in ${AUTH_KEYS}"

unset BAO_TOKEN
SCRIPT
```

**Schritt 3: Rechte setzen**

```bash
chmod +x bootstrap-ssh.sh
```

**Schritt 4: Token setzen und Script ausführen**

```bash
export BAO_TOKEN="hvs.CAESIGxyz..."
./bootstrap-ssh.sh webservers
```

**Schritt 5: Prüfen ob die Keys da sind**

```bash
cat ~/.ssh/authorized_keys
```

**Schritt 6: Vom Server abmelden**

```bash
exit
```

**Schritt 7: Verbindung mit SSH-Key testen**

```bash
# Jetzt sollte der Login ohne Passwort funktionieren:
ssh -i ~/.ssh/id_training tln<tln-nr>@linux-server.do.t3isp.de
```

> **Ergebnis:** Wenn alles korrekt ist, wirst du ohne Passwortabfrage eingeloggt.

---

## 6. Beispiel: Ansible

```yaml
# playbook-ssh-group.yml
# Ausführen:
#   ansible-playbook -i zielrechner.example.com, \
#     -e "bao_token=hvs.xxx" \
#     -e "group=webservers" \
#     playbook-ssh-group.yml
---
- name: SSH Keys einer OpenBao-Gruppe ausrollen
  hosts: all
  become: true
  vars:
    bao_addr: "https://openbao.jmetzger.do.t3isp.de:8200"
    group: "webservers"
    target_user: "root"

  tasks:
    # Schritt 1: Mitgliederliste der Gruppe aus OpenBao holen
    - name: Gruppenmitglieder lesen
      ansible.builtin.uri:
        url: "{{ bao_addr }}/v1/secret/data/ssh-groups/{{ group }}"
        headers:
          X-Vault-Token: "{{ bao_token }}"
        return_content: true
      register: group_result
      delegate_to: localhost

    - name: Mitgliederliste parsen
      ansible.builtin.set_fact:
        members: "{{ group_result.json.data.data.members.split(',') | map('trim') | list }}"

    - name: Mitglieder anzeigen
      ansible.builtin.debug:
        msg: "Gruppe {{ group }}: {{ members }}"

    # Schritt 2: Public Key jedes Mitglieds holen
    - name: SSH Keys aus OpenBao lesen
      ansible.builtin.uri:
        url: "{{ bao_addr }}/v1/secret/data/ssh/{{ item }}"
        headers:
          X-Vault-Token: "{{ bao_token }}"
        return_content: true
      register: bao_keys
      loop: "{{ members }}"
      delegate_to: localhost

    # Schritt 3: Keys auf dem Zielrechner deployen
    - name: authorized_keys befüllen
      ansible.posix.authorized_key:
        user: "{{ target_user }}"
        key: "{{ item.json.data.data.public_key }}"
        state: present
      loop: "{{ bao_keys.results }}"
      when: item.status == 200
```

---

## 7. Beispiel: cloud-init (Bash-Format)

```bash
#!/bin/bash
# cloud-init User Data - Alle Keys einer OpenBao-Gruppe deployen
set -euo pipefail

BAO_ADDR="https://openbao.jmetzger.do.t3isp.de:8200"
BAO_TOKEN="hvs.CAESIGxyz_EINMAL_TOKEN_HIER"
GROUP="webservers"
TARGET_USER="root"

SSH_DIR="/root/.ssh"
AUTH_KEYS="${SSH_DIR}/authorized_keys"
mkdir -p "$SSH_DIR" && chmod 700 "$SSH_DIR"

# Schritt 1: Mitgliederliste der Gruppe holen
MEMBERS=$(curl -sf \
  -H "X-Vault-Token: ${BAO_TOKEN}" \
  "${BAO_ADDR}/v1/secret/data/ssh-groups/${GROUP}" \
  | jq -r '.data.data.members')

# Schritt 2: Keys aller Mitglieder holen
IFS=',' read -ra MEMBER_LIST <<< "$MEMBERS"
for MEMBER in "${MEMBER_LIST[@]}"; do
  MEMBER=$(echo "$MEMBER" | xargs)
  PUBLIC_KEY=$(curl -sf \
    -H "X-Vault-Token: ${BAO_TOKEN}" \
    "${BAO_ADDR}/v1/secret/data/ssh/${MEMBER}" \
    | jq -r '.data.data.public_key') || continue

  grep -qF "$PUBLIC_KEY" "$AUTH_KEYS" 2>/dev/null || echo "$PUBLIC_KEY" >> "$AUTH_KEYS"
done

chmod 600 "$AUTH_KEYS"
echo "SSH-Keys der Gruppe ${GROUP} deployed (${#MEMBER_LIST[@]} Mitglieder)." | logger -t bootstrap-ssh
```

---

## Zusammenfassung

| Aspekt | Wert |
|---|---|
| **OpenBao-Server** | `https://openbao.jmetzger.do.t3isp.de:8200` |
| **Key-Pfad** | `secret/ssh/tln<tln-nr>` |
| **Gruppen-Pfad** | `secret/ssh-groups/<GRUPPENNAME>` |
| **Zuordnung** | `members`-Feld als kommaseparierte Liste |
| **use-limit Formel** | `1 (Auth) + 1 (Gruppe) + N (Mitglieder)` |
| **Bootstrap** | Script, Ansible, cloud-init — alle gruppenbasiert |

### Ablauf im Überblick

```
1. Teilnehmer speichert Key    →  secret/ssh/tln1
2. Trainer definiert Gruppe     →  secret/ssh-groups/webservers { members: "tln1,tln2,..." }
3. Token erstellen              →  use-limit = 1 + 1 + Anzahl_Mitglieder
4. Neuer Server bootstrapped    →  Script liest Gruppe → holt alle Keys → authorized_keys
```
