# OpenBao – Architektur-Überblick

OpenBao ist ein Open-Source Fork von HashiCorp Vault (MPL 2.0 Lizenz) zur zentralen Verwaltung von Secrets, Zertifikaten und Verschlüsselungskeys. Hier ein pragmatischer Überblick, wie das Ding unter der Haube funktioniert.

---

## Kernkonzept: Die Barrier

OpenBao verschlüsselt **alles**, bevor es auf die Platte geschrieben wird. Die sogenannte *Barrier* (Verschlüsselungsschicht) trennt die vertrauenswürdige Innenwelt von OpenBao vom untrusted Storage Backend.

> **Faustregel:** Wer Zugriff auf das Storage Backend hat, sieht nur verschlüsselte Blobs – niemals Klartext.

```mermaid
graph LR
    Client -->|API Request| Server[OpenBao Server]
    Server -->|Encrypt/Decrypt| Barrier[🔐 Barrier]
    Barrier -->|Encrypted Data| Storage[(Storage Backend)]

    style Barrier fill:#e74c3c,color:#fff
    style Server fill:#3498db,color:#fff
    style Storage fill:#95a5a6,color:#fff
```

---

## Hauptkomponenten

```mermaid
graph TB
    subgraph "OpenBao Server"
        direction TB
        API[HTTP API] --> Core[Core]
        Core --> TokenStore[Token Store]
        Core --> PolicyStore[Policy Store]
        Core --> AuthMethods[Auth Methods]
        Core --> SecretsEngines[Secrets Engines]
        Core --> AuditDevices[Audit Devices]
        Core --> Barrier[🔐 Barrier]
    end

    AuthMethods -.- am1[LDAP]
    AuthMethods -.- am2[Kubernetes]
    AuthMethods -.- am3[AppRole]
    AuthMethods -.- am4[OIDC/JWT]

    SecretsEngines -.- se1[KV v2]
    SecretsEngines -.- se2[PKI]
    SecretsEngines -.- se3[Transit]
    SecretsEngines -.- se4[SSH]
    SecretsEngines -.- se5[Database]

    Barrier --> Storage[(Raft / Storage)]

    style Barrier fill:#e74c3c,color:#fff
    style Core fill:#3498db,color:#fff
```

| Komponente | Was macht das? |
|---|---|
| **Core** | Zentrale Steuerung – nimmt Requests entgegen, prüft Policies, leitet an die richtige Engine weiter |
| **Barrier** | Ver-/Entschlüsselung aller Daten vor dem Schreiben ins Storage |
| **Token Store** | Verwaltet Tokens nach erfolgreicher Authentifizierung (inkl. Policies, TTLs, Renewals) |
| **Policy Store** | Speichert ACL-Policies (deny-by-default, pfadbasiert) |
| **Auth Methods** | Pluggable Authentifizierung – wer bist du? (z.B. Kubernetes, OIDC, AppRole, LDAP) |
| **Secrets Engines** | Pluggable Backends, gemountet auf Pfaden – hier liegen/entstehen die eigentlichen Secrets |
| **Audit Devices** | Logging jedes einzelnen Requests (wer hat wann was gemacht?) |

---

## Request-Lebenszyklus

So läuft ein typischer Request durch OpenBao:

```mermaid
sequenceDiagram
    participant C as Client
    participant A as Auth Method
    participant S as OpenBao Server
    participant P as Policy Store
    participant E as Secrets Engine
    participant B as Barrier/Storage

    C->>S: 1. Login (Credentials)
    S->>A: 2. Authentifizierung prüfen
    A-->>S: ✅ Identity + Policies
    S-->>C: 3. Token zurück

    C->>S: 4. Request mit Token (z.B. GET /secret/data/myapp)
    S->>P: 5. Policies prüfen (hat der Token Zugriff?)
    P-->>S: ✅ Erlaubt
    S->>E: 6. Secrets Engine abfragen
    E->>B: 7. Daten lesen (entschlüsseln)
    B-->>E: Klartext-Daten
    E-->>S: Secret-Daten
    S-->>C: 8. Response mit Secret
```

---

## Seal / Unseal Mechanismus

OpenBao startet im **Sealed**-Zustand – es kann nichts lesen oder schreiben. Erst durch das Unseal-Verfahren wird der Encryption Key im RAM verfügbar.

```mermaid
graph LR
    subgraph "Shamir's Secret Sharing"
        K1[🔑 Key Share 1]
        K2[🔑 Key Share 2]
        K3[🔑 Key Share 3]
        K4[🔑 Key Share 4]
        K5[🔑 Key Share 5]
    end

    K1 & K2 & K3 -->|3 von 5 reichen| RK[Root Key]
    RK -->|entschlüsselt| EK[Encryption Key]
    EK -->|im RAM| Unsealed[✅ Unsealed]

    style Unsealed fill:#27ae60,color:#fff
    style RK fill:#e74c3c,color:#fff
```

**Zwei Varianten:**

| Variante | Wie funktioniert's? |
|---|---|
| **Shamir Seal** | Root Key wird in N Teile gesplittet, M davon werden zum Unseal benötigt (z.B. 3 von 5) |
| **Auto Unseal** | Root Key wird durch ein externes KMS geschützt (z.B. AWS KMS, Azure Key Vault, Transit-Engine eines anderen OpenBao) – automatisches Unseal beim Start |

---

## HA-Cluster mit Integrated Storage (Raft)

