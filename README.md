# OpenBao on Kubernetes Training

## Server verwalten

  - **Server bereitstellen:** `./install-openbao-single.sh` oder `./install-openbao-single.sh <N>`
  - **Server löschen:** [destroy-openbao-single.sh – Usage Guide](docs/destroy-openbao-single.md)

## Agenda

  1. OpenBao Grundlagen
     * [Architektur-Überblick](openbao/overview.md)
     * [Was ist OpenBao?](openbao/what-is-openbao.md)

  2. Installation
     * [Standalone – .deb-Paket hinter nginx Reverse Proxy](openbao/installation/standalone.md)
     * [Single Node – Debian + nginx Reverse Proxy](openbao/installation/single.md)
    
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
