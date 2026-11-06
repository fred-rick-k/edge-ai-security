# System Architecture

> **Document Purpose:** Structural overview of the edge device governance architecture. Outlines the runtime components, communication channels, and trust boundaries across the system.
>
> **Related Documents:**
> - Step-by-step cryptographic sequence diagrams: [`CREDENTIAL_ARCHITECTURE.md`](CREDENTIAL_ARCHITECTURE.md)
> - TPM enrollment and attestation sequence diagrams: [`TPM_ATTESTATION_ARCH.md`](TPM_ATTESTATION_ARCH.md)
> - Threat analysis and security register: [`THREAT_MODEL.md`](THREAT_MODEL.md)

---

## High-Level Topology

```mermaid
flowchart LR
    subgraph EDGE["Local Area Network"]
        CAM["RTSP Camera<br/>:554, password protected"]
    end

    subgraph JET["Jetson Edge Device — 8 GB Unified Memory"]
        TPM["Firmware TPM 2.0<br/>fTPM in OP-TEE<br/>/dev/tpmrm0"]

        subgraph SB["Sandbox: camera-agent<br/>network_mode=none, Landlock LSM"]
            AG["agent.py<br/>holds: placeholder key, frames, VLM text<br/>holds NOT: Vault token, RTSP URL, DB cred, DEK"]
        end

        subgraph HOST["Host Services (trusted, but OS user is root-equivalent)"]
            VA1["vault-agent<br/>edge role<br/>token: 0640 root:edge-ingest"]
            VA2["vault-agent-gateway<br/>gateway role<br/>token: 0640 root:jetson"]
            GW["OpenShell gateway + supervisor<br/>Vault credential driver<br/>providers: edge-ingest, cosmos-vlm"]
            TE["trusted-edge :8095<br/>User=edge-ingest<br/>holds in memory: RTSP URL, DEK, DB cred"]
            VLM["llama-server :8090<br/>Cosmos-Reason2-2B Q4_K_M<br/>5 GB memory cap, swap limit 0"]
            UI["WebUI :8443<br/>unauthenticated on LAN"]
        end
    end

    subgraph MAC["Control Plane Server (Docker)"]
        subgraph VAULT["HashiCorp Vault Enterprise — HTTPS :8200"]
            TPMAUTH["auth/tpm<br/>two roles, two policies"]
            APPROLE["auth/approle<br/>control-plane-reader<br/>Transit decrypt only"]
            TRANSIT["Transit<br/>edge-telemetry"]
            DBENG["Database engine<br/>5 min dynamic credentials"]
            KV["KV v2<br/>camera URL, ingest key hash,<br/>admin key hash, provider credentials"]
            AUDIT["File audit log"]
        end
        PG["PostgreSQL 16 :5432<br/>events: AES-GCM payload + wrapped DEK"]
    end

    %% identity
    TPM ==>|"attest (no bootstrap token)"| VA1
    TPM ==>|"attest (no bootstrap token)"| VA2
    VA1 ==>|"1 h token"| TPMAUTH
    VA2 ==>|"1 h token"| TPMAUTH
    VA1 -->|"token file"| TE
    VA2 -->|"token file"| GW
    VA1 -->|"template renders camera URL<br/>to tmpfs, LoadCredential="| UI

    %% camera
    CAM -->|"RTSP, not through sandbox"| TE
    CAM -->|"RTSP, direct preview"| UI

    %% sandbox
    AG -->|"GET /frame.jpg, POST /events<br/>(placeholder handle)"| GW
    AG -->|"POST /v1/chat/completions"| GW
    GW -->|"forwarded, real key injected"| TE
    GW -->|"forwarded"| VLM
    GW <-->|"provider credentials<br/>(Vault driver)"| KV

    %% trusted-edge
    TE <-->|"KV, Transit datakey, dynamic DB cred"| VAULT
    TE -->|"datakey/plaintext"| TRANSIT
    TE ==>|"INSERT encrypted rows"| PG
    DBENG ==>|"CREATE and DROP ROLE"| PG

    %% WebUI
    UI -->|"/admin/* with admin key"| TE
    UI -->|"manual inference"| VLM
    UI <-->|"AppRole login, Transit decrypt"| APPROLE
    APPROLE -->|"decrypt only"| TRANSIT
    UI -->|"SSH tail of audit log"| AUDIT
```

