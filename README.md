# OpenBao & Kubernetes

## Agenda

  1. Bereitstellen der Openbao-Server (durch Trainer erledigt)
     * **Server bereitstellen:** `./install-openbao-single.sh` oder `./install-openbao-single.sh <N>]`
  -  * [Server löschen](docs/destroy-openbao-single.md)

  1. OpenBao Grundlagen
     * [Architektur-Überblick](openbao/overview.md)
     * [Was ist OpenBao?](openbao/what-is-openbao.md)
     * [Was sind secret-engines?](openbao/secret-engines.md)

  1. OpenBao Installation
     * [Standalone – .deb-Paket hinter nginx Reverse Proxy](openbao/installation/standalone.md)
    
  1. OpenBao Konfiguration
     * [User für Passwort-Authentifizierung als Admin-Nutzer in Gruppe aufsetzen](openbao/configuration/01-setup-userpass-for-user-with-group.md)
     * [MariaDB Deployment mit OpenBao & Vault Secrets Operator (VSO)](openbao/configuration/02-kubernetes-to-openbao-vso-secrets.md)
   
## Backlog 

  1. OpenBao Grundlagen 
     * [OpenBao vs. HashiCorp Vault](openbao/openbao-vs-vault.md)
     * [Seal / Unseal Mechanismus](openbao/seal-unseal.md)
     * [Auth Methods](openbao/auth-methods.md)
     * [Secrets Engines](openbao/secrets-engines.md)

  2. OpenBao auf Kubernetes deployen
     * [Konfiguration (HA + Raft)](openbao/config-ha-raft.md)
     * [Initialisierung und Unseal](openbao/init-unseal.md)
     * [Auto Unseal mit Transit](openbao/auto-unseal.md)

  3. Kubernetes-Integration
     * [Kubernetes Auth Method](openbao/kubernetes-auth.md)
     * [ServiceAccount-basierter Zugriff](openbao/serviceaccount-access.md)
     * [Secrets in Pods injizieren (Agent Injector)](openbao/agent-injector.md)
     * [Secrets Sync mit External Secrets Operator](openbao/external-secrets.md)

  4. Secrets Engines im Detail
     * [KV v2 – Key/Value Secrets](openbao/kv-v2.md)
     * [PKI – Zertifikate ausstellen](openbao/pki.md)
     * [Database – dynamische Credentials](openbao/database.md)
     * [Transit – Encryption as a Service](openbao/transit.md)

  5. Policies und Zugriffskontrolle
     * [ACL Policies](openbao/policies.md)
     * [Token-Management](openbao/tokens.md)
     * [Namespaces](openbao/namespaces.md)

  6. Betrieb und Monitoring
     * [Audit Logging](openbao/audit-logging.md)
     * [Backup und Restore (Raft Snapshots)](openbao/backup-restore.md)
     * [Monitoring mit Prometheus](openbao/monitoring.md)
     * [Upgrade-Strategie](openbao/upgrade.md)