Für Produktion läuft OpenBao als Cluster mit **Integrated Storage (Raft)**. Raft ist ein Konsensus-Protokoll – alle Daten werden automatisch zwischen den Nodes repliziert.

```mermaid
graph TB
    LB[Load Balancer] --> N1 & N2 & N3

    subgraph Cluster["3-Node Raft Cluster"]
        N1[🟢 Node 1<br/>LEADER<br/>aktiv]
        N2[🔵 Node 2<br/>STANDBY<br/>forwarded requests]
        N3[🔵 Node 3<br/>STANDBY<br/>forwarded requests]

        N1 <-->|Raft Replication| N2
        N1 <-->|Raft Replication| N3
        N2 <-->|Raft Replication| N3
    end

    style N1 fill:#27ae60,color:#fff
    style N2 fill:#3498db,color:#fff
    style N3 fill:#3498db,color:#fff
    style LB fill:#f39c12,color:#fff
```

**Wichtige Punkte:**

- **1 Leader** bearbeitet alle Schreiboperationen und repliziert an die Follower
- **Standby-Nodes** leiten Requests per Forwarding an den Leader weiter
- Ein 3-Node-Cluster toleriert den Ausfall von **1 Node** (Quorum: 2 von 3)
- Ein 5-Node-Cluster toleriert den Ausfall von **2 Nodes** (Quorum: 3 von 5)
- Netzwerk-Latenz zwischen Nodes sollte **< 8 ms** sein
- Performance ist primär durch **Disk I/O und Netzwerk-Latenz** begrenzt

---

## Ressourcen-Empfehlung pro Node (3-Node-Cluster)

OpenBao gibt keine eigenen Hardware-Empfehlungen, basiert aber architektonisch auf HashiCorp Vault. Die folgenden Werte orientieren sich an bewährten Praxiswerten:

| Sizing | CPU | RAM | Disk | Anmerkung |
|---|---|---|---|---|
| **Minimum** | 2 vCPUs | 4–8 GB | 20 GB SSD | Nur für Dev/Test oder sehr geringe Last |
| **Empfohlen (Produktion)** | 4 vCPUs | 8–16 GB | 50–100 GB SSD | Standard-Workload, bis zu ein paar hundert RPS |
| **Groß (High-Traffic)** | 8 vCPUs | 32 GB | 100+ GB SSD | Viele dynamische Secrets, Transit-Encryption, hoher Durchsatz |

### Hinweise

- **SSD ist Pflicht** – Raft mit BoltDB ist für SSDs optimiert. Spinning Disks führen zu massiven Performance-Einbrüchen
- **Burstable Instanzen vermeiden** (z.B. AWS `t2`/`t3`) – unter Dauerlast bricht die Performance ein
- **Audit-Logs** idealerweise auf eine **separate Disk** schreiben
- RAM-Verbrauch steigt mit der Anzahl aktiver Leases, Tokens und gemounteter Engines
- Für einen typischen **3-Node-Cluster in der Cloud**: 3× eine VM mit **4 vCPUs, 8 GB RAM, 50 GB SSD** ist ein solider Start

### Beispiel Cloud-Instanztypen

| Provider | Instanztyp | Specs |
|---|---|---|
| **AWS** | `m5.xlarge` | 4 vCPU, 16 GB RAM |
| **DigitalOcean** | `s-4vcpu-8gb` | 4 vCPU, 8 GB RAM |
| **Azure** | `Standard_D4s_v3` | 4 vCPU, 16 GB RAM |
| **GCP** | `e2-standard-4` | 4 vCPU, 16 GB RAM |
| **Hetzner** | `CPX31` | 4 vCPU, 8 GB RAM |

---

## Netzwerk-Ports

| Port | Protokoll | Zweck |
|---|---|---|
| `8200` | TCP | API & UI (Client-Zugriff) |
| `8201` | TCP | Cluster-Kommunikation (Raft, Request Forwarding) |

Beide Ports müssen zwischen den Cluster-Nodes erreichbar sein. Port `8200` wird zusätzlich für Clients / Load Balancer geöffnet.

---

## Zusammenfassung

```mermaid
graph TB
    subgraph "Was reinfliegt"
        Clients[Clients / Apps]
        K8s[Kubernetes Pods]
        CI[CI/CD Pipelines]
    end

    Clients & K8s & CI -->|HTTPS :8200| LB[Load Balancer]

    subgraph "OpenBao Cluster"
        LB --> Leader[Leader Node]
        Leader <-->|Raft :8201| S1[Standby 1]
        Leader <-->|Raft :8201| S2[Standby 2]
    end

    subgraph "Was rausfällt"
        Leader --> Secrets[Secrets]
        Leader --> Certs[Zertifikate]
        Leader --> DynCreds[Dynamische Credentials]
        Leader --> Encryption[Encryption as a Service]
    end

    style Leader fill:#27ae60,color:#fff
    style LB fill:#f39c12,color:#fff
```

**TL;DR:** OpenBao ist ein verschlüsselter Tresor für Secrets. Alles wird durch eine Barrier verschlüsselt, bevor es gespeichert wird. Authentication und Authorization sind strikt getrennt. Im HA-Modus läuft ein Raft-Cluster mit einem Leader und Standby-Nodes. Für einen produktiven 3-Node-Cluster reichen 3× 4 vCPUs, 8 GB RAM, 50 GB SSD als Startpunkt.