---

## System Components

| Component | Host Environment | Core Responsibility | Sensitive Material Held |
|---|---|---|---|
| **Firmware TPM 2.0** | Jetson (`/dev/tpmrm0`) | Proves device identity to Vault using Endorsement Key (EK) challenge-response | EK private key (isolated in hardware/OP-TEE) |
| **`vault-agent` (edge)** | Jetson (systemd) | Performs TPM attestation; writes and renews 1-hour token for `trusted-edge` | Edge-role Vault token (`0640 root:edge-ingest`) |
| **`vault-agent-gateway`** | Jetson (systemd) | Performs TPM attestation; writes and renews 1-hour token for OpenShell gateway | Gateway-role Vault token (`0640 root:jetson`) |
| **`trusted-edge.service`** | Jetson (`User=edge-ingest`) | Ingest pipeline daemon: captures RTSP frames, performs envelope encryption, and writes to PostgreSQL | RTSP URL, Data Encryption Key (DEK), Dynamic DB credentials (in volatile memory only) |
| **OpenShell Gateway & Supervisor** | Jetson (`User=jetson`) | Executes sandbox container, enforces Landlock filesystem policy and deny-by-default network policy, injects wire credentials | Provider credentials (fetched from Vault) |
| **Sandbox (`camera-agent`)** | Jetson (container) | Executes autonomous vision loop: fetches frames, requests VLM inference, evaluates motion/objects, posts events | Opaque provider handle, raw image frames, model text output (no credentials) |
| **`llama-server`** | Jetson (container) | Serves vision-language model (`Cosmos-Reason2-2B`) via OpenAI-compatible HTTP API | Vision-language model weights |
| **WebUI Dashboard** | Jetson (systemd) | Live operator dashboard: camera stream, jtop telemetry, Vault widgets, side-by-side audit view | Camera URL (`LoadCredential=`), Admin key, AppRole secret, Control plane SSH key |
| **HashiCorp Vault Enterprise** | Control Plane (Docker) | Manages identity (`auth/tpm`), dynamic database credentials, Transit encryption keys, and secrets KV engines | Master encryption keys, root database credentials |
| **PostgreSQL 16** | Control Plane (Docker) | Stores encrypted event records and encrypted datakey references | Ciphertext event records |

---

## Trust Boundaries & Isolation Guarantees

1. **Sandbox Isolation:** The autonomous agent runtime (`agent/agent.py`) is strictly quarantined inside an OpenShell container with `network_mode=none` and Landlock LSM filesystem constraints. Outbound socket creation is intercepted by the local supervisor; unapproved egress attempts are rejected at the network boundary.
2. **Host Privileges:** Host services on the edge device are trusted relative to the sandbox, but separated from one another via Linux user boundaries (`edge-ingest` vs `jetson`) and file modes (`0640`). As noted in [`THREAT_MODEL.md`](THREAT_MODEL.md), the `jetson` OS user possesses `sudo` and `docker` group membership.
3. **Control Plane Isolation:** The control plane host is trusted. Vault dynamically provisions least-privilege credentials and rotates the database superuser password upon initial configuration.
4. **Relationship to WebUI Architecture View:** The interactive SVG architecture tab in the live dashboard (`ui/static/arch-scene.js`) isolates and visualizes the core security and credential governance flows (TPM attestation, token renewal, provider credential injection, Landlock containment). The diagram in this document provides the comprehensive system topology, including auxiliary management channels (WebUI direct preview, manual inference triggers, and SSH audit log tailing).
